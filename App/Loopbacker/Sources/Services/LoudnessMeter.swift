import Foundation

/// ITU-R BS.1770-4 / EBU R128 loudness meter: K-weighted momentary (400 ms), short-term (3 s)
/// and gated integrated loudness, plus an oversampled true-peak estimate.
///
/// `process(_:frames:channels:)` is real-time safe: every buffer (filter state, step
/// accumulators, momentary/short-term rings, the integrated-loudness histogram) is allocated
/// once in `init` for the configured channel count, and the method itself never allocates,
/// locks, or calls into Objective-C. Readings publish through plain `UnsafeMutablePointer`
/// slots written by the audio thread and read by the main thread — the same benign-race
/// pattern `AudioRouter.RouteContext`'s `meterLevelsPtr`/`outMeterLevelsPtr` and `MeterLevels`
/// already use: a torn or one-block-stale read is inaudible/invisible and self-corrects on the
/// next 100 ms step.
final class LoudnessMeter {
    let sampleRate: Double
    let channelCount: Int

    // MARK: - K-weighting (ITU-R BS.1770-4 Annex 1): a high-shelf stage then an RLB high-pass
    // stage, cascaded. Coefficients are derived from the standard's analog prototypes via the
    // bilinear transform for the actual sample rate (not hardcoded to 48 kHz), the same general
    // design used by reference implementations (e.g. libebur128).

    private struct Biquad {
        var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    }

    private struct ChannelFilterState {
        var s1z1: Double = 0, s1z2: Double = 0
        var s2z1: Double = 0, s2z2: Double = 0
        // True-peak oversampling: last two raw samples, for Catmull-Rom interpolation of the
        // intersample points between them (an approximation of BS.1770 Annex 2's polyphase FIR
        // oversampler — real-time safe and allocation-free, at the cost of some precision vs.
        // the standard's exact filter; true peak isn't part of the LUFS agreement acceptance
        // test, only a UI readout).
        var peakPrev2: Double = 0, peakPrev1: Double = 0
        var hasPeakHistory = false
    }

    private let stage1: Biquad
    private let stage2: Biquad
    /// BS.1770 channel weighting (G): center/L/R channels are 1.0; a stereo or mono meter (the
    /// only configurations this app's virtual devices and soundboard clips use) is always 1.0
    /// on every channel.
    private let channelWeights: [Double]
    private var filterState: [ChannelFilterState]

    // MARK: - 100 ms step accumulation (400 ms gating blocks step every 100 ms, 75% overlap)

    private let stepFrames: Int
    private var stepSampleCount: Int = 0
    private var stepSumSquares: [Double]
    private var stepPeak: Double = 0

    // MARK: - Momentary (400 ms = 4 steps) / short-term (3 s = 30 steps) running rings

    private static let momentarySteps = 4
    private static let shortTermSteps = 30
    private var momentaryRing: UnsafeMutablePointer<Double>
    private var momentaryIndex = 0
    private var momentaryFilled = 0
    private var momentarySum: Double = 0
    private var shortTermRing: UnsafeMutablePointer<Double>
    private var shortTermIndex = 0
    private var shortTermFilled = 0
    private var shortTermSum: Double = 0

    // MARK: - Integrated loudness: absolute gate (running totals) + relative gate (histogram)
    //
    // Histogram-of-blocks gating (as used by reference implementations such as libebur128) gives
    // exact two-pass BS.1770 gating in O(bin count) at query time regardless of how long the
    // meter has been running, instead of storing (and rescanning) every 100 ms block forever.

    private static let histogramMinLUFS = -70.0
    private static let histogramResolution = 0.1
    private static let histogramBinCount = 1301 // -70.0 ... +60.0 LUFS inclusive, clamped
    private var histogramCount: UnsafeMutablePointer<Int>
    private var histogramSumZ: UnsafeMutablePointer<Double>
    private var sumAbsGatedZ: Double = 0
    private var countAbsGatedZ: Int = 0

    // MARK: - Published readouts (written on the audio thread, read on the main thread)

