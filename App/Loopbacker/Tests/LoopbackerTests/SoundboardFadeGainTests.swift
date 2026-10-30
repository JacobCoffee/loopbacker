import Testing
@testable import Loopbacker

@Suite("soundboardFadeGain")
struct SoundboardFadeGainTests {
    @Test("No fade configured is always full gain")
    func noFadeIsUnity() {
        #expect(soundboardFadeGain(position: 0, activeFrames: 100, fadeInFrames: 0, fadeOutFrames: 0) == 1.0)
        #expect(soundboardFadeGain(position: 99, activeFrames: 100, fadeInFrames: 0, fadeOutFrames: 0) == 1.0)
    }

    @Test("Fade-in ramps linearly from 0 at the start to 1 at the end of the ramp")
    func fadeInRamp() {
        #expect(soundboardFadeGain(position: 0, activeFrames: 1000, fadeInFrames: 100, fadeOutFrames: 0) == 0.0)
        #expect(soundboardFadeGain(position: 50, activeFrames: 1000, fadeInFrames: 100, fadeOutFrames: 0) == 0.5)
        #expect(soundboardFadeGain(position: 100, activeFrames: 1000, fadeInFrames: 100, fadeOutFrames: 0) == 1.0)
        // Past the ramp: full gain.
        #expect(soundboardFadeGain(position: 500, activeFrames: 1000, fadeInFrames: 100, fadeOutFrames: 0) == 1.0)
    }

    @Test("Fade-out ramps linearly from 1 down to 0 approaching the end")
    func fadeOutRamp() {
        // 1000 active frames, 100-frame fade-out: ramp starts at position 900.
        #expect(soundboardFadeGain(position: 899, activeFrames: 1000, fadeInFrames: 0, fadeOutFrames: 100) == 1.0)
        #expect(soundboardFadeGain(position: 900, activeFrames: 1000, fadeInFrames: 0, fadeOutFrames: 100) == 1.0)
        #expect(soundboardFadeGain(position: 950, activeFrames: 1000, fadeInFrames: 0, fadeOutFrames: 100) == 0.5)
        // Last sample: remaining = 1, gain = 1/100.
        #expect(abs(soundboardFadeGain(position: 999, activeFrames: 1000, fadeInFrames: 0, fadeOutFrames: 100) - 0.01) < 0.001)
    }

    @Test("Overlapping fade-in and fade-out on a short clip multiplies both ramps")
    func overlappingFadesMultiply() {
        // 40 active frames, 20-frame fade in and out: they overlap across the whole clip.
        // At the midpoint (position 20): fade-in is complete (== 20 frames in), fade-out hasn't
        // started yet (remaining = 20, not <= fadeOutFrames... wait remaining==20==fadeOutFrames,
        // so fade-out factor is 20/20 = 1). Both factors are 1 at the midpoint.
        let mid = soundboardFadeGain(position: 20, activeFrames: 40, fadeInFrames: 20, fadeOutFrames: 20)
        #expect(abs(mid - 1.0) < 0.001)

        // Near the very start, fade-in dominates (small gain); near the very end, fade-out
        // dominates (also a small gain).
        let start = soundboardFadeGain(position: 2, activeFrames: 40, fadeInFrames: 20, fadeOutFrames: 20)
        let end = soundboardFadeGain(position: 37, activeFrames: 40, fadeInFrames: 20, fadeOutFrames: 20)
        #expect(start < 0.2)
        #expect(end < 0.2)
    }

    @Test("Gain never exceeds 1 or goes negative across the whole active range")
    func gainStaysInUnitRange() {
        let activeFrames: UInt32 = 200
        for position: UInt32 in stride(from: 0, to: activeFrames, by: 7) {
            let gain = soundboardFadeGain(position: position, activeFrames: activeFrames, fadeInFrames: 30, fadeOutFrames: 30)
            #expect(gain >= 0 && gain <= 1)
        }
    }
}
