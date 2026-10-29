import Foundation

/// Noise suppression engines. Each trades cleanup quality against latency and CPU.
enum NoiseSuppressionEngine: String, Codable, CaseIterable, Identifiable {
    /// CEVA's DPDFNet2 48 kHz (Apache-2.0): the strongest cleanup, 60 ms latency.
    case dpdfnet
    /// aask1357's FastEnhancer-S 48 kHz (MIT): near-DPDFNet cleanup at RNNoise-like latency
    /// (10.67 ms) and under 2% of a core.
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
    var engine: NoiseSuppressionEngine = .dpdfnet
    /// How far noise may be pulled down. Easing off (e.g. -12 dB) keeps some room tone;
    /// -60 dB is effectively full removal.
    var maxReductionDB: Float = -60

    static let reductionRange: ClosedRange<Float> = -60 ... -6

    init(isEnabled: Bool = false, engine: NoiseSuppressionEngine = .dpdfnet, maxReductionDB: Float = -60) {
        self.isEnabled = isEnabled
        self.engine = engine
        self.maxReductionDB = maxReductionDB
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, engine, maxReductionDB
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? false
        engine = (try? container.decode(NoiseSuppressionEngine.self, forKey: .engine)) ?? .dpdfnet
        maxReductionDB = (try? container.decode(Float.self, forKey: .maxReductionDB)) ?? -60
    }
}
