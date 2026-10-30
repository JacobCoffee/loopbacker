import Foundation

/// Lists installed JSFX effects by reading only their `desc:`/`tags:` header lines — never
/// compiling them (compiling, via `JSFXNode.load`, happens lazily when the user picks one).
///
/// JSFX scripts are plain text files, conventionally with no file extension, under REAPER's
/// `Effects` folder (REAPER's own stock scripts and anything installed through ReaPack) and
/// Loopbacker's own `JSFX` folder for user-dropped scripts. A script's header is always the
/// text before its first `@`-prefixed section (`@init`, `@sample`, ...); this scan never reads
/// past that point.
enum JSFXCatalog: FXPluginCatalog {
    /// Case-insensitive tag/description words that mark a generator or instrument rather than
    /// an audio effect — these need a MIDI/note source Loopbacker's voice chain doesn't have.
    private static let instrumentMarkers: Set<String> = [
        "instrument", "instruments", "synth", "synthesizer", "generator", "generators"
    ]

    /// Caps how much of a file is scanned for header lines; real JSFX headers are a handful of
    /// lines, so anything beyond this is either not a header or not a JSFX script at all.
    private static let headerScanBytes = 16 * 1024

    static func scan() async -> [FXPluginInfo] {
        await Task.detached(priority: .utility) { () -> [FXPluginInfo] in
            var infos: [FXPluginInfo] = []
            var seenPaths = Set<String>()
            for root in roots() {
                for info in scanRoot(root) where seenPaths.insert(info.ref.identifier).inserted {
                    infos.append(info)
                }
            }
            return infos
        }.value
    }

    private static func roots() -> [URL] {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return [] }
        return [
            support.appendingPathComponent("REAPER/Effects", isDirectory: true),
            support.appendingPathComponent("Loopbacker/JSFX", isDirectory: true)
        ]
    }

    private static func scanRoot(_ root: URL) -> [FXPluginInfo] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var infos: [FXPluginInfo] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            guard let header = readHeader(of: url) else { continue }
            guard let desc = header.desc, !desc.isEmpty else { continue }

            let words = Set(header.tags.map { $0.lowercased() })
                .union(descWords(desc))
            if !words.isDisjoint(with: instrumentMarkers) { continue }

            let category = header.tags.first.map { $0.prefix(1).uppercased() + $0.dropFirst() }
                ?? url.deletingLastPathComponent().lastPathComponent

            infos.append(FXPluginInfo(
                ref: FXPluginRef(format: .jsfx, identifier: url.path, name: desc, vendor: nil),
                category: category,
                summary: desc
            ))
        }
        return infos
    }

    private static func descWords(_ desc: String) -> Set<String> {
        Set(desc.lowercased().split { !$0.isLetter })
            .map(String.init)
            .reduce(into: Set<String>()) { $0.insert($1) }
    }

    private struct Header {
        var desc: String?
        var tags: [String] = []
    }

    /// Reads at most `headerScanBytes` of `url`, stopping at the first `@`-prefixed section.
    private static func readHeader(of url: URL) -> Header? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let chunk = try? handle.read(upToCount: headerScanBytes),
              let text = String(data: chunk, encoding: .utf8) ?? String(data: chunk, encoding: .isoLatin1)
        else { return nil }

        var header = Header()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("@") { break }
            if line.hasPrefix("desc:") {
                let value = line.dropFirst("desc:".count).trimmingCharacters(in: .whitespaces)
                if header.desc == nil { header.desc = value }
            } else if line.hasPrefix("tags:") {
                let value = line.dropFirst("tags:".count)
                if header.tags.isEmpty {
                    header.tags = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                }
            }
        }
        return header
    }
}
