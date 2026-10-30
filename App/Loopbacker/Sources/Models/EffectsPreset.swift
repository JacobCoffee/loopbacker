import Foundation

// MARK: - App-capture processing

/// What makes `AppAudioFX` duck app-capture audio: the user's own mic (original, default
/// behavior -- existing presets decode to this unchanged), the far-end voices of people in a
/// call (`CallVoiceBus`, published by `CallAudioMonitor`), or both. Shared with
/// `ListenDuckSettings` (Part B, "duck what I hear"), whose picker only ever shows
/// `.callVoices`/`.both` since ducking your own output while nobody else is talking has no
/// use case there.
enum CallDuckTrigger: String, Codable, CaseIterable, Sendable {
    case myVoice
    case callVoices
    case both

    var dependsOnMyVoice: Bool { self == .myVoice || self == .both }
    var dependsOnCallVoices: Bool { self == .callVoices || self == .both }
}

/// Ducking and leveling applied to app-capture routes (game, music, browser), separate from the
/// voice chain's `nodes`: app captures never run the voice chain (see
/// `RouteContext.isVoiceInput`). Owned by `AppAudioProcessor` on each app-capture route.
struct AppAudioFX: Codable, Equatable {
    var duckingEnabled = false
    /// How far app audio is pulled down while the trigger is active.
    var duckAmountDB: Float = -12
    var duckAttackMs: Float = 40
    var duckReleaseMs: Float = 600
    /// What counts as "someone's talking": the user's own mic (default, matches every preset
    /// saved before this existed), far-end call voices, or both. `CallDuckTrigger.myVoice` is
    /// exactly the old (only) behavior, so old presets and the factory presets below are
    /// unaffected until a user opts in.
    var trigger: CallDuckTrigger = .myVoice
    var levelerEnabled = false
    /// Target loudness (LUFS) the leveler holds app audio at.
    var levelerTarget: Float = -20

    static let duckAmountRange: ClosedRange<Float> = -30...0

    private enum CodingKeys: String, CodingKey {
        case duckingEnabled, duckAmountDB, duckAttackMs, duckReleaseMs, trigger, levelerEnabled, levelerTarget
    }

    init() {}

    /// Tolerant decode: `trigger` didn't exist before this feature, so any JSON saved earlier
    /// (or by an older build re-importing a preset) is missing the key entirely. Falls back to
    /// `.myVoice`, preserving the exact ducking behavior those presets had.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        duckingEnabled = (try? c.decode(Bool.self, forKey: .duckingEnabled)) ?? false
        duckAmountDB = (try? c.decode(Float.self, forKey: .duckAmountDB)) ?? -12
        duckAttackMs = (try? c.decode(Float.self, forKey: .duckAttackMs)) ?? 40
        duckReleaseMs = (try? c.decode(Float.self, forKey: .duckReleaseMs)) ?? 600
        trigger = (try? c.decode(CallDuckTrigger.self, forKey: .trigger)) ?? .myVoice
        levelerEnabled = (try? c.decode(Bool.self, forKey: .levelerEnabled)) ?? false
        levelerTarget = (try? c.decode(Float.self, forKey: .levelerTarget)) ?? -20
    }
}

// MARK: - Effects Preset (v2: an ordered node graph)

/// The voice chain's configuration, as persisted in routing configs, scenes and exported
/// presets. v2 replaced the fixed 9-stage layout with an ordered `nodes` graph so stages can be
/// added, removed, reordered and hosted (Audio Unit / JSFX / Airwindows) effects inserted.
/// `init(from:)` migrates v1 JSON (flat `gateEnabled`/`gateThresholdDB`/... fields, no `nodes`
/// key) into an equivalent `nodes` array; v2 is always the encoded shape.
struct EffectsPreset: Codable, Equatable {
    var version = 2
    var isEnabled = false
    /// The chain, in processing order.
    var nodes: [FXNodeConfig]
    var appAudio = AppAudioFX()

