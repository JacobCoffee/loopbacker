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
/// `DriftCompensatedRing.Reader` bound to a `SystemAudioTap`'s ring) and feeds it to AEC3's
/// `ProcessReverseStream` before running `ProcessStream` on the mic hop. Unlike MDF, AEC3
/// estimates and tracks the render/capture delay itself (`set_stream_delay_ms` only supplies a
/// starting point), so it isn't limited by the reference ring's own latency the way MDF was —
/// AEC3 handles delays up to roughly 500 ms on its own. Each `EchoCanceller` owns its own
/// `Reader` (via `DriftCompensatedRing.makeReader()`), so multiple cancellers on different
/// capture devices reading the same `SystemAudioTap.ring` each track that far-end timeline
/// independently instead of racing one shared cursor.
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
/// - `process` runs on the capture device's IO thread. It is the sole reader of its own
///   `DriftCompensatedRing.Reader` and touches no Swift reference types other than itself; the
///   per-hop calls into the shim's `webrtc_aec3_process_reverse_stream`/
///   `webrtc_aec3_process_stream` reach into `webrtc::AudioProcessing`'s steady-state
///   processing path, which (verified with an interposed malloc over 2000 process() calls)
///   does not allocate — all working buffers are sized at `webrtc_aec3_create`/`Initialize`
///   time.
/// - `setEnabled` and `setStreamDelay` may be called from any thread.
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
    /// only needs to be in the right ballpark, not exact. `AudioRouter` overrides this with a
    /// real HAL-latency estimate via `setStreamDelay` once a route attaches; this default only
    /// matters for the brief window before that first call, and in tests that skip it.
    private static let initialDelayMs: Int32 = 30
    /// ERLE smoothing: a one-pole average over roughly 1 s of hops (100 at 10 ms/hop), so the
    /// UI's live indicator doesn't flicker hop to hop.
    private static let erleSmoothing: Float = 0.01

    /// Declared latency: a hop must fill before any of it can be emitted.
    let latencySamples = EchoCanceller.hop - 1

    private let reference: DriftCompensatedRing.Reader
    private let state: OpaquePointer

    private let enabled = Atomic<Bool>(false)
    private var wetGain: Float = 0
    /// IO thread only: true once the FIFO has emitted real AEC3 output at least once since
    /// construction or the last `reset()`. Before that, `fifo` still holds its startup
    /// zero-fill over the first `hop - 1` reads (the declared `latencySamples`), so the
    /// crossfade in `processChunk` must not start ramping toward wet yet -- blending toward
    /// silence there would mute the live mic almost completely for ~10 ms on every attach,
    /// then abruptly jump to real output once a hop actually lands.
    private var primed = false
    private var hopFill = 0
    private var fifoRead = 0
    private var fifoWrite: Int
    private let fifoMask: Int

    /// Set from any thread (`AudioRouter`, computing it from HAL latency properties);
    /// applied on the IO thread at the start of the next hop, since the AEC3 state isn't safe
    /// to touch concurrently with `ProcessStream`/`ProcessReverseStream`.
    private let desiredDelayMs = Atomic<Int32>(EchoCanceller.initialDelayMs)
    /// IO thread only: the delay last actually pushed into AEC3, to skip the shim call on hops
    /// where nothing changed.
    private var appliedDelayMs = EchoCanceller.initialDelayMs
    /// Smoothed echo-return-loss enhancement in dB (how much the hop's power dropped from mic
    /// input to cancelled output), for `EchoCancellationSection`'s live "echo removed"
    /// indicator. Updated every hop on the IO thread, read from any thread.
    private let erleDBBits = Atomic<UInt32>(Float(0).bitPattern)

    /// Shared-route cache: the other voice route on the same capture device (virtual mic +
    /// monitor) copies this call's result instead of re-running AEC3 on the same mic block,
    /// the same downmix/writeback/cache-by-`sampleTime` shape `NoiseSuppressor.process` uses.
    /// Duplicated rather than factored into a shared helper type since `NoiseSuppressor.swift`
    /// belongs to another slice. Touched only by `process(_:frames:stride:sampleTime:)`.
    private let busy = Atomic<Bool>(false)
    private var cachedStart: Float64 = -1
    private var cachedFrames = 0
    private var cachedActive = false

    /// One wired (mlock'd) anonymous mapping holds every buffer the IO thread touches.
    private let arena: UnsafeMutableRawPointer
    private let arenaSize: Int
    private let hopIn: UnsafeMutablePointer<Float>
    private let hopOut: UnsafeMutablePointer<Float>
    private let refRaw: UnsafeMutablePointer<Float>
    private let fifo: UnsafeMutablePointer<Float>
    private let cachedBlock: UnsafeMutablePointer<Float>

    /// An echo canceller reading its far-end reference from a new `Reader` on `reference`
    /// (its own independent cursor -- see `DriftCompensatedRing`'s multi-reader doc comment),
    /// or nil (logged) if the vendored AEC3 implementation can't be initialized.
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
        return EchoCanceller(reference: reference.makeReader(), channels: reference.channels, state: state)
    }

    private init(reference: DriftCompensatedRing.Reader, channels: Int, state: OpaquePointer) {
        self.reference = reference
        self.state = state

        func powerOfTwo(atLeast n: Int) -> Int { 1 << (Int.bitWidth - (n - 1).leadingZeroBitCount) }
        let lead = Self.hop - 1
        let fifoSize = powerOfTwo(atLeast: lead + Self.hop)
        fifoMask = fifoSize - 1
        fifoWrite = lead

        func rounded(_ bytes: Int, to alignment: Int) -> Int { (bytes + alignment - 1) / alignment * alignment }
        let refChannels = max(channels, 1)
        let floatCounts = [Self.hop, Self.hop, Self.hop * refChannels, fifoSize, Self.maxBlock]
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
        cachedBlock = floats(Self.maxBlock)
    }

    deinit {
        webrtc_aec3_destroy(state)
        munmap(arena, arenaSize)
    }

    func setEnabled(_ on: Bool) {
        enabled.store(on, ordering: .relaxed)
    }

    /// Updates AEC3's delay-estimator starting point (see `webrtc_aec3_shim.h`). Any thread.
    func setStreamDelay(ms: Int32) {
        desiredDelayMs.store(ms, ordering: .relaxed)
    }

    /// Smoothed echo-return-loss enhancement in dB, or 0 before the first hop with meaningful
    /// mic input has run. Any thread.
    var erleDB: Float { Float(bitPattern: erleDBBits.load(ordering: .relaxed)) }

    func reset() {
        webrtc_aec3_reset(state)
        let delay = desiredDelayMs.load(ordering: .relaxed)
        webrtc_aec3_set_stream_delay_ms(state, delay)
        appliedDelayMs = delay
        wetGain = 0
        primed = false
        hopFill = 0
        fifoRead = 0
        fifoWrite = EchoCanceller.hop - 1
        fifo.update(repeating: 0, count: fifoMask + 1)
        erleDBBits.store(Float(0).bitPattern, ordering: .relaxed)
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

    /// Cancels far-end echo from a voice pair's mixed buffer in place: downmixes `stride`
    /// channels to mono, runs `process`, and writes the result back to up to 2 channels --
    /// `NoiseSuppressor.process`'s downmix/writeback/cache-by-`sampleTime` shape, so the other
    /// voice route on the same capture device (virtual mic + monitor) copies this call's
    /// result instead of re-running AEC3 on the same mic block.
    ///
    /// - Parameter sampleTime: the block's HAL input sample time. A block already processed
    ///   for another route (same start and length) is copied instead of processed again.
    func process(_ buffer: UnsafeMutablePointer<Float>, frames: Int, stride: Int, sampleTime: Float64?) {
        let channels = min(stride, 2)
        guard channels > 0, frames > 0 else { return }
        guard busy.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged else { return }
        defer { busy.store(false, ordering: .releasing) }

        if let sampleTime, sampleTime == cachedStart, frames == cachedFrames {
            if cachedActive { writeBack(cachedBlock, into: buffer, frames: frames, stride: stride, channels: channels) }
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
            downmix(block, frames: n, stride: stride, channels: channels, into: cachedBlock)
            processChunk(cachedBlock, frames: n)
            if shareable { cachedActive = true }
            writeBack(cachedBlock, into: block, frames: n, stride: stride, channels: channels)
            offset += n
        }
    }

    private func downmix(_ buffer: UnsafePointer<Float>, frames: Int, stride: Int, channels: Int,
                         into mono: UnsafeMutablePointer<Float>) {
        for i in 0..<frames {
            let base = i * stride
            mono[i] = channels == 1 ? buffer[base] : 0.5 * (buffer[base] + buffer[base + 1])
        }
    }

    private func writeBack(_ mono: UnsafePointer<Float>, into buffer: UnsafeMutablePointer<Float>,
                           frames: Int, stride: Int, channels: Int) {
        for i in 0..<frames {
            buffer[i * stride] = mono[i]
            if channels == 2 { buffer[i * stride + 1] = mono[i] }
        }
    }

    private func processChunk(_ buf: UnsafeMutablePointer<Float>, frames n: Int) {
        let want = enabled.load(ordering: .relaxed)
        var g = wetGain
        let lead = EchoCanceller.hop - 1
        for i in 0..<n {
            let dry = buf[i]
            hopIn[hopFill] = dry
            hopFill += 1
            if hopFill == EchoCanceller.hop {
                runHop()
                hopFill = 0
            }
            // The FIFO's first `lead` reads are still startup zero-fill (see `primed`'s doc
            // comment); once `fifoRead` reaches `lead`, every subsequent read is genuine AEC3
            // output.
            if !primed, fifoRead >= lead { primed = true }
            let wet = fifo[fifoRead & fifoMask]
            fifoRead += 1

            let target: Float = (want && primed) ? 1 : 0
            g = target > g ? min(target, g + Self.fadeStep) : max(target, g - Self.fadeStep)
            buf[i] = g * wet + (1 - g) * dry
        }
        wetGain = g
    }

    /// Applies any pending delay update, pulls the matching reference hop, runs AEC3 on
    /// `hopIn`, queues the result, and updates the smoothed ERLE metric.
    private func runHop() {
        let wantedDelay = desiredDelayMs.load(ordering: .relaxed)
        if wantedDelay != appliedDelayMs {
            webrtc_aec3_set_stream_delay_ms(state, wantedDelay)
            appliedDelayMs = wantedDelay
        }

        let hop = EchoCanceller.hop
        reference.read(into: refRaw, frames: UInt32(hop))
        _ = webrtc_aec3_process_reverse_stream(state, refRaw)

        hopOut.update(from: hopIn, count: hop)
        _ = webrtc_aec3_process_stream(state, hopOut)

        var inPower: Float = 0
        var outPower: Float = 0
        vDSP_measqv(hopIn, 1, &inPower, vDSP_Length(hop))
        vDSP_measqv(hopOut, 1, &outPower, vDSP_Length(hop))
        if inPower > 1e-9, outPower > 1e-9 {
            let instantaneousERLE = max(0, 10 * log10f(inPower / outPower))
            let prev = Float(bitPattern: erleDBBits.load(ordering: .relaxed))
            let smoothed = prev + Self.erleSmoothing * (instantaneousERLE - prev)
            erleDBBits.store(smoothed.bitPattern, ordering: .relaxed)
        }

        for i in 0..<hop {
            fifo[fifoWrite & fifoMask] = hopOut[i]
            fifoWrite += 1
        }
    }
}