    private let momentaryPtr: UnsafeMutablePointer<Float>
    private let shortTermPtr: UnsafeMutablePointer<Float>
    private let truePeakPtr: UnsafeMutablePointer<Float>

    init(sampleRate: Double, channelCount: Int) {
        precondition(channelCount >= 1, "LoudnessMeter needs at least one channel")
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        // Loopbacker's virtual devices expose a user-chosen channel count (2...16) that isn't a
        // fixed surround layout (channels are arbitrary route destinations, not L/R/C/Ls/Rs), so
        // BS.1770's position-based channel weights don't apply here — every channel counts
        // equally, the same as the standard's L/R weight of 1.0.
        self.channelWeights = Array(repeating: 1.0, count: channelCount)
        (stage1, stage2) = Self.kWeightingCoefficients(sampleRate: sampleRate)
        filterState = Array(repeating: ChannelFilterState(), count: channelCount)
        stepFrames = max(1, Int((sampleRate * 0.1).rounded()))
        stepSumSquares = Array(repeating: 0, count: channelCount)

        momentaryRing = .allocate(capacity: Self.momentarySteps)
        momentaryRing.initialize(repeating: 0, count: Self.momentarySteps)
        shortTermRing = .allocate(capacity: Self.shortTermSteps)
        shortTermRing.initialize(repeating: 0, count: Self.shortTermSteps)

        histogramCount = .allocate(capacity: Self.histogramBinCount)
        histogramCount.initialize(repeating: 0, count: Self.histogramBinCount)
        histogramSumZ = .allocate(capacity: Self.histogramBinCount)
        histogramSumZ.initialize(repeating: 0, count: Self.histogramBinCount)

        momentaryPtr = .allocate(capacity: 1)
        momentaryPtr.initialize(to: -.infinity)
        shortTermPtr = .allocate(capacity: 1)
        shortTermPtr.initialize(to: -.infinity)
        truePeakPtr = .allocate(capacity: 1)
        truePeakPtr.initialize(to: 0)
    }

    deinit {
        momentaryRing.deallocate()
        shortTermRing.deallocate()
        histogramCount.deallocate()
        histogramSumZ.deallocate()
        momentaryPtr.deallocate()
        shortTermPtr.deallocate()
        truePeakPtr.deallocate()
    }

    /// Derives the two K-weighting biquad stages for a given sample rate from BS.1770-4 Annex 1's
    /// analog prototypes (high-shelf stage 1, RLB high-pass stage 2).
    private static func kWeightingCoefficients(sampleRate: Double) -> (Biquad, Biquad) {
        // Stage 1: high-shelf boosting above ~1.68 kHz by ~4 dB.
        let f0s1 = 1681.9744509555319
        let gs1 = 3.999843853973347
        let qs1 = 0.7071752369554196
        let ks1 = tan(Double.pi * f0s1 / sampleRate)
        let vh = pow(10.0, gs1 / 20.0)
        let vb = pow(vh, 0.4996667741545416)
        let a0s1 = 1.0 + ks1 / qs1 + ks1 * ks1
        let stage1 = Biquad(
            b0: (vh + vb * ks1 / qs1 + ks1 * ks1) / a0s1,
            b1: 2.0 * (ks1 * ks1 - vh) / a0s1,
            b2: (vh - vb * ks1 / qs1 + ks1 * ks1) / a0s1,
            a1: 2.0 * (ks1 * ks1 - 1.0) / a0s1,
            a2: (1.0 - ks1 / qs1 + ks1 * ks1) / a0s1
        )

        // Stage 2: RLB high-pass removing content below ~38 Hz.
        let f0s2 = 38.13547087602444
        let qs2 = 0.5003270373238773
        let ks2 = tan(Double.pi * f0s2 / sampleRate)
        let a0s2 = 1.0 + ks2 / qs2 + ks2 * ks2
        let stage2 = Biquad(
            b0: 1.0,
            b1: -2.0,
            b2: 1.0,
            a1: 2.0 * (ks2 * ks2 - 1.0) / a0s2,
            a2: (1.0 - ks2 / qs2 + ks2 * ks2) / a0s2
        )
        return (stage1, stage2)
    }