    init(isEnabled: Bool = false, nodes: [FXNodeConfig] = EffectsPreset.defaultNodes, appAudio: AppAudioFX = AppAudioFX()) {
        self.isEnabled = isEnabled
        self.nodes = nodes
        self.appAudio = appAudio
    }

    /// Gate(Voice mode) → EQ(Broadcast) → Compressor → De-Esser → Limiter, the rest
    /// of the chain disabled-by-omission. Off by default until the user enables it.
    static let defaultNodes: [FXNodeConfig] = [
        FXNodeConfig(kind: .gate),
        FXNodeConfig(kind: .eq, eqBands: EQBandConfig.broadcast),
        FXNodeConfig(kind: .compressor),
        FXNodeConfig(kind: .deEsser),
        FXNodeConfig(kind: .limiter),
    ]

    // MARK: Decoding / v1 migration

    private enum CodingKeys: String, CodingKey {
        case version, isEnabled, nodes, appAudio
        // v1 (flat, no `nodes` key)
        case gateEnabled, gateThresholdDB, gateAttackMs, gateReleaseMs, gateReductionDB
        case eqEnabled, eqBands
        case compressorEnabled, compressorThresholdDB, compressorRatio, compressorAttackMs, compressorReleaseMs, compressorMakeupDB
        case deEsserEnabled, deEsserFrequencyHz, deEsserReductionDB
        case chorusEnabled, chorusRate, chorusDepth, chorusMix
        case pitchShiftEnabled, pitchSemitones, pitchMix
        case reverbEnabled, reverbRoomSize, reverbDamping, reverbMix
        case delayEnabled, delayTimeMs, delayFeedback, delayMix
        case limiterEnabled, limiterCeilingDB, limiterReleaseMs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? c.decode(Bool.self, forKey: .isEnabled)) ?? false

        if let nodes = try? c.decode([FXNodeConfig].self, forKey: .nodes) {
            version = (try? c.decode(Int.self, forKey: .version)) ?? 2
            self.nodes = nodes
            appAudio = (try? c.decode(AppAudioFX.self, forKey: .appAudio)) ?? AppAudioFX()
            return
        }

        // v1: flat fields, gate mode fixed to Level (its old, only behaviour).
        version = 2
        appAudio = AppAudioFX()

