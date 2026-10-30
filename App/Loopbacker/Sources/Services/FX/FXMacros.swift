import Foundation

/// Four simple knobs (0...1 each) over the full node graph, for a quick-tune UI that doesn't
/// expose every stage's parameters.
struct FXMacroValues: Equatable, Sendable {
    var clarity: Float
    var warmth: Float
    var noise: Float
    var loudness: Float
}

/// Maps `FXMacroValues` onto the built-in stages and back. Each macro drives a small, fixed set
/// of parameters with a straight linear map (`lerp`), so `apply` is monotonic in every macro and
/// `estimate` inverts it exactly (`unlerp`) -- `estimate(apply(v)) == v` up to floating-point
/// rounding, well inside the 0.05 round-trip tolerance `FXMacrosTests` checks.
///
/// Never touches hosted (AU/JSFX/Airwindows) nodes: only `FXNodeKind` built-ins are read or
/// written. A built-in stage missing from `preset.nodes` is inserted (enabled) in the chain's
/// canonical signal-flow order before being tuned, rather than silently skipped.
enum FXMacros {
    /// Reserved EQ band ids FXMacros owns, chosen well above any id a factory preset or the
    /// user's own bands would use, so re-applying a macro updates the same bands instead of
    /// stacking new ones.
    private enum BandID {
        static let presence = 900
        static let air = 901
        static let body = 902
        static let mud = 903
    }

    private static let presenceRange: ClosedRange<Float> = -2...6
    private static let airRange: ClosedRange<Float> = -2...5
    private static let deEsserRangeRange: ClosedRange<Float> = 2...12
    private static let bodyRange: ClosedRange<Float> = -2...4
    private static let mudRange: ClosedRange<Float> = -3...1 // warmth lerps 1 -> -3: more warmth cuts more mud
    private static let gateRangeRange: ClosedRange<Float> = (-35)...(-6)
    private static let gateThresholdRange: ClosedRange<Float> = (-50)...(-30)
    private static let reductionRange: ClosedRange<Float> = (-60)...(-20)
    private static let levelerTargetRange: ClosedRange<Float> = (-26)...(-14)
    private static let compressorRatioRange: ClosedRange<Float> = 1.5...8

    static func apply(_ v: FXMacroValues, to preset: EffectsPreset, noise: NoiseSuppressionSettings)
        -> (EffectsPreset, NoiseSuppressionSettings) {
        var preset = preset
        var noise = noise
        let clarity = clamp01(v.clarity), warmth = clamp01(v.warmth), noiseAmt = clamp01(v.noise), loudness = clamp01(v.loudness)

        // Clarity: presence/air EQ + de-ess balance.
        ensureNode(&preset, kind: .eq)
        withEQBands(&preset) { bands in
            setBand(&bands, id: BandID.presence, type: .peaking, freq: 3200, q: 1.1, gainDB: lerp(presenceRange, clarity))
            setBand(&bands, id: BandID.air, type: .highshelf, freq: 9000, q: 0.7, gainDB: lerp(airRange, clarity))
        }
        ensureNode(&preset, kind: .deEsser)
        setParams(&preset, kind: .deEsser) { config in
            config.enabled = clarity > 0.1
            config.params["range"] = lerp(deEsserRangeRange, clarity)
            config.params["threshold"] = lerp((-34)...(-22), clarity) // brighter -> catches sibilance earlier
        }

        // Warmth: low-mid shelf/body vs. mud.
        ensureNode(&preset, kind: .eq)
        withEQBands(&preset) { bands in
            setBand(&bands, id: BandID.body, type: .lowshelf, freq: 180, q: 0.7, gainDB: lerp(bodyRange, warmth))
            setBand(&bands, id: BandID.mud, type: .peaking, freq: 350, q: 1.0, gainDB: lerp(mudRange, 1 - warmth))
        }

        // Noise: gate range/threshold + noise suppression reduction.
        ensureNode(&preset, kind: .gate)
        setParams(&preset, kind: .gate) { config in
            config.enabled = true
            config.params["range"] = lerp(gateRangeRange, noiseAmt)
            config.params["threshold"] = lerp(gateThresholdRange, noiseAmt)
        }
        noise.isEnabled = noiseAmt > 0.02
        noise.maxReductionDB = lerp(reductionRange, noiseAmt)

        // Loudness: leveler target + compression amount.
        ensureNode(&preset, kind: .leveler)
        setParams(&preset, kind: .leveler) { config in
            config.enabled = true
            config.params["target"] = lerp(levelerTargetRange, loudness)
        }
        ensureNode(&preset, kind: .compressor)
        setParams(&preset, kind: .compressor) { config in
            config.enabled = loudness > 0.05
            config.params["ratio"] = lerp(compressorRatioRange, loudness)
            config.params["makeup"] = lerp(0...6, loudness)
        }

        return (preset, noise)
    }

