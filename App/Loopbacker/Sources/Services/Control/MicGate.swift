import Synchronization

/// Lock-free mute gate for voice routes feeding the virtual mic. `MicControl` (main actor)
/// publishes the desired gain; each `RouteContext.processCapturedBlock` (capture device IO
/// thread) ramps its own ramp state toward that target over 10 ms so a mute/unmute (or a
/// push-to-talk edge) never produces an audible click.
///
/// Thread contract: `setTarget` may be called from any thread (lock-free publish). `process`
/// is called from a capture device's IO thread with the caller's own `RouteState`; a
/// `RouteState` must only ever be touched from one IO thread at a time (the route that owns it).
final class MicGate: @unchecked Sendable {
    static let shared = MicGate()

    /// 10 ms ramp at 48 kHz (contract: 48 kHz fixed).
    private static let rampStep: Float = 1.0 / 480.0

    /// Target gain (0 = muted, 1 = live), published from the main actor as a bit-pattern so any
    /// IO thread can load it without a lock. The only state shared across routes/threads --
    /// each route's own ramp *position* toward this target lives in its own `RouteState`.
    private let targetGainBits = Atomic<UInt32>(Float(1).bitPattern)

    private init() {}

    /// Publishes the desired gain. Safe from any thread.
    func setTarget(muted: Bool) {
        let gain: Float = muted ? 0 : 1
        targetGainBits.store(gain.bitPattern, ordering: .releasing)
    }

    /// One route's own ramp cursor: the gain it's actually applying right now, which may lag
    /// `targetGainBits` while mid-fade. Letting two routes (the virtual mic and Stream Mix
    /// targets, or two capture devices) share one cursor meant whichever route's callback ran
    /// second each block picked up wherever the first route's ramp had gotten to instead of
    /// continuing its own -- block-edge gain jumps that defeated the intended continuous
    /// 10 ms fade. Each `RouteContext` that feeds the virtual mic owns one instead.
    final class RouteState: @unchecked Sendable {
        /// IO-thread-owned; `fileprivate(set)` so only `MicGate.process` (in this file)
        /// mutates it, but visible (not `fileprivate` entirely) so tests can read it directly.
        fileprivate(set) var currentGain: Float
        init(currentGain: Float = 1) {
            self.currentGain = currentGain
        }
    }

    /// IO thread only (the thread that owns `state`). Ramps `buffer` (interleaved, `stride`
    /// channels, `frames` frames) toward the published target gain at 10 ms/full-scale, sample
    /// by sample so no block boundary clicks. No allocation, no locks.
    func process(_ buffer: UnsafeMutablePointer<Float>, frames: Int, stride: Int, state: RouteState) {
        guard frames > 0, stride > 0 else { return }
        let target = Float(bitPattern: targetGainBits.load(ordering: .acquiring))
        var gain = state.currentGain
        // Already settled: skip the per-sample loop (common case, mic unmuted and steady).
        if gain == target {
            if gain != 1 {
                for i in 0..<frames {
                    let base = buffer + i * stride
                    for c in 0..<stride { base[c] *= gain }
                }
            }
            return
        }
        for i in 0..<frames {
            if gain < target {
                gain = min(target, gain + Self.rampStep)
            } else {
                gain = max(target, gain - Self.rampStep)
            }
            let base = buffer + i * stride
            for c in 0..<stride { base[c] *= gain }
        }
        state.currentGain = gain
    }

    /// Test-only: resets the published target gain. Each test constructs and owns its own
    /// `RouteState` for its starting ramp position instead of going through the (now
    /// per-route) `currentGain`.
    func resetForTesting(target: Float = 1) {
        targetGainBits.store(target.bitPattern, ordering: .releasing)
    }
}
