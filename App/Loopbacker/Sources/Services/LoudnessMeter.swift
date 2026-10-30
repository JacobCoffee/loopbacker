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
    }

    private let stage1: Biquad
    private let stage2: Biquad
    /// BS.1770 channel weighting (G): center/L/R channels are 1.0; a stereo or mono meter (the
    /// only configurations this app's virtual devices and soundboard clips use) is always 1.0
    /// on every channel.
    private let channelWeights: [Double]
    private var filterState: [ChannelFilterState]

    // MARK: - True peak (ITU-R BS.1770-4/5 Annex 2): 4x oversampling via a 48-tap, 4-phase
    // polyphase FIR -- the standard's published example filter, exact coefficients (not a
    // generated approximation). Each phase is a 12-tap FIR against a 12-sample circular history
    // per channel; every incoming sample produces 4 interpolated points 1/4 sample apart, and
    // the true peak is the max |value| seen across all of them.

    private static let truePeakTaps = 12
    private static let truePeakPhases = 4
    /// Source coefficients, read only once -- during `init`, to flatten into
    /// `truePeakCoefficientsFlat` below. Swift's `static let` is lazily (and thread-safely)
    /// initialized on first touch; if that first touch happened inside `accumulateTruePeak`
    /// (the IO callback) it would allocate the nested `[[Double]]` on the real-time thread.
    /// Touching it here in `init` instead (never read again after that) keeps that one-time
    /// allocation off the audio thread.
    private static let truePeakCoefficients: [[Double]] = [
        [
            0.001708984375, 0.010986328125, -0.0196533203125, 0.033203125,
            -0.0594482421875, 0.1373291015625, 0.97216796875, -0.102294921875,
            0.047607421875, -0.026611328125, 0.014892578125, -0.00830078125,
        ],
        [
            -0.0291748046875, 0.029296875, -0.0517578125, 0.089111328125, -0.16650390625,
            0.465087890625, 0.77978515625, -0.2003173828125, 0.1015625, -0.0582275390625,
            0.0330810546875, -0.0189208984375,
        ],
        [
            -0.0189208984375, 0.0330810546875, -0.0582275390625, 0.1015625,
            -0.2003173828125, 0.77978515625, 0.465087890625, -0.16650390625,
            0.089111328125, -0.0517578125, 0.029296875, -0.0291748046875,
        ],
        [
            -0.00830078125, 0.014892578125, -0.026611328125, 0.047607421875,
            -0.102294921875, 0.97216796875, 0.1373291015625, -0.0594482421875,
            0.033203125, -0.0196533203125, 0.010986328125, 0.001708984375,
        ],
    ]
    /// Flattened `truePeakPhases * truePeakTaps` coefficients, phase-major (`[phase * taps +
    /// tap]`), materialized from `truePeakCoefficients` once in `init` (non-real-time). Only
    /// this flat buffer -- never `truePeakCoefficients` itself -- is read from
    /// `accumulateTruePeak` (the IO callback), so there's no static-initialization or
    /// array-of-arrays bridging work on the real-time thread.
    private var truePeakCoefficientsFlat: UnsafeMutablePointer<Double>
    /// `channelCount * truePeakTaps` circular history, laid out per channel: `history[ch *
    /// truePeakTaps ..< (ch + 1) * truePeakTaps]`. Preallocated in `init`, mutated in place.
    private var truePeakHistory: UnsafeMutablePointer<Double>
    /// Per-channel write position within its 12-slot history (the index holding the most
    /// recently pushed sample).
    private var truePeakWriteIndex: UnsafeMutablePointer<Int>
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
    /// Bumped whenever momentary/short-term/true-peak/integrated state actually changes (a new
    /// 100 ms step, a consumed reset, or `clearLiveWindows`) -- callers that publish readings on
    /// a timer (`AudioRouter`) compare this against the value they last published instead of
    /// unconditionally re-reading and republishing every tick.
    private let changeGenerationPtr: UnsafeMutablePointer<Int>
    /// Set by `resetIntegrated()` (any thread), consumed only where it's safe to mutate the
    /// histogram/totals without racing a concurrent writer: a 100 ms step boundary inside
    /// `process` (this meter's own audio thread), or externally via `consumePendingReset()` once
    /// a caller has confirmed there's no concurrent writer (see that method).
    private let resetRequestedPtr: UnsafeMutablePointer<Bool>

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
        truePeakCoefficientsFlat = .allocate(capacity: Self.truePeakPhases * Self.truePeakTaps)
        for phase in 0..<Self.truePeakPhases {
            for tap in 0..<Self.truePeakTaps {
                truePeakCoefficientsFlat[phase * Self.truePeakTaps + tap] = Self.truePeakCoefficients[phase][tap]
            }
        }
        truePeakHistory = .allocate(capacity: channelCount * Self.truePeakTaps)
        truePeakHistory.initialize(repeating: 0, count: channelCount * Self.truePeakTaps)
        truePeakWriteIndex = .allocate(capacity: channelCount)
        truePeakWriteIndex.initialize(repeating: 0, count: channelCount)
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
        changeGenerationPtr = .allocate(capacity: 1)
        changeGenerationPtr.initialize(to: 0)
        resetRequestedPtr = .allocate(capacity: 1)
        resetRequestedPtr.initialize(to: false)
    }

    deinit {
        momentaryRing.deallocate()
        shortTermRing.deallocate()
        histogramCount.deallocate()
        histogramSumZ.deallocate()
        momentaryPtr.deallocate()
        shortTermPtr.deallocate()
        truePeakPtr.deallocate()
        truePeakHistory.deallocate()
        truePeakWriteIndex.deallocate()
        truePeakCoefficientsFlat.deallocate()
        changeGenerationPtr.deallocate()
        resetRequestedPtr.deallocate()
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
                accumulateTruePeak(x, channel: ch)
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

    /// Pushes one raw sample into the channel's 12-sample circular history, then runs all 4
    /// polyphase FIR phases against it -- 4 points spaced 1/4 sample apart, interpolating the
    /// continuous-time waveform between this sample and its neighbors per BS.1770-4/5 Annex 2.
    /// Tracks the peak across all 4 phases (and so implicitly the original samples too: one
    /// phase's dominant tap sits near unity gain, close to a pass-through). Reads only
    /// `truePeakCoefficientsFlat` (materialized in `init`), never the static source array.
    @inline(__always)
    private func accumulateTruePeak(_ x: Double, channel: Int) {
        let taps = Self.truePeakTaps
        let base = channel * taps
        let head = truePeakWriteIndex[channel]
        truePeakHistory[base + head] = x

        for phase in 0..<Self.truePeakPhases {
            let phaseBase = phase * taps
            var acc = 0.0
            var lag = 0
            while lag < taps {
                let idx = base + (head - lag + taps) % taps
                acc += truePeakCoefficientsFlat[phaseBase + lag] * truePeakHistory[idx]
                lag += 1
            }
            let a = abs(acc)
            if a > stepPeak { stepPeak = a }
        }

        truePeakWriteIndex[channel] = (head + 1) % taps
    }

    private func finalizeStep() {
        changeGenerationPtr.pointee &+= 1
        // A step boundary on this meter's own audio thread is a safe point to mutate the
        // integrated-loudness histogram/totals -- nothing else writes them concurrently here --
        // so a pending `resetIntegrated()` request is applied before this step's own data joins
        // the (now-cleared) accumulation below.
        consumePendingReset()

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

        // Integrated-loudness gating (ITU-R BS.1770-4 §3) operates on 400 ms blocks stepped
        // every 100 ms (75% overlap), not on raw 100 ms steps: each gating block's energy is the
        // mean of the 4 most recent 100 ms step energies -- `momentarySum / momentarySteps`, the
        // same window `momentaryLUFS` already tracks -- not this one step's `z` alone. Nothing
        // is gated until a full 400 ms has accumulated.
        if momentaryFilled == Self.momentarySteps {
            let blockZ = momentarySum / Double(Self.momentarySteps)
            let blockLoudness = Self.loudness(ofZ: blockZ)
            if blockLoudness >= Float(Self.histogramMinLUFS) {
                sumAbsGatedZ += blockZ
                countAbsGatedZ += 1
                let bin = binIndex(for: Double(blockLoudness))
                histogramCount[bin] += 1
                histogramSumZ[bin] += blockZ
            }
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

    /// Bumped on every 100 ms step and every applied reset/clear -- callers that publish on a
    /// timer compare this against the value they last saw instead of recomputing every tick.
    var changeGeneration: Int { changeGenerationPtr.pointee }

    /// Gated integrated loudness (ITU-R BS.1770-4 §3: absolute gate at -70 LUFS, then a relative
    /// gate at -10 LU below the absolute-gated mean) over everything processed since the last
    /// `resetIntegrated()`. `-infinity` if nothing has passed the absolute gate yet, or if a
    /// reset was requested but not yet physically applied (a reset must be visible to readers
    /// the instant it's requested, not only once the audio thread gets around to consuming it --
    /// see `resetIntegrated`).
    ///
    /// Cheap enough to call every meter tick: it scans the fixed-size histogram (a few hundred
    /// microseconds), not the full block history.
    func integratedLUFS() -> Float {
        guard !resetRequestedPtr.pointee else { return -.infinity }
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

    /// Requests that integrated-loudness accumulation (absolute-gate totals and the histogram)
    /// be cleared, without touching momentary/short-term state. Safe to call from any thread (a
    /// UI button): only sets a flag here -- `integratedLUFS()` reports the reset immediately
    /// (see its doc comment), but the actual histogram/totals mutation is deferred to
    /// `consumePendingReset()`, which only ever runs somewhere with no concurrent writer, so the
    /// histogram is never torn by a main-thread clear racing an audio-thread write.
    func resetIntegrated() {
        resetRequestedPtr.pointee = true
        changeGenerationPtr.pointee &+= 1
    }

    /// Applies a pending `resetIntegrated()` request if one is set, returning whether it did.
    /// Only ever safe to call from a context with no concurrent writer: a 100 ms step boundary
    /// inside `process` (this meter's own audio thread, via `finalizeStep`), or externally once
    /// a caller (`MicLoudnessBus`, confirmed idle) knows nothing else is writing this meter
    /// concurrently.
    @discardableResult
    func consumePendingReset() -> Bool {
        guard resetRequestedPtr.pointee else { return false }
        resetRequestedPtr.pointee = false
        sumAbsGatedZ = 0
        countAbsGatedZ = 0
        histogramCount.update(repeating: 0, count: Self.histogramBinCount)
        histogramSumZ.update(repeating: 0, count: Self.histogramBinCount)
        return true
    }

    /// Clears momentary/short-term/true-peak state (as if freshly constructed) and applies any
    /// pending reset, but otherwise leaves integrated-loudness accumulation untouched. Called
    /// when a feed goes idle so the UI doesn't keep showing a stale momentary/short-term/
    /// true-peak reading -- so "On target" doesn't linger once nothing is playing. Like
    /// `consumePendingReset()`, only safe to call where there's no concurrent writer.
    func clearLiveWindows() {
        consumePendingReset()
        changeGenerationPtr.pointee &+= 1

        for ch in 0..<channelCount { filterState[ch] = ChannelFilterState() }
        stepSampleCount = 0
        for ch in 0..<channelCount { stepSumSquares[ch] = 0 }
        stepPeak = 0

        momentaryRing.update(repeating: 0, count: Self.momentarySteps)
        momentaryIndex = 0
        momentaryFilled = 0
        momentarySum = 0
        momentaryPtr.pointee = -.infinity

        shortTermRing.update(repeating: 0, count: Self.shortTermSteps)
        shortTermIndex = 0
        shortTermFilled = 0
        shortTermSum = 0
        shortTermPtr.pointee = -.infinity

        truePeakHistory.update(repeating: 0, count: channelCount * Self.truePeakTaps)
        truePeakWriteIndex.update(repeating: 0, count: channelCount)
        truePeakPtr.pointee = -.infinity
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
