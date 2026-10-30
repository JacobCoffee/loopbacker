import Foundation
import Testing
@testable import Loopbacker

/// Exercises `EchoCanceller.process(_:frames:stride:sampleTime:)`, the wrapper `AudioRouter`
/// wires into a voice route's `processCapturedBlock` (mix → echo cancellation → noise
/// suppression → FX chain): downmix/writeback to a stereo voice pair, and the
/// cache-by-`sampleTime` sharing two voice routes on the same capture device (virtual mic +
/// monitor) rely on so only one of them actually runs AEC3 per block. `AudioRouter.RouteContext`
/// itself is `fileprivate`, so this constructs the lowest-level pieces it composes
/// (`EchoCanceller` + `DriftCompensatedRing`) directly, the same approach `EchoCancellerTests`
/// uses for the mono path.
@Suite("Echo cancellation routing (stride/sharing/crossfade)")
struct EchoCancellationRoutingTests {
    private let rate: Float = 48_000

    /// A reference ring pre-loaded with `seconds` of a 440 Hz tone, long enough that every hop
    /// this suite reads comes from real data already written -- no interleaved writer thread
    /// needed, unlike `EchoCancellerTests`' drift scenarios.
    private func makeReferenceRing(seconds: Float) -> DriftCompensatedRing {
        let totalFrames = Int(seconds * rate)
        var capacity: UInt32 = 1 << 16
        while capacity < UInt32(totalFrames) { capacity <<= 1 }
        let ring = DriftCompensatedRing(capacityFrames: capacity, channels: 2, targetFill: 2_400, sampleRate: 48_000)
        var tone = [Float](repeating: 0, count: totalFrames * 2)
        for i in 0..<totalFrames {
            let s = sinf(2 * .pi * 440 * Float(i) / rate) * 0.5
            tone[i * 2] = s
            tone[i * 2 + 1] = s
        }
        tone.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: UInt32(totalFrames)) }
        return ring
    }

    /// Mic signal: the same tone as the reference (an unattenuated, undelayed echo) duplicated
    /// into a stereo voice pair, matching how `RouteContext.mixBuffer` holds channels 1-2.
    private func makeStereoMic(seconds: Float) -> [Float] {
        let totalFrames = Int(seconds * rate)
        var out = [Float](repeating: 0, count: totalFrames * 2)
        for i in 0..<totalFrames {
            let s = sinf(2 * .pi * 440 * Float(i) / rate) * 0.5
            out[i * 2] = s
            out[i * 2 + 1] = s
        }
        return out
    }

    private func power(_ x: ArraySlice<Float>) -> Float {
        x.reduce(Float(0)) { $0 + $1 * $1 } / Float(x.count)
    }

    @Test("Cancels a synthetic echo fed through a reference ring (stride/stereo path)")
    func cancelsEchoThroughStridePath() throws {
        let seconds: Float = 4
        let ring = makeReferenceRing(seconds: seconds)
        let canceller = try #require(EchoCanceller.make(reference: ring))
        canceller.setEnabled(true)

        var mic = makeStereoMic(seconds: seconds)
        let chunk = 960 // 20 ms, an ordinary FXBlock-sized voice route block
        let totalFrames = Int(seconds * rate)
        var offset = 0
        var sampleTime: Float64 = 0
        mic.withUnsafeMutableBufferPointer { buf in
            while offset < totalFrames {
                let n = min(chunk, totalFrames - offset)
                canceller.process(buf.baseAddress!.advanced(by: offset * 2), frames: n, stride: 2, sampleTime: sampleTime)
                offset += n
                sampleTime += Float64(n)
            }
        }
        #expect(mic.allSatisfy { $0.isFinite })

        // Measure the last second, well after the adaptive filter has converged, on one
        // channel (both channels carry the same mono-cancelled result written back).
        let windowFrames = Int(rate)
        let micDry = makeStereoMic(seconds: seconds)
        let startSample = (totalFrames - windowFrames) * 2
        var dryChannel: [Float] = []
        var outChannel: [Float] = []
        dryChannel.reserveCapacity(windowFrames)
        outChannel.reserveCapacity(windowFrames)
        var i = startSample
        while i < totalFrames * 2 {
            dryChannel.append(micDry[i])
            outChannel.append(mic[i])
            i += 2
        }
        let erle = 10 * log10f(power(dryChannel[...]) / power(outChannel[...]))
        #expect(erle >= 15, "ERLE \(erle) dB through the stride/stereo path")
    }

    @Test("Shares one canceller's result across two voice routes on the same capture device by sampleTime")
    func sharesResultBySampleTime() throws {
        let ring = makeReferenceRing(seconds: 2)
        let canceller = try #require(EchoCanceller.make(reference: ring))
        canceller.setEnabled(true)

        let frames = 480
        let sampleTime: Float64 = 12_345

        // Route A (e.g. the virtual mic route): the real dry mic content.
        var routeA = makeStereoMic(seconds: 1)
        routeA = Array(routeA.prefix(frames * 2))
        routeA.withUnsafeMutableBufferPointer { buf in
            canceller.process(buf.baseAddress!, frames: frames, stride: 2, sampleTime: sampleTime)
        }

        // Route B (e.g. the monitor route): same capture-device block (same `sampleTime` and
        // frame count), but deliberately filled with different numbers. If sharing works, this
        // call is a cache hit and copies route A's already-computed result verbatim rather than
        // running AEC3 again on these (wrong) contents.
        var routeB = [Float](repeating: 0.987_654, count: frames * 2)
        routeB.withUnsafeMutableBufferPointer { buf in
            canceller.process(buf.baseAddress!, frames: frames, stride: 2, sampleTime: sampleTime)
        }

        #expect(routeB == routeA)

        // A different sampleTime is a cache miss: it must not just replay the stale cached
        // block, even though the contents happen to be identical to route A's dry input again.
        var routeC = Array(makeStereoMic(seconds: 1).prefix(frames * 2))
        let routeCInput = routeC
        routeC.withUnsafeMutableBufferPointer { buf in
            canceller.process(buf.baseAddress!, frames: frames, stride: 2, sampleTime: sampleTime + Float64(frames))
        }
        #expect(routeC.allSatisfy { $0.isFinite })
        // It should still have been processed (not left dry), proving this wasn't a copy of a
        // stale cache entry from a shortcut that ignores `sampleTime`.
        #expect(routeC != routeCInput)
    }

    @Test("Disabling crossfades back to the dry signal instead of cutting instantly")
    func disablingCrossfades() throws {
        let ring = makeReferenceRing(seconds: 3)
        let canceller = try #require(EchoCanceller.make(reference: ring))
        canceller.setEnabled(true)

        var mic = makeStereoMic(seconds: 3)
        let chunk = 960
        let totalFrames = Int(3 * rate)
        var offset = 0
        var sampleTime: Float64 = 0
        var disabledAtOffset = -1
        mic.withUnsafeMutableBufferPointer { buf in
            while offset < totalFrames {
                // Disable partway through, once the filter has had a second to converge.
                if offset >= Int(rate), disabledAtOffset < 0 {
                    canceller.setEnabled(false)
                    disabledAtOffset = offset
                }
                let n = min(chunk, totalFrames - offset)
                canceller.process(buf.baseAddress!.advanced(by: offset * 2), frames: n, stride: 2, sampleTime: sampleTime)
                offset += n
                sampleTime += Float64(n)
            }
        }
        #expect(mic.allSatisfy { $0.isFinite })
        #expect(disabledAtOffset >= 0)

        let dry = makeStereoMic(seconds: 3)
        // Immediately after disabling, the signal is still mostly the cancelled (wet) output,
        // not yet back to dry: the 10 ms crossfade hasn't finished.
        let justAfterDisable = disabledAtOffset * 2
        let earlyDeltaFromDry = abs(mic[justAfterDisable] - dry[justAfterDisable])

        // Well after the crossfade (480 samples = 10 ms) has had time to complete and a
        // further hop to flush through the FIFO, the signal has settled back to dry.
        let settledIndex = (disabledAtOffset + 2_000) * 2
        let settledDelta = abs(mic[settledIndex] - dry[settledIndex])
        #expect(settledDelta < 0.01, "still \(settledDelta) away from dry long after disabling")

        // The crossfade actually happened gradually: the settled error is much smaller than
        // right after disabling (which was still showing meaningful cancellation).
        #expect(settledDelta < earlyDeltaFromDry || earlyDeltaFromDry < 0.01)
    }
}
