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

    /// What `decide` tells the caller to do.
    enum Action: Equatable {
        case none
        case apply(presetID: String)
        /// Restore the live state snapshot the caller captured before the first rule engaged
        /// (see `Decision.shouldCaptureBeforeApplying`) — not a named preset, since the state
        /// before automation took over may be unsaved/customized and have no preset id at all.
        case restorePrevious
    }

    struct Decision: Equatable {
        let action: Action
        /// Carry forward into the next `decide` call's `activeRuleID`.
        let activeRuleID: UUID?
        /// Carry forward into the next `decide` call's `hasCapturedBefore`.
        let hasCapturedBefore: Bool
        /// True exactly when the caller must snapshot the actual live state (not a named
        /// preset id) right now, before applying `action` — the moment any rule first takes
        /// over from no rule being active.
        let shouldCaptureBeforeApplying: Bool
    }

    /// One pure evaluation step. `activeRuleID`/`hasCapturedBefore`/`lastAppliedPresetID` are
    /// the caller's bookkeeping from the previous call (or initial values); `decide` never
    /// touches global state itself, and never holds the live `EffectsPreset`/noise-suppression
    /// snapshot itself — that's the caller's job (`PresetAutoSwitcher`), triggered by
    /// `shouldCaptureBeforeApplying`.
    ///
    /// - `activeRuleID`: the rule the previous call applied, or nil.
    /// - `hasCapturedBefore`: whether the caller is holding a live-state snapshot captured
    ///   before the current/most recent automation episode started, so a `restorePreviousOnQuit`
    ///   rule can revert to it instead of falling through.
    /// - `lastAppliedPresetID`: whatever this engine itself last applied (rule or fallback),
    ///   used only to avoid redundantly reapplying the fallback.
    static func decide(
        rules: [PresetAutoSwitchRule],
        signals: Signals,
        fallbackPresetID: String?,
        activeRuleID: UUID?,
        hasCapturedBefore: Bool,
        lastAppliedPresetID: String?
    ) -> Decision {
        let matched = resolve(rules: rules, signals: signals)

        // The previously active rule no longer matches (its app quit, for `.launched`) and asked
        // to be restored rather than falling through.
        if matched == nil,
           let activeRuleID,
           let activeRule = rules.first(where: { $0.id == activeRuleID }),
           activeRule.restorePreviousOnQuit,
           hasCapturedBefore {
            return Decision(action: .restorePrevious, activeRuleID: nil, hasCapturedBefore: false, shouldCaptureBeforeApplying: false)
        }

        if let matched {
            guard matched.id != activeRuleID else {
                // Same rule still in charge: no change.
                return Decision(action: .none, activeRuleID: activeRuleID, hasCapturedBefore: hasCapturedBefore,
                                shouldCaptureBeforeApplying: false)
            }
            // Capture "what was active before" the first time any rule engages, unconditionally
            // (not only for rules with `restorePreviousOnQuit`, since a later rule-to-rule chain
            // might still need it); a direct rule-to-rule switch (A quits while B is already
            // running) keeps the original pre-automation snapshot, not A's.
            let isFirstEngagement = activeRuleID == nil
            return Decision(
                action: .apply(presetID: matched.presetID), activeRuleID: matched.id,
                hasCapturedBefore: isFirstEngagement ? true : hasCapturedBefore,
                shouldCaptureBeforeApplying: isFirstEngagement
            )
        }

        // No rule matches: fall back, but only actually apply when the fallback isn't already
        // what's showing (comparing against `lastAppliedPresetID`, not `activeRuleID`, since
        // "no rule" and "sitting on the fallback" are both `activeRuleID == nil`).
        if let fallbackPresetID {
            guard fallbackPresetID != lastAppliedPresetID || activeRuleID != nil else {
                return Decision(action: .none, activeRuleID: nil, hasCapturedBefore: false, shouldCaptureBeforeApplying: false)
            }
            return Decision(action: .apply(presetID: fallbackPresetID), activeRuleID: nil, hasCapturedBefore: false,
                            shouldCaptureBeforeApplying: false)
        }
        return Decision(action: .none, activeRuleID: nil, hasCapturedBefore: false, shouldCaptureBeforeApplying: false)
    }
}
