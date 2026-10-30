import Testing
@testable import Loopbacker

@Suite("PresetAutoSwitchEngine")
struct PresetAutoSwitchEngineTests {
    private func rule(
        bundleID: String = "com.example.app", name: String = "Example", presetID: String = "factory:P",
        matchOn: PresetAutoSwitchMatch = .launched, isEnabled: Bool = true, restorePreviousOnQuit: Bool = false
    ) -> PresetAutoSwitchRule {
        PresetAutoSwitchRule(
            appBundleID: bundleID, appName: name, presetID: presetID, presetName: presetID,
            matchOn: matchOn, isEnabled: isEnabled, restorePreviousOnQuit: restorePreviousOnQuit
        )
    }

    // MARK: - matches / resolve

    @Test("launched matches on the running set, not frontmost")
    func matchesLaunched() {
        let r = rule(bundleID: "com.a", matchOn: .launched)
        #expect(PresetAutoSwitchEngine.matches(r, signals: .init(runningBundleIDs: ["com.a"], frontmostBundleID: "com.b")))
        #expect(!PresetAutoSwitchEngine.matches(r, signals: .init(runningBundleIDs: [], frontmostBundleID: "com.a")))
    }

    @Test("frontmost matches only the active app")
    func matchesFrontmost() {
        let r = rule(bundleID: "com.a", matchOn: .frontmost)
        #expect(PresetAutoSwitchEngine.matches(r, signals: .init(runningBundleIDs: ["com.a"], frontmostBundleID: "com.a")))
        #expect(!PresetAutoSwitchEngine.matches(r, signals: .init(runningBundleIDs: ["com.a"], frontmostBundleID: "com.b")))
    }

    @Test("resolve picks the first enabled matching rule in list order (priority)")
    func resolvePriority() {
        let low = rule(bundleID: "com.a", presetID: "low")
        let high = rule(bundleID: "com.a", presetID: "high")
        let signals = PresetAutoSwitchEngine.Signals(runningBundleIDs: ["com.a"])
        #expect(PresetAutoSwitchEngine.resolve(rules: [high, low], signals: signals)?.presetID == "high")
        #expect(PresetAutoSwitchEngine.resolve(rules: [low, high], signals: signals)?.presetID == "low")
    }

    @Test("resolve skips disabled rules")
    func resolveSkipsDisabled() {
        let disabled = rule(bundleID: "com.a", presetID: "disabled", isEnabled: false)
        let enabled = rule(bundleID: "com.a", presetID: "enabled")
        let signals = PresetAutoSwitchEngine.Signals(runningBundleIDs: ["com.a"])
        #expect(PresetAutoSwitchEngine.resolve(rules: [disabled, enabled], signals: signals)?.presetID == "enabled")
    }

    // MARK: - decide

    @Test("No rule matches and no fallback: no action")
    func decideNothingMatches() {
        let decision = PresetAutoSwitchEngine.decide(
            rules: [rule(bundleID: "com.a")], signals: .init(), fallbackPresetID: nil,
            activeRuleID: nil, presetBeforeActiveRule: nil, lastAppliedPresetID: nil
        )
        #expect(decision.action == .none)
        #expect(decision.activeRuleID == nil)
    }

    @Test("No rule matches, fallback set: applies fallback")
    func decideFallback() {
        let decision = PresetAutoSwitchEngine.decide(
            rules: [rule(bundleID: "com.a")], signals: .init(), fallbackPresetID: "fallback",
            activeRuleID: nil, presetBeforeActiveRule: nil, lastAppliedPresetID: nil
        )
        #expect(decision.action == .apply(presetID: "fallback"))
        #expect(decision.activeRuleID == nil)
    }

