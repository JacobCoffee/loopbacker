import Testing
@testable import Loopbacker

@MainActor
@Suite("MeterLevels")
struct MeterLevelsTests {
    @Test("Output meters fall as well as rise")
    func outputsFollowLevel() {
        let meters = MeterLevels()
        meters.updateOutputs([1: 0.8, 2: 0.5])
        meters.updateOutputs([1: 0.2, 2: 0])
        #expect(abs(meters.output(channel: 1) - 0.2) < 1 / 256)
        #expect(meters.output(channel: 2) == 0)
    }

    @Test("A source's peak is its loudest channel and falls with it")
    func peak() {
        let meters = MeterLevels()
        meters.updateSource("mic", channels: [1: 0.3, 2: 0.7])
        #expect(abs(meters.peak(source: "mic") - 0.7) < 1 / 256)
        meters.updateSource("mic", channels: [1: 0.1, 2: 0.05])
        #expect(abs(meters.peak(source: "mic") - 0.1) < 1 / 256)
        #expect(abs(meters.level(source: "mic", channel: 2) - 0.05) < 1 / 256)
    }

    @Test("Stopped routes stop reporting levels")
    func retain() {
        let meters = MeterLevels()
        meters.updateSource("a", channels: [1: 0.5])
        meters.updateSource("b", channels: [1: 0.5])
        meters.retainSources(["a"])
        #expect(meters.peak(source: "b") == 0)
        #expect(meters.peak(source: "a") > 0)
    }
}
