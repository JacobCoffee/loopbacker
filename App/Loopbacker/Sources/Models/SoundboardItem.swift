import AVFoundation
import Foundation

/// How a pad plays once triggered.
enum SoundboardPlayMode: String, Codable, CaseIterable, Identifiable {
    case oneShot, loop, holdToPlay
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .oneShot: "One-shot"
        case .loop: "Loop"
        case .holdToPlay: "Hold to play"
        }
    }
}

/// What a second trigger does while a pad (or an instance of it) is already playing.
enum SoundboardRetrigger: String, Codable, CaseIterable, Identifiable {
    /// Stop the current instance and start over (the pre-existing toggle behavior).
    case restart
    /// Start a new overlapping instance; the previous one keeps playing.
    case layer
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .restart: "Restart"
        case .layer: "Layer"
        }
    }
}

/// Where a pad's audio is sent.
enum SoundboardOutputTarget: String, Codable, CaseIterable, Identifiable {
    case virtualMicOnly
    case virtualMicAndSpeakers
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .virtualMicOnly: "Virtual mic only"
        case .virtualMicAndSpeakers: "Virtual mic + speakers"
        }
    }
}

struct SoundboardItem: Identifiable, Codable, Equatable {
    /// Common integrated-loudness target (LUFS) pads are matched to on import. Separate from
    /// `LoudnessTarget`'s user-facing mic presets: this is an internal, fixed reference so every
    /// pad in a board is comparable regardless of the user's current mic target.
    static let loudnessMatchTargetLUFS: Float = -16

    var id: UUID = UUID()
    var name: String
    var emoji: String = ""
    var fileBookmark: Data  // security-scoped bookmark for sandbox persistence
    var volume: Float = 1.0
    var sortIndex: Int = 0

    /// Trim start, in seconds from the top of the file.
    var trimStart: Double = 0
    /// Trim end, in seconds from the top of the file; `nil` plays to the end of the file.
    var trimEnd: Double? = nil
    var fadeInSeconds: Double = 0
    var fadeOutSeconds: Double = 0

    var playMode: SoundboardPlayMode = .oneShot
    /// Pads sharing a non-empty choke group stop each other when one starts (radio-style).
    var chokeGroup: String? = nil
    var retrigger: SoundboardRetrigger = .restart
    var outputTarget: SoundboardOutputTarget = .virtualMicAndSpeakers

    /// Gain offset (dB) applied on top of `volume` so this pad's integrated loudness matches
    /// `loudnessMatchTargetLUFS`. `nil` until measured (on import, or lazily on first play for
    /// pads saved before this existed).
    var loudnessGainOffsetDB: Float? = nil

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

    // Fields past `sortIndex` were added after the original soundboard.json shipped; decode them
    // with fallbacks so existing saved boards keep loading unchanged.
    private enum CodingKeys: String, CodingKey {
        case id, name, emoji, fileBookmark, volume, sortIndex
        case trimStart, trimEnd, fadeInSeconds, fadeOutSeconds
        case playMode, chokeGroup, retrigger, outputTarget, loudnessGainOffsetDB
    }

