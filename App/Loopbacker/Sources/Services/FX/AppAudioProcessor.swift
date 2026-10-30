import Foundation

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
    private let configLock = NSLock()
    private var config = Config()

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
        configLock.lock()
        config = newValue
        configLock.unlock()
        if let targetIndex = leveler.index(ofParam: "target") {
            leveler.params.set(targetIndex, newValue.levelerTarget)
        }
    }

    /// IO thread. `buffer` is interleaved with `stride` channels; only the first `min(stride,2)`
    /// (the voice-pair slots the virtual mic carries app audio in) are touched.
    func process(_ buffer: UnsafeMutablePointer<Float>, frames: Int, stride: Int) {
        guard frames > 0, stride > 0 else { return }
        configLock.lock()
        let cfg = config
        configLock.unlock()
        guard cfg.duckingEnabled || cfg.levelerEnabled else { return }

        var offset = 0
        while offset < frames {
            let n = min(frames - offset, FXBlock.maxFrames)
            processChunk(buffer.advanced(by: offset * stride), frames: n, stride: stride, cfg: cfg)
            offset += n
        }
    }

    private func processChunk(_ buf: UnsafeMutablePointer<Float>, frames: Int, stride: Int, cfg: Config) {
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
