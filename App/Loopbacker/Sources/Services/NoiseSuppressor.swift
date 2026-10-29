import Foundation
import Synchronization
import os.log

let nsLogger = Logger(subsystem: "com.jacobcoffee.loopbacker", category: "NoiseSuppressor")

/// Noise suppression for a mic's voice pair, running a `DenoiseKernel` (DPDFNet or RNNoise)
/// inline on the capture device's IO thread.
///
/// One instance serves every voice route capturing the same device (mic → virtual mic and
/// mic → monitor). Those routes' input callbacks run back to back on the device's IO thread
/// with the same HAL sample time and the same channel mix, so the first route to see a block
/// computes it and the others copy the result.
///
/// Latency is constant: the kernel's `delay` plus `hop - 1` samples waiting for a hop to fill
/// (DPDFNet 2879 samples ≈ 60 ms, RNNoise 1439 ≈ 30 ms). Switching on passes the dry signal
/// until real output arrives, then crossfades over 10 ms; switching off crossfades back.
/// Neither clicks.
///
/// Thread contract:
/// - `process` runs on the capture devices' IO threads, one call at a time (a busy flag
///   enforces this; a contended call leaves its block dry).
/// - `setEnabled`/`setMaxReduction` may be called from any thread.
final class NoiseSuppressor: @unchecked Sendable {
    static let sampleRate: Float64 = 48_000

    /// Largest block cached for routes sharing this instance; larger blocks aren't shared.
    private static let maxBlock = 4096
    /// Wet/dry crossfade step per sample (10 ms at 48 kHz).
    private static let fadeStep: Float = 1.0 / 480.0

    let engine: NoiseSuppressionEngine
    private let kernel: any DenoiseKernel
    private let hop: Int
    private let delay: Int
    /// Output queued ahead at session start so a hop is always ready: a hop is emitted only
    /// once it has fully arrived, so output trails input by at most `hop - 1` samples.
    private let lead: Int
    /// Output samples before the enhanced signal is real.
    private let primeSamples: Int
    private let historyMask: Int
    private let fifoMask: Int

    // MARK: Shared state

    private let enabled = Atomic<Bool>(false)
    /// Linear gain of the dry signal blended under the enhanced one (`10^(maxReduction/20)`).
    private let dryMixBits = Atomic<UInt32>(Float(0.001).bitPattern)
    private let busy = Atomic<Bool>(false)

    // MARK: Stream state (IO thread)

    private var inSession = false
    private var failed = false
    private var wetGain: Float = 0
    /// Input (and output) samples this session.
    private var sessionSamples = 0
    /// Kernel calls this session.
    private var hops = 0
    private var hopFill = 0
    private var fifoRead = 0
    private var fifoWrite = 0
    /// Last block processed, for the other routes on the same device.
    private var cachedStart: Float64 = -1
    private var cachedFrames = 0
    private var cachedActive = false

    /// One wired (mlock'd) anonymous mapping holds every buffer the IO thread touches, so
    /// memory pressure can't page or compress them out from under the callback.
    private let arena: UnsafeMutableRawPointer
    private let arenaSize: Int
    private let hopIn: UnsafeMutablePointer<Float>
    private let hopOut: UnsafeMutablePointer<Float>
    /// Dry input by session sample index, reaching back `hop + delay`.
    private let history: UnsafeMutablePointer<Float>
    /// Blended output samples, `lead` ahead of the reader.
    private let fifo: UnsafeMutablePointer<Float>
    private let cachedBlock: UnsafeMutablePointer<Float>

    /// A suppressor for a route at `sampleRate`, or nil (logged) when it can't be suppressed.
    static func make(sampleRate: Float64, engine: NoiseSuppressionEngine, kernel: any DenoiseKernel) -> NoiseSuppressor? {
        guard sampleRate == Self.sampleRate else {
            nsLogger.error("Noise suppression needs 48 kHz; route runs at \(sampleRate) Hz")
            return nil
        }
        return NoiseSuppressor(engine: engine, kernel: kernel)
    }

