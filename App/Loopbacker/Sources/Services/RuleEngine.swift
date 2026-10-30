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
    /// live signals differ from the ones captured at pause time.
    static func shouldResume(pausedSignals: Signals, currentSignals: Signals) -> Bool {
        pausedSignals != currentSignals
    }
}

/// Debounces rapid repeated calls (e.g. a flapping USB device) so the wrapped action only runs
/// once, `delay` after the last call that didn't get superseded. The scheduler is injectable so
/// tests can drive it without real timers.
@MainActor
final class Debouncer {
    private let delay: TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var generation = 0

    init(delay: TimeInterval, schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }) {
        self.delay = delay
        self.schedule = schedule
    }

    /// Schedules `action`, canceling any call still pending from a previous `call(_:)`.
    func call(_ action: @escaping () -> Void) {
        generation += 1
        let myGeneration = generation
        schedule(delay) { [weak self] in
            guard let self, self.generation == myGeneration else { return }
            action()
        }
    }
}
