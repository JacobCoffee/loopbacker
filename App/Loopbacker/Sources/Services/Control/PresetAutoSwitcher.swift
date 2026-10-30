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

    /// Whether `snapshotBeforeActiveRule` currently holds a valid capture, mirroring
    /// `PresetAutoSwitchEngine.Decision.hasCapturedBefore`.
    private var hasCapturedBefore = false
    /// The actual live `routingState` state (not a named preset id, which may not exist for an
    /// unsaved/customized configuration) captured the moment the first automation rule engaged,
    /// so a `restorePreviousOnQuit` rule — or quitting automation entirely — can put it back.
    private var snapshotBeforeActiveRule: (preset: EffectsPreset, noiseSuppression: NoiseSuppressionSettings)?
    private var runningBundleIDs: Set<String> = []
    private var frontmostBundleID: String?

    private let debouncer: Debouncer
    private var workspaceObservers: [NSObjectProtocol] = []
    private var suppressionCancellable: AnyCancellable?

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

        // `evaluate()` skips entirely while suppressed (the Effects page is open/editing), so a
        // matching app launching/quitting mid-edit is otherwise silently dropped: `evaluate()`
        // returns before touching any bookkeeping, and nothing re-runs it once editing ends.
        // Re-evaluate with the latest cached signals as soon as suppression clears.
        suppressionCancellable = rulesState.$isSuppressedByEditing
            .removeDuplicates()
            .sink { [weak self] isSuppressed in
                guard !isSuppressed else { return }
                self?.scheduleEvaluate()
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
    /// entirely while `rulesState.isSuppressedByEditing` (the Effects page is open/editing);
    /// `observe()` reschedules a pass as soon as that clears.
    func evaluate() {
        guard !rulesState.isSuppressedByEditing else { return }

        let decision = PresetAutoSwitchEngine.decide(
            rules: rulesState.rules,
            signals: currentSignals,
            fallbackPresetID: rulesState.fallbackPresetID,
            activeRuleID: activeRule?.id,
            hasCapturedBefore: hasCapturedBefore,
            lastAppliedPresetID: lastAppliedPresetID
        )

        if decision.shouldCaptureBeforeApplying {
            snapshotBeforeActiveRule = (routingState.effectsPreset, routingState.noiseSuppression)
        }
        hasCapturedBefore = decision.hasCapturedBefore
        activeRule = decision.activeRuleID.flatMap { id in rulesState.rules.first { $0.id == id } }

        switch decision.action {
        case .none:
            return
        case .apply(let presetID):
            guard EffectsPresetLibrary.apply(id: presetID, to: routingState) else {
                switcherLogger.warning("Preset auto-switch referenced missing preset '\(presetID, privacy: .public)'")
                return
            }
            lastAppliedPresetID = presetID
        case .restorePrevious:
            guard let snapshot = snapshotBeforeActiveRule else {
                switcherLogger.warning("Preset auto-switch asked to restore with no captured snapshot")
                return
            }
            routingState.effectsPreset = snapshot.preset
            routingState.noiseSuppression = snapshot.noiseSuppression
            routingState.save()
            lastAppliedPresetID = nil
            snapshotBeforeActiveRule = nil
        }
    }

    isolated deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { center.removeObserver(observer) }
    }
}
