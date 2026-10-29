import Foundation

/// Neural noise suppression for physical inputs. Runs ahead of the effects chain and is kept
/// apart from `EffectsPreset`: the chain's bypass and its presets don't touch it.
struct NoiseSuppressionSettings: Codable, Equatable {
    var isEnabled = false
    /// How far noise may be pulled down. Easing off (e.g. -12 dB) keeps some room tone;
    /// -60 dB is effectively full removal.
    var maxReductionDB: Float = -60

    static let reductionRange: ClosedRange<Float> = -60 ... -6
}
