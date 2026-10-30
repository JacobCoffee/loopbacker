import Foundation

/// What a stage in the voice chain is. Built-in kinds are implemented in `Services/FX/DSP`;
/// hosted kinds load a third-party effect named by `FXNodeConfig.pluginRef`.
enum FXNodeKind: String, Codable, CaseIterable, Sendable {
    case gate, eq, compressor, leveler, deEsser, chorus, pitchShift, reverb, delay, limiter
    case audioUnit, jsfx, airwindows

    var isHosted: Bool {
        switch self {
        case .audioUnit, .jsfx, .airwindows: true
        default: false
        }
    }
}

/// Identifies a hosted effect so it can be found again after a relaunch.
struct FXPluginRef: Codable, Equatable, Hashable, Sendable {
    /// `.audioUnit`, `.jsfx` or `.airwindows`.
    var format: FXNodeKind
    /// AU: `"type subtype manufacturer"` as three FourCC strings, e.g. `"aufx dely appl"`.
    /// JSFX: absolute path to the effect file. Airwindows: the registry name, e.g. `"Pressure5"`.
    var identifier: String
    var name: String
    var vendor: String?
}

/// A hosted effect as listed in the effect browser.
struct FXPluginInfo: Equatable, Hashable, Sendable, Identifiable {
    var ref: FXPluginRef
    /// Browser grouping, e.g. "Dynamics", "Ambience".
    var category: String?
    /// One or two sentences describing the effect.
    var summary: String?
    /// AU only: true for AUv3 app extensions (loaded out of process).
    var isAUv3 = false

    var id: String { "\(ref.format.rawValue):\(ref.identifier)" }
}

/// One stage of the voice chain, as persisted in routing configs, scenes and exported presets.
struct FXNodeConfig: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var kind: FXNodeKind
    var enabled: Bool
    /// Parameter values by `FXParamSpec.id`. A missing id means the spec's default.
    var params: [String: Float]
    /// `.eq` only: the bands, in any number.
    var eqBands: [EQBandConfig]?
    /// Hosted kinds only: what to load.
    var pluginRef: FXPluginRef?
    /// Hosted kinds only: the effect's full opaque state (AU class info, JSFX serialization,
    /// Airwindows chunk), restored after loading. Takes precedence over `params`.
    var pluginState: Data?

    init(id: UUID = UUID(), kind: FXNodeKind, enabled: Bool = true, params: [String: Float] = [:],
         eqBands: [EQBandConfig]? = nil, pluginRef: FXPluginRef? = nil, pluginState: Data? = nil) {
        self.id = id
        self.kind = kind
        self.enabled = enabled
        self.params = params
        self.eqBands = eqBands
        self.pluginRef = pluginRef
        self.pluginState = pluginState
    }
}

/// One band of the parametric EQ stage.
struct EQBandConfig: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    var type: BandType
    var frequencyHz: Float
    /// Peaking and shelves only.
    var gainDB: Float
    var q: Float
    var enabled: Bool = true
    /// High/low pass only: 12, 24 or 48 dB per octave (cascaded second-order sections).
    var slopeDBPerOctave: Int = 12

    enum BandType: String, Codable, Sendable, CaseIterable {
        case highpass, lowshelf, peaking, highshelf, lowpass, notch
    }

    init(id: Int, type: BandType, frequencyHz: Float, gainDB: Float, q: Float,
         enabled: Bool = true, slopeDBPerOctave: Int = 12) {
        self.id = id
        self.type = type
        self.frequencyHz = frequencyHz
        self.gainDB = gainDB
        self.q = q
        self.enabled = enabled
        self.slopeDBPerOctave = slopeDBPerOctave
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, frequencyHz, gainDB, q, enabled, slopeDBPerOctave
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        type = try c.decode(BandType.self, forKey: .type)
        frequencyHz = try c.decode(Float.self, forKey: .frequencyHz)
        gainDB = try c.decode(Float.self, forKey: .gainDB)
        q = try c.decode(Float.self, forKey: .q)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        slopeDBPerOctave = (try? c.decode(Int.self, forKey: .slopeDBPerOctave)) ?? 12
    }

    /// The original Broadcast preset's EQ, from EasyEffects' "Masculine Voice + Broadcast
    /// Sound" (gist jtrv/47542c8b): rumble cut, mud and box cuts, presence and air lifts.
    static let broadcast: [EQBandConfig] = [
        EQBandConfig(id: 0, type: .highpass, frequencyHz: 80, gainDB: 0, q: 0.7),
        EQBandConfig(id: 1, type: .peaking, frequencyHz: 220, gainDB: -2, q: 0.7),
        EQBandConfig(id: 2, type: .peaking, frequencyHz: 350, gainDB: -2, q: 1.2),
        EQBandConfig(id: 3, type: .peaking, frequencyHz: 3500, gainDB: 2, q: 0.9),
        EQBandConfig(id: 4, type: .highshelf, frequencyHz: 10000, gainDB: 2, q: 0.7),
    ]
}
