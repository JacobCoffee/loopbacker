import Foundation
import Synchronization

/// App-wide voice-activity signal used to duck app-capture audio (game, music, browser) while
/// the user is talking. Every running `FXChain`'s voice activity detector publishes its
/// per-block probability here; `AppAudioProcessor` reads the combined value on its own IO
/// thread. Lock-free: a single atomic float plus a timestamp, no allocation either side.
///
/// Thread contract: `update` runs on each chain's IO thread; `probability` runs on each
/// app-capture route's IO thread. Both are safe to call concurrently from multiple threads.
enum VoiceBus {
    /// How long a published value is trusted before it's treated as stale (e.g. the mic route
    /// that was publishing it stopped) and reported as silence instead.
    private static let staleNanos: UInt64 = 300_000_000
    /// One-pole decay applied to the previous value before taking the max with a fresh
    /// reading, so probability relaxes smoothly even while a chain keeps publishing quiet
    /// (non-speech) blocks, rather than latching at the loudest moment forever.
    private static let decayPerUpdate: Float = 0.97

    private static let bits = Atomic<UInt32>(Float(0).bitPattern)
    private static let lastUpdateNanos = Atomic<UInt64>(0)

    /// Any thread (an `FXChain`'s IO thread), once per processed block. Combines `probability`
    /// into the bus as the max of every currently-publishing chain, decaying prior readings so
    /// a chain that goes quiet doesn't keep the bus pinned high.
    static func update(_ probability: Float) {
        lastUpdateNanos.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed)
        var current = bits.load(ordering: .relaxed)
        while true {
            let decayed = Float(bitPattern: current) * decayPerUpdate
            let next = max(decayed, min(max(probability, 0), 1))
            let result = bits.compareExchange(expected: current, desired: next.bitPattern, ordering: .relaxed)
            if result.exchanged { break }
            current = result.original
        }
    }

    /// Any thread. The current combined speech probability, or 0 if nobody has published
    /// recently (every voice chain stopped or is bypassed).
    static func probability() -> Float {
        let last = lastUpdateNanos.load(ordering: .relaxed)
        guard last != 0, DispatchTime.now().uptimeNanoseconds &- last < staleNanos else { return 0 }
        return Float(bitPattern: bits.load(ordering: .relaxed))
    }
}
