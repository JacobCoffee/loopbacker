import Foundation

// MARK: - App-capture processing

/// Ducking and leveling applied to app-capture routes (game, music, browser), separate from the
/// voice chain's `nodes`: app captures never run the voice chain (see
/// `RouteContext.isVoiceInput`). Owned by `AppAudioProcessor` on each app-capture route.
struct AppAudioFX: Codable, Equatable {
    var duckingEnabled = false
    /// How far app audio is pulled down while you're talking.
    var duckAmountDB: Float = -12
    var duckAttackMs: Float = 40
    var duckReleaseMs: Float = 600
    var levelerEnabled = false
    /// Target loudness (LUFS) the leveler holds app audio at.
    var levelerTarget: Float = -20

    static let duckAmountRange: ClosedRange<Float> = -30...0
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

    /// Gate(Voice mode) → EQ(Broadcast Masculine) → Compressor → De-Esser → Limiter, the rest
    /// of the chain disabled-by-omission. Off by default until the user enables it.
    static let defaultNodes: [FXNodeConfig] = [
        FXNodeConfig(kind: .gate),
        FXNodeConfig(kind: .eq, eqBands: EQBandConfig.broadcastMasculine),
        FXNodeConfig(kind: .compressor),
        FXNodeConfig(kind: .deEsser),
        FXNodeConfig(kind: .limiter),
    ]

    // MARK: Decoding / v1 migration

    private enum CodingKeys: String, CodingKey {
        case version, isEnabled, nodes, appAudio
        // v1 (flat, no `nodes` key)
        case gateEnabled, gateThresholdDB, gateAttackMs, gateReleaseMs, gateReductionDB
        case eqBands
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
            eqBands: dec(.eqBands, EQBandConfig.broadcastMasculine),
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
        eqBands: [EQBandConfig] = EQBandConfig.broadcastMasculine,
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
            FXNodeConfig(kind: .eq, enabled: true, params: ["outputGain": 0], eqBands: eqBands),
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

    // MARK: - Factory presets (re-expressed in v2; a later wave redesigns this list)

    static let broadcastVoice = EffectsPreset(isEnabled: true, nodes: v2Nodes())

    static let podcastClean = EffectsPreset(isEnabled: true, nodes: v2Nodes(
        gateThresholdDB: -40, gateReductionDB: -8,
        eqBands: [
            EQBandConfig(id: 0, type: .highpass, frequencyHz: 100, gainDB: 0, q: 0.707),
            EQBandConfig(id: 1, type: .peaking, frequencyHz: 250, gainDB: -1, q: 1.0),
            EQBandConfig(id: 2, type: .peaking, frequencyHz: 400, gainDB: 0, q: 1.0),
            EQBandConfig(id: 3, type: .peaking, frequencyHz: 3000, gainDB: 1.5, q: 1.0),
            EQBandConfig(id: 4, type: .highshelf, frequencyHz: 8000, gainDB: 1, q: 0.707),
        ],
        compressorThresholdDB: -20, compressorRatio: 2.5, compressorMakeupDB: 2,
        deEsserReductionDB: -4, limiterCeilingDB: -1.0
    ))

    static let heavyCompression = EffectsPreset(isEnabled: true, nodes: v2Nodes(
        gateThresholdDB: -30, gateReductionDB: -20,
        compressorThresholdDB: -24, compressorRatio: 6, compressorAttackMs: 5, compressorReleaseMs: 100,
        compressorMakeupDB: 6, limiterCeilingDB: -2.0
    ))

    static let minimal = EffectsPreset(isEnabled: true, nodes: v2Nodes(
        gateThresholdDB: -40, gateReductionDB: -10, deEsserEnabled: false, limiterCeilingDB: -1.0
    ))

    static let chipmunk = EffectsPreset(isEnabled: true, nodes: v2Nodes(
        gateEnabled: false, compressorEnabled: false, deEsserEnabled: false,
        pitchShiftEnabled: true, pitchSemitones: 12, pitchMix: 1.0, limiterCeilingDB: -1.0
    ))

    static let deepVoice = EffectsPreset(isEnabled: true, nodes: v2Nodes(
        gateThresholdDB: -40, gateReductionDB: -10,
        eqBands: [
            EQBandConfig(id: 0, type: .highpass, frequencyHz: 60, gainDB: 0, q: 0.7),
            EQBandConfig(id: 1, type: .peaking, frequencyHz: 150, gainDB: 3, q: 0.8),
            EQBandConfig(id: 2, type: .peaking, frequencyHz: 300, gainDB: 1, q: 1.0),
            EQBandConfig(id: 3, type: .peaking, frequencyHz: 3000, gainDB: -2, q: 1.0),
            EQBandConfig(id: 4, type: .highshelf, frequencyHz: 8000, gainDB: -3, q: 0.7),
        ],
        compressorThresholdDB: -20, compressorRatio: 3.0, compressorMakeupDB: 2.0,
        deEsserEnabled: false, pitchShiftEnabled: true, pitchSemitones: -5, pitchMix: 1.0, limiterCeilingDB: -1.5
    ))

