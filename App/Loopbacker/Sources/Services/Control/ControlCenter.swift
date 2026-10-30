import Foundation

/// The single place both the `loopbacker://` URL scheme and the App Intents (#21) reach into
/// the running app. Both are instantiated fresh by the system (URL events/Shortcuts don't carry
/// SwiftUI's environment), so this holds weak references to the app's real singletons, wired
/// once from `LoopbackerApp.init()`. Unconfigured (app not finished launching yet, or running
/// under a test host) calls are no-ops/failures rather than crashes.
@MainActor
final class ControlCenter {
    static let shared = ControlCenter()

    private weak var micControl: MicControl?
    private weak var routingState: RoutingState?
    private weak var audioRouter: AudioRouter?

    private init() {}

    /// Called once from `LoopbackerApp.init()` once every object exists.
    func configure(micControl: MicControl, routingState: RoutingState, audioRouter: AudioRouter) {
        self.micControl = micControl
        self.routingState = routingState
        self.audioRouter = audioRouter
    }

    // MARK: - Mute

    @discardableResult
    func toggleMute() -> Bool {
        guard let micControl else { return false }
        micControl.toggleMute()
        return true
    }

    @discardableResult
    func setMuted(_ muted: Bool) -> Bool {
        guard let micControl else { return false }
        micControl.setMuted(muted)
        return true
    }

    var isMuted: Bool { micControl?.isMuted ?? false }

    // MARK: - Effects preset / bypass

    @discardableResult
    func applyPreset(id: String) -> Bool {
        guard let routingState else { return false }
        return EffectsPresetLibrary.apply(id: id, to: routingState)
    }

    @discardableResult
    func setEffectsEnabled(_ enabled: Bool) -> Bool {
        guard let routingState else { return false }
        routingState.effectsPreset.isEnabled = enabled
        routingState.save()
        return true
    }

    @discardableResult
    func toggleEffects() -> Bool {
        guard let routingState else { return false }
        routingState.effectsPreset.isEnabled.toggle()
        routingState.save()
        return true
    }

    var isEffectsEnabled: Bool { routingState?.effectsPreset.isEnabled ?? false }

    func availablePresets() -> [NamedPreset] { EffectsPresetLibrary.all() }

    // MARK: - Scenes

    func availableScenes() -> [String] { PresetManager.list() }

    @discardableResult
    func loadScene(name: String) -> Bool {
        guard let routingState, let data = PresetManager.load(name: name) else { return false }
        audioRouter?.stopAll()
        routingState.importConfig(data)
        return true
    }
}
