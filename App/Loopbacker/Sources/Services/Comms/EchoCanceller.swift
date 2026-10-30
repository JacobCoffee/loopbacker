import Accelerate
import CSpeexAEC
import Synchronization
import os.log

private let aecLogger = Logger(subsystem: "com.jacobcoffee.loopbacker", category: "EchoCanceller")

/// Acoustic echo cancellation for a mic's voice pair, running SpeexDSP's MDF adaptive filter
/// (BSD-3-Clause) against the far-end reference from a `SystemAudioTap`. See
/// `../../../CSpeexAEC/README.md` for why this vendors SpeexDSP's MDF rather than WebRTC's AEC3
/// (the originally planned engine).
///
/// 48 kHz, 10 ms (480-sample) hops, mono capture. `process` accepts any block size from 1 to
/// `FXBlock.maxFrames` (4096): samples are queued into a 480-sample hop buffer and the filter
/// only ever runs on exact hops, so output trails input by `latencySamples` (`hop - 1` = 479
/// samples) while a hop fills — the same buffering shape as `NoiseSuppressor`, but without its
/// extra kernel delay, since MDF's synchronized API has no inherent lookahead beyond the hop
/// itself.
///
/// Each hop also pulls `hop` frames of far-end reference from `reference` (a `DriftCompensatedRing`
/// fed by `SystemAudioTap`'s IOProc), downmixing stereo to mono before handing both to
/// `speex_echo_cancellation`. The ring's own drift/delay steering keeps the reference
/// time-aligned with capture; MDF's adaptive filter (`filterLength` taps, 200 ms at 48 kHz)
/// absorbs the residual room impulse response and any alignment error within that window.
///
/// Thread contract:
/// - `process` runs on the capture device's IO thread. It is the sole reader of `reference`
///   (`DriftCompensatedRing`'s single-reader contract) and touches no Swift reference types other
///   than itself; the one call per hop into `speex_echo_cancellation`/`speex_echo_ctl` is a C
///   function call into state fixed at init, which allocates nothing (verified: every
///   `speex_alloc` in the vendored `mdf.c` runs only from `speex_echo_state_init`).
/// - `setEnabled` may be called from any thread.
final class EchoCanceller: @unchecked Sendable {
    static let sampleRate = 48_000
    static let hop = 480
    /// 200 ms at 48 kHz: comfortably covers the 40–150 ms bulk delays plus room reverberation
    /// tail this is meant to cancel.
    static let filterLength = 9_600
    /// Largest block cached in one `process` call; larger blocks are split into chunks of this
    /// size internally, same convention as `NoiseSuppressor.maxBlock`.
    private static let maxBlock = 4_096
    /// Wet/dry crossfade step per sample (10 ms at 48 kHz).
    private static let fadeStep: Float = 1.0 / 480.0

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
    private let refMono: UnsafeMutablePointer<Float>
    private let micInt16: UnsafeMutablePointer<Int16>
    private let refInt16: UnsafeMutablePointer<Int16>
    private let outInt16: UnsafeMutablePointer<Int16>
    private let fifo: UnsafeMutablePointer<Float>

    /// An echo canceller reading its far-end reference from `reference`, or nil (logged) if the
    /// vendored MDF implementation can't be initialized.
    static func make(reference: DriftCompensatedRing) -> EchoCanceller? {
        guard reference.sampleRate == Double(Self.sampleRate) else {
            aecLogger.error("Echo cancellation needs a 48 kHz reference; tap runs at \(reference.sampleRate) Hz")
            return nil
        }
        guard let state = speex_echo_state_init(Int32(hop), Int32(filterLength)) else {
            aecLogger.error("speex_echo_state_init failed")
            return nil
        }
        var rate = Int32(sampleRate)
        _ = speex_echo_ctl(state, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)
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
        let floatCounts = [Self.hop, Self.hop, Self.hop * refChannels, Self.hop, fifoSize]
        let int16Bytes = 3 * Self.hop * MemoryLayout<Int16>.size
        let total = rounded(
            floatCounts.reduce(0) { $0 + rounded($1 * MemoryLayout<Float>.size, to: 64) } + rounded(int16Bytes, to: 64),
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
        refMono = floats(Self.hop)
        fifo = floats(fifoSize)
        func int16s(_ count: Int) -> UnsafeMutablePointer<Int16> {
            let p = (mapping + offset).bindMemory(to: Int16.self, capacity: count)
            offset += rounded(count * MemoryLayout<Int16>.size, to: 64)
            return p
        }
        micInt16 = int16s(Self.hop)
        refInt16 = int16s(Self.hop)
        outInt16 = int16s(Self.hop)
    }

    deinit {
        speex_echo_state_destroy(state)
        munmap(arena, arenaSize)
    }

    func setEnabled(_ on: Bool) {
        enabled.store(on, ordering: .relaxed)
    }

    func reset() {
        speex_echo_state_reset(state)
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

    /// Pulls the matching reference hop, runs MDF on `hopIn`, and queues the result.
    private func runHop() {
        let hop = EchoCanceller.hop
        let refChannels = max(reference.channels, 1)
        reference.read(into: refRaw, frames: UInt32(hop))
        if refChannels == 1 {
            refMono.update(from: refRaw, count: hop)
        } else if refChannels == 2 {
            // Interleaved stereo: average L/R with strided vDSP adds rather than a scalar loop.
            var half: Float = 0.5
            vDSP_vadd(refRaw, 2, refRaw.advanced(by: 1), 2, refMono, 1, vDSP_Length(hop))
            vDSP_vsmul(refMono, 1, &half, refMono, 1, vDSP_Length(hop))
        } else {
            for i in 0..<hop {
                var sum: Float = 0
                for c in 0..<refChannels { sum += refRaw[i * refChannels + c] }
                refMono[i] = sum / Float(refChannels)
            }
        }

        // Clamp before quantizing: `vDSP_vfix16` wraps rather than saturates, and real mic/system
        // audio routinely exceeds ±1 (clipping, hot room-impulse-response peaks), which would
        // otherwise corrupt the int16 frame the adaptive filter sees.
        var scaleUp: Float = 32767, lo: Float = -1, hi: Float = 1
        vDSP_vclip(hopIn, 1, &lo, &hi, hopOut, 1, vDSP_Length(hop))
        vDSP_vsmul(hopOut, 1, &scaleUp, hopOut, 1, vDSP_Length(hop))
        vDSP_vfix16(hopOut, 1, micInt16, 1, vDSP_Length(hop))
        vDSP_vclip(refMono, 1, &lo, &hi, hopOut, 1, vDSP_Length(hop))
        vDSP_vsmul(hopOut, 1, &scaleUp, hopOut, 1, vDSP_Length(hop))
        vDSP_vfix16(hopOut, 1, refInt16, 1, vDSP_Length(hop))

        speex_echo_cancellation(state, micInt16, refInt16, outInt16)

        vDSP_vflt16(outInt16, 1, hopOut, 1, vDSP_Length(hop))
        var scaleDown: Float = 1.0 / 32767
        vDSP_vsmul(hopOut, 1, &scaleDown, hopOut, 1, vDSP_Length(hop))
        for i in 0..<hop {
            fifo[fifoWrite & fifoMask] = hopOut[i]
            fifoWrite += 1
        }
    }
}