    private init?(engine: NoiseSuppressionEngine, kernel: any DenoiseKernel) {
        func powerOfTwo(atLeast n: Int) -> Int { 1 << (Int.bitWidth - (n - 1).leadingZeroBitCount) }
        self.engine = engine
        self.kernel = kernel
        hop = kernel.hop
        delay = kernel.delay
        lead = hop - 1
        primeSamples = lead + delay
        let historySize = powerOfTwo(atLeast: hop + delay)
        let fifoSize = powerOfTwo(atLeast: lead + hop)
        historyMask = historySize - 1
        fifoMask = fifoSize - 1

        func rounded(_ bytes: Int, to alignment: Int) -> Int { (bytes + alignment - 1) / alignment * alignment }
        let counts = [hop, hop, historySize, fifoSize, Self.maxBlock]
        let total = rounded(counts.reduce(0) { $0 + rounded($1 * MemoryLayout<Float>.size, to: 64) }, to: Int(getpagesize()))
        guard let mapping = mmap(nil, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
              mapping != MAP_FAILED else {
            nsLogger.error("Noise suppression buffers could not be mapped")
            return nil
        }
        if mlock(mapping, total) != 0 {
            nsLogger.error("Could not wire noise suppression buffers: errno \(errno)")
        }
        arena = mapping
        arenaSize = total
        // Anonymous mappings start zeroed.
        var offset = 0
        func floats(_ count: Int) -> UnsafeMutablePointer<Float> {
            let p = (mapping + offset).bindMemory(to: Float.self, capacity: count)
            offset += rounded(count * MemoryLayout<Float>.size, to: 64)
            return p
        }
        hopIn = floats(hop)
        hopOut = floats(hop)
        history = floats(historySize)
        fifo = floats(fifoSize)
        cachedBlock = floats(Self.maxBlock)
    }

    deinit {
        munmap(arena, arenaSize)
        nsLogger.info("Noise suppression (\(self.engine.rawValue, privacy: .public)) freed")
    }

    func setEnabled(_ on: Bool) {
        enabled.store(on, ordering: .relaxed)
    }

    /// - Parameter dB: how far noise may be pulled down, as a negative level (e.g. -60).
    func setMaxReduction(dB: Float) {
        dryMixBits.store(powf(10, min(0, dB) / 20).bitPattern, ordering: .relaxed)
    }

    // MARK: - IO thread

    /// Replaces the first `min(stride, 2)` channels of interleaved `buffer` with the enhanced
    /// voice. Leaves the buffer untouched while disabled.
    ///
    /// - Parameter sampleTime: the block's HAL input sample time. A block already processed
    ///   for another route (same start and length) is copied instead of processed again.
    func process(_ buffer: UnsafeMutablePointer<Float>, frames: Int, stride: Int, sampleTime: Float64?) {
        let channels = min(stride, 2)
        guard channels > 0, frames > 0 else { return }
        guard busy.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged else { return }
        defer { busy.store(false, ordering: .releasing) }

        if let sampleTime, sampleTime == cachedStart, frames == cachedFrames {
            if cachedActive { write(cachedBlock, into: buffer, frames: frames, stride: stride, channels: channels) }
            return
        }

        let shareable = sampleTime != nil && frames <= Self.maxBlock
        cachedStart = shareable ? sampleTime! : -1
        cachedFrames = shareable ? frames : 0
        cachedActive = false
        var offset = 0
        while offset < frames {
            let n = min(frames - offset, Self.maxBlock)
            let block = buffer.advanced(by: offset * stride)
            if processChunk(block, frames: n, stride: stride, channels: channels) {
                if shareable { cachedActive = true }
                write(cachedBlock, into: block, frames: n, stride: stride, channels: channels)
            }
            offset += n
        }
    }

    private func write(_ mono: UnsafePointer<Float>, into buffer: UnsafeMutablePointer<Float>,
                       frames: Int, stride: Int, channels: Int) {
        for i in 0..<frames {
            buffer[i * stride] = mono[i]
            if channels == 2 { buffer[i * stride + 1] = mono[i] }
        }
    }

    /// Runs one chunk into `cachedBlock`. Returns false (and leaves the chunk alone) while
    /// fully dry outside a session, so the stereo image survives.
    private func processChunk(_ buf: UnsafeMutablePointer<Float>, frames n: Int, stride: Int, channels: Int) -> Bool {
        let want = enabled.load(ordering: .relaxed)
        if !inSession {
            guard want else { return false }
            startSession()
        } else if !want && wetGain == 0 {
            inSession = false
            return false
        }

        var g = wetGain
        for i in 0..<n {
            let base = i * stride
            let dry = channels == 1 ? buf[base] : 0.5 * (buf[base] + buf[base + 1])
            hopIn[hopFill] = dry
            history[sessionSamples & historyMask] = dry
            hopFill += 1
            sessionSamples += 1
            if hopFill == hop {
                if !failed { failed = !processHop() }
                hopFill = 0
            }
            let wet = fifo[fifoRead & fifoMask]
            fifoRead += 1

            let target: Float = want && !failed && sessionSamples > primeSamples ? 1 : 0
            g = target > g ? min(target, g + Self.fadeStep) : max(target, g - Self.fadeStep)
            cachedBlock[i] = g * wet + (1 - g) * dry
        }
        wetGain = g
        if !want && g == 0 { inSession = false }
        return true
    }

    private func startSession() {
        inSession = true
        failed = false
        wetGain = 0
        sessionSamples = 0
        hops = 0
        hopFill = 0
        history.update(repeating: 0, count: historyMask + 1)
        fifo.update(repeating: 0, count: lead)
        fifoRead = 0
        fifoWrite = lead
        kernel.reset()
    }

    /// Runs the kernel on the hop in `hopIn` and queues its output, with the matching dry
    /// sample blended back in to cap the reduction. Returns false if the kernel failed.
    private func processHop() -> Bool {
        guard kernel.process(hopIn, hopOut) else { return false }
        let dryMix = Float(bitPattern: dryMixBits.load(ordering: .relaxed))
        let wetMix = 1 - dryMix
        let outStart = hops * hop - delay
        for i in 0..<hop {
            let j = outStart + i
            let dry = j >= 0 ? history[j & historyMask] : 0
            fifo[fifoWrite & fifoMask] = wetMix * hopOut[i] + dryMix * dry
            fifoWrite += 1
        }
        hops += 1
        return true
    }
}
