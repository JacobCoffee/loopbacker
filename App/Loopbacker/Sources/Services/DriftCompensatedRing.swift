import Foundation
import Synchronization

/// Single-producer/single-consumer interleaved Float ring between two audio callbacks that run on
/// independent device clocks (e.g. a USB interface's crystal vs. the virtual device's host clock).
///
/// Those clocks disagree by tens of ppm, so a plain copy-through ring slowly drains or overfills
/// until it under/overruns, after which every callback is a partial read and the output crackles
/// until the route is rebuilt. The reader here instead resamples by a ratio within
/// ±`maxDeviation` (cubic Hermite interpolation), steered so the smoothed fill level tracks
/// `targetFill`. The writer only copies frames in.
///
/// Thread contract: `write` is called from exactly one thread, `read` from exactly one other.
/// `writePos` is the only state shared between them: the writer publishes it with release
/// ordering after copying frames in, the reader loads it with acquire ordering before reading
/// them. Everything else is owned by one side.
final class DriftCompensatedRing: @unchecked Sendable {
    /// Ratio deviation per frame of fill error. Closed-loop time constant is
    /// 1 / (gain * sampleRate) ≈ 10 s at 48 kHz; a 50 ppm drift settles ~25 frames off target.
    private static let gain = 2e-6
    /// ±0.1% rate change (≈1.7 cents) — inaudible, and ~48 frames/s of correction at 48 kHz.
    private static let maxDeviation = 1e-3
    /// The instantaneous fill saw-tooths by a whole IO buffer as the two callbacks interleave;
    /// steer on a low-passed estimate instead.
    private static let smoothingSeconds = 0.5

    let channels: Int
    let targetFill: UInt32
    private let mask: UInt32
    /// Fill above this means the writer is about to lap the reader's interpolation window.
    private let overrunThreshold: UInt32
    let sampleRate: Double
    private let storage: UnsafeMutablePointer<Float>

    // Written by the writer, read by both.
    private let writePos: Atomic<UInt32>

    // Reader-owned.
    private var readPos: UInt32 = 0
    private var readFrac: Double = 0
    private var fillEstimate: Double
    private var priming = false

    /// - Parameters:
    ///   - capacityFrames: power of two.
    ///   - targetFill: frames of latency the reader steers toward; also the startup cushion.
    init(capacityFrames: UInt32, channels: Int, targetFill: UInt32, sampleRate: Double) {
        precondition(capacityFrames.nonzeroBitCount == 1, "capacity must be a power of two")
        precondition(targetFill < capacityFrames / 2)
        self.mask = capacityFrames - 1
        self.overrunThreshold = capacityFrames - capacityFrames / 4
        self.channels = channels
        self.targetFill = targetFill
        self.sampleRate = sampleRate
        let samples = Int(capacityFrames) * channels
        storage = UnsafeMutablePointer<Float>.allocate(capacity: samples)
        storage.initialize(repeating: 0, count: samples)
        // Start with `targetFill` frames of silence queued so the reader has a cushion
        // before the first real data arrives.
        writePos = Atomic(targetFill)
        fillEstimate = Double(targetFill)
    }

    deinit {
        storage.deallocate()
    }

    func write(_ data: UnsafePointer<Float>, frames: UInt32) {
        let ch = channels
        // Only this thread stores writePos, so its own value needs no ordering.
        let start = writePos.load(ordering: .relaxed)
        for i in 0..<Int(frames) {
            let dst = Int((start &+ UInt32(i)) & mask) * ch
            let src = i * ch
            for c in 0..<ch {
                storage[dst + c] = data[src + c]
            }
        }
        writePos.store(start &+ frames, ordering: .releasing)
    }

    /// Fill `out` with `frames` interleaved frames, consuming ring data at the steered rate.
    func read(into out: UnsafeMutablePointer<Float>, frames: UInt32) {
        let n = Int(frames)
        let ch = channels
        let written = writePos.load(ordering: .acquiring)
        var available = written &- readPos

        if available > overrunThreshold {
            // Writer stalled the reader (or both just started far apart): jump to target latency.
            readPos = written &- targetFill
            readFrac = 0
            fillEstimate = Double(targetFill)
            available = targetFill
        }

        if priming {
            // After an underrun, stay silent until a full cushion has rebuilt rather than
            // emitting a stream of partial buffers.
            guard available >= targetFill else {
                zero(out, samples: n * ch)
                return
            }
            priming = false
            fillEstimate = Double(available)
        }

        let alpha = min(1.0, Double(frames) / (sampleRate * Self.smoothingSeconds))
        fillEstimate += alpha * (Double(available) - fillEstimate)
        let deviation = (fillEstimate - Double(targetFill)) * Self.gain
        let ratio = 1.0 + min(Self.maxDeviation, max(-Self.maxDeviation, deviation))

        // Interpolating sample i reads frames floor(pos_i) - 1 ... floor(pos_i) + 2.
        let lastPos = readFrac + ratio * Double(n - 1)
        guard Double(available) >= lastPos.rounded(.down) + 3 else {
            priming = true
            zero(out, samples: n * ch)
            return
        }

        var pos = readFrac
        for i in 0..<n {
            let whole = pos.rounded(.down)
            let t = Float(pos - whole)
            let base = readPos &+ UInt32(whole)
            let im1 = Int((base &- 1) & mask) * ch
            let i0 = Int(base & mask) * ch
            let i1 = Int((base &+ 1) & mask) * ch
            let i2 = Int((base &+ 2) & mask) * ch
            let o = i * ch
            for c in 0..<ch {
                let xm1 = storage[im1 + c]
                let x0 = storage[i0 + c]
                let x1 = storage[i1 + c]
                let x2 = storage[i2 + c]
                // Catmull-Rom cubic Hermite.
                let c1 = 0.5 * (x1 - xm1)
                let c2 = xm1 - 2.5 * x0 + 2.0 * x1 - 0.5 * x2
                let c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1)
                out[o + c] = ((c3 * t + c2) * t + c1) * t + x0
            }
            pos += ratio
        }

        let advance = pos.rounded(.down)
        readPos = readPos &+ UInt32(advance)
        readFrac = pos - advance
    }

    private func zero(_ out: UnsafeMutablePointer<Float>, samples: Int) {
        out.update(repeating: 0, count: samples)
    }
}
