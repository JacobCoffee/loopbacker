import Foundation
import Testing
@testable import Loopbacker

/// `CallVoiceHysteresis` is the pure attack/hold/release state machine `CallAudioMonitor`'s
/// IOProc feeds per callback -- tested directly (no CoreAudio, no real tap) since it's the only
/// part of far-end detection that isn't itself CoreAudio glue.
@Suite("CallVoiceHysteresis (far-end talking attack/hold/release)")
struct CallVoiceHysteresisTests {
    private static let sampleRate: Float = 48_000

    /// Feeds `probability` for `seconds` of audio in 10 ms blocks (matching the VAD's own hop
    /// size), returning the hysteresis state after each block so a test can inspect the timeline.
    private static func feed(_ hysteresis: inout CallVoiceHysteresis, probability: Float, seconds: Double) {
        let blockFrames = Int(sampleRate * 0.01) // 10 ms, matches VoiceActivityDetector's hop
        let blocks = Int(seconds * 100)
        for _ in 0..<blocks {
            hysteresis.update(rawProbability: probability, frames: blockFrames, sampleRate: sampleRate)
        }
    }

    @Test("Starts silent: not talking, level 0")
    func startsSilent() {
        let hysteresis = CallVoiceHysteresis()
        #expect(hysteresis.talking == false)
        #expect(hysteresis.level == 0)
    }

    @Test("Sustained high probability eventually flips talking true")
    func attackFlipsTrue() {
        var hysteresis = CallVoiceHysteresis()
        Self.feed(&hysteresis, probability: 1, seconds: 0.5)
        #expect(hysteresis.talking == true)
    }

    @Test("A single noisy high-probability block doesn't flip talking true (smoothing absorbs it)")
    func singleSpikeDoesNotFlutterOn() {
        var hysteresis = CallVoiceHysteresis()
        hysteresis.update(rawProbability: 1, frames: 480, sampleRate: Self.sampleRate)
        #expect(hysteresis.talking == false)
    }

    @Test("Once talking, a brief silent gap (shorter than the hold) doesn't flip talking false")
    func briefGapDoesNotFlutterOff() {
        var hysteresis = CallVoiceHysteresis()
        Self.feed(&hysteresis, probability: 1, seconds: 0.5)
        #expect(hysteresis.talking == true)
        // A pause well under the 500 ms hold -- a natural gap between words.
        Self.feed(&hysteresis, probability: 0, seconds: 0.2)
        #expect(hysteresis.talking == true)
    }

    @Test("Silence held past the hold duration flips talking false")
    func sustainedSilenceReleases() {
        var hysteresis = CallVoiceHysteresis()
        Self.feed(&hysteresis, probability: 1, seconds: 0.5)
        #expect(hysteresis.talking == true)
        // Comfortably longer than the 500 ms hold once the smoothed level has also decayed
        // below the off-threshold.
        Self.feed(&hysteresis, probability: 0, seconds: 2.0)
        #expect(hysteresis.talking == false)
    }

    @Test("Resuming speech during the hold window keeps talking true without re-attacking")
    func resumingDuringHoldStaysTalking() {
        var hysteresis = CallVoiceHysteresis()
        Self.feed(&hysteresis, probability: 1, seconds: 0.5)
        #expect(hysteresis.talking == true)
        Self.feed(&hysteresis, probability: 0, seconds: 0.1)
        Self.feed(&hysteresis, probability: 1, seconds: 0.1)
        #expect(hysteresis.talking == true)
        // The hold should have been refreshed, so another short gap still doesn't release.
        Self.feed(&hysteresis, probability: 0, seconds: 0.2)
        #expect(hysteresis.talking == true)
    }

    @Test("A zero-frame update is a no-op")
    func zeroFramesNoOp() {
        var hysteresis = CallVoiceHysteresis()
        hysteresis.update(rawProbability: 1, frames: 0, sampleRate: Self.sampleRate)
        #expect(hysteresis.talking == false)
        #expect(hysteresis.level == 0)
    }
}
