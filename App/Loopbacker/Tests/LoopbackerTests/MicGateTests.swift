import Testing
@testable import Loopbacker

/// `MicGate.shared` is a singleton (its target gain is published for the real IO thread), so
/// every test resets it first and drives it with its own buffer -- no cross-test interference.
@Suite("MicGate", .serialized)
struct MicGateTests {
    private let frames = 64
    private let channelStride = 2

    private func makeBuffer(value: Float = 1) -> [Float] {
        Array(repeating: value, count: frames * channelStride)
    }

    @Test("Unmuted, steady gain passes audio through unchanged")
    func passthroughWhenLive() {
        MicGate.shared.resetForTesting(currentGain: 1, target: 1)
        var buffer = makeBuffer(value: 0.5)
        buffer.withUnsafeMutableBufferPointer { ptr in
            MicGate.shared.process(ptr.baseAddress!, frames: frames, stride: channelStride)
        }
        #expect(buffer.allSatisfy { $0 == 0.5 })
    }

    @Test("Muted, steady gain zeroes the block")
    func silentWhenMuted() {
        MicGate.shared.resetForTesting(currentGain: 0, target: 0)
        var buffer = makeBuffer(value: 0.5)
        buffer.withUnsafeMutableBufferPointer { ptr in
            MicGate.shared.process(ptr.baseAddress!, frames: frames, stride: channelStride)
        }
        #expect(buffer.allSatisfy { $0 == 0 })
    }

    @Test("Mute ramps down smoothly over 10 ms without a click")
    func rampDownIsClickFree() {
        MicGate.shared.resetForTesting(currentGain: 1, target: 0)
        var buffer = makeBuffer(value: 1)
        buffer.withUnsafeMutableBufferPointer { ptr in
            MicGate.shared.process(ptr.baseAddress!, frames: frames, stride: channelStride)
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
        MicGate.shared.resetForTesting(currentGain: 1, target: 0)
        var buffer = Array(repeating: Float(1), count: 480 * channelStride)
        buffer.withUnsafeMutableBufferPointer { ptr in
            MicGate.shared.process(ptr.baseAddress!, frames: 480, stride: channelStride)
        }
        let lastGain = buffer[buffer.count - channelStride]
        #expect(lastGain == 0)
    }

    @Test("Unmute ramps up smoothly over 10 ms without a click")
    func rampUpIsClickFree() {
        MicGate.shared.resetForTesting(currentGain: 0, target: 1)
        var buffer = makeBuffer(value: 1)
        buffer.withUnsafeMutableBufferPointer { ptr in
            MicGate.shared.process(ptr.baseAddress!, frames: frames, stride: channelStride)
        }
        let gains = stride(from: 0, to: buffer.count, by: channelStride).map { buffer[$0] }
        for i in 1..<gains.count {
            #expect(gains[i] >= gains[i - 1] - 1e-6)
            #expect(gains[i] - gains[i - 1] <= 1.0 / 480.0 + 1e-6)
        }
    }

    @Test("A ramp in progress continues from where the previous block left off")
    func rampContinuesAcrossBlocks() {
        MicGate.shared.resetForTesting(currentGain: 1, target: 0)
        var first = makeBuffer(value: 1)
        first.withUnsafeMutableBufferPointer { ptr in
            MicGate.shared.process(ptr.baseAddress!, frames: frames, stride: channelStride)
        }
        let firstEnd = first[first.count - channelStride]

        var second = makeBuffer(value: 1)
        second.withUnsafeMutableBufferPointer { ptr in
            MicGate.shared.process(ptr.baseAddress!, frames: frames, stride: channelStride)
        }
        let secondStart = second[0]
        // No discontinuity across the block boundary.
        #expect(abs(secondStart - (firstEnd - 1.0 / 480.0)) < 1e-5)
    }

    @Test("Zero-frame or zero-channelStride calls are a no-op, not a crash")
    func degenerateCallsAreNoOps() {
        MicGate.shared.resetForTesting(currentGain: 1, target: 0)
        var buffer: [Float] = []
        buffer.withUnsafeMutableBufferPointer { ptr in
            MicGate.shared.process(ptr.baseAddress ?? UnsafeMutablePointer<Float>(bitPattern: 1)!, frames: 0, stride: 2)
        }
        #expect(buffer.isEmpty)
    }

    @Test("Target can be set via setTarget(muted:) and is picked up by the next process call")
    func setTargetMuted() {
        MicGate.shared.resetForTesting(currentGain: 1, target: 1)
        MicGate.shared.setTarget(muted: true)
        var buffer = Array(repeating: Float(1), count: 480 * channelStride)
        buffer.withUnsafeMutableBufferPointer { ptr in
            MicGate.shared.process(ptr.baseAddress!, frames: 480, stride: channelStride)
        }
        #expect(buffer[buffer.count - channelStride] == 0)
    }
}
