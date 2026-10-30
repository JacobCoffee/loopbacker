import Foundation
import Synchronization

/// Single-producer/multi-consumer interleaved Float ring between one writer callback and one or
/// more reader callbacks that run on independent device clocks (e.g. a USB interface's crystal
/// vs. the virtual device's host clock).
///
/// Those clocks disagree by tens of ppm, so a plain copy-through ring slowly drains or overfills
/// until it under/overruns, after which every callback is a partial read and the output crackles
/// until the route is rebuilt. Each reader instead resamples by a ratio within `±maxDeviation`
/// (cubic Hermite interpolation), steered so its own smoothed fill level tracks `targetFill`.
/// The writer only copies frames in.
///
/// Thread contract: `write` is called from exactly one thread. Each `Reader` returned by
/// `makeReader()` is read from exactly one thread (its own, or a different one per reader) --
/// never the same `Reader` from two threads. `writePos` is the only state shared between the
/// writer and any reader: the writer publishes it with release ordering after copying frames
/// in, each reader loads it with acquire ordering before reading them. A reader's own cursor
/// (`readPos`/`readFrac`/`fillEstimate`/`priming`) is private to that `Reader` instance, so
/// multiple readers consuming the same ring (e.g. two `EchoCanceller`s on different capture
/// devices both reading `SystemAudioTap.ring`) each track the same underlying timeline
/// independently instead of racing one shared cursor and stealing each other's frames.
final class DriftCompensatedRing: @unchecked Sendable {
    /// Ratio deviation per frame of fill error. Closed-loop time constant is
    /// 1 / (gain * sampleRate) ≈ 10 s at 48 kHz; a 50 ppm drift settles ~25 frames off target.
    fileprivate static let gain = 2e-6
    /// ±0.1% rate change (≈1.7 cents) — inaudible, and ~48 frames/s of correction at 48 kHz.
    fileprivate static let maxDeviation = 1e-3
    /// The instantaneous fill saw-tooths by a whole IO buffer as the two callbacks interleave;
    /// steer on a low-passed estimate instead.
    fileprivate static let smoothingSeconds = 0.5

    let channels: Int
    let targetFill: UInt32
    fileprivate let mask: UInt32
    /// Fill above this means a reader is about to lap the writer's interpolation window.
    fileprivate let overrunThreshold: UInt32
    let sampleRate: Double
    fileprivate let storage: UnsafeMutablePointer<Float>

    // Written by the writer, read by every reader.
    fileprivate let writePos: Atomic<UInt32>

    /// - Parameters:
    ///   - capacityFrames: power of two.
    ///   - targetFill: frames of latency each reader steers toward; also its startup cushion.
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
        // Start with `targetFill` frames of silence queued so a fresh reader has a cushion
        // before the first real data arrives.
        writePos = Atomic(targetFill)
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

    /// A new independent reader cursor into this ring, steered toward the ring's own
    /// `targetFill`. Each consumer that needs its own view of the writer's timeline (e.g. one
    /// `EchoCanceller` per capture device, all reading `SystemAudioTap.ring`) should call this
    /// once and keep the returned `Reader` rather than sharing one `Reader` across consumers.
    func makeReader() -> Reader {
        Reader(ring: self)
    }

    /// Lazily created on first use by the convenience single-reader `read(into:frames:)`
    /// below. Queue/IO-thread callers that only ever have one consumer (e.g.
    /// `RouteContext`'s own output ring) can keep calling `read` directly on the ring itself
    /// instead of managing a `Reader`; anything with more than one consumer must call
    /// `makeReader()` once per consumer instead (see the class doc comment).
    private var defaultReader: Reader?

    /// Convenience for the single-reader case: reads via an implicitly owned default
    /// `Reader`, created on first call. Equivalent to calling `makeReader()` once, up front,
    /// and always reading through that same instance.
    func read(into out: UnsafeMutablePointer<Float>, frames: UInt32) {
        let reader = defaultReader ?? makeReader()
        if defaultReader == nil { defaultReader = reader }
        reader.read(into: out, frames: frames)
    }

    /// One consumer's independent, drift-steered cursor into a `DriftCompensatedRing`. See the
    /// ring's own doc comment for the thread contract: a `Reader` is read from exactly one
    /// thread.
    final class Reader: @unchecked Sendable {
        private let ring: DriftCompensatedRing

        // Owned entirely by this reader; never touched by the ring's writer or any other
        // reader.
        private var readPos: UInt32 = 0
        private var readFrac: Double = 0
        private var fillEstimate: Double
        private var priming = false

        fileprivate init(ring: DriftCompensatedRing) {
            self.ring = ring
            self.fillEstimate = Double(ring.targetFill)
        }

        /// Fill `out` with `frames` interleaved frames, consuming ring data at this reader's
        /// own steered rate.
        func read(into out: UnsafeMutablePointer<Float>, frames: UInt32) {
            let n = Int(frames)
            let ch = ring.channels
            let storage = ring.storage
            let mask = ring.mask
            let targetFill = ring.targetFill
            let written = ring.writePos.load(ordering: .acquiring)
            var available = written &- readPos

            if available > ring.overrunThreshold {
                // Writer stalled this reader (or both just started far apart): jump to target
                // latency. Doesn't affect any other reader's own cursor.
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

            let alpha = min(1.0, Double(frames) / (ring.sampleRate * DriftCompensatedRing.smoothingSeconds))
            fillEstimate += alpha * (Double(available) - fillEstimate)
            let deviation = (fillEstimate - Double(targetFill)) * DriftCompensatedRing.gain
            let ratio = 1.0 + min(DriftCompensatedRing.maxDeviation, max(-DriftCompensatedRing.maxDeviation, deviation))

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
}
