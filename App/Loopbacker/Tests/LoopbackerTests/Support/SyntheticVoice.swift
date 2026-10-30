import Foundation
@testable import Loopbacker

/// A deterministic, seedable pseudo-random source for reproducible noise/transients.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform `Float` in `-1...1`.
    mutating func uniform() -> Float {
        Float(next() >> 11) * (1.0 / Float(1 << 53)) * 2 - 1
    }
}

/// A synthetic "voice" recording for numerically verifying factory presets without a real
/// microphone.
struct SyntheticVoice {
    let samples: [Float]
    let sampleRate: Float
    /// Sample ranges classified as speech (syllables): ground truth for loudness measurement.
    let speechRanges: [Range<Int>]
    /// `true` at the same index in `speechRanges` for a syllable with a sibilant burst.
    let sibilantFlags: [Bool]
    /// The plateau (15% trimmed off each edge, dropping the attack/release amplitude ramps) of
    /// the last two non-sibilant speech ranges: by here a leveler has had several seconds of
    /// cumulative voiced time to converge, so this is the steady-state loudness a `target`
    /// should actually be judged against. Non-sibilant specifically, so the de-esser's own
    /// (separately verified) reduction of a sibilant burst doesn't get counted against the
    /// leveler, which runs upstream of it and never sees that reduction.
    var steadyStateSpeechRanges: [Range<Int>] {
        let nonSibilant = zip(speechRanges, sibilantFlags).filter { !$0.1 }.map(\.0)
        let candidates = nonSibilant.isEmpty ? speechRanges : nonSibilant
        return candidates.suffix(2).map { range in
            let trim = Int(Float(range.count) * 0.15)
            return (range.lowerBound + trim)..<(range.upperBound - trim)
        }
    }
    /// Sample ranges, all inside pauses, where a keyboard-click transient was injected.
    let clickRanges: [Range<Int>]
}

/// Builds a glottal pulse train (through formant resonators) shaped into syllables, separated by
/// room-noise pauses carrying keyboard-click transients and occasional sibilant bursts -- enough
/// for a gate/leveler/de-esser/limiter chain to all have something real to react to.
enum SyntheticVoiceGenerator {
    /// `speechPeakDBFS`: peak level of the voiced syllables before any processing.
    /// `roomNoiseDBFS`: level of the room tone/noise floor during pauses.
    /// `tiltBiasDB`: extra high-shelf gain (positive = brighter, negative = boomier) applied to
    /// the whole signal after synthesis, for the "bright"/"boomy" mic variants `AutoSetup` is
    /// verified against.
    static func generate(sampleRate: Float = 48_000, speechPeakDBFS: Float, roomNoiseDBFS: Float = -52,
                         tiltBiasDB: Float = 0, seed: UInt64 = 1) -> SyntheticVoice {
        var rng = SplitMix64(seed: seed)
        let pauseFrames = Int(0.2 * sampleRate)
        let syllableFrames = Int(0.8 * sampleRate)
        let syllableCount = 6
        let f0s: [Float] = [110, 150, 190, 130, 170, 120] // within the requested 100-220 Hz range

        var samples: [Float] = []
        samples.reserveCapacity((pauseFrames + syllableFrames) * syllableCount + pauseFrames)
        var speechRanges: [Range<Int>] = []
        var sibilantFlags: [Bool] = []
        var clickRanges: [Range<Int>] = []

        appendPause(&samples, frames: pauseFrames, roomNoiseDBFS: roomNoiseDBFS, sampleRate: sampleRate,
                   rng: &rng, withClick: true, clickRanges: &clickRanges)
        for s in 0..<syllableCount {
            let start = samples.count
            let sibilant = s.isMultiple(of: 2)
            appendSyllable(&samples, frames: syllableFrames, f0: f0s[s % f0s.count], peakDBFS: speechPeakDBFS,
                          sampleRate: sampleRate, sibilant: sibilant)
            speechRanges.append(start..<samples.count)
            sibilantFlags.append(sibilant)
            appendPause(&samples, frames: pauseFrames, roomNoiseDBFS: roomNoiseDBFS, sampleRate: sampleRate,
                       rng: &rng, withClick: s.isMultiple(of: 2), clickRanges: &clickRanges)
        }

        if tiltBiasDB != 0 {
            let coeffs = FXBiquadCoeffs.make(type: .highshelf, frequency: 3000, q: 0.707, gainDB: Double(tiltBiasDB),
                                             sampleRate: Double(sampleRate))
            var state = FXBiquadState()
            for i in 0..<samples.count { samples[i] = Float(state.process(Double(samples[i]), coeffs)) }
        }

        return SyntheticVoice(samples: samples, sampleRate: sampleRate, speechRanges: speechRanges,
                              sibilantFlags: sibilantFlags, clickRanges: clickRanges)
    }