    static let robot = EffectsPreset(isEnabled: true, nodes: v2Nodes(
        gateEnabled: false, compressorEnabled: false, deEsserEnabled: false,
        chorusEnabled: true, chorusRate: 5.0, chorusDepth: 0.5, chorusMix: 0.7,
        pitchShiftEnabled: true, pitchSemitones: -7, pitchMix: 0.8,
        reverbEnabled: true, reverbRoomSize: 0.2, reverbDamping: 0.9, reverbMix: 0.3, limiterCeilingDB: -1.0
    ))

    static let cathedral = EffectsPreset(isEnabled: true, nodes: v2Nodes(
        gateThresholdDB: -45, gateReductionDB: -8,
        compressorThresholdDB: -22, compressorRatio: 2.5, compressorMakeupDB: 2.0,
        reverbEnabled: true, reverbRoomSize: 0.95, reverbDamping: 0.2, reverbMix: 0.35,
        delayEnabled: true, delayTimeMs: 120, delayFeedback: 0.25, delayMix: 0.1, limiterCeilingDB: -1.5
    ))

    static let radioAnnouncer = EffectsPreset(isEnabled: true, nodes: v2Nodes(
        gateThresholdDB: -32, gateReductionDB: -15,
        eqBands: [
            EQBandConfig(id: 0, type: .highpass, frequencyHz: 80, gainDB: 0, q: 0.7),
            EQBandConfig(id: 1, type: .peaking, frequencyHz: 180, gainDB: 3, q: 0.8),
            EQBandConfig(id: 2, type: .peaking, frequencyHz: 400, gainDB: -3, q: 1.2),
            EQBandConfig(id: 3, type: .peaking, frequencyHz: 3200, gainDB: 3, q: 0.9),
            EQBandConfig(id: 4, type: .highshelf, frequencyHz: 10000, gainDB: 2, q: 0.7),
        ],
        compressorThresholdDB: -16, compressorRatio: 5.0, compressorAttackMs: 10.0, compressorReleaseMs: 120.0,
        compressorMakeupDB: 5.0, deEsserReductionDB: -8,
        reverbEnabled: true, reverbRoomSize: 0.3, reverbDamping: 0.6, reverbMix: 0.06, limiterCeilingDB: -0.5
    ))

    static let dreamy = EffectsPreset(isEnabled: true, nodes: v2Nodes(
        gateEnabled: false, compressorEnabled: false, deEsserEnabled: false,
        chorusEnabled: true, chorusRate: 0.5, chorusDepth: 4.0, chorusMix: 0.5,
        reverbEnabled: true, reverbRoomSize: 0.85, reverbDamping: 0.3, reverbMix: 0.4,
        delayEnabled: true, delayTimeMs: 400, delayFeedback: 0.4, delayMix: 0.15, limiterCeilingDB: -1.5
    ))

    static let telephone = EffectsPreset(isEnabled: true, nodes: v2Nodes(
        gateEnabled: false,
        eqBands: [
            EQBandConfig(id: 0, type: .highpass, frequencyHz: 300, gainDB: 0, q: 0.7),
            EQBandConfig(id: 1, type: .peaking, frequencyHz: 800, gainDB: 3, q: 0.8),
            EQBandConfig(id: 2, type: .peaking, frequencyHz: 2000, gainDB: 4, q: 1.0),
            EQBandConfig(id: 3, type: .peaking, frequencyHz: 3500, gainDB: -2, q: 1.0),
            EQBandConfig(id: 4, type: .highshelf, frequencyHz: 4000, gainDB: -12, q: 0.7),
        ],
        compressorThresholdDB: -15, compressorRatio: 8.0, compressorMakeupDB: 4.0,
        deEsserEnabled: false, limiterCeilingDB: -2.0
    ))

    static let spaceStation = EffectsPreset(isEnabled: true, nodes: v2Nodes(
        gateEnabled: false, compressorEnabled: false, deEsserEnabled: false,
        chorusEnabled: true, chorusRate: 2.5, chorusDepth: 3.0, chorusMix: 0.6,
        pitchShiftEnabled: true, pitchSemitones: -3, pitchMix: 0.7,
        reverbEnabled: true, reverbRoomSize: 0.9, reverbDamping: 0.15, reverbMix: 0.45,
        delayEnabled: true, delayTimeMs: 300, delayFeedback: 0.5, delayMix: 0.2, limiterCeilingDB: -1.0
    ))

    static let factoryPresets: [(name: String, preset: EffectsPreset)] = [
        ("Broadcast Masculine Voice", .broadcastVoice),
        ("Podcast Clean", .podcastClean),
        ("Radio Announcer", .radioAnnouncer),
        ("Heavy Compression", .heavyCompression),
        ("Minimal (Gate + Limiter)", .minimal),
        ("Chipmunk", .chipmunk),
        ("Deep Voice", .deepVoice),
        ("Robot", .robot),
        ("Telephone", .telephone),
        ("Cathedral", .cathedral),
        ("Dreamy", .dreamy),
        ("Space Station", .spaceStation),
    ]
}

// MARK: - Effects Preset Manager (file-based, shareable)

struct EffectsPresetManager {
    private static let presetsDirectoryURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Loopbacker", isDirectory: true)
            .appendingPathComponent("effects-presets", isDirectory: true)
    }()

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

    /// Import preset from file data
    static func importData(_ data: Data) -> EffectsPreset? {
        try? JSONDecoder().decode(EffectsPreset.self, from: data)
    }

    private static func sanitizedFileName(_ name: String) -> String {
        let safe = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(safe).json"
    }
}
