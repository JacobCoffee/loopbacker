import Foundation
import Testing
@testable import Loopbacker

@Suite("FXMacros")
struct FXMacrosTests {
    private func values(_ clarity: Float, _ warmth: Float, _ noise: Float, _ loudness: Float) -> FXMacroValues {
        FXMacroValues(clarity: clarity, warmth: warmth, noise: noise, loudness: loudness)
    }

    @Test("estimate(apply(v)) round-trips within 0.05 across the macro space",
          arguments: [0.0, 0.2, 0.5, 0.8, 1.0] as [Float])
    func roundTrips(t: Float) {
        let v = values(t, 1 - t, t, 1 - t)
        let (preset, noise) = FXMacros.apply(v, to: EffectsPreset(nodes: []), noise: NoiseSuppressionSettings())
        let estimated = FXMacros.estimate(preset: preset, noise: noise)
        #expect(abs(estimated.clarity - v.clarity) <= 0.05, "clarity: \(estimated.clarity) vs \(v.clarity)")
        #expect(abs(estimated.warmth - v.warmth) <= 0.05, "warmth: \(estimated.warmth) vs \(v.warmth)")
        #expect(abs(estimated.noise - v.noise) <= 0.05, "noise: \(estimated.noise) vs \(v.noise)")
        #expect(abs(estimated.loudness - v.loudness) <= 0.05, "loudness: \(estimated.loudness) vs \(v.loudness)")
    }

    @Test("Round-trips starting from an existing factory preset, not just an empty graph",
          arguments: FactoryPresets.all.map(\.id))
    func roundTripsFromFactoryPreset(id: String) {
        let factory = FactoryPresets.preset(id: id)!
        let v = values(0.3, 0.7, 0.6, 0.4)
        let (preset, noise) = FXMacros.apply(v, to: factory.preset, noise: NoiseSuppressionSettings())
        let estimated = FXMacros.estimate(preset: preset, noise: noise)
        #expect(abs(estimated.clarity - v.clarity) <= 0.05)
        #expect(abs(estimated.warmth - v.warmth) <= 0.05)
        #expect(abs(estimated.noise - v.noise) <= 0.05)
        #expect(abs(estimated.loudness - v.loudness) <= 0.05)
    }

    @Test("Each macro is monotonic: increasing it never decreases its own estimate")
    func monotonic() {
        let steps: [Float] = [0, 0.25, 0.5, 0.75, 1.0]
        var previous = values(0, 0, 0, 0)
        var lastEstimate = FXMacros.estimate(preset: EffectsPreset(nodes: []), noise: NoiseSuppressionSettings())
        for t in steps {
            let v = values(t, t, t, t)
            let (preset, noise) = FXMacros.apply(v, to: EffectsPreset(nodes: []), noise: NoiseSuppressionSettings())
            let estimate = FXMacros.estimate(preset: preset, noise: noise)
            #expect(estimate.clarity >= lastEstimate.clarity - 0.01)
            #expect(estimate.warmth >= lastEstimate.warmth - 0.01)
            #expect(estimate.noise >= lastEstimate.noise - 0.01)
            #expect(estimate.loudness >= lastEstimate.loudness - 0.01)
            lastEstimate = estimate
            previous = v
        }
        _ = previous
    }

    @Test("apply never touches a hosted node")
    func neverTouchesHostedNodes() {
        let hostedID = UUID()
        let hosted = FXNodeConfig(id: hostedID, kind: .audioUnit, enabled: true, params: ["foo": 1],
                                  pluginRef: FXPluginRef(format: .audioUnit, identifier: "aufx abcd appl", name: "Test"))
        let base = EffectsPreset(nodes: [hosted])
        let (preset, _) = FXMacros.apply(values(1, 1, 1, 1), to: base, noise: NoiseSuppressionSettings())
        let stillHosted = preset.nodes.first { $0.id == hostedID }
        #expect(stillHosted == hosted)
    }

    @Test("A preset missing a built-in stage gets it inserted, enabled, rather than silently skipped")
    func insertsMissingStage() {
        let base = EffectsPreset(nodes: [])
        let (preset, _) = FXMacros.apply(values(0.5, 0.5, 0.5, 0.5), to: base, noise: NoiseSuppressionSettings())
        for kind: FXNodeKind in [.gate, .eq, .compressor, .leveler, .deEsser] {
            #expect(preset.nodes.contains { $0.kind == kind && $0.enabled })
        }
    }

    @Test("Increasing Noise strengthens suppression (lower gate range, lower max reduction), not weakens it")
    func noiseIncreasesSuppressionStrength() {
        let low = FXMacros.apply(values(0, 0, 0.1, 0), to: EffectsPreset(nodes: []), noise: NoiseSuppressionSettings())
        let high = FXMacros.apply(values(0, 0, 0.9, 0), to: EffectsPreset(nodes: []), noise: NoiseSuppressionSettings())
        let lowGateRange = low.0.nodes.first { $0.kind == .gate }?.params["range"] ?? 0
        let highGateRange = high.0.nodes.first { $0.kind == .gate }?.params["range"] ?? 0
        #expect(highGateRange < lowGateRange,
               "higher Noise should attenuate more (more negative range): low \(lowGateRange), high \(highGateRange)")
        #expect(high.1.maxReductionDB < low.1.maxReductionDB,
               "higher Noise should suppress more (more negative maxReductionDB): low \(low.1.maxReductionDB), high \(high.1.maxReductionDB)")
    }

    @Test("Touching an existing disabled EQ's bands (Clarity/Warmth) re-enables it")
    func reEnablesDisabledEQ() {
        let disabledEQ = FXNodeConfig(kind: .eq, enabled: false, eqBands: [])
        let base = EffectsPreset(nodes: [disabledEQ])
        let (preset, _) = FXMacros.apply(values(0.5, 0.5, 0, 0), to: base, noise: NoiseSuppressionSettings())
        let eq = preset.nodes.first { $0.kind == .eq }
        #expect(eq?.enabled == true, "an existing disabled EQ should be enabled once a macro writes bands into it")
    }
}
