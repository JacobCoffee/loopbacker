import Accelerate
import Foundation

/// Noise/breath gate with two trigger modes. The key signal is `max(|L|, |R|)` through a
/// high-pass (so rumble and breath noise below `keyHighPass` can't hold or open the gate), fed
/// into a branching dB envelope follower.
///
/// - Level mode: opens when the key envelope rises above `threshold`, closes when it falls
///   `hysteresis` dB below it, so word endings that dip near the threshold don't chatter.
/// - Voice mode: opens only when RNNoise's speech probability (`block.sidechain.voiceProbability`)
///   clears a threshold derived from `voiceSensitivity` *and* the key envelope clears
///   `threshold - hysteresis` (so the detector can never open the gate on pure silence, and a
///   fast plosive onset that the detector hasn't caught up to yet still opens the gate once it's
///   loud enough — the "level-only fallback for fast onsets").
///
/// `attack`/`release` ramp the gain in dB (perceptually linear); `hold` keeps it open after the
/// open condition drops, so trailing consonants aren't chopped. A ~2 ms lookahead delays the
/// audio path relative to the key detector so fast attacks on percussive onsets don't clip the
/// first few milliseconds.
///
/// `meters.activity` = current openness 0 (closed, `range` dB attenuation) ... 1 (fully open).
/// `meters.gainReductionDB` = current attenuation below unity, as a positive number.
final class GateNode: FXNode, @unchecked Sendable {
    let kind: FXNodeKind = .gate
    let specs = FXBuiltinSpecs.gate
    let params: FXParamStore
    let meters = FXMeters()
    let latencySamples: Int

    private let sampleRate: Float
    private var lastGeneration: UInt32 = .max

    // Cached params, refreshed when `params.generation` changes.
    private var mode = 1 // 0 = Level, 1 = Voice
    private var threshold: Float = -45
    private var hysteresis: Float = 4
    private var voiceSensitivity: Float = 50
    private var holdSamples = 0
    private var rangeDB: Float = -20
    private var keyHP = FXBiquadCoeffs.make(type: .highpass, frequency: 80, q: 0.707, gainDB: 0, sampleRate: 48_000)

    private var keyStateL = FXBiquadState()
    private var keyStateR = FXBiquadState()
    private var envelope = FXEnvelopeDB(initial: -120)
    private var isOpen = false
    private var holdCounter = 0
    /// Current gain in dB, ramped toward 0 (open) or `rangeDB` (closed) at the attack/release
    /// rate — a direct dB ramp rather than a one-pole, so `attack`/`release` are the exact time
    /// to cross the full range, matching users' expectations from other gates.
    private var gainDB: Float
    private var gainTargetDB: Float = 0
    private var dBPerSampleAttack: Float = 0
    private var dBPerSampleRelease: Float = 0

