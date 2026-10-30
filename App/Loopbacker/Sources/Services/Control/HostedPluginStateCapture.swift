import Foundation

/// Persists a hosted plugin's current state (AU class info, JSFX serialization, Airwindows
/// chunk) into the active routing config whenever its editor window closes, independent of
/// whether `EffectsView` is in the view hierarchy. `PluginEditorWindowController` keeps its
/// `NSPanel`s alive on their own, so an editor can still be open after the user navigates to
/// Routing/Scenes or closes the main window; without an app-lifetime observer, closing the
/// panel in that state drops the notification and loses the edit at relaunch.
///
/// Owned by the app for its lifetime (like `PresetAutoSwitcher`/`RoutingSync`), not by
/// `EffectsView`. `EffectsView` also calls `captureIntoPreset()` directly before an explicit
/// save/export, so a plugin editor left open doesn't silently export stale `pluginState`.
@MainActor
final class HostedPluginStateCapture: ObservableObject {
    private let fxEngine: FXEngine
    private let routingState: RoutingState
    private var observer: NSObjectProtocol?

    init(fxEngine: FXEngine, routingState: RoutingState) {
        self.fxEngine = fxEngine
        self.routingState = routingState
        observer = NotificationCenter.default.addObserver(
            forName: .fxPluginEditorClosed, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.captureIntoPreset()
            }
        }
    }

    /// Captures every live hosted node's current state into `routingState.effectsPreset.nodes`
    /// and saves, if anything changed. Safe to call redundantly (e.g. editor-close and an
    /// explicit save racing) — it always captures the current live state.
    func captureIntoPreset() async {
        let states = await fxEngine.captureHostedStates()
        guard !states.isEmpty else { return }
        for (id, data) in states {
            guard let idx = routingState.effectsPreset.nodes.firstIndex(where: { $0.id == id }) else { continue }
            routingState.effectsPreset.nodes[idx].pluginState = data
        }
        routingState.save()
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