    /// A voiced syllable: a harmonic glottal source (band-limited sawtooth-like, falling off
    /// ~1/k per harmonic) through three parallel formant resonators approximating a vowel
    /// (~700/1220/2600 Hz), under a syllable amplitude envelope, with a sibilant noise burst
    /// `peakDBFS` is matched as the syllable's own K-weighted (BS.1770) loudness, not its
    /// instantaneous sample peak -- real speech's crest factor (peak well above sustained
    /// loudness) would otherwise make "3 input levels 20 dB apart" demand leveler gain swings
    /// far beyond any sane `maxBoost`/`maxCut`; matching loudness directly keeps the needed
    /// correction exactly `target - peakDBFS`, the range the built-in leveler is designed for.
    private static func appendSyllable(_ samples: inout [Float], frames: Int, f0: Float, peakDBFS: Float,
                                       sampleRate: Float, sibilant: Bool) {
        var rng = SplitMix64(seed: UInt64(f0 * 1000))
        let maxHarmonic = max(1, Int(sampleRate / 2 / f0) - 1)

        var f1 = FXBiquadState(), f2 = FXBiquadState(), f3 = FXBiquadState()
        let c1 = FXBiquadCoeffs.make(type: .peaking, frequency: 700, q: 8, gainDB: 18, sampleRate: Double(sampleRate))
        let c2 = FXBiquadCoeffs.make(type: .peaking, frequency: 1220, q: 10, gainDB: 14, sampleRate: Double(sampleRate))
        let c3 = FXBiquadCoeffs.make(type: .peaking, frequency: 2600, q: 12, gainDB: 10, sampleRate: Double(sampleRate))

        let attack = Int(0.04 * sampleRate), release = Int(0.1 * sampleRate)
        let sibilantStart = sibilant ? Int(Float(frames) * 0.62) : frames
        let sibilantLen = Int(0.12 * sampleRate)
        var hpSib1 = FXBiquadState(), hpSib2 = FXBiquadState(), lpSib = FXBiquadState()
        let hpSibCoeffs = FXBiquadCoeffs.make(type: .highpass, frequency: 6000, q: 0.707, gainDB: 0, sampleRate: Double(sampleRate))
        let lpSibCoeffs = FXBiquadCoeffs.make(type: .lowpass, frequency: 8000, q: 0.707, gainDB: 0, sampleRate: Double(sampleRate))

        var raw = [Float](repeating: 0, count: frames)
        var phase: Float = 0
        let phaseInc = f0 / sampleRate

        for i in 0..<frames {
            var source: Float = 0
            for k in 1...maxHarmonic { source += sinf(2 * .pi * Float(k) * phase) / Float(k) }
            phase += phaseInc
            if phase >= 1 { phase -= 1 }

            let formant = Float(f1.process(Double(source), c1))
                + Float(f2.process(Double(source), c2))
                + Float(f3.process(Double(source), c3))

            let envelope: Float
            if i < attack { envelope = Float(i) / Float(attack) }
            else if i > frames - release { envelope = Float(frames - i) / Float(release) }
            else { envelope = 1 }

            var sample = formant * envelope

            if i >= sibilantStart, i < sibilantStart + sibilantLen {
                let t = Float(i - sibilantStart) / Float(sibilantLen)
                let burstEnvelope = sinf(.pi * min(1, t)) // smooth rise/fall over the burst
                var noise = rng.uniform()
                noise = Float(hpSib1.process(Double(noise), hpSibCoeffs))
                noise = Float(hpSib2.process(Double(noise), hpSibCoeffs))
                noise = Float(lpSib.process(Double(noise), lpSibCoeffs))
                sample += noise * burstEnvelope * 0.8
            }

            raw[i] = sample
        }

        // Match this syllable's own K-weighted (BS.1770) loudness to `peakDBFS`, the same
        // filter `LevelerNode`/`measuredLUFS` use, so the leveler's target maps directly onto
        // this parameter.
        var shelfState = FXBiquadState(), hpState = FXBiquadState()
        let shelfCoeffs = FXBiquadCoeffs.make(type: .highshelf, frequency: 1681.9744509555319, q: 0.7071752369554196,
                                              gainDB: 3.999843853973347, sampleRate: Double(sampleRate))
        let hpCoeffs = FXBiquadCoeffs.make(type: .highpass, frequency: 38.13547087602444, q: 0.5003270373238773,
                                           gainDB: 0, sampleRate: Double(sampleRate))
        var sumSquares: Double = 0
        for i in 0..<frames {
            var k = Float(shelfState.process(Double(raw[i]), shelfCoeffs))
            k = Float(hpState.process(Double(k), hpCoeffs))
            sumSquares += 2 * Double(k * k)
        }
        let rawLUFS = Float(-0.691 + 10 * log10(max(sumSquares / Double(frames), 1e-12)))
        let scale = fxDBToLinear(peakDBFS - rawLUFS)
        for i in 0..<frames { samples.append(raw[i] * scale) }
    }

    /// A pause: room-noise-colored white noise at `roomNoiseDBFS`, with an optional keyboard
    /// click (a short, sharply-decaying broadband transient) partway through.
    private static func appendPause(_ samples: inout [Float], frames: Int, roomNoiseDBFS: Float, sampleRate: Float,
                                    rng: inout SplitMix64, withClick: Bool, clickRanges: inout [Range<Int>]) {
        let noiseLinear = fxDBToLinear(roomNoiseDBFS)
        let clickAt = frames / 2
        // Clearly above room noise, but still well under any tested speech level (the quietest
        // is -30 dBFS): a real keyboard click is a brief, modest transient, never as loud as
        // speech.
        let clickPeak = fxDBToLinear(roomNoiseDBFS + 15)
        let clickDecaySamples = Float(0.004 * sampleRate)
        let clickLenSamples = Int(0.015 * sampleRate)

        let start = samples.count
        for i in 0..<frames {
            var sample = rng.uniform() * noiseLinear
            if withClick, i >= clickAt, i < clickAt + clickLenSamples {
                let t = Float(i - clickAt)
                let decay = expf(-t / clickDecaySamples)
                sample += rng.uniform() * clickPeak * decay
            }
            samples.append(sample)
        }
        if withClick { clickRanges.append((start + clickAt)..<(start + clickAt + clickLenSamples)) }
    }
}
