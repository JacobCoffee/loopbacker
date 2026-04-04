import Foundation

// MARK: - EQ Band

struct EQBandConfig: Codable, Equatable, Identifiable {
    let id: Int
    var type: BandType
    var frequencyHz: Float
    var gainDB: Float
    var q: Float

    enum BandType: String, Codable {
        case highpass, lowshelf, peaking, highshelf
    }

    /// "Masculine Voice + Broadcast Sound" preset from EasyEffects
    /// Matches jtrv/47542c8be6345951802eebcf9dc7da31 gist values
    static let broadcastMasculine: [EQBandConfig] = [
        EQBandConfig(id: 0, type: .highpass, frequencyHz: 80,    gainDB:  0, q: 0.7),   // rumble cut
        EQBandConfig(id: 1, type: .peaking,  frequencyHz: 220,   gainDB: -2, q: 0.7),   // mud reduction
        EQBandConfig(id: 2, type: .peaking,  frequencyHz: 350,   gainDB: -2, q: 1.2),   // boxiness
        EQBandConfig(id: 3, type: .peaking,  frequencyHz: 3500,  gainDB:  2, q: 0.9),   // presence
        EQBandConfig(id: 4, type: .highshelf, frequencyHz: 10000, gainDB:  2, q: 0.7),   // air
    ]
}

// MARK: - Effects Preset

struct EffectsPreset: Codable, Equatable {
    var isEnabled: Bool = false  // Off by default until user enables

    // Noise Gate
    var gateEnabled: Bool = true
    var gateThresholdDB: Float = -36.0
    var gateAttackMs: Float = 5.0
    var gateReleaseMs: Float = 250.0
    var gateReductionDB: Float = -12.0  // soft gate, not full mute

    // 5-band Parametric EQ
    var eqEnabled: Bool = true
    var eqBands: [EQBandConfig] = EQBandConfig.broadcastMasculine

    // Compressor
    var compressorEnabled: Bool = true
    var compressorThresholdDB: Float = -18.0
    var compressorRatio: Float = 3.0
    var compressorAttackMs: Float = 15.0
    var compressorReleaseMs: Float = 200.0
    var compressorMakeupDB: Float = 3.0

    // De-Esser
    var deEsserEnabled: Bool = true
    var deEsserFrequencyHz: Float = 6000.0
    var deEsserReductionDB: Float = -6.0
    var deEsserRatio: Float = 3.0

    // Chorus
    var chorusEnabled: Bool = false
    var chorusRate: Float = 0.8       // LFO Hz, 0.1...5 (slow = natural)
    var chorusDepth: Float = 1.5      // modulation depth ms, 0...10 (subtle)
    var chorusMix: Float = 0.3        // 0...1

    // Pitch Shift
    var pitchShiftEnabled: Bool = false
    var pitchSemitones: Float = 0.0   // -12...12
    var pitchMix: Float = 1.0         // 0...1

    // Reverb (Freeverb)
    var reverbEnabled: Bool = false
    var reverbRoomSize: Float = 0.5   // 0...1
    var reverbDamping: Float = 0.5    // 0...1
    var reverbMix: Float = 0.15       // 0...1

    // Delay
    var delayEnabled: Bool = false
    var delayTimeMs: Float = 250.0    // 10...1000
    var delayFeedback: Float = 0.3    // 0...0.9
    var delayMix: Float = 0.25        // 0...1

    // Limiter
    var limiterEnabled: Bool = true
    var limiterCeilingDB: Float = -1.5
    var limiterReleaseMs: Float = 50.0

    // MARK: - Factory presets

    static let broadcastVoice = EffectsPreset(isEnabled: true)

