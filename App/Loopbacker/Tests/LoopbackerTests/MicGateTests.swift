import Testing
@testable import Loopbacker

/// `MicGate.shared` publishes a single target gain (the singleton part), but each route's ramp
/// *position* toward that target lives in its own `MicGate.RouteState`, constructed fresh by
/// each test -- no cross-test interference, and no cross-route interference either (see
/// `perRouteRampStateIsIndependent`).
@Suite("MicGate", .serialized)
struct MicGateTests {
    private let frames = 64
    private let channelStride = 2

    private func makeBuffer(value: Float = 1) -> [Float] {
        Array(repeating: value, count: frames * channelStride)
    }

    @Test("Unmuted, steady gain passes audio through unchanged")
    func passthroughWhenLive() {
        MicGate.shared.resetForTesting(target: 1)
        let state = MicGate.RouteState(currentGain: 1)
        var buffer = makeBuffer(value: 0.5)
        buffer.withUnsafeMutableBufferPointer { ptr in
            MicGate.shared.process(ptr.baseAddress!, frames: frames, stride: channelStride, state: state)
        }
        #expect(buffer.allSatisfy { $0 == 0.5 })
    }

    @Test("Muted, steady gain zeroes the block")
    func silentWhenMuted() {
        MicGate.shared.resetForTesting(target: 0)
        let state = MicGate.RouteState(currentGain: 0)
        var buffer = makeBuffer(value: 0.5)
        buffer.withUnsafeMutableBufferPointer { ptr in
            MicGate.shared.process(ptr.baseAddress!, frames: frames, stride: channelStride, state: state)
        }
        #expect(buffer.allSatisfy { $0 == 0 })
    }

    @Test("Mute ramps down smoothly over 10 ms without a click")
    func rampDownIsClickFree() {
        MicGate.shared.resetForTesting(target: 0)
        let state = MicGate.RouteState(currentGain: 1)
        var buffer = makeBuffer(value: 1)
        buffer.withUnsafeMutableBufferPointer { ptr in
            MicGate.shared.process(ptr.baseAddress!, frames: frames, stride: channelStride, state: state)
        }
        // Every sample pair shares one gain; extract the per-frame gain via channel 0.
        let gains = stride(from: 0, to: buffer.count, by: channelStride).map { buffer[$0] }
        // Monotonically non-increasing: no click (no abrupt jump back up).
        for i in 1..<gains.count {
            #expect(gains[i] <= gains[i - 1] + 1e-6)
        }
        // Step per frame is bounded to the 10 ms ramp (1/480 of full scale at 48 kHz).
        for i in 1..<gains.count {
            #expect(gains[i - 1] - gains[i] <= 1.0 / 480.0 + 1e-6)
        }
        // After 64 frames (< 480), still live-ish: hasn't reached zero yet.
        #expect(gains.last! > 0)
    }

    @Test("Mute ramp fully settles to silence after 480 samples (10 ms at 48 kHz)")
    func rampDownSettles() {
        MicGate.shared.resetForTesting(target: 0)
        let state = MicGate.RouteState(currentGain: 1)
        var buffer = Array(repeating: Float(1), count: 480 * channelStride)
        buffer.withUnsafeMutableBufferPointer { ptr in
            MicGate.shared.process(ptr.baseAddress!, frames: 480, stride: channelStride, state: state)
        }
        let lastGain = buffer[buffer.count - channelStride]
        #expect(lastGain == 0)
    }

    @Test("Unmute ramps up smoothly over 10 ms without a click")
    func rampUpIsClickFree() {
        MicGate.shared.resetForTesting(target: 1)
        let state = MicGate.RouteState(currentGain: 0)
        var buffer = makeBuffer(value: 1)
        buffer.withUnsafeMutableBufferPointer { ptr in
            MicGate.shared.process(ptr.baseAddress!, frames: frames, stride: channelStride, state: state)
        }
        let gains = stride(from: 0, to: buffer.count, by: channelStride).map { buffer[$0] }
        for i in 1..<gains.count {
            #expect(gains[i] >= gains[i - 1] - 1e-6)
            #expect(gains[i] - gains[i - 1] <= 1.0 / 480.0 + 1e-6)
        }
    }

