import Foundation

/// Pure matching and decision logic for `PresetAutoSwitchRule`s, decoupled from `NSWorkspace`
/// and `EffectsPresetLibrary` so priority, restore-on-quit, and fallback behavior are testable
/// without a live app environment.
enum PresetAutoSwitchEngine {
    /// A snapshot of the live signals rules match against.
    struct Signals: Equatable, Sendable {
        var runningBundleIDs: Set<String> = []
        var frontmostBundleID: String?
    }

    static func matches(_ rule: PresetAutoSwitchRule, signals: Signals) -> Bool {
        switch rule.matchOn {
        case .launched: signals.runningBundleIDs.contains(rule.appBundleID)
        case .frontmost: signals.frontmostBundleID == rule.appBundleID
        }
    }

    /// The rule that should be active right now: the first enabled rule, in list order (= the
    /// rules' persisted priority), whose trigger matches.
    static func resolve(rules: [PresetAutoSwitchRule], signals: Signals) -> PresetAutoSwitchRule? {
        rules.first { $0.isEnabled && matches($0, signals: signals) }
    }

    /// What `decide` tells the caller to do; `apply`/`restorePrevious` both mean "set this
    /// preset", kept distinct only so a caller can log/notify differently.
    enum Action: Equatable {
        case none
        case apply(presetID: String)
        case restorePrevious(presetID: String)
    }

    struct Decision: Equatable {
        let action: Action
        /// Carry these forward into the next `decide` call's `activeRuleID`/`presetBeforeActiveRule`.
        let activeRuleID: UUID?
        let presetBeforeActiveRule: String?
    }

    /// One pure evaluation step. `activeRuleID`/`presetBeforeActiveRule`/`lastAppliedPresetID`
    /// are the caller's bookkeeping from the previous call (or initial values); `decide` never
    /// touches global state itself.
    ///
    /// - `activeRuleID`: the rule the previous call applied, or nil.
    /// - `presetBeforeActiveRule`: what was active just before `activeRuleID` took over, so a
    ///   `restorePreviousOnQuit` rule can revert to it instead of falling through.
    /// - `lastAppliedPresetID`: whatever this engine itself last applied (rule or fallback), the
    ///   seed for `presetBeforeActiveRule` the first time a rule activates.
    static func decide(
        rules: [PresetAutoSwitchRule],
        signals: Signals,
        fallbackPresetID: String?,
        activeRuleID: UUID?,
        presetBeforeActiveRule: String?,
        lastAppliedPresetID: String?
    ) -> Decision {
        let matched = resolve(rules: rules, signals: signals)

        // The previously active rule no longer matches (its app quit, for `.launched`) and asked
        // to be restored rather than falling through.
        if matched == nil,
           let activeRuleID,
           let activeRule = rules.first(where: { $0.id == activeRuleID }),
           activeRule.restorePreviousOnQuit,
           let presetBeforeActiveRule {
            return Decision(action: .restorePrevious(presetID: presetBeforeActiveRule), activeRuleID: nil, presetBeforeActiveRule: nil)
        }

        if let matched {
            guard matched.id != activeRuleID else {
                // Same rule still in charge: no change.
                return Decision(action: .none, activeRuleID: activeRuleID, presetBeforeActiveRule: presetBeforeActiveRule)
            }
            // Only capture "what was active before" the first time a rule engages; a direct
            // rule-to-rule switch (A quits while B is already running) keeps the original
            // pre-automation preset as the thing to restore, not rule A's preset.
            let before = activeRuleID == nil ? lastAppliedPresetID : presetBeforeActiveRule
            return Decision(action: .apply(presetID: matched.presetID), activeRuleID: matched.id, presetBeforeActiveRule: before)
        }

        // No rule matches: fall back, but only actually apply when the fallback isn't already
        // what's showing (comparing against `lastAppliedPresetID`, not `activeRuleID`, since
        // "no rule" and "sitting on the fallback" are both `activeRuleID == nil`).
        if let fallbackPresetID {
            guard fallbackPresetID != lastAppliedPresetID || activeRuleID != nil else {
                return Decision(action: .none, activeRuleID: nil, presetBeforeActiveRule: nil)
            }
            return Decision(action: .apply(presetID: fallbackPresetID), activeRuleID: nil, presetBeforeActiveRule: nil)
        }
        return Decision(action: .none, activeRuleID: nil, presetBeforeActiveRule: nil)
    }
}