    static let podcastClean = EffectsPreset(
        isEnabled: true,
        gateThresholdDB: -40.0, gateReductionDB: -8.0,
        eqBands: [
            EQBandConfig(id: 0, type: .highpass, frequencyHz: 100, gainDB: 0, q: 0.707),
            EQBandConfig(id: 1, type: .peaking,  frequencyHz: 250, gainDB: -1, q: 1.0),
            EQBandConfig(id: 2, type: .peaking,  frequencyHz: 400, gainDB: 0, q: 1.0),
            EQBandConfig(id: 3, type: .peaking,  frequencyHz: 3000, gainDB: 1.5, q: 1.0),
            EQBandConfig(id: 4, type: .highshelf, frequencyHz: 8000, gainDB: 1, q: 0.707),
        ],
        compressorThresholdDB: -20.0, compressorRatio: 2.5, compressorMakeupDB: 2.0,
        deEsserReductionDB: -4.0,
        limiterCeilingDB: -1.0
    )

    static let heavyCompression = EffectsPreset(
        isEnabled: true,
        gateThresholdDB: -30.0, gateReductionDB: -20.0,
        compressorThresholdDB: -24.0, compressorRatio: 6.0,
        compressorAttackMs: 5.0, compressorReleaseMs: 100.0, compressorMakeupDB: 6.0,
        limiterCeilingDB: -2.0
    )

    static let minimal = EffectsPreset(
        isEnabled: true,
        gateEnabled: true, gateThresholdDB: -40.0, gateReductionDB: -10.0,
        eqEnabled: false,
        compressorEnabled: false,
        deEsserEnabled: false,
        limiterEnabled: true, limiterCeilingDB: -1.0
    )

    // --- Fun / Creative presets ---

    static let chipmunk = EffectsPreset(
        isEnabled: true,
        gateEnabled: false, eqEnabled: false, compressorEnabled: false, deEsserEnabled: false,
        pitchShiftEnabled: true, pitchSemitones: 12, pitchMix: 1.0,
        limiterEnabled: true, limiterCeilingDB: -1.0
    )

    static let deepVoice = EffectsPreset(
        isEnabled: true,
        gateEnabled: true, gateThresholdDB: -40, gateReductionDB: -10,
        eqEnabled: true, eqBands: [
            EQBandConfig(id: 0, type: .highpass, frequencyHz: 60, gainDB: 0, q: 0.7),
            EQBandConfig(id: 1, type: .peaking,  frequencyHz: 150, gainDB: 3, q: 0.8),
            EQBandConfig(id: 2, type: .peaking,  frequencyHz: 300, gainDB: 1, q: 1.0),
            EQBandConfig(id: 3, type: .peaking,  frequencyHz: 3000, gainDB: -2, q: 1.0),
            EQBandConfig(id: 4, type: .highshelf, frequencyHz: 8000, gainDB: -3, q: 0.7),
        ],
        compressorEnabled: true, compressorThresholdDB: -20, compressorRatio: 3.0, compressorMakeupDB: 2.0,
        deEsserEnabled: false,
        pitchShiftEnabled: true, pitchSemitones: -5, pitchMix: 1.0,
        limiterEnabled: true, limiterCeilingDB: -1.5
    )

    static let robot = EffectsPreset(
        isEnabled: true,
        gateEnabled: false, eqEnabled: false, compressorEnabled: false, deEsserEnabled: false,
        chorusEnabled: true, chorusRate: 5.0, chorusDepth: 0.5, chorusMix: 0.7,
        pitchShiftEnabled: true, pitchSemitones: -7, pitchMix: 0.8,
        reverbEnabled: true, reverbRoomSize: 0.2, reverbDamping: 0.9, reverbMix: 0.3,
        limiterEnabled: true, limiterCeilingDB: -1.0
    )

    static let cathedral = EffectsPreset(
        isEnabled: true,
        gateEnabled: true, gateThresholdDB: -45, gateReductionDB: -8,
        eqEnabled: true,
        compressorEnabled: true, compressorThresholdDB: -22, compressorRatio: 2.5, compressorMakeupDB: 2.0,
        deEsserEnabled: true,
        reverbEnabled: true, reverbRoomSize: 0.95, reverbDamping: 0.2, reverbMix: 0.35,
        delayEnabled: true, delayTimeMs: 120, delayFeedback: 0.25, delayMix: 0.1,
        limiterEnabled: true, limiterCeilingDB: -1.5
    )

