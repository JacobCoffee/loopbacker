import Accelerate
import Foundation

/// Feed-forward compressor with a log-domain gain computer and soft knee, following the
/// standard formulation (Giannoulis, Massberg & Reiss, "Digital Dynamic Range Compressor
/// Design", JAES 2012): the knee blends linearly between the straight-line "below threshold,
/// no reduction" and "above threshold, 1/ratio slope" segments over `knee` dB centered on
/// `threshold`, giving a parabolic (C1-continuous) transition instead of a sharp corner.
///
/// Detection is stereo-linked (`max(|L|, |R|)`) so compression doesn't shift the image; peak or
/// RMS (`detector`) picks the ballistic character. Attack/release are smooth branching dB
/// envelopes (`FXEnvelopeDB`). `makeup` adds flat gain after compression; `mix` blends with the
/// uncompressed signal (parallel/New-York compression) after makeup, so turning mix down doesn't
/// also undo the makeup gain on the dry path the user is blending toward.
///
/// `meters.gainReductionDB` = current reduction (positive number, 0 = none).
/// `meters.activity` = same reduction mapped 0...1 against a 24 dB reference for a UI meter.
final class CompressorNode: FXNode, @unchecked Sendable {
    let kind: FXNodeKind = .compressor
    let specs = FXBuiltinSpecs.compressor
    let params: FXParamStore
    let meters = FXMeters()
    let latencySamples = 0

    private let sampleRate: Float
    private var lastGeneration: UInt32 = .max

    private var threshold: Float = -20
    private var ratio: Float = 3
    private var knee: Float = 6
    private var useRMS = true
    private var makeup: FXSmoother
    private var mix: FXSmoother

    /// Tracks gain reduction magnitude (0 = none, positive = dB of reduction).
    private var envelope = FXEnvelopeDB(initial: 0)
    /// RMS detector state: mean of squares, one-pole smoothed (~10 ms window regardless of
    /// attack/release, matching how most RMS-detector compressors behave).
    private var rmsState: Double = 0
    private let rmsCoeff: Float

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
        params = FXParamStore(specs: FXBuiltinSpecs.compressor)
        makeup = FXSmoother(initial: 1, timeMs: 20, sampleRate: sampleRate)
        mix = FXSmoother(initial: 1, timeMs: 20, sampleRate: sampleRate)
        rmsCoeff = fxTimeCoeff(ms: 10, sampleRate: sampleRate)
    }

    private func refreshParams() {
        let gen = params.generation
        guard gen != lastGeneration else { return }
        lastGeneration = gen
        threshold = params.get(0)
        ratio = params.get(1)
        knee = params.get(2)
        envelope.setTimes(attackMs: params.get(3), releaseMs: params.get(4), sampleRate: sampleRate)
        useRMS = params.get(5) >= 0.5
        makeup.target = fxDBToLinear(params.get(6))
        mix.target = params.get(7) / 100
    }

    func reset() {
        envelope.reset(to: 0)
        rmsState = 0
        makeup.snap()
        mix.snap()
    }

    /// Static gain computer: input level in dB -> output level in dB, with the soft-knee blend.
    @inline(__always) private func computeCurve(_ inputDB: Float) -> Float {
        let overshoot = inputDB - threshold
        if knee <= 0 {
            return overshoot <= 0 ? inputDB : threshold + overshoot / ratio
        }
        let half = knee / 2
        if overshoot <= -half {
            return inputDB
        } else if overshoot >= half {
            return threshold + overshoot / ratio
        } else {
            // Parabolic knee segment (Giannoulis et al. eq. 4).
            let x = overshoot + half
            return inputDB + (1 / ratio - 1) * x * x / (2 * knee)
        }
    }

    func process(_ block: FXBlock) {
        refreshParams()
        meters.inputPeak = fxBlockPeak(block)

        for i in 0..<block.frames {
            let l = block.left[i]
            let r = block.channels == 2 ? block.right[i] : l
            let linked = max(abs(l), abs(r))

            let detectorLevel: Float
            if useRMS {
                let sq = Double(linked) * Double(linked)
                rmsState = fxFlush(sq + Double(rmsCoeff) * (rmsState - sq))
                detectorLevel = Float(sqrt(rmsState))
            } else {
                detectorLevel = linked
            }
            let inputDB = fxLinearToDB(detectorLevel)
            let outputDB = computeCurve(inputDB)
            // Positive magnitude (0 = no reduction) so the generic envelope's "rising input ->
            // attack" matches "reduction deepening -> attack" here.
            let reductionTarget = max(0, inputDB - outputDB)
            let smoothedReduction = max(0, envelope.next(reductionTarget))
            let gr = -smoothedReduction
            let compGain = fxDBToLinear(gr)
            let mk = makeup.next()
            let mx = mix.next()

            let wetL = l * compGain * mk
            let wetR = r * compGain * mk
            block.left[i] = wetL * mx + l * (1 - mx)
            if block.channels == 2 { block.right[i] = wetR * mx + r * (1 - mx) }

            meters.gainReductionDB = -gr
            meters.activity = min(1, -gr / 24)
        }
        meters.outputPeak = fxBlockPeak(block)
    }
}
