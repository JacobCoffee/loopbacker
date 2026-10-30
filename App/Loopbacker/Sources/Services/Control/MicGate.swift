import Synchronization

/// Lock-free mute gate for the virtual-mic voice route. `MicControl` (main actor) publishes the
/// desired gain; `process` runs on the capture device's IO thread (via
/// `RouteContext.processCapturedBlock`) and ramps the live gain toward it over 10 ms so a
/// mute/unmute (or a push-to-talk edge) never produces an audible click.
///
/// Thread contract: `setTarget` may be called from any thread (lock-free publish). `process`
/// is called from the capture device's IO thread; like `AudioRouter`'s `mixMatrix`, it assumes
/// one physical mic drives the virtual mic at a time, so `currentGain` is touched without
/// synchronization — a race across two simultaneous capture devices could at worst blend one
/// block's ramp, which is inaudible (same tolerance as the router's own mix-matrix updates).
final class MicGate: @unchecked Sendable {
    static let shared = MicGate()

    /// 10 ms ramp at 48 kHz (contract: 48 kHz fixed).
    private static let rampStep: Float = 1.0 / 480.0

    /// Target gain (0 = muted, 1 = live), published from the main actor as a bit-pattern so the
    /// IO thread can load it without a lock.
    private let targetGainBits = Atomic<UInt32>(Float(1).bitPattern)
    /// IO-thread-owned ramp state: the gain actually being applied right now.
    private var currentGain: Float = 1

    private init() {}

    /// Publishes the desired gain. Safe from any thread.
    func setTarget(muted: Bool) {
        let gain: Float = muted ? 0 : 1
        targetGainBits.store(gain.bitPattern, ordering: .releasing)
    }

    /// IO thread only. Ramps `buffer` (interleaved, `stride` channels, `frames` frames) toward
    /// the published target gain at 10 ms/full-scale, sample by sample so no block boundary
    /// clicks. No allocation, no locks.
    func process(_ buffer: UnsafeMutablePointer<Float>, frames: Int, stride: Int) {
        guard frames > 0, stride > 0 else { return }
        let target = Float(bitPattern: targetGainBits.load(ordering: .acquiring))
        var gain = currentGain
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
        currentGain = gain
    }

    /// Test-only: resets the ramp state for a fresh scenario without touching the published
    /// target (which other tests/instances may depend on).
    func resetForTesting(currentGain: Float = 1, target: Float = 1) {
        self.currentGain = currentGain
        targetGainBits.store(target.bitPattern, ordering: .releasing)
    }
}