    // Lookahead ring buffer, stereo.
    private let lookaheadFrames: Int
    private let delayL: UnsafeMutablePointer<Float>
    private let delayR: UnsafeMutablePointer<Float>
    private var delayWrite = 0

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
        params = FXParamStore(specs: FXBuiltinSpecs.gate)
        lookaheadFrames = max(1, Int((0.002 * sampleRate).rounded()))
        latencySamples = lookaheadFrames
        delayL = .allocate(capacity: lookaheadFrames)
        delayR = .allocate(capacity: lookaheadFrames)
        delayL.initialize(repeating: 0, count: lookaheadFrames)
        delayR.initialize(repeating: 0, count: lookaheadFrames)
        gainDB = rangeDB
        refreshParams(force: true)
    }

    deinit {
        delayL.deallocate()
        delayR.deallocate()
    }

    private func refreshParams(force: Bool) {
        let gen = params.generation
        guard force || gen != lastGeneration else { return }
        lastGeneration = gen
        mode = params.get(0) >= 0.5 ? 1 : 0
        threshold = params.get(1)
        hysteresis = params.get(2)
        voiceSensitivity = params.get(3)
        let attackMs = params.get(4)
        holdSamples = Int(params.get(5) * sampleRate / 1000)
        let releaseMs = params.get(6)
        rangeDB = params.get(7)
        let keyFreq = params.get(8)
        keyHP = FXBiquadCoeffs.make(type: .highpass, frequency: Double(keyFreq), q: 0.707, gainDB: 0, sampleRate: Double(sampleRate))
        // Fixed (not user-exposed) key-detector smoothing: fast enough to track syllable
        // onsets, slow enough that a sample landing near a zero crossing doesn't read as
        // silence (without this, the envelope would equal the raw instantaneous key level and
        // dip to -inf dB at every zero crossing of a steady tone/voice).
        envelope.setTimes(attackMs: 1, releaseMs: 10, sampleRate: sampleRate)
        dBPerSampleAttack = abs(rangeDB) / max(attackMs * sampleRate / 1000, 1)
        dBPerSampleRelease = abs(rangeDB) / max(releaseMs * sampleRate / 1000, 1)
    }
    func reset() {
        keyStateL.reset()
        keyStateR.reset()
        envelope.reset(to: -120)
        isOpen = false
        holdCounter = 0
        gainDB = rangeDB
        gainTargetDB = rangeDB
        delayL.update(repeating: 0, count: lookaheadFrames)
        delayR.update(repeating: 0, count: lookaheadFrames)
        delayWrite = 0
    }

    func process(_ block: FXBlock) {
        refreshParams(force: false)
        meters.inputPeak = fxBlockPeak(block)

        // Voice-mode threshold: 100% sensitivity should reliably open on quiet speech (low
        // probability threshold), 0% should require near-certainty.
        let voiceThreshold = 0.9 - 0.85 * (voiceSensitivity / 100)
        let fallbackThreshold = threshold
        let openThreshold = threshold
        let closeThreshold = threshold - hysteresis

        for i in 0..<block.frames {
            let l = block.left[i]
            let r = block.channels == 2 ? block.right[i] : l
            // Filter each channel *before* rectifying: high-passing the already-rectified
            // (always non-negative) signal would reject its DC component — which carries the
            // actual sustained level — leaving only a small ripple at 2x the input frequency
            // and making the gate see a near-silent key for any steady tone or held note.
            let keyL = Float(keyStateL.process(Double(l), keyHP))
            let keyR = block.channels == 2 ? Float(keyStateR.process(Double(r), keyHP)) : keyL
            let keyed = max(abs(keyL), abs(keyR))
            let keyDB = fxLinearToDB(keyed)
            let envDB = envelope.next(keyDB)

            let levelOpen = envDB > (isOpen ? closeThreshold : openThreshold)
            let wantOpen: Bool
            if mode == 1 {
                let voiceSays = block.sidechain.voiceProbability >= voiceThreshold
                let keyAboveFloor = envDB > closeThreshold
                let fastOnset = envDB > fallbackThreshold + 6 // clearly loud: let it through even if the detector lags
                wantOpen = (voiceSays && keyAboveFloor) || fastOnset
            } else {
                wantOpen = levelOpen
            }

            if wantOpen {
                isOpen = true
                holdCounter = holdSamples
                gainTargetDB = 0
            } else if isOpen {
                if holdCounter > 0 {
                    holdCounter -= 1
                } else {
                    isOpen = false
                    gainTargetDB = rangeDB
                }
            } else {
                gainTargetDB = rangeDB
            }

            let step = gainTargetDB > gainDB ? dBPerSampleAttack : dBPerSampleRelease
            if gainDB < gainTargetDB {
                gainDB = min(gainTargetDB, gainDB + step)
            } else {
                gainDB = max(gainTargetDB, gainDB - step)
            }
            let gain = fxDBToLinear(gainDB)

            // Lookahead: delay the audio path by `lookaheadFrames` relative to the (already
            // causal) control signal above, which was derived from the un-delayed key.
            let outL = delayL[delayWrite]
            let outR = delayR[delayWrite]
            delayL[delayWrite] = l
            delayR[delayWrite] = r
            delayWrite = (delayWrite + 1) % lookaheadFrames

            block.left[i] = outL * gain
            if block.channels == 2 { block.right[i] = outR * gain }

            meters.activity = (gainDB - rangeDB) / max(-rangeDB, 1e-6)
            meters.gainReductionDB = -gainDB
        }
        meters.outputPeak = fxBlockPeak(block)
    }
}
