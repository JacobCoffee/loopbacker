import Accelerate
import Foundation

/// Auto-leveler that holds the speaker's voice at a target loudness, ITU-R BS.1770-style: a
/// K-weighting pre-filter (high-shelf ~+4 dB above ~1.68 kHz, then a high-pass at ~38 Hz, the
/// standard two-stage filter from the recommendation) feeds a mean-square integrator over a
/// 400 ms momentary window, converted to LUFS.
///
/// The gain only moves while the chain's voice activity detector reports speech
/// (`block.sidechain.voiceProbability > 0.5`): during pauses the measured loudness collapses
/// toward silence, and a leveler that chased that would ramp gain up during every pause and slam
/// it down at the next word (pumping the room noise). Holding the gain during non-speech and
/// only re-measuring on voiced frames is the standard way broadcast auto-levelers avoid that.
///
/// `speed` sets the one-pole time constant the gain moves toward its target with; `maxBoost`/
/// `maxCut` clamp the total applied gain.
///
/// `meters.activity` = momentary loudness mapped -60...0 LUFS -> 0...1.
/// `meters.gainReductionDB` = documented here as *cut*: negative values mean the leveler is
/// currently *boosting* (the sign most dynamics meters use is reduction-positive; a leveler
/// spends at least as much time boosting quiet voices, so this stage reports the signed amount
/// instead of clamping boosts to zero).
final class LevelerNode: FXNode, @unchecked Sendable {
    let kind: FXNodeKind = .leveler
    let specs = FXBuiltinSpecs.leveler
    let params: FXParamStore
    let meters = FXMeters()
    let latencySamples = 0

    private let sampleRate: Float
    private var lastGeneration: UInt32 = .max

    private var targetLUFS: Float = -18
    private var maxBoostDB: Float = 12
    private var maxCutDB: Float = 12
    private var gainCoeff: Float = 0

    // K-weighting: stage 1 high-shelf (~+4 dB at high frequencies), stage 2 high-pass.
    private let shelfCoeffs: FXBiquadCoeffs
    private let hpCoeffs: FXBiquadCoeffs
    private var shelfStateL = FXBiquadState()
    private var shelfStateR = FXBiquadState()
    private var hpStateL = FXBiquadState()
    private var hpStateR = FXBiquadState()

    /// Sliding sum of squares over the momentary (400 ms) window via a preallocated ring of
    /// per-sample squared, K-weighted mono energy.
    private let windowFrames: Int
    private let windowBuffer: UnsafeMutablePointer<Float>
    private var windowWrite = 0
    private var windowFilled = 0
    private var windowSum: Double = 0

    private var currentGainDB: Float = 0

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
        params = FXParamStore(specs: FXBuiltinSpecs.leveler)
        shelfCoeffs = FXBiquadCoeffs.make(type: .highshelf, frequency: 1681.9744509555319, q: 0.7071752369554196, gainDB: 3.999843853973347, sampleRate: Double(sampleRate))
        hpCoeffs = FXBiquadCoeffs.make(type: .highpass, frequency: 38.13547087602444, q: 0.5003270373238773, gainDB: 0, sampleRate: Double(sampleRate))
        windowFrames = max(1, Int(0.4 * sampleRate))
        windowBuffer = .allocate(capacity: windowFrames)
        windowBuffer.initialize(repeating: 0, count: windowFrames)
    }

    deinit {
        windowBuffer.deallocate()
    }

    private func refreshParams() {
        let gen = params.generation
        guard gen != lastGeneration else { return }
        lastGeneration = gen
        targetLUFS = params.get(0)
        maxBoostDB = params.get(1)
        maxCutDB = params.get(2)
        gainCoeff = fxTimeCoeff(ms: params.get(3), sampleRate: sampleRate)
    }

    func reset() {
        shelfStateL.reset(); shelfStateR.reset(); hpStateL.reset(); hpStateR.reset()
        windowBuffer.update(repeating: 0, count: windowFrames)
        windowWrite = 0
        windowFilled = 0
        windowSum = 0
        currentGainDB = 0
    }

    func process(_ block: FXBlock) {
        refreshParams()
        meters.inputPeak = fxBlockPeak(block)
        let voiced = block.sidechain.voiceProbability > 0.5

        for i in 0..<block.frames {
            let l = block.left[i]
            let r = block.channels == 2 ? block.right[i] : l

            // K-weight each channel, then combine per BS.1770's mean-square sum (mono voice:
            // equal weight per channel).
            var kl = Float(shelfStateL.process(Double(l), shelfCoeffs))
            kl = Float(hpStateL.process(Double(kl), hpCoeffs))
            var kr = Float(shelfStateR.process(Double(r), shelfCoeffs))
            kr = Float(hpStateR.process(Double(kr), hpCoeffs))
            let energy = Double(kl * kl + kr * kr) / Double(block.channels)

            let old = Double(windowBuffer[windowWrite])
            windowBuffer[windowWrite] = Float(energy)
            windowWrite = (windowWrite + 1) % windowFrames
            windowSum = fxFlush(windowSum - old + energy)
            if windowFilled < windowFrames { windowFilled += 1 }

            let meanSquare = windowSum / Double(max(windowFilled, 1))
            // BS.1770: LUFS = -0.691 + 10*log10(mean square).
            let momentaryLUFS = Float(-0.691 + 10 * log10(max(meanSquare, 1e-12)))

            if voiced {
                let desired = targetLUFS - momentaryLUFS
                let clamped = min(maxBoostDB, max(-maxCutDB, desired))
                currentGainDB = clamped + gainCoeff * (currentGainDB - clamped)
            }
            // else: hold currentGainDB.

            let gain = fxDBToLinear(currentGainDB)
            block.left[i] = l * gain
            if block.channels == 2 { block.right[i] = r * gain }

            meters.activity = min(1, max(0, (momentaryLUFS + 60) / 60))
            meters.gainReductionDB = -currentGainDB
        }
        meters.outputPeak = fxBlockPeak(block)
    }
}
