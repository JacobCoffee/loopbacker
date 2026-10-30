import Combine
import Foundation
import os.log

private let logger = Logger(subsystem: "com.jacobcoffee.loopbacker", category: "AutomationRules")

/// Watches app and device signals and loads the matching rule's scene — or the fallback scene
/// when nothing matches. Runs from `LoopbackerApp.init()` like `RoutingSync`, so rules apply
/// whether or not the main window is open (Open at Login with no window).
@MainActor
final class AutomationRulesEngine: ObservableObject {
    let rulesState: AutomationRulesState
    private let sceneLoader: SceneLoader
    private let appCaptureService: AppCaptureService
    private let audioDeviceManager: AudioDeviceManager

    /// The rule currently in effect, or `nil` when the fallback scene (or nothing) applies.
    @Published private(set) var activeRule: AutomationRule?
    /// Name of the scene the engine last loaded, for UI display even when no rule matched
    /// (fallback) or rules are paused.
    @Published private(set) var lastAppliedSceneName: String?

    private let debouncer: Debouncer
    private var cancellables: Set<AnyCancellable> = []

    init(rulesState: AutomationRulesState, sceneLoader: SceneLoader, appCaptureService: AppCaptureService,
         audioDeviceManager: AudioDeviceManager, debounce: TimeInterval = 1.0) {
        self.rulesState = rulesState
        self.sceneLoader = sceneLoader
        self.appCaptureService = appCaptureService
        self.audioDeviceManager = audioDeviceManager
        self.debouncer = Debouncer(delay: debounce)

        observe()
        evaluate()
    }

    private func observe() {
        appCaptureService.$runningBundleIDs
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleEvaluate() }
            .store(in: &cancellables)

        appCaptureService.$frontmostBundleID
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleEvaluate() }
            .store(in: &cancellables)

        // Debounced so a flapping device (one that drops and re-enumerates a few times in a
        // row) doesn't thrash between rules/fallback.
        audioDeviceManager.$systemDevices
            .dropFirst()
            .map { Set($0.map(\.uid)) }
            .removeDuplicates()
            .sink { [weak self] _ in self?.scheduleEvaluate() }
            .store(in: &cancellables)
    }

    private func scheduleEvaluate() {
        debouncer.call { [weak self] in self?.evaluate() }
    }

    /// The current signals rules match against.
    var currentSignals: RuleEngine.Signals {
        RuleEngine.Signals(
            runningBundleIDs: appCaptureService.runningBundleIDs,
            frontmostBundleID: appCaptureService.frontmostBundleID,
            connectedDeviceUIDs: Set(audioDeviceManager.systemDevices.map(\.uid))
        )
    }

    /// Re-evaluates rules against the current signals and loads whatever should be active.
    /// Public so the UI's Resume action and tests can force an immediate pass.
    func evaluate() {
        let signals = currentSignals

        if rulesState.isPaused {
            guard let paused = rulesState.pausedSignals, RuleEngine.shouldResume(pausedSignals: paused, currentSignals: signals) else {
                return
            }
            rulesState.resume()
        }

        let matched = RuleEngine.resolve(rules: rulesState.rules, signals: signals)
        activeRule = matched

        guard let sceneName = matched?.action.sceneName ?? rulesState.fallbackSceneName else {
            lastAppliedSceneName = nil
            return
        }
        guard sceneName != lastAppliedSceneName else { return }

        guard sceneLoader.loadScene(name: sceneName) != nil else {
            logger.warning("Automation rule referenced missing scene '\(sceneName, privacy: .public)'")
            return
        }
        lastAppliedSceneName = sceneName
        SceneNotifier.shared.sceneApplied(sceneName: sceneName, reason: matched?.name ?? "fallback scene")
    }

    /// Called when the user manually loads a scene from the Scenes UI: pauses automation until
    /// the signals that were true at pause time change.
    func pauseForManualSelection(sceneName: String) {
        rulesState.pauseForManualSelection(signals: currentSignals)
        activeRule = nil
        lastAppliedSceneName = sceneName
    }
}
