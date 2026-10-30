import Accelerate
import CWebRTCAEC
import Synchronization
import os.log

private let aecLogger = Logger(subsystem: "com.jacobcoffee.loopbacker", category: "EchoCanceller")

/// Acoustic echo cancellation for a mic's voice pair, running WebRTC's AEC3 (vendored from
/// `webrtc-audio-processing`, BSD-3-Clause, via `CWebRTCAEC`) against the far-end reference
/// from a `SystemAudioTap`. See `../../../CWebRTCAEC/README.md` for the vendoring process and
/// for why this replaced an initial SpeexDSP MDF implementation: AEC3 has a nonlinear residual
/// echo suppressor, its own delay estimator, and clock-drift handling, which real (nonlinear)
/// laptop speakers need and MDF's linear-only adaptive filter doesn't provide.
///
/// 48 kHz, 10 ms (480-sample) hops, mono capture, mono or stereo render reference (matching
/// `reference.channels`). `process` accepts any block size from 1 to `FXBlock.maxFrames`
/// (4096): samples are queued into a 480-sample hop buffer and AEC3 only ever runs on exact
/// hops, so output trails input by `latencySamples` (`hop - 1` = 479 samples) while a hop
/// fills — the same buffering shape as `NoiseSuppressor`.
///
/// Each hop also pulls `hop` frames of far-end reference from `reference` (a
/// `DriftCompensatedRing` fed by `SystemAudioTap`'s IOProc) and feeds it to AEC3's
/// `ProcessReverseStream` before running `ProcessStream` on the mic hop. Unlike MDF, AEC3
/// estimates and tracks the render/capture delay itself (`set_stream_delay_ms` only supplies a
/// starting point), so it isn't limited by `reference`'s own ring latency the way MDF was —
/// AEC3 handles delays up to roughly 500 ms on its own.
///
/// Double-talk (simultaneous far-end echo + near-end speech) note: AEC3's suppressor is more
/// aggressive than MDF's was at suppressing near-end speech when the echo and near-end are
/// comparable in level; `makeEchoCanceller3Config()` tunes `dominant_nearend_detection` to
/// recognize double talk faster, verified against a sweep of echo:near-end loudness ratios
/// (real desk speakers measure roughly -10 to -20 dB below the near-end talker's own mic
/// level) — see `../../../CWebRTCAEC/README.md`'s "Double-talk tuning" section for the full
/// table and what was tried.
///
/// Thread contract:
/// - `process` runs on the capture device's IO thread. It is the sole reader of `reference`
///   (`DriftCompensatedRing`'s single-reader contract) and touches no Swift reference types
///   other than itself; the per-hop calls into the shim's `webrtc_aec3_process_reverse_stream`/
///   `webrtc_aec3_process_stream` reach into `webrtc::AudioProcessing`'s steady-state
///   processing path, which (verified with an interposed malloc over 2000 process() calls)
///   does not allocate — all working buffers are sized at `webrtc_aec3_create`/`Initialize`
///   time.
/// - `setEnabled` may be called from any thread.
final class EchoCanceller: @unchecked Sendable {
    static let sampleRate = 48_000
    static let hop = Int(webrtc_aec3_frame_size(48_000))
    /// Largest block cached in one `process` call; larger blocks are split into chunks of this
    /// size internally, same convention as `NoiseSuppressor.maxBlock`.
    private static let maxBlock = 4_096
    /// Wet/dry crossfade step per sample (10 ms at 48 kHz).
    private static let fadeStep: Float = 1.0 / 480.0
    /// Starting point handed to AEC3's internal delay estimator: the ring's own latency plus a
    /// margin for device-to-device scheduling jitter. AEC3 refines this continuously, so this
    /// only needs to be in the right ballpark, not exact.
    private static let initialDelayMs: Int32 = 30

    /// Declared latency: a hop must fill before any of it can be emitted.
    let latencySamples = EchoCanceller.hop - 1

    private let reference: DriftCompensatedRing
    private let state: OpaquePointer

    private let enabled = Atomic<Bool>(false)
    private var wetGain: Float = 0
    private var hopFill = 0
    private var fifoRead = 0
    private var fifoWrite: Int
    private let fifoMask: Int

    /// One wired (mlock'd) anonymous mapping holds every buffer the IO thread touches.
    private let arena: UnsafeMutableRawPointer
    private let arenaSize: Int
    private let hopIn: UnsafeMutablePointer<Float>
    private let hopOut: UnsafeMutablePointer<Float>
    private let refRaw: UnsafeMutablePointer<Float>
    private let fifo: UnsafeMutablePointer<Float>