    @inline(__always)
    private func kWeight(_ x: Double, _ state: inout ChannelFilterState) -> Double {
        // Direct Form II transposed, both stages cascaded.
        let y1 = stage1.b0 * x + state.s1z1
        state.s1z1 = stage1.b1 * x - stage1.a1 * y1 + state.s1z2
        state.s1z2 = stage1.b2 * x - stage1.a2 * y1
        let y2 = stage2.b0 * y1 + state.s2z1
        state.s2z1 = stage2.b1 * y1 - stage2.a1 * y2 + state.s2z2
        state.s2z2 = stage2.b2 * y1 - stage2.a2 * y2
        return y2
    }

    @inline(__always)
    private func binIndex(for loudnessLUFS: Double) -> Int {
        let raw = Int(((loudnessLUFS - Self.histogramMinLUFS) / Self.histogramResolution).rounded())
        return min(max(raw, 0), Self.histogramBinCount - 1)
    }

    /// Feeds one block of interleaved audio (the same samples the destination is about to play,
    /// e.g. the ring-read buffer the AUHAL output callback hands to the device). `channels` must
    /// equal `channelCount`.
    func process(_ buffer: UnsafePointer<Float>, frames: Int, channels: Int) {
        var frame = 0
        while frame < frames {
            for ch in 0..<channelCount {
                let x = Double(buffer[frame * channels + ch])
                let y = kWeight(x, &filterState[ch])
                stepSumSquares[ch] += y * y
                accumulateTruePeak(x, &filterState[ch])
            }
            stepSampleCount += 1
            frame += 1
            if stepSampleCount >= stepFrames {
                finalizeStep()
                stepSampleCount = 0
                for ch in 0..<channelCount { stepSumSquares[ch] = 0 }
            }
        }
    }

    /// Catmull-Rom interpolation between the previous two raw samples and the new one, tracking
    /// the peak across the 4x-oversampled intersample points.
    @inline(__always)
    private func accumulateTruePeak(_ x: Double, _ state: inout ChannelFilterState) {
        defer {
            state.peakPrev2 = state.peakPrev1
            state.peakPrev1 = x
            state.hasPeakHistory = true
        }
        var peak = abs(x)
        guard state.hasPeakHistory else {
            if peak > stepPeak { stepPeak = peak }
            return
        }
        let p0 = state.peakPrev2, p1 = state.peakPrev1, p2 = x, p3 = x
        for tap in 1..<4 {
            let t = Double(tap) / 4.0
            let t2 = t * t
            let t3 = t2 * t
            let interp = 0.5 * (
                (2 * p1)
                + (-p0 + p2) * t
                + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
                + (-p0 + 3 * p1 - 3 * p2 + p3) * t3
            )
            let a = abs(interp)
            if a > peak { peak = a }
        }
        if peak > stepPeak { stepPeak = peak }
    }

    private func finalizeStep() {
        var z = 0.0
        for ch in 0..<channelCount {
            z += channelWeights[ch] * (stepSumSquares[ch] / Double(stepSampleCount))
        }

        momentarySum -= momentaryRing[momentaryIndex]
        momentaryRing[momentaryIndex] = z
        momentarySum += z
        momentaryIndex = (momentaryIndex + 1) % Self.momentarySteps
        momentaryFilled = min(momentaryFilled + 1, Self.momentarySteps)
        momentaryPtr.pointee = Self.loudness(ofAverageZ: momentarySum / Double(momentaryFilled))

        shortTermSum -= shortTermRing[shortTermIndex]
        shortTermRing[shortTermIndex] = z
        shortTermSum += z
        shortTermIndex = (shortTermIndex + 1) % Self.shortTermSteps
        shortTermFilled = min(shortTermFilled + 1, Self.shortTermSteps)
        shortTermPtr.pointee = Self.loudness(ofAverageZ: shortTermSum / Double(shortTermFilled))

        let blockLoudness = Self.loudness(ofZ: z)
        if blockLoudness >= Float(Self.histogramMinLUFS) {
            sumAbsGatedZ += z
            countAbsGatedZ += 1
            let bin = binIndex(for: Double(blockLoudness))
            histogramCount[bin] += 1
            histogramSumZ[bin] += z
        }

        let peakDB = stepPeak > 0 ? 20 * log10(stepPeak) : -Double.infinity
        truePeakPtr.pointee = Float(peakDB)
        stepPeak = 0
    }

