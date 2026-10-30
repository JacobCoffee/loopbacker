import AppIntents

/// Registers Loopbacker's App Intents with Shortcuts/Siri. `shortTitle`/`systemImageName` drive
/// the Shortcuts app gallery entry; phrases use `\(.applicationName)` so they read naturally
/// regardless of how the app is renamed.
///
/// Unlike `loopbacker://` URL commands (`Services/Control/LoopbackerURLCommand.swift`, gated by
/// Settings › General → "Allow Other Apps to Control Loopbacker", off by default), every intent
/// below calls `ControlCenter.shared` directly and is never gated by that setting (LB-URL-001).
/// This is deliberate, not an oversight: an intent only runs when the user (or an automation
/// they configured themselves) explicitly invokes it through the Shortcuts app, Siri, or a
/// Shortcuts automation they set up — unlike an arbitrary `open loopbacker://…` from any local
/// process or a web page link, invoking a Shortcut is itself a user consent gate.
struct LoopbackerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleMuteIntent(),
            phrases: [
                "Toggle mute in \(.applicationName)",
                "Toggle my mic in \(.applicationName)",
            ],
            shortTitle: "Toggle Mute",
            systemImageName: "mic.slash"
        )
        AppShortcut(
            intent: SetMuteIntent(),
            phrases: [
                "Mute my mic in \(.applicationName)",
                "Set mute in \(.applicationName)",
            ],
            shortTitle: "Set Mute",
            systemImageName: "mic.slash.fill"
        )
        AppShortcut(
            intent: SetEffectsPresetIntent(),
            phrases: [
                "Set \(.applicationName) effects preset",
                "Apply a \(.applicationName) preset",
            ],
            shortTitle: "Set Preset",
            systemImageName: "slider.horizontal.3"
        )
        AppShortcut(
            intent: ToggleEffectsIntent(),
            phrases: [
                "Toggle \(.applicationName) effects",
            ],
            shortTitle: "Toggle Effects",
            systemImageName: "slider.vertical.3"
        )
        AppShortcut(
            intent: LoadSceneIntent(),
            phrases: [
                "Load a \(.applicationName) scene",
                "Switch \(.applicationName) scene",
            ],
            shortTitle: "Load Scene",
            systemImageName: "square.stack.3d.up"
        )
    }
}
