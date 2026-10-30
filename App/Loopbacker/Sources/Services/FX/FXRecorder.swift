import Foundation
import Synchronization

/// A finished A/B capture: the raw mic mix (before noise suppression) and the matching chain
/// output, mono, at the chain's sample rate.
struct FXRecording: Sendable {
    var raw: [Float]
    var processed: [Float]
    var sampleRate: Double
}

/// Lock-free single-producer (the chain's IO thread), single-consumer (whoever is awaiting
/// `FXChain.record`) capture of up to 30 s of mono audio. Armed from the main thread; the IO
/// thread only ever writes into the preallocated arena and bumps an atomic write count -- no
/// allocation, no locks.
final class FXRecorder: @unchecked Sendable {
    let sampleRate: Double
    private let capacity: Int
    private let rawBuf: UnsafeMutablePointer<Float>
    private let processedBuf: UnsafeMutablePointer<Float>
    private let armed = Atomic<Bool>(false)
    private let written = Atomic<Int>(0)
    private let targetFrames = Atomic<Int>(0)

    init(sampleRate: Double, maxSeconds: Double = 30) {
        self.sampleRate = sampleRate
        capacity = Int(maxSeconds * sampleRate) + 1
        rawBuf = .allocate(capacity: capacity)
        processedBuf = .allocate(capacity: capacity)
        rawBuf.initialize(repeating: 0, count: capacity)
        processedBuf.initialize(repeating: 0, count: capacity)
    }

    deinit {
        rawBuf.deallocate()
        processedBuf.deallocate()
    }

    /// Main thread: start a new capture of up to `seconds` (capped at the arena's 30 s).
    func arm(seconds: Double) {
        written.store(0, ordering: .relaxed)
        targetFrames.store(max(1, min(Int(seconds * sampleRate), capacity)), ordering: .relaxed)
        armed.store(true, ordering: .releasing)
    }

    /// IO thread: appends up to `frames` mono samples of each stream. A no-op while not armed.
    /// Stops (and clears `armed`) once the target length is reached, never writing past the
    /// arena.
    func capture(raw: UnsafePointer<Float>, processed: UnsafePointer<Float>, frames: Int) {
        guard armed.load(ordering: .acquiring) else { return }
        let target = targetFrames.load(ordering: .relaxed)
        var w = written.load(ordering: .relaxed)
        var i = 0
        while i < frames, w < target {
            rawBuf[w] = raw[i]
            processedBuf[w] = processed[i]
            w += 1
            i += 1
        }
        written.store(w, ordering: .relaxed)
        if w >= target { armed.store(false, ordering: .releasing) }
    }

    /// Any thread: true once armed and not yet full.
    var isCapturing: Bool { armed.load(ordering: .acquiring) }

    /// Any thread: a snapshot of everything captured so far (even mid-capture).
    func snapshot() -> FXRecording {
        let count = written.load(ordering: .relaxed)
        return FXRecording(raw: Array(UnsafeBufferPointer(start: rawBuf, count: count)),
                           processed: Array(UnsafeBufferPointer(start: processedBuf, count: count)),
                           sampleRate: sampleRate)
    }
}
