import Accelerate
import Foundation

/// Brickwall true-peak limiter. "True peak" means the ceiling is enforced on the signal as a DAC
/// would reconstruct it between samples, not just on the sample values themselves — a signal
/// can sit under 0 dBFS at every sample and still clip the analog output if its reconstructed
/// waveform overshoots between them (a sine near Nyquist/4 is the classic example). This stage
/// detects that by a 4x polyphase-FIR oversampled peak estimate of each lookahead sample.
///
/// Algorithm (the standard lookahead-brickwall design):
/// 1. `inputGain` drives the signal in before detection.
/// 2. Each sample's true-peak estimate feeds a ~1.5 ms lookahead window. A monotonic deque keeps
///    the running minimum "safe gain" (`ceiling / peak`, clamped to ≤ 1) over that window in
///    O(1) amortized per sample — the same trick as a sliding-window-minimum, applied to gain
///    instead of a raw value, so a peak anywhere in the lookahead immediately pulls the gain
///    down *before* that sample is output (true lookahead, not reactive attack).
/// 3. The applied gain is smoothed *down* instantly to the deque's minimum (so it's always safe)
///    but only recovers *up* at the `release` rate, so gain doesn't flap on dense peaks.
///
/// Because the gain for sample `t` already accounts for peaks up to `t + lookahead`, the stage
/// delays its output by `latencySamples` (the lookahead) to align gain and audio.
final class LimiterNode: FXNode, @unchecked Sendable {
    /// Oversampling factor for true-peak detection.
    private static let oversample = 4
    private static let lookaheadMs: Float = 1.5
    /// Polyphase FIR length per phase. 48 taps/phase (192 total across 4 phases) keeps the
    /// windowed-sinc reconstruction accurate enough all the way to Nyquist, where a short
    /// filter's truncation loss would otherwise make the detector under-read inter-sample
    /// peaks on near-Nyquist content.
    private static let firTapsPerPhase = 64

    let kind: FXNodeKind = .limiter
    let specs = FXBuiltinSpecs.limiter
    let params: FXParamStore
    let meters = FXMeters()
    let latencySamples: Int

    private let sampleRate: Float
    private var lastGeneration: UInt32 = .max

    private var inputGain: FXSmoother
    private var ceilingLinear: Float = fxDBToLinear(-1)
    private var releaseCoeff: Float = 0

    // MARK: Polyphase true-peak FIR (windowed sinc, `oversample` phases x `firTapsPerPhase` taps)
    private let firTaps: UnsafeMutablePointer<Float> // [phase][tap], row-major
    private let historyL: UnsafeMutablePointer<Float>
    private let historyR: UnsafeMutablePointer<Float>
    private let historyMask: Int
    private var historyWrite = 0

    // MARK: Lookahead delay for the audio path (input gain applied, pre true-peak estimation).
    private let delayFrames: Int
    private let delayMask: Int
    private let delayL: UnsafeMutablePointer<Float>
    private let delayR: UnsafeMutablePointer<Float>
    private var delayWrite = 0

    // MARK: Monotonic deque of (sample index, true-peak magnitude), descending index / descending
    // peak, so the front is always the maximum peak (== minimum safe gain, recomputed from the
    // *current* ceiling on every read, not baked in at push time) still inside the lookahead
    // window.
    private let dequeIndex: UnsafeMutablePointer<Int>
    private let dequePeak: UnsafeMutablePointer<Float>
    private let dequeCapacity: Int
    private var dequeHead = 0
    private var dequeTail = 0 // one-past-last
    private var sampleCounter = 0

    private var currentGain: Float = 1

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
        params = FXParamStore(specs: FXBuiltinSpecs.limiter)
        inputGain = FXSmoother(initial: 1, timeMs: 10, sampleRate: sampleRate)
        latencySamples = max(1, Int((Self.lookaheadMs / 1000 * sampleRate).rounded()))

        let os = Self.oversample
        let taps = Self.firTapsPerPhase
        firTaps = .allocate(capacity: os * taps)
        // Windowed-sinc polyphase interpolator: phase p's filter samples the ideal sinc
        // reconstruction at offset p/os between input samples.
        let center = Float(taps - 1) / 2
        for p in 0..<os {
            let frac = Float(p) / Float(os)
            for t in 0..<taps {
                let x = Float(t) - center - frac
                let sinc: Float = abs(x) < 1e-6 ? 1 : sinf(.pi * x) / (.pi * x)
                // Hann window over the tap span for a clean low-pass skirt.
                let window = 0.5 - 0.5 * cosf(2 * .pi * (Float(t) + 0.5) / Float(taps))
                firTaps[p * taps + t] = sinc * window
            }
        }

        let historySize = 1 << (Int.bitWidth - (taps - 1).leadingZeroBitCount)
        historyMask = historySize - 1
        historyL = .allocate(capacity: historySize); historyL.initialize(repeating: 0, count: historySize)
        historyR = .allocate(capacity: historySize); historyR.initialize(repeating: 0, count: historySize)