    init(
        id: UUID = UUID(), name: String, emoji: String = "", fileBookmark: Data, volume: Float = 1.0,
        sortIndex: Int = 0, trimStart: Double = 0, trimEnd: Double? = nil, fadeInSeconds: Double = 0,
        fadeOutSeconds: Double = 0, playMode: SoundboardPlayMode = .oneShot, chokeGroup: String? = nil,
        retrigger: SoundboardRetrigger = .restart, outputTarget: SoundboardOutputTarget = .virtualMicAndSpeakers,
        loudnessGainOffsetDB: Float? = nil
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.fileBookmark = fileBookmark
        self.volume = volume
        self.sortIndex = sortIndex
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.fadeInSeconds = fadeInSeconds
        self.fadeOutSeconds = fadeOutSeconds
        self.playMode = playMode
        self.chokeGroup = chokeGroup
        self.retrigger = retrigger
        self.outputTarget = outputTarget
        self.loudnessGainOffsetDB = loudnessGainOffsetDB
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        emoji = (try? container.decode(String.self, forKey: .emoji)) ?? ""
        fileBookmark = try container.decode(Data.self, forKey: .fileBookmark)
        volume = (try? container.decode(Float.self, forKey: .volume)) ?? 1.0
        sortIndex = (try? container.decode(Int.self, forKey: .sortIndex)) ?? 0
        trimStart = (try? container.decode(Double.self, forKey: .trimStart)) ?? 0
        trimEnd = try? container.decodeIfPresent(Double.self, forKey: .trimEnd)
        fadeInSeconds = (try? container.decode(Double.self, forKey: .fadeInSeconds)) ?? 0
        fadeOutSeconds = (try? container.decode(Double.self, forKey: .fadeOutSeconds)) ?? 0
        playMode = (try? container.decode(SoundboardPlayMode.self, forKey: .playMode)) ?? .oneShot
        chokeGroup = try? container.decodeIfPresent(String.self, forKey: .chokeGroup)
        retrigger = (try? container.decode(SoundboardRetrigger.self, forKey: .retrigger)) ?? .restart
        outputTarget = (try? container.decode(SoundboardOutputTarget.self, forKey: .outputTarget)) ?? .virtualMicAndSpeakers
        loudnessGainOffsetDB = try? container.decodeIfPresent(Float.self, forKey: .loudnessGainOffsetDB)
    }
}

// MARK: - Soundboard state (persistence + observable)

@MainActor
class SoundboardState: ObservableObject {
    @Published var items: [SoundboardItem] = []

    nonisolated private static let configURL: URL = {
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
            // Lazily measure loudness for pads saved before loudness matching existed, instead
            // of blocking launch on decoding every file up front.
            for item in items where item.loudnessGainOffsetDB == nil {
                state.measureLoudnessIfNeeded(for: item.id)
            }
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
        measureLoudnessIfNeeded(for: item.id)
    }

    /// Add all audio files from a folder — references them in-place (no copy)
    func addFolder(url: URL) {
        let extensions = Set(["mp3", "m4a", "wav", "aiff", "aif", "mp4", "caf", "flac"])
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return }

        let audioFiles = contents.filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var addedIDs: [UUID] = []
        for file in audioFiles {
            if let item = SoundboardItem.from(url: file, sortIndex: items.count) {
                items.append(item)
                addedIDs.append(item.id)
            }
        }
        save()
        for id in addedIDs { measureLoudnessIfNeeded(for: id) }
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func removeAll() {
        items.removeAll()
        save()
    }

    // MARK: - Loudness matching

    /// Measures a pad's integrated loudness off the main thread and stores a gain offset to
    /// `SoundboardItem.loudnessMatchTargetLUFS`, so pads mastered at different levels play back
    /// at matching perceived loudness. No-op if already measured or the file can't be resolved.
    func measureLoudnessIfNeeded(for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].loudnessGainOffsetDB == nil,
              let url = items[index].resolveURL()
        else { return }
        Task {
            guard let lufs = await SoundboardLoudnessMeasurer.shared.integratedLoudness(url: url), lufs.isFinite else { return }
            let offset = SoundboardItem.loudnessMatchTargetLUFS - lufs
            guard let i = items.firstIndex(where: { $0.id == id }) else { return }
            items[i].loudnessGainOffsetDB = offset
            save()
        }
    }
}

/// Decodes and measures whole files off the main actor, so the soundboard's loudness matching
/// never blocks the UI.
private actor SoundboardLoudnessMeasurer {
    static let shared = SoundboardLoudnessMeasurer()

    /// Offline integrated loudness (ITU-R BS.1770-4) of a file, in LUFS.
    func integratedLoudness(url: URL) -> Float? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }
        guard let channelData = buffer.floatChannelData else { return nil }
        let channels = Int(format.channelCount)
        let frames = Int(buffer.frameLength)
        guard channels > 0, frames > 0 else { return nil }

        var interleaved = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            for ch in 0..<channels {
                interleaved[frame * channels + ch] = channelData[ch][frame]
            }
        }
        return interleaved.withUnsafeBufferPointer {
            LoudnessMeter.integratedLoudness(
                samples: $0.baseAddress!, frames: frames, channels: channels, sampleRate: format.sampleRate
            )
        }
    }
}
