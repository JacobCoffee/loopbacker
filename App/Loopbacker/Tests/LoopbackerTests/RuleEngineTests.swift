import Foundation
import Testing
@testable import Loopbacker

@Suite("RuleEngine")
struct RuleEngineTests {
    private func rule(_ name: String, _ trigger: RuleTrigger, scene: String, enabled: Bool = true) -> AutomationRule {
        AutomationRule(name: name, trigger: trigger, action: .loadScene(name: scene), isEnabled: enabled)
    }

    @Test("Matches app-launched, app-quit, app-frontmost, device-added, and device-removed triggers")
    func triggerMatching() {
        let signals = RuleEngine.Signals(
            runningBundleIDs: ["com.zoom.xos"], frontmostBundleID: "com.zoom.xos",
            connectedDeviceUIDs: ["motu-uid"]
        )

        #expect(RuleEngine.matches(.appLaunched(bundleID: "com.zoom.xos", appName: "Zoom"), signals: signals))
        #expect(!RuleEngine.matches(.appLaunched(bundleID: "com.obsproject.obs", appName: "OBS"), signals: signals))
        #expect(RuleEngine.matches(.appQuit(bundleID: "com.obsproject.obs", appName: "OBS"), signals: signals))
        #expect(!RuleEngine.matches(.appQuit(bundleID: "com.zoom.xos", appName: "Zoom"), signals: signals))
        #expect(RuleEngine.matches(.appFrontmost(bundleID: "com.zoom.xos", appName: "Zoom"), signals: signals))
        #expect(!RuleEngine.matches(.appFrontmost(bundleID: "com.obsproject.obs", appName: "OBS"), signals: signals))
        #expect(RuleEngine.matches(.deviceAdded(uid: "motu-uid", name: "MOTU M2"), signals: signals))
        #expect(!RuleEngine.matches(.deviceAdded(uid: "missing-uid", name: "Missing"), signals: signals))
        #expect(RuleEngine.matches(.deviceRemoved(uid: "missing-uid", name: "Missing"), signals: signals))
        #expect(!RuleEngine.matches(.deviceRemoved(uid: "motu-uid", name: "MOTU M2"), signals: signals))
    }

    @Test("The first enabled matching rule in list order wins")
    func precedence() {
        let signals = RuleEngine.Signals(runningBundleIDs: ["com.zoom.xos"])
        let rules = [
            rule("Zoom general", .appLaunched(bundleID: "com.zoom.xos", appName: "Zoom"), scene: "Call"),
            rule("Zoom specific", .appLaunched(bundleID: "com.zoom.xos", appName: "Zoom"), scene: "Call Loud")
        ]

        let resolved = RuleEngine.resolve(rules: rules, signals: signals)

        #expect(resolved?.action.sceneName == "Call")
    }

    @Test("A disabled rule is skipped even if it would otherwise match first")
    func disabledRuleSkipped() {
        let signals = RuleEngine.Signals(runningBundleIDs: ["com.zoom.xos"])
        let rules = [
            rule("Disabled", .appLaunched(bundleID: "com.zoom.xos", appName: "Zoom"), scene: "Nope", enabled: false),
            rule("Enabled", .appLaunched(bundleID: "com.zoom.xos", appName: "Zoom"), scene: "Call")
        ]

        let resolved = RuleEngine.resolve(rules: rules, signals: signals)

        #expect(resolved?.action.sceneName == "Call")
    }

    @Test("No matching rule resolves to nil, so the caller falls back")
    func fallback() {
        let signals = RuleEngine.Signals()
        let rules = [rule("Zoom", .appLaunched(bundleID: "com.zoom.xos", appName: "Zoom"), scene: "Call")]

        let resolved = RuleEngine.resolve(rules: rules, signals: signals)

        #expect(resolved == nil)
    }

    @Test("Resume only fires once the signals differ from the ones frozen at pause time")
    func manualOverrideResume() {
        let paused = RuleEngine.Signals(runningBundleIDs: ["com.zoom.xos"])

        #expect(!RuleEngine.shouldResume(pausedSignals: paused, currentSignals: paused))

        let changed = RuleEngine.Signals(runningBundleIDs: [])
        #expect(RuleEngine.shouldResume(pausedSignals: paused, currentSignals: changed))

        let frontmostChanged = RuleEngine.Signals(runningBundleIDs: ["com.zoom.xos"], frontmostBundleID: "com.zoom.xos")
        #expect(RuleEngine.shouldResume(pausedSignals: paused, currentSignals: frontmostChanged))
    }
}

@Suite("Debouncer")
@MainActor
struct DebouncerTests {
    /// A scheduler that just records the work closures instead of running them, so the test
    /// can "fire" a specific generation deterministically without a real timer.
    private final class FakeScheduler {
        var scheduled: [() -> Void] = []
        func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
            scheduled.append(work)
        }
    }

    @Test("Only the last scheduled call fires; earlier ones are superseded")
    func supersedesEarlierCalls() {
        let scheduler = FakeScheduler()
        let debouncer = Debouncer(delay: 1.0) { delay, work in scheduler.schedule(delay, work) }
        var fired: [Int] = []

        debouncer.call { fired.append(1) }
        debouncer.call { fired.append(2) }
        debouncer.call { fired.append(3) }

        #expect(scheduler.scheduled.count == 3)
        // Simulate every one of the three delayed callbacks actually firing (as real timers
        // would once their window elapses) -- only the last one should run its action.
        for work in scheduler.scheduled { work() }

        #expect(fired == [3])
    }

    @Test("A call after the previous one already fired still runs")
    func separateBurstsBothFire() {
        let scheduler = FakeScheduler()
        let debouncer = Debouncer(delay: 1.0) { delay, work in scheduler.schedule(delay, work) }
        var fired: [Int] = []

        debouncer.call { fired.append(1) }
        scheduler.scheduled.first?()
        scheduler.scheduled.removeAll()

        debouncer.call { fired.append(2) }
        scheduler.scheduled.first?()

        #expect(fired == [1, 2])
    }
}
