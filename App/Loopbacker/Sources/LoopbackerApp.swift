import SwiftUI

@main
struct LoopbackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var routingState: RoutingState
    @StateObject private var audioDeviceManager: AudioDeviceManager
    @StateObject private var driverInstaller: DriverInstaller
    @StateObject private var audioRouter: AudioRouter
    @StateObject private var soundboardState: SoundboardState
    @StateObject private var soundboardPlayer: SoundboardPlayer
    @StateObject private var appCaptureService: AppCaptureService
    @StateObject private var fxEngine: FXEngine
    // Mute/push-to-talk state (Control slice); the global hotkey and muted overlay are wired
    // from `init()` so they work even if the main window never opens.
    @StateObject private var micControl: MicControl
    // App-based effects preset auto-switch (Control slice, #20): rules + the live NSWorkspace
    // watcher, both needed for the whole app's lifetime like `routingSync` below.
    @StateObject private var presetAutoSwitchState: PresetAutoSwitchState
    @StateObject private var presetAutoSwitcher: PresetAutoSwitcher
    // Owns engine startup and the RoutingState -> AudioRouter sync for the app's lifetime, so
    // routes start and menu-bar edits reach the engine even if the main window never opens.
    @StateObject private var routingSync: RoutingSync

    init() {
        let routingState = RoutingState.load()
        let audioDeviceManager = AudioDeviceManager()
        let audioRouter = AudioRouter()
        let appCaptureService = AppCaptureService()
        let systemAudioTap = SystemAudioTap()
        let micControl = MicControl()
        let presetAutoSwitchState = PresetAutoSwitchState.load()
        _routingState = StateObject(wrappedValue: routingState)
        _audioDeviceManager = StateObject(wrappedValue: audioDeviceManager)
        _driverInstaller = StateObject(wrappedValue: DriverInstaller())
        _audioRouter = StateObject(wrappedValue: audioRouter)
        _soundboardState = StateObject(wrappedValue: SoundboardState.load())
        _soundboardPlayer = StateObject(wrappedValue: SoundboardPlayer())
        _appCaptureService = StateObject(wrappedValue: appCaptureService)
        _fxEngine = StateObject(wrappedValue: FXEngine(audioRouter: audioRouter))
        _micControl = StateObject(wrappedValue: micControl)
        _presetAutoSwitchState = StateObject(wrappedValue: presetAutoSwitchState)
        _presetAutoSwitcher = StateObject(wrappedValue: PresetAutoSwitcher(
            rulesState: presetAutoSwitchState, routingState: routingState
        ))
        _routingSync = StateObject(wrappedValue: RoutingSync(
            routingState: routingState,
            audioDeviceManager: audioDeviceManager,
            audioRouter: audioRouter,
            appCaptureService: appCaptureService,
            systemAudioTap: systemAudioTap
        ))
        ControlCenter.shared.configure(micControl: micControl, routingState: routingState, audioRouter: audioRouter)
        micControl.refreshHotkeyRegistration()
        MutedOverlayController.shared.start(micControl: micControl)
    }

    private var actions: StudioActions {
        StudioActions(routingState: routingState, audioRouter: audioRouter,
                      audioDeviceManager: audioDeviceManager, driverInstaller: driverInstaller)
    }

    var body: some Scene {
        Window("Loopbacker", id: WindowID.main) {
            ContentView()
                .environmentObject(routingState)
                .environmentObject(audioDeviceManager)
                .environmentObject(driverInstaller)
                .environmentObject(audioRouter)
                .environmentObject(soundboardState)
                .environmentObject(soundboardPlayer)
                .environmentObject(appCaptureService)
                .environmentObject(fxEngine)
                .environmentObject(routingSync.systemAudioTap)
                .environmentObject(micControl)
                .environmentObject(presetAutoSwitchState)
                .environmentObject(presetAutoSwitcher)
                .environment(audioRouter.meters)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1180, height: 760)
        .commands {
            StudioCommands(actions: actions, driverInstalled: driverInstaller.isInstalled)
        }

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(routingState)
                .environmentObject(audioDeviceManager)
                .environmentObject(driverInstaller)
                .environmentObject(audioRouter)
                .environmentObject(appCaptureService)
                .environmentObject(fxEngine)
                .environmentObject(routingSync.systemAudioTap)
                .environmentObject(micControl)
                .environment(audioRouter.meters)
        } label: {
            Image(systemName: micControl.isMuted ? "mic.slash" : "waveform.path")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsRootView()
                .environmentObject(micControl)
                .environmentObject(presetAutoSwitchState)
                .environmentObject(presetAutoSwitcher)
        }
    }
}

// MARK: - Menu bar commands

struct StudioCommands: Commands {
    let actions: StudioActions
    let driverInstalled: Bool

    @FocusedBinding(\.studioSection) private var section: StudioSection?
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        CommandGroup(before: .sidebar) {
            ForEach(StudioSection.allCases) { item in
                Button(item.title) { section = item }
                    .keyboardShortcut(item.shortcut, modifiers: .command)
                    .disabled(section == nil)
            }
            Divider()
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Divider()
        }

        CommandMenu("Audio") {
            Button("Reconnect Audio") { actions.reconnect() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Rescan Devices") { actions.rescanDevices() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Auto-Route Stereo") { actions.autoRouteStereo() }
            Button("Stop All Routing") { actions.stopAllRouting() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Divider()
            Button("Play Test Tone") { actions.playTestTone() }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button("Copy Debug Snapshot") { actions.copyDebugSnapshot() }
            Divider()
            Button(driverInstalled ? "Uninstall Driver…" : "Install Driver…") { actions.toggleDriver() }
            Button("Quit and Stop Routing") { AppDelegate.forceQuit() }
                .keyboardShortcut("q", modifiers: [.command, .option])
        }
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var shouldReallyQuit = false

    static func forceQuit() {
        shouldReallyQuit = true
        NSApplication.shared.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearanceMode.applyStored()
        DefaultDeviceRestorer.shared.saveDefaults()
        // Started at login: stay in the menu bar. Routing doesn't need the window (RoutingSync).
        if LoginItem.isLaunchingAtLogin() {
            DispatchQueue.main.async {
                for window in NSApp.windows where window.identifier?.rawValue.hasPrefix(WindowID.main) == true {
                    window.close()
                }
            }
        }
    }

    /// `loopbacker://` URL scheme commands (mute, preset, scene, effects — see
    /// `LoopbackerURLCommand`). Delivered here at the `NSApplication` level, not via SwiftUI's
    /// `.onOpenURL`, so it works even when the main window is closed: Loopbacker is a menu-bar
    /// app whose window often isn't open.
    func application(_ application: NSApplication, open urls: [URL]) {
        URLCommandRouter.handle(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// LB-HOST-002: a clean termination proves no hosted node crashed this session, even one
    /// still loaded and live right up to quit (its `QuarantineWitnessNode` may not `deinit`
    /// before the process actually exits).
    func applicationWillTerminate(_ notification: Notification) {
        HostedPluginQuarantine.shared.clearSessionSentinels()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.shouldReallyQuit {
            DefaultDeviceRestorer.shared.restoreDefaultsIfNeeded()
            return .terminateNow
        }
        for window in NSApplication.shared.windows { window.close() }
        return .terminateCancel
    }
}