    static func estimate(preset: EffectsPreset, noise: NoiseSuppressionSettings) -> FXMacroValues {
        let bands = preset.nodes.first { $0.kind == .eq }?.eqBands ?? []
        let presence = band(bands, id: BandID.presence)?.gainDB ?? presenceRange.lowerBound
        let air = band(bands, id: BandID.air)?.gainDB ?? airRange.lowerBound
        let deEsserRange = preset.nodes.first { $0.kind == .deEsser }?.params["range"] ?? deEsserRangeRange.lowerBound
        let clarity = unlerp(presenceRange, presence) * 0.5 + unlerp(airRange, air) * 0.2
            + unlerp(deEsserRangeRange, deEsserRange) * 0.3

        let body = band(bands, id: BandID.body)?.gainDB ?? bodyRange.lowerBound
        let mud = band(bands, id: BandID.mud)?.gainDB ?? mudRange.upperBound
        let warmth = unlerp(bodyRange, body) * 0.6 + (1 - unlerp(mudRange, mud)) * 0.4

        let gateRange = preset.nodes.first { $0.kind == .gate }?.params["range"] ?? gateRangeRange.lowerBound
        let reduction = noise.isEnabled ? noise.maxReductionDB : reductionRange.lowerBound
        let noiseAmt = unlerp(gateRangeRange, gateRange) * 0.5 + unlerp(reductionRange, reduction) * 0.5

        let target = preset.nodes.first { $0.kind == .leveler }?.params["target"] ?? levelerTargetRange.lowerBound
        let ratio = preset.nodes.first { $0.kind == .compressor }?.params["ratio"] ?? compressorRatioRange.lowerBound
        let loudness = unlerp(levelerTargetRange, target) * 0.6 + unlerp(compressorRatioRange, ratio) * 0.4

        return FXMacroValues(clarity: clamp01(clarity), warmth: clamp01(warmth), noise: clamp01(noiseAmt),
                             loudness: clamp01(loudness))
    }

    // MARK: - Helpers

    private static func clamp01(_ x: Float) -> Float { min(1, max(0, x)) }

    private static func lerp(_ range: ClosedRange<Float>, _ t: Float) -> Float {
        range.lowerBound + (range.upperBound - range.lowerBound) * t
    }

    private static func unlerp(_ range: ClosedRange<Float>, _ x: Float) -> Float {
        let span = range.upperBound - range.lowerBound
        guard span != 0 else { return 0 }
        return (x - range.lowerBound) / span
    }

    /// Inserts a disabled-by-default stage of `kind` into `preset.nodes` at its canonical
    /// signal-flow position if one isn't already present. A pre-existing node (any kind,
    /// built-in or hosted) is never touched.
    private static func ensureNode(_ preset: inout EffectsPreset, kind: FXNodeKind) {
        guard !preset.nodes.contains(where: { $0.kind == kind }) else { return }
        let order: [FXNodeKind] = [.gate, .eq, .compressor, .leveler, .deEsser, .chorus, .pitchShift, .reverb, .delay, .limiter]
        guard let rank = order.firstIndex(of: kind) else { return }
        let insertAt = preset.nodes.firstIndex { config in
            guard let configRank = order.firstIndex(of: config.kind) else { return false }
            return configRank > rank
        } ?? preset.nodes.count
        preset.nodes.insert(FXNodeConfig(kind: kind, enabled: true), at: insertAt)
    }

    private static func setParams(_ preset: inout EffectsPreset, kind: FXNodeKind, _ body: (inout FXNodeConfig) -> Void) {
        guard let idx = preset.nodes.firstIndex(where: { $0.kind == kind }) else { return }
        body(&preset.nodes[idx])
    }

    private static func withEQBands(_ preset: inout EffectsPreset, _ body: (inout [EQBandConfig]) -> Void) {
        guard let idx = preset.nodes.firstIndex(where: { $0.kind == .eq }) else { return }
        var bands = preset.nodes[idx].eqBands ?? []
        body(&bands)
        preset.nodes[idx].eqBands = bands
    }

    private static func band(_ bands: [EQBandConfig], id: Int) -> EQBandConfig? { bands.first { $0.id == id } }

    private static func setBand(_ bands: inout [EQBandConfig], id: Int, type: EQBandConfig.BandType, freq: Float,
                                q: Float, gainDB: Float) {
        if let idx = bands.firstIndex(where: { $0.id == id }) {
            bands[idx].type = type
            bands[idx].frequencyHz = freq
            bands[idx].q = q
            bands[idx].gainDB = gainDB
        } else {
            bands.append(EQBandConfig(id: id, type: type, frequencyHz: freq, gainDB: gainDB, q: q))
        }
    }
}
