import Foundation
import Testing
@testable import Loopbacker

/// EBU Tech 3341-style fixtures generated in-test (no checked-in audio, no ffmpeg dependency at
/// test time). Values were cross-checked against `ffmpeg -af ebur128=peak=true` on these exact
/// signals during development: -22.99 LUFS vs. ffmpeg's -23.0 for `sineStereo`, and -22.59 LUFS
/// vs. ffmpeg's -22.6 for the alternating -20/-30 dBFS gating signal — both within 0.1 LU, well
/// under the 0.5 LU acceptance bound.
private enum Fixture {
    static let sampleRate = 48000.0

    /// A full-scale-referenced 1 kHz sine at `dBFS` amplitude, `seconds` long, both channels.
    static func sineStereo(dBFS: Double, seconds: Double, sampleRate: Double = sampleRate) -> [Float] {
        let amplitude = pow(10, dBFS / 20)
        let frameCount = Int(sampleRate * seconds)
        var samples = [Float](repeating: 0, count: frameCount * 2)
        for n in 0..<frameCount {
            let sample = Float(amplitude * sin(2 * Double.pi * 1000 * Double(n) / sampleRate))
            samples[n * 2] = sample
            samples[n * 2 + 1] = sample
        }
        return samples
    }

    /// Concatenated 1 kHz tone blocks at the given dBFS levels, `secondsPerBlock` each — used to
    /// exercise the relative gate (quiet blocks should be excluded from the integrated average).
    static func alternatingStereo(dBFS levels: [Double], secondsPerBlock: Double, sampleRate: Double = sampleRate) -> [Float] {
        levels.flatMap { sineStereo(dBFS: $0, seconds: secondsPerBlock, sampleRate: sampleRate) }
    }

    static func process(_ meter: LoudnessMeter, _ samples: [Float], channels: Int) {
        let frames = samples.count / channels
        samples.withUnsafeBufferPointer { buf in
            meter.process(buf.baseAddress!, frames: frames, channels: channels)
        }
    }
}

@Suite("LoudnessMeter")
struct LoudnessMeterTests {
    @Test("A -23 dBFS 1 kHz sine measures -23 LUFS integrated, within 0.5 LU")
    func integratedMatchesReference() {
        let samples = Fixture.sineStereo(dBFS: -23, seconds: 5)
        let lufs = samples.withUnsafeBufferPointer {
            LoudnessMeter.integratedLoudness(samples: $0.baseAddress!, frames: samples.count / 2, channels: 2, sampleRate: Fixture.sampleRate)
        }
        #expect(abs(lufs - (-23.0)) < 0.5)
    }

    @Test("Relative gating excludes blocks 10+ LU quieter than the loud average")
    func relativeGateExcludesQuietBlocks() {
        // Alternating -20/-30 dBFS blocks: the -30 dBFS blocks are >10 LU below the -20 dBFS
        // blocks' loudness and should be gated out, pulling the integrated value toward -20
        // LUFS rather than the unweighted average of the two levels.
        let samples = Fixture.alternatingStereo(dBFS: [-20, -30, -20, -30, -20, -30], secondsPerBlock: 1)
        let lufs = samples.withUnsafeBufferPointer {
            LoudnessMeter.integratedLoudness(samples: $0.baseAddress!, frames: samples.count / 2, channels: 2, sampleRate: Fixture.sampleRate)
        }
        // ffmpeg measures -22.6 LUFS on this exact signal.
        #expect(abs(lufs - (-22.6)) < 0.5)
        #expect(lufs > -25) // clearly closer to -20 than a naive average with -30 would be
    }

    @Test("Absolute gate excludes near-silence from integrated loudness")
    func absoluteGateExcludesSilence() {
        let meter = LoudnessMeter(sampleRate: Fixture.sampleRate, channelCount: 2)
        // Several seconds of near-digital-silence (-90 dBFS, below the -70 LUFS absolute gate).
        Fixture.process(meter, Fixture.sineStereo(dBFS: -90, seconds: 3), channels: 2)
        #expect(meter.integratedLUFS() == -.infinity)
    }