    @inline(__always)
    private static func loudness(ofZ z: Double) -> Float {
        z > 0 ? Float(-0.691 + 10 * log10(z)) : -.infinity
    }

    @inline(__always)
    private static func loudness(ofAverageZ avgZ: Double) -> Float {
        avgZ > 0 ? Float(-0.691 + 10 * log10(avgZ)) : -.infinity
    }

    // MARK: - Reads (main thread)

    /// K-weighted loudness of the trailing 400 ms, in LUFS. `-infinity` before any audio.
    var momentaryLUFS: Float { momentaryPtr.pointee }

    /// K-weighted loudness of the trailing 3 s, in LUFS. `-infinity` before any audio.
    var shortTermLUFS: Float { shortTermPtr.pointee }

    /// 4x-oversampled true peak of the most recent 100 ms step, in dBTP.
    var truePeakDBTP: Float { truePeakPtr.pointee }

    /// Gated integrated loudness (ITU-R BS.1770-4 §3: absolute gate at -70 LUFS, then a relative
    /// gate at -10 LU below the absolute-gated mean) over everything processed since the last
    /// `resetIntegrated()`. `-infinity` if nothing has passed the absolute gate yet.
    ///
    /// Cheap enough to call every meter tick: it scans the fixed-size histogram (a few hundred
    /// microseconds), not the full block history.
    func integratedLUFS() -> Float {
        guard countAbsGatedZ > 0 else { return -.infinity }
        let avgZ1 = sumAbsGatedZ / Double(countAbsGatedZ)
        let gamma1 = -0.691 + 10 * log10(avgZ1)
        let relativeThreshold = gamma1 - 10.0

        var sumZ2 = 0.0
        var countZ2 = 0
        for bin in 0..<Self.histogramBinCount where histogramCount[bin] > 0 {
            let binLoudness = Self.histogramMinLUFS + Double(bin) * Self.histogramResolution
            if binLoudness >= relativeThreshold {
                sumZ2 += histogramSumZ[bin]
                countZ2 += histogramCount[bin]
            }
        }
        guard countZ2 > 0 else { return Float(gamma1) }
        let avgZ2 = sumZ2 / Double(countZ2)
        return Float(-0.691 + 10 * log10(avgZ2))
    }

    /// Clears integrated-loudness accumulation (absolute-gate totals and the histogram) without
    /// touching momentary/short-term state. Called from the main thread (a UI button); the
    /// audio thread may be mid-step, which at worst drops one 100 ms block — the same benign
    /// race the mix matrix already accepts on a routing change.
    func resetIntegrated() {
        sumAbsGatedZ = 0
        countAbsGatedZ = 0
        histogramCount.update(repeating: 0, count: Self.histogramBinCount)
        histogramSumZ.update(repeating: 0, count: Self.histogramBinCount)
    }
}

// MARK: - Offline whole-file measurement (soundboard loudness matching)

extension LoudnessMeter {
    /// Integrated loudness (ITU-R BS.1770-4) of a complete interleaved buffer. Not real-time
    /// safe (allocates a meter instance) — used off the main thread by the soundboard's
    /// import-time loudness matching, not on any audio IO thread.
    static func integratedLoudness(samples: UnsafePointer<Float>, frames: Int, channels: Int, sampleRate: Double) -> Float {
        guard frames > 0, channels >= 1 else { return -.infinity }
        let meter = LoudnessMeter(sampleRate: sampleRate, channelCount: channels)
        let chunk = 4096
        var offset = 0
        while offset < frames {
            let n = min(chunk, frames - offset)
            meter.process(samples + offset * channels, frames: n, channels: channels)
            offset += n
        }
        return meter.integratedLUFS()
    }
}
