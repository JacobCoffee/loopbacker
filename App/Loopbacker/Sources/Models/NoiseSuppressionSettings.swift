import Foundation

/// Noise suppression engines. Each trades cleanup quality against latency and CPU.
enum NoiseSuppressionEngine: String, Codable, CaseIterable, Identifiable {
    /// CEVA's DPDFNet2 48 kHz (Apache-2.0): strong cleanup, 60 ms latency.
    case dpdfnet
    /// aask1357's FastEnhancer-M 48 kHz (MIT): DPDFNet-level cleanup, 21 ms latency, about 6%
    /// of a core. The default.
    case fastenhancer
    /// Xiph's RNNoise (BSD-3-Clause): light cleanup, 30 ms latency, a fraction of the CPU.
    case rnnoise

    var id: String { rawValue }
}

/// Neural noise suppression for physical inputs. Runs ahead of the effects chain and is kept
/// apart from `EffectsPreset`: the chain's bypass and its presets don't touch it. Each source
/// can opt out (`AudioSource.noiseSuppression`).
struct NoiseSuppressionSettings: Codable, Equatable {
    var isEnabled = false
    var engine: NoiseSuppressionEngine = .fastenhancer
    /// How far noise may be pulled down. Easing off (e.g. -12 dB) keeps some room tone;
    /// -60 dB is effectively full removal.
    var maxReductionDB: Float = -60
    /// Acoustic echo cancellation (AEC3) on voice routes: removes the sound Loopbacker plays
    /// to real speakers (monitor output, and anything else it renders) from the mic before it
    /// reaches the virtual mic/monitor, so other call participants don't hear themselves back.
    /// Needs the System Audio Recording permission (`SystemAudioTap`). Off by default: it's a
    /// new feature, and the permission prompt shouldn't appear unasked.
    var echoCancellation = false

    static let reductionRange: ClosedRange<Float> = -60 ... -6

    init(isEnabled: Bool = false, engine: NoiseSuppressionEngine = .fastenhancer, maxReductionDB: Float = -60,
         echoCancellation: Bool = false) {
        self.isEnabled = isEnabled
        self.engine = engine
        self.maxReductionDB = maxReductionDB
        self.echoCancellation = echoCancellation
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, engine, maxReductionDB, echoCancellation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? false
        // Configs from before 4.4 have no engine key; DPDFNet was the only engine then.
        engine = (try? container.decode(NoiseSuppressionEngine.self, forKey: .engine)) ?? .dpdfnet
        maxReductionDB = (try? container.decode(Float.self, forKey: .maxReductionDB)) ?? -60
        // Configs from before echo cancellation shipped have no key; default off.
        echoCancellation = (try? container.decode(Bool.self, forKey: .echoCancellation)) ?? false
    }
}