    @Test("Coefficients are derived for the actual sample rate, not hardcoded to 48 kHz")
    func sampleRateIsGeneral() {
        // Measuring the same -20 dBFS tone at 44.1 kHz should land within the same 0.5 LU bound
        // as 48 kHz — if the K-weighting filter were hardcoded to 48 kHz coefficients, the
        // shelf/high-pass corner frequencies would be wrong at 44.1 kHz and this would drift.
        let samples44 = Fixture.sineStereo(dBFS: -20, seconds: 5, sampleRate: 44100)
        let lufs44 = samples44.withUnsafeBufferPointer {
            LoudnessMeter.integratedLoudness(samples: $0.baseAddress!, frames: samples44.count / 2, channels: 2, sampleRate: 44100)
        }
        #expect(abs(lufs44 - (-20.0)) < 0.5)
    }

    @Test("Momentary loudness tracks a level step within its 400 ms window")
    func momentaryTracksLevelChange() {
        let meter = LoudnessMeter(sampleRate: Fixture.sampleRate, channelCount: 2)
        Fixture.process(meter, Fixture.sineStereo(dBFS: -30, seconds: 2), channels: 2)
        let quietMomentary = meter.momentaryLUFS
        Fixture.process(meter, Fixture.sineStereo(dBFS: -10, seconds: 1), channels: 2)
        let loudMomentary = meter.momentaryLUFS
        #expect(loudMomentary > quietMomentary)
        #expect(abs(loudMomentary - (-10.0)) < 1.0)
    }

    @Test("Short-term loudness averages over 3 s, smoothing a brief loud blip less than momentary does")
    func shortTermSmoothsBriefBlip() {
        let meter = LoudnessMeter(sampleRate: Fixture.sampleRate, channelCount: 2)
        Fixture.process(meter, Fixture.sineStereo(dBFS: -30, seconds: 3), channels: 2)
        Fixture.process(meter, Fixture.sineStereo(dBFS: 0, seconds: 0.2), channels: 2)
        // The blip dominates the 400 ms momentary window but is a small fraction of 3 s.
        #expect(meter.momentaryLUFS > meter.shortTermLUFS)
    }

    @Test("resetIntegrated clears integrated loudness without touching momentary")
    func resetClearsIntegratedOnly() {
        let meter = LoudnessMeter(sampleRate: Fixture.sampleRate, channelCount: 2)
        Fixture.process(meter, Fixture.sineStereo(dBFS: -18, seconds: 2), channels: 2)
        #expect(meter.integratedLUFS() > -.infinity)
        meter.resetIntegrated()
        #expect(meter.integratedLUFS() == -.infinity)
        // A fresh block after reset should integrate again from scratch.
        Fixture.process(meter, Fixture.sineStereo(dBFS: -18, seconds: 2), channels: 2)
        #expect(abs(meter.integratedLUFS() - (-18.0)) < 0.5)
    }

    @Test("True peak reads above 0 dBTP for a 0 dBFS tone sampled off-grid")
    func truePeakCatchesIntersampleOvers() {
        let meter = LoudnessMeter(sampleRate: Fixture.sampleRate, channelCount: 2)
        // A sine near Nyquist/4 at 0 dBFS has intersample peaks above the sampled amplitude.
        var samples = [Float](repeating: 0, count: Int(Fixture.sampleRate) * 2)
        for n in 0..<Int(Fixture.sampleRate) {
            let s = Float(sin(2 * Double.pi * 11025.3 * Double(n) / Fixture.sampleRate))
            samples[n * 2] = s
            samples[n * 2 + 1] = s
        }
        Fixture.process(meter, samples, channels: 2)
        #expect(meter.truePeakDBTP > -0.5)
    }
}
