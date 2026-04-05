import Foundation

struct SoundboardItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var emoji: String = ""
    var fileBookmark: Data  // security-scoped bookmark for sandbox persistence
    var volume: Float = 1.0
    var sortIndex: Int = 0

    /// Resolve the bookmark back to a URL. Returns nil if the file moved/deleted.
    func resolveURL() -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: fileBookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return url
    }

    /// Create from a file URL (generates bookmark data)
    static func from(url: URL, name: String? = nil, sortIndex: Int = 0) -> SoundboardItem? {
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope) else { return nil }
        let displayName = name ?? url.deletingPathExtension().lastPathComponent
        return SoundboardItem(
            name: displayName,
            fileBookmark: bookmark,
            sortIndex: sortIndex
        )
    }
}

// MARK: - Soundboard state (persistence + observable)

class SoundboardState: ObservableObject {
    @Published var items: [SoundboardItem] = []

    private static let configURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Loopbacker", isDirectory: true)
        return dir.appendingPathComponent("soundboard.json")
    }()

    private static let saveQueue = DispatchQueue(label: "com.jacobcoffee.loopbacker.soundboard.save", qos: .utility)

    func save() {
        let snapshot = items
        Self.saveQueue.async {
            do {
                let dir = Self.configURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: Self.configURL, options: .atomic)
            } catch {
                print("Loopbacker: failed to save soundboard: \(error)")
            }
        }
    }

    static func load() -> SoundboardState {
        let state = SoundboardState()
        if let data = try? Data(contentsOf: configURL),
           let items = try? JSONDecoder().decode([SoundboardItem].self, from: data) {
            state.items = items
        }
        return state
    }

    private static let soundsDirectoryURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Loopbacker", isDirectory: true)
            .appendingPathComponent("sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Add a single file — copies it to app storage so the original can be deleted
    func addFile(url: URL) {
        let dest = Self.soundsDirectoryURL.appendingPathComponent(url.lastPathComponent)
        // Copy to app storage (skip if already there)
        if !FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.copyItem(at: url, to: dest)
        }
        guard let item = SoundboardItem.from(url: dest, sortIndex: items.count) else { return }
        items.append(item)
        save()
    }

    /// Add all audio files from a folder — references them in-place (no copy)
    func addFolder(url: URL) {
        let extensions = Set(["mp3", "m4a", "wav", "aiff", "aif", "mp4", "caf", "flac"])
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return }

        let audioFiles = contents.filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for file in audioFiles {
            if let item = SoundboardItem.from(url: file, sortIndex: items.count) {
                items.append(item)
            }
        }
        save()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func removeAll() {
        items.removeAll()
        save()
    }
}
