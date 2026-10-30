import Foundation
import Testing
@testable import Loopbacker

/// `MicLoudnessBus` is a process-wide singleton, so these tests drive it directly through
/// `contribute` the way `AudioRouter`'s and `SoundboardPlayer`'s render callbacks do -- in
/// realistic ~1024-frame IO blocks (not a whole 100 ms step at once; the bus accumulates across
/// many such blocks the same way the real render callbacks' blocks do) -- and fully flush its
/// momentary ring (4 x 100 ms steps) with fresh cycles before each assertion so one test's
/// content can't bleed into another's.
@Suite("MicLoudnessBus", .serialized)
struct MicLoudnessBusTests {
    private let blockFrames = 1024
    private let sampleRate = 48000.0

    private func tone(amplitude: Float, blocks: Int, channels: Int) -> [Float] {
        let totalFrames = blockFrames * blocks
        var samples = [Float](repeating: 0, count: totalFrames * channels)
        for n in 0..<totalFrames {
            let s = amplitude * Float(sin(2 * Double.pi * 1000 * Double(n) / sampleRate))
            for ch in 0..<channels { samples[n * channels + ch] = s }
        }
        return samples
    }

    /// Feeds enough ~1024-frame IO blocks (one `contribute` per feed per block, all sharing that
    /// block's sample time) to fully flush the 4-step momentary ring with fresh content, then
    /// returns the momentary reading.
    private func measureMomentary(
        _ bus: MicLoudnessBus, _ feeds: [(samples: [Float], channels: Int)], startingAt sampleTime: inout Float64
    ) -> Float {
        // ~5 steps' worth of blocks: enough to finalize 4 full 100 ms steps of fresh content
        // (evicting anything left in the ring from a previous call) plus one more to be safe.
        let stepsNeeded = 5
        let blocksPerStep = Int((sampleRate * 0.1 / Double(blockFrames)).rounded(.up))
        for _ in 0..<(stepsNeeded * blocksPerStep) {
            for feed in feeds {
                feed.samples.withUnsafeBufferPointer { buf in
                    bus.contribute(buffer: buf.baseAddress!, frames: blockFrames, channels: feed.channels, sampleTime: sampleTime)
                }
            }
            sampleTime += Float64(blockFrames)
        }
        return bus.momentaryLUFS
    }

    @Test("Two equal feeds in the same IO cycle sum to +6 dB, not the single-feed level")
    func sameSampleTimeFeedsSum() {
        let bus = MicLoudnessBus.shared
        var t: Float64 = 1_000_000

        let blocksNeeded = Int((sampleRate * 0.1 / Double(blockFrames)).rounded(.up)) * 6
        let feed = tone(amplitude: 0.1, blocks: blocksNeeded, channels: 2)
        // Reuse the same decoded tone block-by-block by slicing; simplest is to just generate a
        // buffer long enough and feed the same first `blockFrames` window every call (the tone's
        // own periodicity, 1 kHz into 48 kHz, means any aligned 1024-frame window is equivalent
        // for this test's purpose: comparing one feed's level to two feeds' summed level).
        func block(_ samples: [Float]) -> [Float] { Array(samples[0..<(blockFrames * 2)]) }
        let feedBlock = block(feed)

        let singleFeedMomentary = measureMomentary(bus, [(feedBlock, 2)], startingAt: &t)
        let summedMomentary = measureMomentary(bus, [(feedBlock, 2), (feedBlock, 2)], startingAt: &t)

        #expect(abs((summedMomentary - singleFeedMomentary) - 6.0) < 0.5)
    }

    @Test("A feed with fewer channels than another in the same cycle only touches its own channels")
    func narrowerFeedDoesNotCorruptWiderFeed() {
        let bus = MicLoudnessBus.shared
        var t: Float64 = 2_000_000

        func block(_ samples: [Float], channels: Int) -> [Float] { Array(samples[0..<(blockFrames * channels)]) }

        // 4-channel feed (e.g. a mic route on a 4-channel virtual mic) plus a 2-channel feed
        // (e.g. the soundboard's stereo loopback) registered second in the same cycle -- this
        // could corrupt the wider feed's layout if the accumulator used a growing stride instead
        // of a fixed one.
        let wideBlock = block(tone(amplitude: 0.2, blocks: 1, channels: 4), channels: 4)
        let narrowBlock = block(tone(amplitude: 0.1, blocks: 1, channels: 2), channels: 2)

        let combined = measureMomentary(bus, [(wideBlock, 4), (narrowBlock, 2)], startingAt: &t)
        let wideAlone = measureMomentary(bus, [(wideBlock, 4)], startingAt: &t)

        // A sane, finite reading -- not NaN/garbage from a corrupted buffer layout -- and louder
        // than the wide feed alone (since the narrow feed added real energy on channels 1-2).
        #expect(combined.isFinite)
        #expect(combined > wideAlone)
    }
}