        delayFrames = latencySamples + 1
        let dSize = 1 << (Int.bitWidth - (delayFrames - 1).leadingZeroBitCount)
        delayMask = dSize - 1
        delayL = .allocate(capacity: dSize); delayL.initialize(repeating: 0, count: dSize)
        delayR = .allocate(capacity: dSize); delayR.initialize(repeating: 0, count: dSize)

        dequeCapacity = delayFrames + 4
        dequeIndex = .allocate(capacity: dequeCapacity)
        dequePeak = .allocate(capacity: dequeCapacity)
    }

    deinit {
        firTaps.deallocate()
        historyL.deallocate(); historyR.deallocate()
        delayL.deallocate(); delayR.deallocate()
        dequeIndex.deallocate(); dequePeak.deallocate()
    }

    private func refreshParams() {
        let gen = params.generation
        guard gen != lastGeneration else { return }
        lastGeneration = gen
        inputGain.target = fxDBToLinear(params.get(0))
        ceilingLinear = fxDBToLinear(params.get(1))
        releaseCoeff = fxTimeCoeff(ms: params.get(2), sampleRate: sampleRate)
    }

    func reset() {
        historyL.update(repeating: 0, count: historyMask + 1)
        historyR.update(repeating: 0, count: historyMask + 1)
        delayL.update(repeating: 0, count: delayMask + 1)
        delayR.update(repeating: 0, count: delayMask + 1)
        historyWrite = 0
        delayWrite = 0
        dequeHead = 0
        dequeTail = 0
        sampleCounter = 0
        currentGain = 1
        inputGain.snap()
    }

    /// 4x-oversampled true-peak estimate of the sample most recently pushed into `historyL/R`
    /// (which sits `firTapsPerPhase/2` samples behind the write head, centering the FIR).
    @inline(__always) private func truePeak() -> Float {
        let taps = Self.firTapsPerPhase
        var peak: Float = 0
        for p in 0..<Self.oversample {
            var accL: Float = 0, accR: Float = 0
            let rowBase = p * taps
            for t in 0..<taps {
                let idx = (historyWrite - t) & historyMask
                accL += firTaps[rowBase + t] * historyL[idx]
                accR += firTaps[rowBase + t] * historyR[idx]
            }
            peak = max(peak, abs(accL), abs(accR))
        }
        return peak
    }

    func process(_ block: FXBlock) {
        refreshParams()
        meters.inputPeak = fxBlockPeak(block)

        for i in 0..<block.frames {
            let gIn = inputGain.next()
            let l = block.left[i] * gIn
            let r = (block.channels == 2 ? block.right[i] : block.left[i]) * gIn

            historyL[historyWrite] = l
            historyR[historyWrite] = r
            historyWrite = (historyWrite + 1) & historyMask
            delayL[delayWrite] = l
            delayR[delayWrite] = r
            delayWrite = (delayWrite + 1) & delayMask

            let peak = truePeak()

            // Push (index, peak) onto the monotonic deque, discarding any trailing entries
            // whose peak is <= this one (they can never be the window maximum again while this
            // sample is still in the window) -- the standard sliding-window-maximum
            // maintenance. Storing the raw peak (not `ceilingLinear`-derived safe gain) means a
            // ceiling change between push and read is picked up immediately: the queued
            // requirement is always recomputed against the *current* ceiling below, instead of
            // baking in whatever ceiling was active when a peak was detected and letting an
            // already-queued impulse emit at the old, now-stale gain.
            while dequeTail > dequeHead && dequePeak[(dequeTail - 1) % dequeCapacity] <= peak {
                dequeTail -= 1
            }
            dequeIndex[dequeTail % dequeCapacity] = sampleCounter
            dequePeak[dequeTail % dequeCapacity] = peak
            dequeTail += 1
            // Evict entries that have fallen out of the lookahead window.
            let windowStart = sampleCounter - latencySamples
            while dequeHead < dequeTail && dequeIndex[dequeHead % dequeCapacity] < windowStart {
                dequeHead += 1
            }
            sampleCounter += 1

            let windowPeak = dequeHead < dequeTail ? dequePeak[dequeHead % dequeCapacity] : 0
            let targetGain = windowPeak > ceilingLinear ? ceilingLinear / windowPeak : 1
            if targetGain < currentGain {
                currentGain = targetGain // instant: a peak in the window must never be exceeded.
            } else {
                currentGain = targetGain + releaseCoeff * (currentGain - targetGain)
            }

            let outL = delayL[(delayWrite - delayFrames) & delayMask] * currentGain
            let outR = delayR[(delayWrite - delayFrames) & delayMask] * currentGain
            block.left[i] = outL
            if block.channels == 2 { block.right[i] = outR }

            meters.gainReductionDB = -fxLinearToDB(currentGain)
            meters.activity = currentGain
        }
        meters.outputPeak = fxBlockPeak(block)
    }
}
