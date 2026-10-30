import SwiftUI

/// The app's `Settings` scene (⌘,): General, Hotkeys, Automation. Separate from the main
/// `ContentView`'s sections (Routing/Effects/Soundboard/Scenes) — these are one-time/background
/// configuration, not the live console.
struct SettingsRootView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            HotkeysSettingsView()
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
            AutomationSettingsView()
                .tabItem { Label("Automation", systemImage: "bolt.badge.a") }
        }
        .frame(width: 480)
        .scenePadding()
    }
}
