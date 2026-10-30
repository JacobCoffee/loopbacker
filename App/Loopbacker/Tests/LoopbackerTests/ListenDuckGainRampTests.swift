import Foundation
import Testing
@testable import Loopbacker

/// `ListenDuckGainRamp` is the pure gain envelope `ListenDucker`'s IOProc applies to the ducked
/// apps' audio on its replay path -- tested directly against plain buffers (no CoreAudio, no
/// real tap), same approach as `AppAudioProcessorTests`.
@Suite("ListenDuckGainRamp (duck what I hear gain envelope)")
struct ListenDuckGainRampTests {
    private static let sampleRate: Float = 48_000

    @Test("Ramping toward a ducked target pulls output down, never overshooting past the target")
    func ducksTowardTarget() {
        var ramp = ListenDuckGainRamp()
        let targetGain: Float = 0.1 // -20 dB
        let frames = 4800 // 100 ms: long enough for a 10 ms time constant to fully settle
        var input = [Float](repeating: 0.5, count: frames)
        var output = [Float](repeating: 0, count: frames)
        input.withUnsafeMutableBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                ramp.copy(from: inPtr.baseAddress!, inChannels: 1, to: outPtr.baseAddress!, outChannels: 1,
                          frames: frames, targetLinearGain: targetGain, sampleRate: Self.sampleRate)
            }
        }
        let finalSample = output[frames - 1]
        #expect(abs(finalSample - 0.5 * targetGain) < 0.01)
        // Monotonic descent toward the target, never below it (no overshoot).
        for sample in output {
            let ratio = sample / 0.5
            #expect(ratio <= 1.001)
            #expect(ratio >= targetGain - 0.001)
        }
    }

    @Test("Releasing back to unity restores full volume")
    func releasesToUnity() {
        var ramp = ListenDuckGainRamp()
        var scratch = [Float](repeating: 0.5, count: 4800)
        // Duck down first.
        scratch.withUnsafeMutableBufferPointer { ptr in
            ramp.copy(from: ptr.baseAddress!, inChannels: 1, to: ptr.baseAddress!, outChannels: 1,
                      frames: 4800, targetLinearGain: 0.1, sampleRate: Self.sampleRate)
        }
        #expect(ramp.gain < 0.11)
        // Release.
        var output = [Float](repeating: 0.5, count: 4800)
        output.withUnsafeMutableBufferPointer { ptr in
            ramp.copy(from: ptr.baseAddress!, inChannels: 1, to: ptr.baseAddress!, outChannels: 1,
                      frames: 4800, targetLinearGain: 1, sampleRate: Self.sampleRate)
        }
        #expect(abs(ramp.gain - 1) < 0.01)
        #expect(abs(output[4799] - 0.5) < 0.01)
    }

    @Test("Multi-channel: gain applies uniformly across every channel of an interleaved frame")
    func multiChannelAppliesUniformly() {
        var ramp = ListenDuckGainRamp()
        let frames = 4800
        var input = [Float](repeating: 0, count: frames * 2)
        for i in stride(from: 0, to: input.count, by: 2) {
            input[i] = 0.4      // left
            input[i + 1] = 0.6  // right
        }
        var output = [Float](repeating: 0, count: frames * 2)
        input.withUnsafeMutableBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                ramp.copy(from: inPtr.baseAddress!, inChannels: 2, to: outPtr.baseAddress!, outChannels: 2,
                          frames: frames, targetLinearGain: 0.5, sampleRate: Self.sampleRate)
            }
        }
        let lastLeft = output[(frames - 1) * 2]
        let lastRight = output[(frames - 1) * 2 + 1]
        #expect(abs(lastLeft - 0.4 * 0.5) < 0.01)
        #expect(abs(lastRight - 0.6 * 0.5) < 0.01)
    }

    @Test("Stereo tap onto a 4-channel interface: L/R on outputs 1-2, silence on 3-4")
    func stereoOntoWiderOutput() {
        var ramp = ListenDuckGainRamp()
        let input: [Float] = [0.4, 0.6, 0.4, 0.6]
        var output = [Float](repeating: 9, count: 8)
        input.withUnsafeBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                ramp.copy(from: inPtr.baseAddress!, inChannels: 2, to: outPtr.baseAddress!, outChannels: 4,
                          frames: 2, targetLinearGain: 1, sampleRate: Self.sampleRate)
            }
        }
        #expect(output == [0.4, 0.6, 0, 0, 0.4, 0.6, 0, 0])
    }

    @Test("Stereo tap onto a mono output plays (L+R)/2")
    func stereoOntoMonoOutput() {
        var ramp = ListenDuckGainRamp()
        let input: [Float] = [0.4, 0.6, 0.2, 0.0]
        var output = [Float](repeating: 9, count: 2)
        input.withUnsafeBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                ramp.copy(from: inPtr.baseAddress!, inChannels: 2, to: outPtr.baseAddress!, outChannels: 1,
                          frames: 2, targetLinearGain: 1, sampleRate: Self.sampleRate)
            }
        }
        #expect(abs(output[0] - 0.5) < 1e-6)
        #expect(abs(output[1] - 0.1) < 1e-6)
    }

    @Test("Zero frames is a no-op")
    func zeroFramesNoOp() {
        var ramp = ListenDuckGainRamp()
        var buf = [Float](repeating: 0.5, count: 1)
        buf.withUnsafeMutableBufferPointer { ptr in
            ramp.copy(from: ptr.baseAddress!, inChannels: 1, to: ptr.baseAddress!, outChannels: 1,
                      frames: 0, targetLinearGain: 0.1, sampleRate: Self.sampleRate)
        }
        #expect(ramp.gain == 1)
    }
}
