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
    /// JSFX: `"<root>:<path relative to that root>"`, e.g. `"reaper:Vocal/Deesser.jsfx"` or
    /// `"loopbacker:MyEffect.jsfx"` — `<root>` names one of `JSFXCatalog`'s two catalog roots
    /// (`~/Library/Application Support/REAPER/Effects`, `.../Loopbacker/JSFX`), never an
    /// absolute filesystem path, so an exported/imported preset is portable across machines
    /// and `JSFXNode.load` can validate it resolves under a known root before touching disk
    /// (LB-PRESET-001). A bare absolute path is still accepted for backward compatibility with
    /// configs persisted before this format existed, but `JSFXNode.load` validates it resolves
    /// under one of the same two roots exactly as the new scheme does — it is never honored
    /// outside them. Airwindows: the registry name, e.g. `"Pressure5"`.
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

    /// Decode-time cap on `pluginState` (LB-RES-001): a value past this is dropped rather than
    /// handed to a hosted loader's own state parser. Each loader independently re-validates its
    /// own internal sizes regardless (e.g. `JSFXNode.restoreState`'s per-field bounds checks,
    /// LB-JSFX-001) — this cap exists so one maliciously or accidentally huge blob in an
    /// imported preset or a hand-edited config can't even reach that point.
    static let maxPluginStateSize = 16 * 1024 * 1024

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

    private enum CodingKeys: String, CodingKey {
        case id, kind, enabled, params, eqBands, pluginRef, pluginState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(FXNodeKind.self, forKey: .kind)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        params = try container.decode([String: Float].self, forKey: .params)
        eqBands = try container.decodeIfPresent([EQBandConfig].self, forKey: .eqBands)
        pluginRef = try container.decodeIfPresent(FXPluginRef.self, forKey: .pluginRef)
        let decodedState = try container.decodeIfPresent(Data.self, forKey: .pluginState)
        pluginState = (decodedState?.count ?? 0) <= Self.maxPluginStateSize ? decodedState : nil
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