        func dec<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decode(T.self, forKey: key)) ?? fallback
        }

        nodes = Self.v2Nodes(
            gateEnabled: dec(.gateEnabled, true), gateMode: 0,
            gateThresholdDB: dec(.gateThresholdDB, -36), gateAttackMs: dec(.gateAttackMs, 5),
            gateReleaseMs: dec(.gateReleaseMs, 250), gateReductionDB: dec(.gateReductionDB, -12),
            eqEnabled: dec(.eqEnabled, true), eqBands: dec(.eqBands, EQBandConfig.broadcast),
            compressorEnabled: dec(.compressorEnabled, true), compressorThresholdDB: dec(.compressorThresholdDB, -18),
            compressorRatio: dec(.compressorRatio, 3), compressorAttackMs: dec(.compressorAttackMs, 15),
            compressorReleaseMs: dec(.compressorReleaseMs, 200), compressorMakeupDB: dec(.compressorMakeupDB, 3),
            deEsserEnabled: dec(.deEsserEnabled, true), deEsserFrequencyHz: dec(.deEsserFrequencyHz, 6000),
            deEsserReductionDB: dec(.deEsserReductionDB, -6),
            chorusEnabled: dec(.chorusEnabled, false), chorusRate: dec(.chorusRate, 0.8),
            chorusDepth: dec(.chorusDepth, 1.5), chorusMix: dec(.chorusMix, 0.3),
            pitchShiftEnabled: dec(.pitchShiftEnabled, false), pitchSemitones: dec(.pitchSemitones, 0),
            pitchMix: dec(.pitchMix, 1.0),
            reverbEnabled: dec(.reverbEnabled, false), reverbRoomSize: dec(.reverbRoomSize, 0.5),
            reverbDamping: dec(.reverbDamping, 0.5), reverbMix: dec(.reverbMix, 0.15),
            delayEnabled: dec(.delayEnabled, false), delayTimeMs: dec(.delayTimeMs, 250),
            delayFeedback: dec(.delayFeedback, 0.3), delayMix: dec(.delayMix, 0.25),
            limiterEnabled: dec(.limiterEnabled, true), limiterCeilingDB: dec(.limiterCeilingDB, -1.5),
            limiterReleaseMs: dec(.limiterReleaseMs, 50)
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(nodes, forKey: .nodes)
        try c.encode(appAudio, forKey: .appAudio)
    }

    // MARK: - v1-shaped node builder, shared by migration and the factory presets below

    // swiftlint:disable:next function_parameter_count
    private static func v2Nodes(
        gateEnabled: Bool = true, gateMode: Float = 0, gateThresholdDB: Float = -36, gateAttackMs: Float = 5,
        gateReleaseMs: Float = 250, gateReductionDB: Float = -12,
        eqEnabled: Bool = true, eqBands: [EQBandConfig] = EQBandConfig.broadcast,
        compressorEnabled: Bool = true, compressorThresholdDB: Float = -18, compressorRatio: Float = 3,
        compressorAttackMs: Float = 15, compressorReleaseMs: Float = 200, compressorMakeupDB: Float = 3,
        deEsserEnabled: Bool = true, deEsserFrequencyHz: Float = 6000, deEsserReductionDB: Float = -6,
        chorusEnabled: Bool = false, chorusRate: Float = 0.8, chorusDepth: Float = 1.5, chorusMix: Float = 0.3,
        pitchShiftEnabled: Bool = false, pitchSemitones: Float = 0, pitchMix: Float = 1.0,
        reverbEnabled: Bool = false, reverbRoomSize: Float = 0.5, reverbDamping: Float = 0.5, reverbMix: Float = 0.15,
        delayEnabled: Bool = false, delayTimeMs: Float = 250, delayFeedback: Float = 0.3, delayMix: Float = 0.25,
        limiterEnabled: Bool = true, limiterCeilingDB: Float = -1.5, limiterReleaseMs: Float = 50
    ) -> [FXNodeConfig] {
        [
            FXNodeConfig(kind: .gate, enabled: gateEnabled, params: [
                "mode": gateMode, "threshold": gateThresholdDB, "hysteresis": 0, "voiceSensitivity": 50,
                "attack": gateAttackMs, "hold": 0, "release": gateReleaseMs, "range": gateReductionDB,
                "keyHighPass": 80,
            ]),
            FXNodeConfig(kind: .eq, enabled: eqEnabled, params: ["outputGain": 0], eqBands: eqBands),
            FXNodeConfig(kind: .compressor, enabled: compressorEnabled, params: [
                "threshold": compressorThresholdDB, "ratio": compressorRatio, "knee": 0,
                "attack": compressorAttackMs, "release": compressorReleaseMs, "detector": 0,
                "makeup": compressorMakeupDB, "mix": 100,
            ]),
            FXNodeConfig(kind: .deEsser, enabled: deEsserEnabled, params: [
                "frequency": deEsserFrequencyHz, "threshold": -22, "range": -deEsserReductionDB, "mode": 0,
            ]),
            FXNodeConfig(kind: .chorus, enabled: chorusEnabled, params: [
                "rate": chorusRate, "depth": chorusDepth, "mix": chorusMix * 100,
            ]),
            FXNodeConfig(kind: .pitchShift, enabled: pitchShiftEnabled, params: [
                "semitones": pitchSemitones, "formant": 0, "preserveFormants": 1, "mix": pitchMix * 100,
            ]),
            FXNodeConfig(kind: .reverb, enabled: reverbEnabled, params: [
                "size": reverbRoomSize * 100, "damping": reverbDamping * 100, "preDelay": 0, "mix": reverbMix * 100,
            ]),
            FXNodeConfig(kind: .delay, enabled: delayEnabled, params: [
                "time": delayTimeMs, "feedback": delayFeedback * 100, "highCut": 8000, "mix": delayMix * 100,
            ]),
            FXNodeConfig(kind: .limiter, enabled: limiterEnabled, params: [
                "inputGain": 0, "ceiling": limiterCeilingDB, "release": limiterReleaseMs,
            ]),
        ]
    }

}