    static let radioAnnouncer = EffectsPreset(
        isEnabled: true,
        gateEnabled: true, gateThresholdDB: -32, gateReductionDB: -15,
        eqEnabled: true, eqBands: [
            EQBandConfig(id: 0, type: .highpass, frequencyHz: 80, gainDB: 0, q: 0.7),
            EQBandConfig(id: 1, type: .peaking,  frequencyHz: 180, gainDB: 3, q: 0.8),
            EQBandConfig(id: 2, type: .peaking,  frequencyHz: 400, gainDB: -3, q: 1.2),
            EQBandConfig(id: 3, type: .peaking,  frequencyHz: 3200, gainDB: 3, q: 0.9),
            EQBandConfig(id: 4, type: .highshelf, frequencyHz: 10000, gainDB: 2, q: 0.7),
        ],
        compressorEnabled: true, compressorThresholdDB: -16, compressorRatio: 5.0,
        compressorAttackMs: 10.0, compressorReleaseMs: 120.0, compressorMakeupDB: 5.0,
        deEsserEnabled: true, deEsserReductionDB: -8,
        reverbEnabled: true, reverbRoomSize: 0.3, reverbDamping: 0.6, reverbMix: 0.06,
        limiterEnabled: true, limiterCeilingDB: -0.5
    )

    static let dreamy = EffectsPreset(
        isEnabled: true,
        gateEnabled: false, eqEnabled: false, compressorEnabled: false, deEsserEnabled: false,
        chorusEnabled: true, chorusRate: 0.5, chorusDepth: 4.0, chorusMix: 0.5,
        reverbEnabled: true, reverbRoomSize: 0.85, reverbDamping: 0.3, reverbMix: 0.4,
        delayEnabled: true, delayTimeMs: 400, delayFeedback: 0.4, delayMix: 0.15,
        limiterEnabled: true, limiterCeilingDB: -1.5
    )

    static let telephone = EffectsPreset(
        isEnabled: true,
        gateEnabled: false,
        eqEnabled: true, eqBands: [
            EQBandConfig(id: 0, type: .highpass, frequencyHz: 300, gainDB: 0, q: 0.7),
            EQBandConfig(id: 1, type: .peaking,  frequencyHz: 800, gainDB: 3, q: 0.8),
            EQBandConfig(id: 2, type: .peaking,  frequencyHz: 2000, gainDB: 4, q: 1.0),
            EQBandConfig(id: 3, type: .peaking,  frequencyHz: 3500, gainDB: -2, q: 1.0),
            EQBandConfig(id: 4, type: .highshelf, frequencyHz: 4000, gainDB: -12, q: 0.7),
        ],
        compressorEnabled: true, compressorThresholdDB: -15, compressorRatio: 8.0,
        compressorMakeupDB: 4.0,
        deEsserEnabled: false,
        limiterEnabled: true, limiterCeilingDB: -2.0
    )

    static let spaceStation = EffectsPreset(
        isEnabled: true,
        gateEnabled: false, eqEnabled: false, compressorEnabled: false, deEsserEnabled: false,
        chorusEnabled: true, chorusRate: 2.5, chorusDepth: 3.0, chorusMix: 0.6,
        pitchShiftEnabled: true, pitchSemitones: -3, pitchMix: 0.7,
        reverbEnabled: true, reverbRoomSize: 0.9, reverbDamping: 0.15, reverbMix: 0.45,
        delayEnabled: true, delayTimeMs: 300, delayFeedback: 0.5, delayMix: 0.2,
        limiterEnabled: true, limiterCeilingDB: -1.0
    )

    static let factoryPresets: [(name: String, preset: EffectsPreset)] = [
        // Voice processing
        ("Broadcast Masculine Voice", .broadcastVoice),
        ("Podcast Clean", .podcastClean),
        ("Radio Announcer", .radioAnnouncer),
        ("Heavy Compression", .heavyCompression),
        ("Minimal (Gate + Limiter)", .minimal),
        // Fun voices
        ("Chipmunk", .chipmunk),
        ("Deep Voice", .deepVoice),
        ("Robot", .robot),
        ("Telephone", .telephone),
        // Spatial / ambient
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
