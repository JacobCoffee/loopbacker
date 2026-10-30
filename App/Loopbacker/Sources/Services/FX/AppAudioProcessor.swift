import Foundation
import Synchronization

/// Ducking and leveling for an app-capture route (game, music, browser), run inline on that
/// route's IO thread. Kept out of `FXChain`: app-capture routes never run the voice chain (see
/// `RouteContext.isVoiceInput`) -- they only get this.
///
/// Ducking pulls the app's audio down while `VoiceBus` reports speech, so talking over a game
/// or a track is heard clearly; the leveler (reusing the DSP slice's `LevelerNode`) can hold
/// the app audio at a target loudness on top of that. Configuration comes from
/// `EffectsPreset.appAudio` via `AudioRouter`.
final class AppAudioProcessor: @unchecked Sendable {
    struct Config: Equatable {
        var duckingEnabled = false
        var duckAmountDB: Float = -12
        var duckAttackMs: Float = 40
        var duckReleaseMs: Float = 600
        var levelerEnabled = false
        var levelerTarget: Float = -20
    }

    private let sampleRate: Float
    private let leveler: LevelerNode

    // Lock-free config, same pattern as `FXParamStore`: any thread writes a field, the IO
    // thread reads every field at the top of each block. A torn read across fields lasts at
    // most one block and is inaudible, matching the rest of the codebase's RT parameter contract.
    private let duckingEnabledBits = Atomic<Bool>(false)
    private let duckAmountDBBits = Atomic<UInt32>(Float(-12).bitPattern)
    private let duckAttackMsBits = Atomic<UInt32>(Float(40).bitPattern)
    private let duckReleaseMsBits = Atomic<UInt32>(Float(600).bitPattern)
    private let levelerEnabledBits = Atomic<Bool>(false)

    // IO thread only.
    private var duckGain: Float = 1
    private let leftScratch: UnsafeMutablePointer<Float>
    private let rightScratch: UnsafeMutablePointer<Float>

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
        leveler = LevelerNode(sampleRate: sampleRate)
        leftScratch = .allocate(capacity: FXBlock.maxFrames)
        rightScratch = .allocate(capacity: FXBlock.maxFrames)
        leftScratch.initialize(repeating: 0, count: FXBlock.maxFrames)
        rightScratch.initialize(repeating: 0, count: FXBlock.maxFrames)
    }

    deinit {
        leftScratch.deallocate()
        rightScratch.deallocate()
    }

    /// Any thread.
    func updateConfig(_ newValue: Config) {
        duckingEnabledBits.store(newValue.duckingEnabled, ordering: .relaxed)
        duckAmountDBBits.store(newValue.duckAmountDB.bitPattern, ordering: .relaxed)
        duckAttackMsBits.store(newValue.duckAttackMs.bitPattern, ordering: .relaxed)
        duckReleaseMsBits.store(newValue.duckReleaseMs.bitPattern, ordering: .relaxed)
        levelerEnabledBits.store(newValue.levelerEnabled, ordering: .relaxed)
        if let targetIndex = leveler.index(ofParam: "target") {
            leveler.params.set(targetIndex, newValue.levelerTarget)
        }
    }

    /// IO thread. `buffer` is interleaved with `stride` channels; only the first `min(stride,2)`
    /// (the voice-pair slots the virtual mic carries app audio in) are touched.
    func process(_ buffer: UnsafeMutablePointer<Float>, frames: Int, stride: Int) {
        guard frames > 0, stride > 0 else { return }
        let duckingEnabled = duckingEnabledBits.load(ordering: .relaxed)
        let levelerEnabled = levelerEnabledBits.load(ordering: .relaxed)
        guard duckingEnabled || levelerEnabled else { return }
        let cfg = (
            duckingEnabled: duckingEnabled,
            duckAmountDB: Float(bitPattern: duckAmountDBBits.load(ordering: .relaxed)),
            duckAttackMs: Float(bitPattern: duckAttackMsBits.load(ordering: .relaxed)),
            duckReleaseMs: Float(bitPattern: duckReleaseMsBits.load(ordering: .relaxed)),
            levelerEnabled: levelerEnabled
        )

        var offset = 0
        while offset < frames {
            let n = min(frames - offset, FXBlock.maxFrames)
            processChunk(buffer.advanced(by: offset * stride), frames: n, stride: stride, cfg: cfg)
            offset += n
        }
    }

    private func processChunk(_ buf: UnsafeMutablePointer<Float>, frames: Int, stride: Int,
                              cfg: (duckingEnabled: Bool, duckAmountDB: Float, duckAttackMs: Float,
                                    duckReleaseMs: Float, levelerEnabled: Bool)) {
        let mono = FXBlockIO.deinterleave(buf, frames: frames, stride: stride, left: leftScratch, right: rightScratch)

        if cfg.duckingEnabled {
            let attackC = fxTimeCoeff(ms: cfg.duckAttackMs, sampleRate: sampleRate)
            let releaseC = fxTimeCoeff(ms: cfg.duckReleaseMs, sampleRate: sampleRate)
            let duckedGain = fxDBToLinear(cfg.duckAmountDB)
            let target: Float = VoiceBus.probability() > 0.5 ? duckedGain : 1
            for i in 0..<frames {
                let c = target < duckGain ? attackC : releaseC
                duckGain = target + c * (duckGain - target)
                leftScratch[i] *= duckGain
                rightScratch[i] = mono ? leftScratch[i] : rightScratch[i] * duckGain
            }
        }

        if cfg.levelerEnabled {
            let sidechain = FXSidechain(voiceProbability: 1)
            let block = FXBlock(left: leftScratch, right: mono ? leftScratch : rightScratch,
                                frames: frames, channels: mono ? 1 : 2, sidechain: sidechain)
            leveler.process(block)
            if mono { for i in 0..<frames { rightScratch[i] = leftScratch[i] } }
        }

        FXBlockIO.reinterleave(buf, frames: frames, stride: stride, channels: min(stride, 2),
                               left: leftScratch, right: rightScratch, mono: mono)
    }
}