    @Test("A rule starts matching: applies its preset and remembers what was active before")
    func decideRuleActivates() {
        let r = rule(bundleID: "com.a", presetID: "p1")
        let decision = PresetAutoSwitchEngine.decide(
            rules: [r], signals: .init(runningBundleIDs: ["com.a"]), fallbackPresetID: nil,
            activeRuleID: nil, presetBeforeActiveRule: nil, lastAppliedPresetID: "manual-preset"
        )
        #expect(decision.action == .apply(presetID: "p1"))
        #expect(decision.activeRuleID == r.id)
        #expect(decision.presetBeforeActiveRule == "manual-preset")
    }

    @Test("Same rule still matching: no change, no repeated apply")
    func decideNoChange() {
        let r = rule(bundleID: "com.a", presetID: "p1")
        let decision = PresetAutoSwitchEngine.decide(
            rules: [r], signals: .init(runningBundleIDs: ["com.a"]), fallbackPresetID: nil,
            activeRuleID: r.id, presetBeforeActiveRule: "manual-preset", lastAppliedPresetID: "p1"
        )
        #expect(decision.action == .none)
        #expect(decision.activeRuleID == r.id)
        #expect(decision.presetBeforeActiveRule == "manual-preset")
    }

    @Test("App quits, rule has restorePreviousOnQuit: restores the preset active before the rule")
    func decideRestorePreviousOnQuit() {
        let r = rule(bundleID: "com.a", presetID: "p1", restorePreviousOnQuit: true)
        let decision = PresetAutoSwitchEngine.decide(
            rules: [r], signals: .init(runningBundleIDs: []), fallbackPresetID: "fallback",
            activeRuleID: r.id, presetBeforeActiveRule: "manual-preset", lastAppliedPresetID: "p1"
        )
        #expect(decision.action == .restorePrevious(presetID: "manual-preset"))
        #expect(decision.activeRuleID == nil)
        #expect(decision.presetBeforeActiveRule == nil)
    }

    @Test("App quits, rule has restorePreviousOnQuit but nothing was captured: falls through to fallback")
    func decideRestoreWithNoCaptureFallsBack() {
        let r = rule(bundleID: "com.a", presetID: "p1", restorePreviousOnQuit: true)
        let decision = PresetAutoSwitchEngine.decide(
            rules: [r], signals: .init(runningBundleIDs: []), fallbackPresetID: "fallback",
            activeRuleID: r.id, presetBeforeActiveRule: nil, lastAppliedPresetID: "p1"
        )
        #expect(decision.action == .apply(presetID: "fallback"))
    }

    @Test("App quits, rule does NOT have restorePreviousOnQuit: falls through to fallback, not restore")
    func decideWithoutRestoreFlagFallsBack() {
        let r = rule(bundleID: "com.a", presetID: "p1", restorePreviousOnQuit: false)
        let decision = PresetAutoSwitchEngine.decide(
            rules: [r], signals: .init(runningBundleIDs: []), fallbackPresetID: "fallback",
            activeRuleID: r.id, presetBeforeActiveRule: "manual-preset", lastAppliedPresetID: "p1"
        )
        #expect(decision.action == .apply(presetID: "fallback"))
        #expect(decision.activeRuleID == nil)
    }

    @Test("Switching directly from rule A to rule B keeps the original pre-automation preset, not A's")
    func decideRuleToRuleKeepsOriginalPrevious() {
        let a = rule(bundleID: "com.a", presetID: "pa")
        let b = rule(bundleID: "com.b", presetID: "pb")
        // a is active, b now also matches and sits earlier in priority (so it wins).
        let decision = PresetAutoSwitchEngine.decide(
            rules: [b, a], signals: .init(runningBundleIDs: ["com.a", "com.b"]), fallbackPresetID: nil,
            activeRuleID: a.id, presetBeforeActiveRule: "manual-preset", lastAppliedPresetID: "pa"
        )
        #expect(decision.action == .apply(presetID: "pb"))
        #expect(decision.activeRuleID == b.id)
        #expect(decision.presetBeforeActiveRule == "manual-preset")
    }
}