// MARK: - Effects Preset Manager (file-based, shareable)

struct EffectsPresetManager {
    private static let presetsDirectoryURL: URL =
        AppDataDirectory.url.appendingPathComponent("effects-presets", isDirectory: true)

    static func save(name: String, preset: EffectsPreset) {
        do {
            try FileManager.default.createDirectory(at: presetsDirectoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(preset)
            let fileURL = presetsDirectoryURL.appendingPathComponent(sanitizedFileName(name))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Loopbacker: failed to save effects preset '\(name)': \(error)")
        }
    }

    static func load(name: String) -> EffectsPreset? {
        let fileURL = presetsDirectoryURL.appendingPathComponent(sanitizedFileName(name))
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(EffectsPreset.self, from: data)
    }

    static func list() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: presetsDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "json" }
            .sorted { a, b in
                let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                return aDate > bDate
            }
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    static func delete(name: String) {
        let fileURL = presetsDirectoryURL.appendingPathComponent(sanitizedFileName(name))
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Export preset to a file URL (for sharing)
    static func exportData(preset: EffectsPreset) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(preset)
    }

    /// Limits rejecting untrusted import files before they reach the hosted-plugin loaders:
    /// a crafted preset otherwise costs a full parse/decode (or worse, a hosted node load) for
    /// an arbitrarily large file.
    static let maxImportFileSize = 4 * 1024 * 1024 // 4 MB
    static let maxImportNodeCount = 64
    static let maxImportPluginStateSize = 2 * 1024 * 1024 // 2 MB per node

    enum ImportError: Error, LocalizedError {
        case tooLarge(bytes: Int)
        case tooManyNodes(count: Int)
        case pluginStateTooLarge(nodeIndex: Int, bytes: Int)
        case invalidData

        var errorDescription: String? {
            switch self {
            case .tooLarge(let bytes):
                return "Preset file is \(bytes / 1024) KB; the maximum is "
                    + "\(EffectsPresetManager.maxImportFileSize / 1024) KB."
            case .tooManyNodes(let count):
                return "Preset has \(count) stages; the maximum is \(EffectsPresetManager.maxImportNodeCount)."
            case .pluginStateTooLarge(let nodeIndex, let bytes):
                return "Stage \(nodeIndex + 1)'s plugin state is \(bytes / (1024 * 1024)) MB; the maximum is "
                    + "\(EffectsPresetManager.maxImportPluginStateSize / (1024 * 1024)) MB."
            case .invalidData:
                return "That file isn't a valid Loopbacker effects preset."
            }
        }
    }

    /// Import preset from file data, rejecting oversized untrusted content before it reaches
    /// any hosted-plugin loader.
    static func importData(_ data: Data) -> Result<EffectsPreset, ImportError> {
        guard data.count <= maxImportFileSize else { return .failure(.tooLarge(bytes: data.count)) }
        guard let preset = try? JSONDecoder().decode(EffectsPreset.self, from: data) else {
            return .failure(.invalidData)
        }
        guard preset.nodes.count <= maxImportNodeCount else {
            return .failure(.tooManyNodes(count: preset.nodes.count))
        }
        for (index, node) in preset.nodes.enumerated() {
            if let stateSize = node.pluginState?.count, stateSize > maxImportPluginStateSize {
                return .failure(.pluginStateTooLarge(nodeIndex: index, bytes: stateSize))
            }
        }
        return .success(preset)
    }

    private static func sanitizedFileName(_ name: String) -> String {
        let safe = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(safe).json"
    }
}
