import AppKit
import Combine
import os.log

private let switcherLogger = Logger(subsystem: "com.jacobcoffee.loopbacker", category: "PresetAutoSwitch")

/// Watches running/frontmost apps via `NSWorkspace` and applies `PresetAutoSwitchEngine`'s
/// decision through `EffectsPresetLibrary`. Owned by the app for its lifetime (like
/// `RoutingSync`) so rules apply whether or not the main window is open.
@MainActor
final class PresetAutoSwitcher: ObservableObject {
    let rulesState: PresetAutoSwitchState
    private let routingState: RoutingState

    /// The rule currently in effect, or nil when the fallback (or nothing) applies. Published
    /// for the Automation settings tab to show "Active rule: …".
    @Published private(set) var activeRule: PresetAutoSwitchRule?
    @Published private(set) var lastAppliedPresetID: String?

    private var presetBeforeActiveRule: String?
    private var runningBundleIDs: Set<String> = []
    private var frontmostBundleID: String?

    private let debouncer: Debouncer
    private var workspaceObservers: [NSObjectProtocol] = []

    init(rulesState: PresetAutoSwitchState, routingState: RoutingState, debounce: TimeInterval = 1.0) {
        self.rulesState = rulesState
        self.routingState = routingState
        self.debouncer = Debouncer(delay: debounce)
        refreshSignals()
        observe()
    }

    private func observe() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
        ] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshSignals()
                    self?.scheduleEvaluate()
                }
            })
        }
    }

    private func refreshSignals() {
        runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private func scheduleEvaluate() {
        debouncer.call { [weak self] in self?.evaluate() }
    }

    var currentSignals: PresetAutoSwitchEngine.Signals {
        PresetAutoSwitchEngine.Signals(runningBundleIDs: runningBundleIDs, frontmostBundleID: frontmostBundleID)
    }

    /// Re-evaluates rules against the current signals and applies whatever should be active.
    /// Public so tests and a manual "Re-evaluate" action can force an immediate pass. Skipped
    /// entirely while `rulesState.isSuppressedByEditing` (the Effects page is open/editing).
    func evaluate() {
        guard !rulesState.isSuppressedByEditing else { return }

        let decision = PresetAutoSwitchEngine.decide(
            rules: rulesState.rules,
            signals: currentSignals,
            fallbackPresetID: rulesState.fallbackPresetID,
            activeRuleID: activeRule?.id,
            presetBeforeActiveRule: presetBeforeActiveRule,
            lastAppliedPresetID: lastAppliedPresetID
        )

        activeRule = decision.activeRuleID.flatMap { id in rulesState.rules.first { $0.id == id } }
        presetBeforeActiveRule = decision.presetBeforeActiveRule

        let presetID: String
        switch decision.action {
        case .none:
            return
        case .apply(let id), .restorePrevious(let id):
            presetID = id
        }

        guard EffectsPresetLibrary.apply(id: presetID, to: routingState) else {
            switcherLogger.warning("Preset auto-switch referenced missing preset '\(presetID, privacy: .public)'")
            return
        }
        lastAppliedPresetID = presetID
    }

    isolated deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { center.removeObserver(observer) }
    }
}