    @Test("A ramp in progress continues from where the previous block left off")
    func rampContinuesAcrossBlocks() {
        MicGate.shared.resetForTesting(target: 0)
        let state = MicGate.RouteState(currentGain: 1)
        var first = makeBuffer(value: 1)
        first.withUnsafeMutableBufferPointer { ptr in
            MicGate.shared.process(ptr.baseAddress!, frames: frames, stride: channelStride, state: state)
        }
        let firstEnd = first[first.count - channelStride]

        var second = makeBuffer(value: 1)
        second.withUnsafeMutableBufferPointer { ptr in
            MicGate.shared.process(ptr.baseAddress!, frames: frames, stride: channelStride, state: state)
        }
        let secondStart = second[0]
        // No discontinuity across the block boundary.
        #expect(abs(secondStart - (firstEnd - 1.0 / 480.0)) < 1e-5)
    }

    @Test("Zero-frame or zero-channelStride calls are a no-op, not a crash")
    func degenerateCallsAreNoOps() {
        MicGate.shared.resetForTesting(target: 0)
        let state = MicGate.RouteState(currentGain: 1)
        var buffer: [Float] = []
        buffer.withUnsafeMutableBufferPointer { ptr in
            MicGate.shared.process(ptr.baseAddress ?? UnsafeMutablePointer<Float>(bitPattern: 1)!, frames: 0,
                                   stride: 2, state: state)
        }
        #expect(buffer.isEmpty)
    }

    @Test("Target can be set via setTarget(muted:) and is picked up by the next process call")
    func setTargetMuted() {
        MicGate.shared.resetForTesting(target: 1)
        MicGate.shared.setTarget(muted: true)
        let state = MicGate.RouteState(currentGain: 1)
        var buffer = Array(repeating: Float(1), count: 480 * channelStride)
        buffer.withUnsafeMutableBufferPointer { ptr in
            MicGate.shared.process(ptr.baseAddress!, frames: 480, stride: channelStride, state: state)
        }
        #expect(buffer[buffer.count - channelStride] == 0)
    }

    @Test("Two routes ramping toward different starting points keep independent ramp state instead of fighting over one shared cursor")
    func perRouteRampStateIsIndependent() {
        // Regression guard for the block-edge gain jump finding: Virtual Mic and Stream Mix
        // (or two capture devices) used to share MicGate's one `currentGain`, so whichever
        // route's callback ran second each block picked up wherever the *other* route's ramp
        // had gotten to. With independent `RouteState`s, route A's progress must never leak
        // into route B's gain, even though both read the same published target.
        MicGate.shared.resetForTesting(target: 0)
        let routeA = MicGate.RouteState(currentGain: 1)   // mid-ramp, close to live
        let routeB = MicGate.RouteState(currentGain: 0.1) // mid-ramp, close to muted

        var bufferA = makeBuffer(value: 1)
        bufferA.withUnsafeMutableBufferPointer { ptr in
            MicGate.shared.process(ptr.baseAddress!, frames: frames, stride: channelStride, state: routeA)
        }
        // Route B's callback runs right after A's, on the same published target, same as two
        // voice routes on one capture device's IO thread back to back.
        var bufferB = makeBuffer(value: 1)
        bufferB.withUnsafeMutableBufferPointer { ptr in
            MicGate.shared.process(ptr.baseAddress!, frames: frames, stride: channelStride, state: routeB)
        }

        let gainA = bufferA[bufferA.count - channelStride]
        let gainB = bufferB[bufferB.count - channelStride]
        // A started at 1 and ramped down by exactly `frames` steps of its own (1/480 each);
        // B started at 0.1 and ramped straight to 0 (0.1 - 64/480 clamps at the target). If
        // they shared one cursor, B's block would instead have continued from A's post-block
        // gain (~0.867) rather than its own near-zero starting point.
        let expectedGainA: Float = 1 - Float(frames) * (1.0 / 480.0)
        #expect(abs(gainA - expectedGainA) < 1e-4, "route A's own ramp should match its own 64-frame descent from 1, not route B's")
        #expect(gainB == 0, "route B's own ramp (started at 0.1) should have reached its target, not jumped up to A's gain")

        // Processing more blocks on A must never move B's state (and vice versa): each
        // `RouteState` is only ever touched through its own `process` calls.
        let gainBBefore = routeB.currentGain
        var moreA = makeBuffer(value: 1)
        moreA.withUnsafeMutableBufferPointer { ptr in
            MicGate.shared.process(ptr.baseAddress!, frames: frames, stride: channelStride, state: routeA)
        }
        #expect(routeB.currentGain == gainBBefore)
    }
}