    /// An echo canceller reading its far-end reference from `reference`, or nil (logged) if the
    /// vendored AEC3 implementation can't be initialized.
    static func make(reference: DriftCompensatedRing) -> EchoCanceller? {
        guard reference.sampleRate == Double(Self.sampleRate) else {
            aecLogger.error("Echo cancellation needs a 48 kHz reference; tap runs at \(reference.sampleRate) Hz")
            return nil
        }
        guard let state = webrtc_aec3_create(Int32(sampleRate), Int32(reference.channels)) else {
            aecLogger.error("webrtc_aec3_create failed")
            return nil
        }
        webrtc_aec3_set_stream_delay_ms(state, Self.initialDelayMs)
        return EchoCanceller(reference: reference, state: state)
    }

    private init(reference: DriftCompensatedRing, state: OpaquePointer) {
        self.reference = reference
        self.state = state

        func powerOfTwo(atLeast n: Int) -> Int { 1 << (Int.bitWidth - (n - 1).leadingZeroBitCount) }
        let lead = Self.hop - 1
        let fifoSize = powerOfTwo(atLeast: lead + Self.hop)
        fifoMask = fifoSize - 1
        fifoWrite = lead

        func rounded(_ bytes: Int, to alignment: Int) -> Int { (bytes + alignment - 1) / alignment * alignment }
        let refChannels = max(reference.channels, 1)
        let floatCounts = [Self.hop, Self.hop, Self.hop * refChannels, fifoSize]
        let total = rounded(
            floatCounts.reduce(0) { $0 + rounded($1 * MemoryLayout<Float>.size, to: 64) },
            to: Int(getpagesize()))
        let mapping = mmap(nil, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)!
        precondition(mapping != MAP_FAILED, "Echo canceller buffers could not be mapped")
        if mlock(mapping, total) != 0 {
            aecLogger.error("Could not wire echo canceller buffers: errno \(errno)")
        }
        arena = mapping
        arenaSize = total
        var offset = 0
        func floats(_ count: Int) -> UnsafeMutablePointer<Float> {
            let p = (mapping + offset).bindMemory(to: Float.self, capacity: count)
            offset += rounded(count * MemoryLayout<Float>.size, to: 64)
            return p
        }
        hopIn = floats(Self.hop)
        hopOut = floats(Self.hop)
        refRaw = floats(Self.hop * refChannels)
        fifo = floats(fifoSize)
    }

    deinit {
        webrtc_aec3_destroy(state)
        munmap(arena, arenaSize)
    }

    func setEnabled(_ on: Bool) {
        enabled.store(on, ordering: .relaxed)
    }

    func reset() {
        webrtc_aec3_reset(state)
        webrtc_aec3_set_stream_delay_ms(state, Self.initialDelayMs)
        wetGain = 0
        hopFill = 0
        fifoRead = 0
        fifoWrite = EchoCanceller.hop - 1
        fifo.update(repeating: 0, count: fifoMask + 1)
    }

    // MARK: - IO thread

    /// Cancels far-end echo from `mic` in place.
    func process(_ mic: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        var offset = 0
        while offset < frames {
            let n = min(frames - offset, Self.maxBlock)
            processChunk(mic.advanced(by: offset), frames: n)
            offset += n
        }
    }

    private func processChunk(_ buf: UnsafeMutablePointer<Float>, frames n: Int) {
        let want = enabled.load(ordering: .relaxed)
        var g = wetGain
        for i in 0..<n {
            let dry = buf[i]
            hopIn[hopFill] = dry
            hopFill += 1
            if hopFill == EchoCanceller.hop {
                runHop()
                hopFill = 0
            }
            let wet = fifo[fifoRead & fifoMask]
            fifoRead += 1

            let target: Float = want ? 1 : 0
            g = target > g ? min(target, g + Self.fadeStep) : max(target, g - Self.fadeStep)
            buf[i] = g * wet + (1 - g) * dry
        }
        wetGain = g
    }

    /// Pulls the matching reference hop, runs AEC3 on `hopIn`, and queues the result.
    private func runHop() {
        let hop = EchoCanceller.hop
        reference.read(into: refRaw, frames: UInt32(hop))
        _ = webrtc_aec3_process_reverse_stream(state, refRaw)

        hopOut.update(from: hopIn, count: hop)
        _ = webrtc_aec3_process_stream(state, hopOut)

        for i in 0..<hop {
            fifo[fifoWrite & fifoMask] = hopOut[i]
            fifoWrite += 1
        }
    }
}
