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
    @StateObject private var appUpdater: AppUpdater
    @StateObject private var automationRulesState: AutomationRulesState
    // Owns engine startup and the RoutingState -> AudioRouter sync for the app's lifetime, so
    // routes start and menu-bar edits reach the engine even if the main window never opens.
    @StateObject private var routingSync: RoutingSync
    // Applies scenes as a diff against the running config, shared with the automation engine
    // and the Scenes UI.
    @StateObject private var sceneLoader: SceneLoader
    // Watches app/device signals and loads scenes automatically; runs independent of any
    // window so rules apply under Open at Login too.
    @StateObject private var automationRulesEngine: AutomationRulesEngine

    init() {
        let routingState = RoutingState.load()
        let audioDeviceManager = AudioDeviceManager()
        let audioRouter = AudioRouter()
        let appCaptureService = AppCaptureService()
        let automationRulesState = AutomationRulesState.load()
        let sceneLoader = SceneLoader(
            routingState: routingState, audioRouter: audioRouter,
            appCaptureService: appCaptureService, audioDeviceManager: audioDeviceManager
        )
        _routingState = StateObject(wrappedValue: routingState)
        _audioDeviceManager = StateObject(wrappedValue: audioDeviceManager)
        _driverInstaller = StateObject(wrappedValue: DriverInstaller())
        _audioRouter = StateObject(wrappedValue: audioRouter)
        _soundboardState = StateObject(wrappedValue: SoundboardState.load())
        _soundboardPlayer = StateObject(wrappedValue: SoundboardPlayer())
        _appCaptureService = StateObject(wrappedValue: appCaptureService)
        _appUpdater = StateObject(wrappedValue: AppUpdater.shared)
        _automationRulesState = StateObject(wrappedValue: automationRulesState)
        _sceneLoader = StateObject(wrappedValue: sceneLoader)
        _routingSync = StateObject(wrappedValue: RoutingSync(
            routingState: routingState,
            audioDeviceManager: audioDeviceManager,
            audioRouter: audioRouter,
            appCaptureService: appCaptureService
        ))
        _automationRulesEngine = StateObject(wrappedValue: AutomationRulesEngine(
            rulesState: automationRulesState,
            sceneLoader: sceneLoader,
            appCaptureService: appCaptureService,
            audioDeviceManager: audioDeviceManager
        ))
    }

    private var actions: StudioActions {
        StudioActions(routingState: routingState, audioRouter: audioRouter,
                      audioDeviceManager: audioDeviceManager, driverInstaller: driverInstaller,
                      appUpdater: appUpdater)
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
                .environmentObject(appUpdater)
                .environmentObject(automationRulesState)
                .environmentObject(automationRulesEngine)
                .environmentObject(sceneLoader)
                .environment(audioRouter.meters)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1180, height: 760)
        .commands {
            StudioCommands(actions: actions, driverInstalled: driverInstaller.isInstalled,
                           driverUpdateAvailable: driverInstaller.updateAvailable,
                           availableAppUpdateVersion: appUpdater.availableUpdate?.displayVersion,
                           installingAppUpdateVersion: appUpdater.installingVersion,
                           canCheckForUpdates: appUpdater.canCheckForUpdates)
        }

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(routingState)
                .environmentObject(audioDeviceManager)
                .environmentObject(driverInstaller)
                .environmentObject(audioRouter)
                .environmentObject(appCaptureService)
                .environmentObject(appUpdater)
                .environment(audioRouter.meters)
        } label: {
            Image(systemName: "waveform.path")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu bar commands

struct StudioCommands: Commands {
    let actions: StudioActions
    let driverInstalled: Bool
    let driverUpdateAvailable: Bool
    let availableAppUpdateVersion: String?
    let installingAppUpdateVersion: String?
    let canCheckForUpdates: Bool

    @FocusedBinding(\.studioSection) private var section: StudioSection?
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        CommandGroup(after: .appInfo) {
            Divider()
            Button("Check for Updates…") { actions.checkForUpdates() }
                .disabled(!canCheckForUpdates)
            if let version = availableAppUpdateVersion {
                Button("Update to \(version)…") { actions.installAvailableUpdate() }
            } else if let version = installingAppUpdateVersion {
                Text("Installing \(version)…")
            }
        }

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
            if driverUpdateAvailable {
                Button("Install Driver Update…") { actions.installDriverUpdate() }
                    .help("Needs admin and briefly drops audio while coreaudiod restarts")
            }
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Sparkle asking us to quit so it can finish installing an update we already agreed to
        // (clicked Install, or it was auto-applied in this same call below): always honor it,
        // independent of whether the user also clicked our own Quit button.
        if AppUpdater.shared.isTerminatingForUpdate {
            DefaultDeviceRestorer.shared.restoreDefaultsIfNeeded()
            return .terminateNow
        }
        if Self.shouldReallyQuit {
            // Install on quit: a downloaded update waiting for the user is applied now rather than
            // lost; Sparkle's helper finishes after this process exits.
            AppUpdater.shared.installPendingUpdateOnQuit()
            DefaultDeviceRestorer.shared.restoreDefaultsIfNeeded()
            return .terminateNow
        }
        for window in NSApplication.shared.windows { window.close() }
        return .terminateCancel
    }
}
