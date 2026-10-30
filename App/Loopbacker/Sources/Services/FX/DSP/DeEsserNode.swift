import Accelerate
import Foundation

/// De-esser: splits the signal into low/high bands with a 4th-order Linkwitz-Riley crossover
/// (two cascaded Butterworth lowpass/highpass sections per band at `frequency`; LR4's defining
/// property is that summing the two bands exactly reconstructs the input, magnitude *and*
/// phase, so split-band processing below doesn't introduce comb filtering) at `frequency`, then
/// reduces only the high band's gain when its stereo-linked level exceeds `threshold`, capped at
/// `range` dB (effectively an infinite-ratio compressor on the sibilant band with a hard
/// ceiling — the standard de-esser behavior of flattening harsh peaks without pumping).
///
/// Attack is fast (~0.5 ms, fast enough to catch the leading edge of a sibilant) and release
/// slow (~40 ms) so the reduction doesn't chatter syllable to syllable. `mode` picks whether the
/// computed reduction is applied only to the high band (Split-band) or to the whole signal
/// (Wideband, for sources where a simpler broadband duck is preferred).
///
/// `meters.gainReductionDB` = current reduction (positive). `meters.activity` = reduction /
/// `range`.
final class DeEsserNode: FXNode, @unchecked Sendable {
    let kind: FXNodeKind = .deEsser
    let specs = FXBuiltinSpecs.deEsser
    let params: FXParamStore
    let meters = FXMeters()
    let latencySamples = 0

    private let sampleRate: Float
    private var lastGeneration: UInt32 = .max

    private var lpCoeffs: FXBiquadCoeffs
    private var hpCoeffs: FXBiquadCoeffs
    private var lpStateL1 = FXBiquadState(), lpStateL2 = FXBiquadState()
    private var lpStateR1 = FXBiquadState(), lpStateR2 = FXBiquadState()
    private var hpStateL1 = FXBiquadState(), hpStateL2 = FXBiquadState()
    private var hpStateR1 = FXBiquadState(), hpStateR2 = FXBiquadState()

    private var threshold: Float = -30
    private var range: Float = 8
    private var wideband = false
    private var envelope = FXEnvelopeDB(initial: 0)

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
        params = FXParamStore(specs: FXBuiltinSpecs.deEsser)
        lpCoeffs = FXBiquadCoeffs.make(type: .lowpass, frequency: 6500, q: 0.7071067811865476, gainDB: 0, sampleRate: Double(sampleRate))
        hpCoeffs = FXBiquadCoeffs.make(type: .highpass, frequency: 6500, q: 0.7071067811865476, gainDB: 0, sampleRate: Double(sampleRate))
        envelope.setTimes(attackMs: 0.5, releaseMs: 40, sampleRate: sampleRate)
    }

    private func refreshParams() {
        let gen = params.generation
        guard gen != lastGeneration else { return }
        lastGeneration = gen
        let freq = Double(params.get(0))
        lpCoeffs = FXBiquadCoeffs.make(type: .lowpass, frequency: freq, q: 0.7071067811865476, gainDB: 0, sampleRate: Double(sampleRate))
        hpCoeffs = FXBiquadCoeffs.make(type: .highpass, frequency: freq, q: 0.7071067811865476, gainDB: 0, sampleRate: Double(sampleRate))
        threshold = params.get(1)
        range = params.get(2)
        wideband = params.get(3) >= 0.5
    }

    func reset() {
        lpStateL1.reset(); lpStateL2.reset(); lpStateR1.reset(); lpStateR2.reset()
        hpStateL1.reset(); hpStateL2.reset(); hpStateR1.reset(); hpStateR2.reset()
        envelope.reset(to: 0)
    }

    func process(_ block: FXBlock) {
        refreshParams()
        meters.inputPeak = fxBlockPeak(block)

        for i in 0..<block.frames {
            let l = block.left[i]
            let r = block.channels == 2 ? block.right[i] : l

            let lowL = Float(lpStateL2.process(lpStateL1.process(Double(l), lpCoeffs), lpCoeffs))
            let highL = Float(hpStateL2.process(hpStateL1.process(Double(l), hpCoeffs), hpCoeffs))
            let lowR: Float, highR: Float
            if block.channels == 2 {
                lowR = Float(lpStateR2.process(lpStateR1.process(Double(r), lpCoeffs), lpCoeffs))
                highR = Float(hpStateR2.process(hpStateR1.process(Double(r), hpCoeffs), hpCoeffs))
            } else {
                lowR = lowL
                highR = highL
            }

            let sibilance = max(abs(highL), abs(highR))
            let levelDB = fxLinearToDB(sibilance)
            let overshoot = max(0, levelDB - threshold)
            let targetReduction = min(range, overshoot)
            let reduction = max(0, envelope.next(targetReduction))
            let gain = fxDBToLinear(-reduction)

            if wideband {
                block.left[i] = l * gain
                if block.channels == 2 { block.right[i] = r * gain }
            } else {
                block.left[i] = lowL + highL * gain
                if block.channels == 2 { block.right[i] = lowR + highR * gain }
            }

            meters.gainReductionDB = reduction
            meters.activity = range > 0 ? reduction / range : 0
        }
        meters.outputPeak = fxBlockPeak(block)
    }
}
