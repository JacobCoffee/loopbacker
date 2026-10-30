import Foundation
import Testing
@testable import Loopbacker

/// `WaveformTrimView.fadeInSeconds(forHandleSeconds:...)`/`fadeOutSeconds(forHandleSeconds:...)`
/// are the pure conversions the fade handles' drag gestures delegate to: a handle's x-mapped
/// seconds position (which can be dragged anywhere in `[0, duration]`) into a fade duration
/// clamped to the active trim window.
@Suite("WaveformTrimView fade handles")
struct WaveformTrimViewTests {
    @Test("Fade-in handle at trimStart is a zero-length fade")
    func fadeInAtTrimStartIsZero() {
        let seconds = WaveformTrimView.fadeInSeconds(forHandleSeconds: 2, trimStart: 2, trimEnd: 10)
        #expect(seconds == 0)
    }

    @Test("Fade-in handle partway into the trim window is the gap from trimStart")
    func fadeInPartwayIsGapFromTrimStart() {
        let seconds = WaveformTrimView.fadeInSeconds(forHandleSeconds: 3.5, trimStart: 2, trimEnd: 10)
        #expect(abs(seconds - 1.5) < 0.0001)
    }

    @Test("Fade-in handle dragged before trimStart clamps to zero")
    func fadeInClampsBeforeTrimStart() {
        let seconds = WaveformTrimView.fadeInSeconds(forHandleSeconds: -5, trimStart: 2, trimEnd: 10)
        #expect(seconds == 0)
    }

    @Test("Fade-in handle dragged past trimEnd clamps to the full trim window")
    func fadeInClampsPastTrimEnd() {
        let seconds = WaveformTrimView.fadeInSeconds(forHandleSeconds: 999, trimStart: 2, trimEnd: 10)
        #expect(seconds == 8)
    }

    @Test("Fade-out handle at trimEnd is a zero-length fade")
    func fadeOutAtTrimEndIsZero() {
        let seconds = WaveformTrimView.fadeOutSeconds(forHandleSeconds: 10, trimStart: 2, trimEnd: 10)
        #expect(seconds == 0)
    }

    @Test("Fade-out handle partway into the trim window is the gap to trimEnd")
    func fadeOutPartwayIsGapToTrimEnd() {
        let seconds = WaveformTrimView.fadeOutSeconds(forHandleSeconds: 7, trimStart: 2, trimEnd: 10)
        #expect(abs(seconds - 3) < 0.0001)
    }

    @Test("Fade-out handle dragged past trimEnd clamps to zero")
    func fadeOutClampsPastTrimEnd() {
        let seconds = WaveformTrimView.fadeOutSeconds(forHandleSeconds: 999, trimStart: 2, trimEnd: 10)
        #expect(seconds == 0)
    }

    @Test("Fade-out handle dragged before trimStart clamps to the full trim window")
    func fadeOutClampsBeforeTrimStart() {
        let seconds = WaveformTrimView.fadeOutSeconds(forHandleSeconds: -5, trimStart: 2, trimEnd: 10)
        #expect(seconds == 8)
    }
}
