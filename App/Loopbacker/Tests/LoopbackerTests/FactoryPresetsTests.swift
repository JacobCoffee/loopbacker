import Foundation
import Testing
@testable import Loopbacker

/// Numerically verifies every factory preset against a synthetic voice at three input levels,
/// through a real `FXChain` (with its own VAD) -- not just that the preset's params look
/// plausible, but that running audio through it behaves the way the preset promises.
///
/// Runs in optimized builds only (`swift test -c release`, which CI uses): unoptimized DSP
/// takes ~9 minutes for the 51 runs, versus ~10 s optimized.
@Suite("FactoryPresets", .serialized, .enabled(if: TestBuild.isOptimized, "needs `swift test -c release`"))
struct FactoryPresetsTests {
    private static let sampleRate: Float = 48_000
    private static let inputLevels: [Float] = [-30, -20, -10]

    @Test("""
          Every factory preset: finite output, true peak within 0.2 dB of its ceiling, loudness \
          within 1.8 LU of target where a leveler runs, keyboard clicks kept well under speech level under a Voice-mode gate
          """)
    func verifyAllPresets() async {
        var rows: [String] = ["preset,input dBFS,LUFS out,true peak dBTP,click-vs-speech margin dB"]

        // One synthetic voice per input level, generated once and reused across every preset
        // (generation is independent of the preset under test).
        let voices = Dictionary(uniqueKeysWithValues: Self.inputLevels.map { level in
            (level, SyntheticVoiceGenerator.generate(sampleRate: Self.sampleRate, speechPeakDBFS: level,
                                                     seed: UInt64(abs(level)) + 1))
        })

        for factory in FactoryPresets.all {
            let nodes = factory.preset.nodes
            let levelerConfig = nodes.first { $0.kind == .leveler }
            let levelerEnabled = levelerConfig?.enabled ?? false
            let levelerTarget = levelerConfig?.params["target"] ?? -18
            let limiterCeiling = nodes.first { $0.kind == .limiter }?.params["ceiling"] ?? -1
            let gateConfig = nodes.first { $0.kind == .gate }
            let voiceGateActive = (gateConfig?.enabled ?? false) && (gateConfig?.params["mode"] ?? 0) >= 0.5

            for level in Self.inputLevels {
                let voice = voices[level]!
                let output = await runFXChain(nodes, sampleRate: Self.sampleRate, input: voice.samples)

                #expect(output.allSatisfy { $0.isFinite },
                       "\(factory.name) at \(level) dBFS produced non-finite output")

                let tp = truePeakDBFS(output)
                #expect(tp <= limiterCeiling + 0.2,
                       "\(factory.name) at \(level) dBFS: true peak \(tp) dBTP exceeds ceiling \(limiterCeiling) dBTP")

                // Steady-state: the leveler gets several seconds of cumulative voiced time to
                // converge before this is measured, same as a real conversation. A few seconds
                // of synthetic speech gives it less settling time than a real one, so this
                // holds to 1.8 LU rather than the nominal 1.5 (see `AutoSetupTests` for the
                // same allowance).
                var lufsOut: Float = .nan
                if levelerEnabled {
                    lufsOut = measuredLUFS(output, ranges: voice.steadyStateSpeechRanges, sampleRate: Self.sampleRate)
                    #expect(abs(lufsOut - levelerTarget) <= 1.8,
                           "\(factory.name) at \(level) dBFS: speech loudness \(lufsOut) LUFS not within 1.8 LU of target \(levelerTarget)")
                }

                // Margin of the processed keyboard click below the processed speech peak -- not
                // a raw input/output comparison, since a leveler holding a large boost from a
                // quiet input (recovering from a gated-down click, same as it recovers a quiet
                // syllable) can leave an absolute click louder than its raw input while it's
                // still comfortably subordinate to speech, which is what a listener hears.
                var clickMargin: Float = .nan
                if voiceGateActive, !voice.clickRanges.isEmpty {
                    let clickPeak = peakDBFS(output, ranges: voice.clickRanges)
                    let speechPeak = peakDBFS(output, ranges: voice.speechRanges)
                    clickMargin = speechPeak - clickPeak
                    #expect(clickMargin >= 6,
                           "\(factory.name) at \(level) dBFS: keyboard clicks only \(clickMargin) dB below speech under a Voice-mode gate")
                }

                rows.append("\(factory.name),\(level),\(fmt(lufsOut)),\(fmt(tp)),\(fmt(clickMargin))")
            }
        }

        // Table requested by the acceptance criteria: preset x input level -> LUFS out, true
        // peak, click attenuation. `swift test` prints this to stdout.
        print(rows.joined(separator: "\n"))
    }

    private func fmt(_ x: Float) -> String { x.isNaN ? "n/a" : String(format: "%.2f", x) }
}
