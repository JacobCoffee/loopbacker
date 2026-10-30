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

    @Test("Resume only fires once the resolved rule changes, not on any unrelated signal change")
    func manualOverrideResume() {
        let rules = [rule("Zoom", .appLaunched(bundleID: "com.zoom.xos", appName: "Zoom"), scene: "Call")]
        let paused = RuleEngine.Signals(runningBundleIDs: ["com.zoom.xos"])
        let pausedRuleID = RuleEngine.resolve(rules: rules, signals: paused)?.id

        // Identical signals: never resume.
        #expect(!RuleEngine.shouldResume(pausedRuleID: pausedRuleID, currentSignals: paused, rules: rules))

        // Cmd-tabbing back to an app that was already running (frontmost changes, but the
        // resolved rule doesn't) must not override the user's manual pick.
        let frontmostChanged = RuleEngine.Signals(runningBundleIDs: ["com.zoom.xos"], frontmostBundleID: "com.zoom.xos")
        #expect(!RuleEngine.shouldResume(pausedRuleID: pausedRuleID, currentSignals: frontmostChanged, rules: rules))

        // An unrelated device connecting (no rule references it) must not resume either.
        let unrelatedDevice = RuleEngine.Signals(runningBundleIDs: ["com.zoom.xos"], connectedDeviceUIDs: ["unrelated-uid"])
        #expect(!RuleEngine.shouldResume(pausedRuleID: pausedRuleID, currentSignals: unrelatedDevice, rules: rules))

        // Zoom quitting changes which rule resolves (Zoom rule -> nil): must resume.
        let zoomQuit = RuleEngine.Signals(runningBundleIDs: [])
        #expect(RuleEngine.shouldResume(pausedRuleID: pausedRuleID, currentSignals: zoomQuit, rules: rules))
    }

    @Test("Disabling or deleting the triggering rule while paused still resumes once its condition goes away")
    func resumeAfterTriggeringRuleEditedWhilePaused() {
        var zoomRule = rule("Zoom", .appLaunched(bundleID: "com.zoom.xos", appName: "Zoom"), scene: "Call")
        var rules = [zoomRule]
        let paused = RuleEngine.Signals(runningBundleIDs: ["com.zoom.xos"])
        // Captured once at pause time, as the real caller does -- not recomputed later against
        // a rule list that may have since changed.
        let pausedRuleID = RuleEngine.resolve(rules: rules, signals: paused)?.id
        #expect(pausedRuleID == zoomRule.id)

        // Disable the triggering rule while paused: both `resolve(pausedSignals)` and
        // `resolve(currentSignals)` against the live (mutated) rule list would now return nil,
        // so a naive re-resolve-both-sides comparison would never resume. The captured id must
        // still differ from the new (nil) resolution once Zoom quits.
        zoomRule.isEnabled = false
        rules = [zoomRule]
        let stillRunning = RuleEngine.Signals(runningBundleIDs: ["com.zoom.xos"])
        #expect(RuleEngine.shouldResume(pausedRuleID: pausedRuleID, currentSignals: stillRunning, rules: rules))

        // Deleting the rule entirely while paused: current resolution is nil against an empty
        // list too, and must still differ from the captured id.
        rules = []
        #expect(RuleEngine.shouldResume(pausedRuleID: pausedRuleID, currentSignals: stillRunning, rules: rules))
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
