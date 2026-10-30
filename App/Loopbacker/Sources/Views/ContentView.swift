import SwiftUI

/// Main window: glass sidebar + section detail, unified toolbar. Engine startup and the
/// `RoutingState` -> `AudioRouter` sync live in `RoutingSync` so they run without this window.
struct ContentView: View {
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var audioDeviceManager: AudioDeviceManager
    @EnvironmentObject var audioRouter: AudioRouter
    @EnvironmentObject var driverInstaller: DriverInstaller
    @EnvironmentObject var appUpdater: AppUpdater

    @SceneStorage("studioSection") private var section: StudioSection = .routing
    @State private var showSourcePicker = false
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system
    @AppStorage(RoutingViewMode.storageKey) private var routingViewMode: RoutingViewMode = .canvas

    private var actions: StudioActions {
        StudioActions(routingState: routingState, audioRouter: audioRouter,
                      audioDeviceManager: audioDeviceManager, driverInstaller: driverInstaller,
                      appUpdater: appUpdater)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(section: $section)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            detail
                .navigationTitle(section.title)
        }
        .tint(.loopbacker)
        .focusedSceneValue(\.studioSection, $section)
        .onChange(of: appearance) { _, mode in mode.apply() }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .routing:
            Group {
                switch routingViewMode {
                case .canvas:
                    RoutingCanvasView(onAddSource: { showSourcePicker = true })
                case .matrix:
                    RoutingMatrixView()
                }
            }
            .toolbar {
                routingToolbar
                GlobalToolbar()
            }
        case .effects:
            EffectsView()
        case .soundboard:
            SoundboardView()
        case .scenes:
            ScenesView()
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var routingToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Routing View", selection: $routingViewMode) {
                ForEach(RoutingViewMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Switch between the cable canvas and the keyboard-navigable connection matrix")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showSourcePicker = true
            } label: {
                Label("Add Source", systemImage: "plus")
            }
            .help("Add an input device or app as a source")
            .popover(isPresented: $showSourcePicker, arrowEdge: .bottom) {
                SourcePickerView { showSourcePicker = false }
            }

            Button {
                actions.autoRouteStereo()
            } label: {
                Label("Auto-Route Stereo", systemImage: "arrow.left.arrow.right")
            }
            .help("Auto-route the first stereo input to outputs 1 & 2")

            Button {
                actions.stopAllRouting()
            } label: {
                Label("Stop All Routing", systemImage: "stop.circle")
            }
            .help("Stop all audio routing and disconnect every route (keeps sources)")
        }
    }

}

// MARK: - Global toolbar

/// App-wide toolbar items. Each section appends this after its own items so section actions
/// sit first and Reconnect / More stay anchored at the trailing edge.
struct GlobalToolbar: ToolbarContent {
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var audioDeviceManager: AudioDeviceManager
    @EnvironmentObject var audioRouter: AudioRouter
    @EnvironmentObject var driverInstaller: DriverInstaller
    @EnvironmentObject var appUpdater: AppUpdater
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system
    @ObservedObject private var loginItem = LoginItem.shared

    private var actions: StudioActions {
        StudioActions(routingState: routingState, audioRouter: audioRouter,
                      audioDeviceManager: audioDeviceManager, driverInstaller: driverInstaller,
                      appUpdater: appUpdater)
    }

    var body: some ToolbarContent {
        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                actions.reconnect()
            } label: {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            .help("Reconnect audio (fixes glitches after sleep)")

            Menu {
                Button("Rescan Devices", systemImage: "arrow.triangle.2.circlepath") { actions.rescanDevices() }
                Button("Play Test Tone", systemImage: "tuningfork") { actions.playTestTone() }
                Button("Copy Debug Snapshot", systemImage: "doc.on.clipboard") { actions.copyDebugSnapshot() }
                Divider()
                Toggle("Open at Login", systemImage: "power.circle", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                if loginItem.needsApproval {
                    Button("Allow Open at Login in System Settings…", systemImage: "gear") { loginItem.openSystemSettings() }
                }
                Divider()
                Picker("Appearance", systemImage: appearance.symbol, selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                Divider()
                Button(driverInstaller.isInstalled ? "Uninstall Driver…" : "Install Driver…",
                       systemImage: driverInstaller.isInstalled ? "minus.circle" : "arrow.down.circle") {
                    actions.toggleDriver()
                }
                .disabled(driverInstaller.isProcessing)
                if driverInstaller.updateAvailable {
                    Button("Install Driver Update…", systemImage: "arrow.triangle.2.circlepath") {
                        actions.installDriverUpdate()
                    }
                    .disabled(driverInstaller.isProcessing)
                    .help("Needs admin and briefly drops audio while coreaudiod restarts")
                }
                Divider()
                Button("Check for Updates…", systemImage: "arrow.down.circle.dotted") {
                    actions.checkForUpdates()
                }
                .disabled(!appUpdater.canCheckForUpdates)
                if let update = appUpdater.availableUpdate {
                    Button("Update to \(update.displayVersion)…", systemImage: "arrow.down.circle") {
                        actions.installAvailableUpdate()
                    }
                }
                Divider()
                Button("Quit and Stop Routing", systemImage: "power") { AppDelegate.forceQuit() }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .help("Devices, test tone, open at login, appearance, driver, updates")
        }
    }
}
