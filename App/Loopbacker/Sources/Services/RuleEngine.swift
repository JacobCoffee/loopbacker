import Foundation

/// Pure matching logic for automation rules, decoupled from the live app/device observers so
/// precedence, fallback, and manual-override behavior can be unit tested without CoreAudio or
/// NSWorkspace.
enum RuleEngine {
    /// A snapshot of the live signals rules match against.
    struct Signals: Codable, Equatable {
        var runningBundleIDs: Set<String> = []
        var frontmostBundleID: String?
        var connectedDeviceUIDs: Set<String> = []
    }

    static func matches(_ trigger: RuleTrigger, signals: Signals) -> Bool {
        switch trigger {
        case .appLaunched(let bundleID, _): signals.runningBundleIDs.contains(bundleID)
        case .appQuit(let bundleID, _): !signals.runningBundleIDs.contains(bundleID)
        case .appFrontmost(let bundleID, _): signals.frontmostBundleID == bundleID
        case .deviceAdded(let uid, _): signals.connectedDeviceUIDs.contains(uid)
        case .deviceRemoved(let uid, _): !signals.connectedDeviceUIDs.contains(uid)
        }
    }

    /// The rule that should be active right now: the first enabled rule (in list order) whose
    /// trigger matches. `nil` when no rule matches (the caller should apply `fallback`).
    static func resolve(rules: [AutomationRule], signals: Signals) -> AutomationRule? {
        rules.first { $0.isEnabled && matches($0.trigger, signals: signals) }
    }

    /// Whether a rules engine paused for manual scene selection should resume: true once the
    /// rule that resolves now differs from `pausedRuleID` (the rule, if any, that was active at
    /// pause time, captured once by the caller rather than re-resolved here). Comparing against
    /// a captured id -- not re-running `resolve` against the paused signals and the CURRENT rule
    /// list -- means editing, disabling, or deleting the triggering rule while paused still
    /// resumes correctly once its condition goes away, instead of both sides resolving to nil
    /// and getting stuck paused forever (persisted across relaunch).
    static func shouldResume(pausedRuleID: UUID?, currentSignals: Signals, rules: [AutomationRule]) -> Bool {
        resolve(rules: rules, signals: currentSignals)?.id != pausedRuleID
    }
}

/// Debounces rapid repeated calls (e.g. a flapping USB device) so the wrapped action only runs
/// once, `delay` after the last call that didn't get superseded. The scheduler is injectable so
/// tests can drive it without real timers.
@MainActor
final class Debouncer {
    private let delay: TimeInterval
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private var generation = 0

    init(delay: TimeInterval, schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }) {
        self.delay = delay
        self.schedule = schedule
    }

    /// Schedules `action`, canceling any call still pending from a previous `call(_:)`.
    func call(_ action: @escaping @MainActor () -> Void) {
        generation += 1
        let myGeneration = generation
        schedule(delay) { [weak self] in
            guard let self, self.generation == myGeneration else { return }
            action()
        }
    }
}
