import Foundation
import Testing
@testable import Loopbacker

/// `AppAudioProcessor` is the only processing app-capture routes run (see
/// `RouteContext.processCapturedBlock`: `isVoiceInput` routes run the voice `FXChain`,
/// everything else -- app captures -- runs `AppAudioProcessor` instead). It has no `FXChain`,
/// no gate/EQ/compressor/de-esser/etc: these tests verify its only behaviour is ducking (driven
/// by `VoiceBus`) and optional leveling, proving app-capture audio never passes through the
/// voice chain's stages.
@Suite("AppAudioProcessor (app-capture, no voice processing)", .serialized)
struct AppAudioProcessorTests {
    private static let sampleRate: Float = 48_000

    @Test("Everything disabled: the buffer is left completely untouched")
    func disabledIsPassthrough() {
        let processor = AppAudioProcessor(sampleRate: Self.sampleRate)
        processor.updateConfig(.init()) // defaults: ducking off, leveler off
        let frames = 256
        var buffer = (0..<(frames * 2)).map { Float($0).truncatingRemainder(dividingBy: 17) / 17 - 0.5 }
        let original = buffer

        buffer.withUnsafeMutableBufferPointer { ptr in
            processor.process(ptr.baseAddress!, frames: frames, stride: 2)
        }

        #expect(buffer == original)
    }

    @Test("Ducking pulls gain toward duckAmountDB while VoiceBus reports speech, nothing else changes")
    func duckingFollowsVoiceBus() {
        let processor = AppAudioProcessor(sampleRate: Self.sampleRate)
        processor.updateConfig(.init(duckingEnabled: true, duckAmountDB: -12, duckAttackMs: 1, duckReleaseMs: 600,
                                     levelerEnabled: false))

        VoiceBus.update(1) // simulate the voice chain reporting full speech confidence
        defer { VoiceBus.update(0) } // don't leak state into other tests

        let frames = 4800 // 100 ms: long enough for a 1 ms attack to fully settle
        var buffer = [Float](repeating: 0.5, count: frames * 2)
        buffer.withUnsafeMutableBufferPointer { ptr in
            processor.process(ptr.baseAddress!, frames: frames, stride: 2)
        }

        let expectedGain = fxDBToLinear(-12)
        let finalLeft = buffer[(frames - 1) * 2]
        #expect(abs(finalLeft - 0.5 * expectedGain) < 0.01)

        // Ducking only ever scales amplitude -- the ratio between every sample and the original
        // constant input is uniform (no filtering, pitch-shifting, gating, or other voice-chain
        // artifact), confirming the only transformation is a gain envelope.
        var ratios = Set<Int>()
        for i in stride(from: 0, to: buffer.count, by: 2) {
            ratios.insert(Int((buffer[i] / 0.5 * 10_000).rounded()))
        }
        // The envelope is monotonic during attack, so distinct ratios appear while it moves,
        // but every one of them must lie between the duck gain and 1 (no overshoot, no
        // unrelated processing).
        for r in ratios {
            let ratio = Float(r) / 10_000
            #expect(ratio <= 1.001)
            #expect(ratio >= expectedGain - 0.001)
        }
    }

    @Test("Ducking releases back to unity once VoiceBus goes quiet")
    func duckingReleases() {
        let processor = AppAudioProcessor(sampleRate: Self.sampleRate)
        processor.updateConfig(.init(duckingEnabled: true, duckAmountDB: -12, duckAttackMs: 1, duckReleaseMs: 1,
                                     levelerEnabled: false))

        VoiceBus.update(1)
        var buffer = [Float](repeating: 0.5, count: 4800 * 2)
        buffer.withUnsafeMutableBufferPointer { ptr in
            processor.process(ptr.baseAddress!, frames: 4800, stride: 2)
        }
        #expect(abs(buffer[(4800 - 1) * 2] - 0.5 * fxDBToLinear(-12)) < 0.01)

        // VoiceBus is a process-wide singleton. Other suites run real `FXChain`s whose VAD
        // keeps calling `VoiceBus.update` for as long as they're processing, so a single
        // quiet-then-release attempt can be re-pinned mid-flight
        // by a concurrently-running suite. Retry the whole settle-and-verify step until it
        // succeeds (bounded, so a genuine regression still fails the test).
        var finalGain: Float = -1
        for _ in 0..<50 {
            var attempts = 0
            while VoiceBus.probability() > 0.1, attempts < 2000 {
                VoiceBus.update(0)
                attempts += 1
            }
            var buffer2 = [Float](repeating: 0.5, count: 4800 * 2)
            buffer2.withUnsafeMutableBufferPointer { ptr in
                processor.process(ptr.baseAddress!, frames: 4800, stride: 2)
            }
            finalGain = buffer2[(4800 - 1) * 2]
            if abs(finalGain - 0.5) < 0.01 { break }
        }
        #expect(abs(finalGain - 0.5) < 0.01)
    }
}
