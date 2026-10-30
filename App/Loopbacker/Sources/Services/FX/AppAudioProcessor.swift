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
        /// What counts as "someone's talking" for ducking: the user's own mic, far-end call
        /// voices (`CallVoiceBus`, published by `CallAudioMonitor`), or both. Default
        /// `.myVoice` is the original (only) behavior.
        var trigger: CallDuckTrigger = .myVoice
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
    /// `CallDuckTrigger.rawValue` is a `String`, not a fixed-width type an `Atomic` can hold
    /// lock-free; stored as a small explicit code instead (`triggerCode`/`trigger(forCode:)`
    /// below), not relying on `allCases` order.
    private let triggerCodeBits = Atomic<UInt8>(0)
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
        triggerCodeBits.store(Self.triggerCode(newValue.trigger), ordering: .relaxed)
        levelerEnabledBits.store(newValue.levelerEnabled, ordering: .relaxed)
        if let targetIndex = leveler.index(ofParam: "target") {
            leveler.params.set(targetIndex, newValue.levelerTarget)
        }
    }

    private static func triggerCode(_ trigger: CallDuckTrigger) -> UInt8 {
        switch trigger {
        case .myVoice: 0
        case .callVoices: 1
        case .both: 2
        }
    }

    private static func trigger(forCode code: UInt8) -> CallDuckTrigger {
        switch code {
        case 1: .callVoices
        case 2: .both
        default: .myVoice
        }
    }

    /// IO thread. `buffer` is interleaved with `stride` channels; only the first `min(stride,2)`
    /// (the voice-pair slots the virtual mic carries app audio in) are touched.
    func process(_ buffer: UnsafeMutablePointer<Float>, frames: Int, stride: Int) {
        guard frames > 0, stride > 0 else { return }
        let duckingEnabled = duckingEnabledBits.load(ordering: .relaxed)
        let levelerEnabled = levelerEnabledBits.load(ordering: .relaxed)
        guard duckingEnabled || levelerEnabled else {
            duckGain = 1
            AppAudioDuckBus.update(1)
            return
        }
        if !duckingEnabled { duckGain = 1 }
        let cfg = (
            duckingEnabled: duckingEnabled,
            duckAmountDB: Float(bitPattern: duckAmountDBBits.load(ordering: .relaxed)),
            duckAttackMs: Float(bitPattern: duckAttackMsBits.load(ordering: .relaxed)),
            duckReleaseMs: Float(bitPattern: duckReleaseMsBits.load(ordering: .relaxed)),
            trigger: Self.trigger(forCode: triggerCodeBits.load(ordering: .relaxed)),
            levelerEnabled: levelerEnabled
        )

        var offset = 0
        while offset < frames {
            let n = min(frames - offset, FXBlock.maxFrames)
            processChunk(buffer.advanced(by: offset * stride), frames: n, stride: stride, cfg: cfg)
            offset += n
        }
        AppAudioDuckBus.update(duckGain)
    }

    private func processChunk(_ buf: UnsafeMutablePointer<Float>, frames: Int, stride: Int,
                              cfg: (duckingEnabled: Bool, duckAmountDB: Float, duckAttackMs: Float,
                                    duckReleaseMs: Float, trigger: CallDuckTrigger, levelerEnabled: Bool)) {
        let mono = FXBlockIO.deinterleave(buf, frames: frames, stride: stride, left: leftScratch, right: rightScratch)

        if cfg.duckingEnabled {
            let attackC = fxTimeCoeff(ms: cfg.duckAttackMs, sampleRate: sampleRate)
            let releaseC = fxTimeCoeff(ms: cfg.duckReleaseMs, sampleRate: sampleRate)
            let duckedGain = fxDBToLinear(cfg.duckAmountDB)
            let userTalking = cfg.trigger.dependsOnMyVoice && VoiceBus.probability() > 0.5
            let callTalking = cfg.trigger.dependsOnCallVoices && CallVoiceBus.isTalking()
            let target: Float = (userTalking || callTalking) ? duckedGain : 1
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

/// App-wide measured duck gain, published by whichever `AppAudioProcessor` route last processed
/// a block, so the Effects page's meter can show the gain actually applied rather than a UI-side
/// guess. Lock-free: a single atomic float plus a timestamp, mirroring `VoiceBus`'s pattern —
/// min-with-decay instead of max-with-decay, since 1 (unity, no reduction) is this bus's "quiet"
/// baseline and lower values are "more active".
///
/// Thread contract: `update` runs on each app-capture route's IO thread; `gain` runs on the
/// main thread (the Effects page's meter). Both are safe to call concurrently.
enum AppAudioDuckBus {
    /// How long a published value is trusted before it's treated as stale (the route that was
    /// publishing it stopped) and reported as unity gain instead.
    private static let staleNanos: UInt64 = 300_000_000
    /// One-pole relaxation of the previous (most-ducked) reading back toward unity before
    /// taking the min with a fresh reading, so the meter eases back up smoothly instead of
    /// latching at the deepest duck forever.
    private static let decayPerUpdate: Float = 0.97

    private static let bits = Atomic<UInt32>(Float(1).bitPattern)
    private static let lastUpdateNanos = Atomic<UInt64>(0)

    /// Any thread (an `AppAudioProcessor`'s IO thread), once per processed block.
    static func update(_ gain: Float) {
        lastUpdateNanos.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed)
        let clamped = min(max(gain, 0), 1)
        var current = bits.load(ordering: .relaxed)
        while true {
            let relaxed = 1 - (1 - Float(bitPattern: current)) * decayPerUpdate
            let next = min(relaxed, clamped)
            let result = bits.compareExchange(expected: current, desired: next.bitPattern, ordering: .relaxed)
            if result.exchanged { break }
            current = result.original
        }
    }

    /// Any thread. The current linear duck gain (1 = no reduction), or 1 if no app-capture
    /// route has published recently.
    static func gain() -> Float {
        let last = lastUpdateNanos.load(ordering: .relaxed)
        guard last != 0, DispatchTime.now().uptimeNanoseconds &- last < staleNanos else { return 1 }
        return Float(bitPattern: bits.load(ordering: .relaxed))
    }
}
