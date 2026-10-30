import Foundation
import Testing
@testable import Loopbacker

@Suite("AutoSetup")
struct AutoSetupTests {
    private static let sampleRate: Float = 48_000

    private func voice(speechPeakDBFS: Float, tiltBiasDB: Float = 0, seed: UInt64 = 1) -> SyntheticVoice {
        SyntheticVoiceGenerator.generate(sampleRate: Self.sampleRate, speechPeakDBFS: speechPeakDBFS,
                                         tiltBiasDB: tiltBiasDB, seed: seed)
    }

    private func recording(_ voice: SyntheticVoice) -> FXRecording {
        FXRecording(raw: voice.samples, processed: voice.samples, sampleRate: Double(Self.sampleRate))
    }

    @Test("Tuned output meets its leveler target within 2 LU at three input levels",
          arguments: [-30.0, -20.0, -10.0] as [Float])
    func tunedOutputMeetsLoudnessTarget(speechPeakDBFS: Float) async {
        let base = FactoryPresets.preset(id: "meeting-natural")!.preset
        let noise = NoiseSuppressionSettings()
        let v = voice(speechPeakDBFS: speechPeakDBFS, seed: UInt64(abs(speechPeakDBFS)) + 10)
        let result = AutoSetup.analyze(recording(v), base: base, noise: noise)

        let levelerTarget = result.preset.nodes.first { $0.kind == .leveler }?.params["target"] ?? -18
        let output = await runFXChain(result.preset.nodes, sampleRate: Self.sampleRate, input: v.samples)
        let lufsOut = measuredLUFS(output, ranges: v.steadyStateSpeechRanges, sampleRate: Self.sampleRate)

        // A few seconds of synthetic speech gives the leveler less settling time than a real
        // conversation; 2 LU (vs. the 1.5 LU `FactoryPresetsTests` holds the untuned presets to)
        // leaves room for that without losing the check that AutoSetup's tuning actually works.
        #expect(abs(lufsOut - levelerTarget) <= 2.0,
               "tuned output \(lufsOut) LUFS not within 2 LU of target \(levelerTarget) at \(speechPeakDBFS) dBFS input")
    }

    @Test("A bright mic variant measures positive tilt, and the tuned EQ correction pulls it toward neutral")
    func brightVariantCorrectsTowardNeutral() {
        let base = FactoryPresets.preset(id: "meeting-natural")!.preset
        let result = AutoSetup.analyze(recording(voice(speechPeakDBFS: -20, tiltBiasDB: 22, seed: 42)), base: base,
                                       noise: NoiseSuppressionSettings())
        #expect(result.tiltDB > 0, "bright variant should measure a positive (brighter than natural) tilt")

        let correction = result.preset.nodes.first { $0.kind == .eq }?.eqBands?.first { $0.id == 950 }?.gainDB ?? 0
        #expect(correction < 0, "a bright mic should get a high-shelf cut, not a boost")
        #expect(abs(correction) <= 4, "the tilt correction must stay within +/-4 dB")
    }

    @Test("A boomy mic variant measures negative tilt, and the tuned EQ correction pulls it toward neutral")
    func boomyVariantCorrectsTowardNeutral() {
        let base = FactoryPresets.preset(id: "meeting-natural")!.preset
        let result = AutoSetup.analyze(recording(voice(speechPeakDBFS: -20, tiltBiasDB: -9, seed: 43)), base: base,
                                       noise: NoiseSuppressionSettings())
        #expect(result.tiltDB < 0, "boomy variant should measure a negative (darker than natural) tilt")

        let correction = result.preset.nodes.first { $0.kind == .eq }?.eqBands?.first { $0.id == 950 }?.gainDB ?? 0
        #expect(correction > 0, "a boomy mic should get a high-shelf boost, not a cut")
        #expect(abs(correction) <= 4, "the tilt correction must stay within +/-4 dB")
    }

    @Test("Noise floor is measured from pauses, independent of the speech level")
    func noiseFloorIndependentOfSpeechLevel() {
        let base = FactoryPresets.preset(id: "meeting-natural")!.preset
        let quiet = AutoSetup.analyze(recording(voice(speechPeakDBFS: -30, seed: 1)), base: base, noise: NoiseSuppressionSettings())
        let loud = AutoSetup.analyze(recording(voice(speechPeakDBFS: -10, seed: 1)), base: base, noise: NoiseSuppressionSettings())
        // Same room noise, speech 20 dB apart: the estimate must not follow the speech.
        #expect(abs(quiet.noiseFloorDBFS - loud.noiseFloorDBFS) < 2,
                "quiet \(quiet.noiseFloorDBFS) dBFS, loud \(loud.noiseFloorDBFS) dBFS")
    }

    @Test("The gate threshold sits between the noise floor and the speech level")
    func gateThresholdBetweenNoiseAndSpeech() {
        let base = FactoryPresets.preset(id: "meeting-natural")!.preset
        let result = AutoSetup.analyze(recording(voice(speechPeakDBFS: -20, seed: 7)), base: base, noise: NoiseSuppressionSettings())
        let threshold = result.preset.nodes.first { $0.kind == .gate }?.params["threshold"] ?? 0
        #expect(threshold > result.noiseFloorDBFS, "gate threshold should sit above the noise floor")
        #expect(threshold < result.peakDBFS, "gate threshold should sit below the recording's peak")
    }

    @Test("An empty recording degrades gracefully with no NaN")
    func emptyRecording() {
        let base = FactoryPresets.preset(id: "meeting-natural")!.preset
        let result = AutoSetup.analyze(FXRecording(raw: [], processed: [], sampleRate: Double(Self.sampleRate)),
                                       base: base, noise: NoiseSuppressionSettings())
        #expect(result.noiseFloorDBFS.isFinite)
        #expect(result.speechLUFS.isFinite)
        #expect(!result.findings.isEmpty)
    }
}
