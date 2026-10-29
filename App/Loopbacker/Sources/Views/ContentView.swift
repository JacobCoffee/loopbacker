import SwiftUI

/// Main window: glass sidebar + section detail, unified toolbar, and the routing sync that keeps
/// the audio engine in step with `RoutingState`.
struct ContentView: View {
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var audioDeviceManager: AudioDeviceManager
    @EnvironmentObject var audioRouter: AudioRouter
    @EnvironmentObject var appCaptureService: AppCaptureService
    @EnvironmentObject var driverInstaller: DriverInstaller

    @SceneStorage("studioSection") private var section: StudioSection = .routing
    @State private var showSourcePicker = false
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system

    private var actions: StudioActions {
        StudioActions(routingState: routingState, audioRouter: audioRouter,
                      audioDeviceManager: audioDeviceManager, driverInstaller: driverInstaller)
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
        .onAppear {
            audioDeviceManager.populateInitialSources(into: routingState)
            // Apply saved effects preset to the audio router
            audioRouter.currentEffectsPreset = routingState.effectsPreset
            audioRouter.updateEffectsPreset(routingState.effectsPreset)
            audioRouter.updateNoiseSuppression(routingState.noiseSuppression)
            // Start routing for saved state after the audio system settles.
            // After a driver reinstall, coreaudiod can take 2-3s to fully
            // re-initialize. Starting too early blocks and hangs the app.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                // Size the virtual devices first; the router queue runs these before the
                // route starts below, so routes open the devices at their final width.
                applyVirtualDeviceChannels()
                rebindMissingDeviceSources()
                syncAudioRouting(sources: routingState.sources, routes: routingState.routes)
                syncOutputRouting(destinations: routingState.outputDestinations)
                // Start monitoring for any sources that have a saved monitor output
                for source in routingState.sources where !source.monitorOutputUID.isEmpty && source.isEnabled && !source.isMuted {
                    audioRouter.startMonitoring(sourceDeviceUID: source.deviceUID, outputDeviceUID: source.monitorOutputUID)
                }
            }
        }
        .onChange(of: routingState.sources) { _, newSources in
            syncAudioRouting(sources: newSources, routes: routingState.routes)
        }
        .onChange(of: routingState.routes) { _, newRoutes in
            syncAudioRouting(sources: routingState.sources, routes: newRoutes)
        }
        // Re-sync when devices are hotplugged (e.g. M2 connected/disconnected)
        .onChange(of: audioDeviceManager.systemDevices) { _, _ in
            rebindMissingDeviceSources()
            syncAudioRouting(sources: routingState.sources, routes: routingState.routes)
        }
        .onChange(of: routingState.effectsPreset) { _, newPreset in
            audioRouter.currentEffectsPreset = newPreset
            audioRouter.updateEffectsPreset(newPreset)
        }
        .onChange(of: routingState.noiseSuppression) { _, settings in
            audioRouter.updateNoiseSuppression(settings)
        }
        .onChange(of: routingState.micChannelCount) { _, count in
            setDeviceChannels(count, deviceUID: VirtualDeviceChannels.micUID)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .routing:
            RoutingCanvasView(onAddSource: { showSourcePicker = true })
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

    // MARK: - Audio routing sync

    /// Re-points sources whose device UID changed (same hardware, different driver)
    /// and tears down any route/monitor still keyed by the old UID.
    private func rebindMissingDeviceSources() {
        let changes = routingState.rebindMissingDeviceSources(to: audioDeviceManager.systemDevices)
        for change in changes {
            audioRouter.stopRouting(sourceDeviceUID: change.old)
            audioRouter.stopOutputRouting(virtualDeviceUID: "monitor:\(change.old)")
            guard let source = routingState.sources.first(where: { $0.deviceUID == change.new }),
                  !source.monitorOutputUID.isEmpty, source.isEnabled, !source.isMuted else { continue }
            audioRouter.startMonitoring(sourceDeviceUID: change.new, outputDeviceUID: source.monitorOutputUID)
        }
    }

    /// Starts/stops audio routing based on which sources are enabled, not muted, and have routes
    private func syncAudioRouting(sources: [AudioSource], routes: [AudioRoute]) {
        let routedSourceIDs = Set(routes.map(\.sourceId))

        for source in sources {
            let hasRoutes = routedSourceIDs.contains(source.id)
            let shouldRoute = source.isEnabled && !source.isMuted && hasRoutes && !source.deviceUID.isEmpty

            // Push the per-source channel mix matrix so the engine knows how to
            // fan source channels into output channels (handles mono→stereo, cross-routing).
            let sourceRoutes: [(srcCh: Int, dstCh: Int)] = routes
                .filter { $0.sourceId == source.id }
                .map { (srcCh: $0.sourceChannelId, dstCh: $0.outputChannelId) }
            let mixUID = source.isAppCapture ? "app:\(source.appBundleID)" : source.deviceUID
            if !mixUID.isEmpty {
                audioRouter.setChannelMix(sourceDeviceUID: mixUID, routes: sourceRoutes)
            }

            if shouldRoute {
                if source.isAppCapture {
                    audioRouter.startAppCapture(bundleID: source.appBundleID, appCaptureService: appCaptureService)
                } else {
                    audioRouter.startRouting(sourceDeviceUID: source.deviceUID)
                }
            } else {
                if source.isAppCapture {
                    audioRouter.stopAppCapture(bundleID: source.appBundleID, appCaptureService: appCaptureService)
                } else if !source.deviceUID.isEmpty {
                    audioRouter.stopRouting(sourceDeviceUID: source.deviceUID)
                }
            }

            // Monitor: only manage stop. Start is handled by the picker in SourceCardView.
            // (Monitoring not supported for app capture sources — they don't have a CoreAudio device)
            if !shouldRoute && !source.monitorOutputUID.isEmpty && !source.isAppCapture {
                audioRouter.stopOutputRouting(virtualDeviceUID: "monitor:\(source.deviceUID)")
            }
        }
    }

    /// Starts/stops output routing based on saved output destinations
    private func syncOutputRouting(destinations: [OutputDestination]) {
        for dest in destinations {
            if dest.isEnabled && !dest.physicalOutputUID.isEmpty {
                audioRouter.startOutputRouting(
                    virtualDeviceUID: dest.virtualDeviceUID,
                    physicalOutputUID: dest.physicalOutputUID,
                    monitorChannel: dest.monitorChannel
                )
            }
        }
    }

    /// Push the saved channel counts to the driver (the virtual mic plus every output device).
    private func applyVirtualDeviceChannels() {
        setDeviceChannels(routingState.micChannelCount, deviceUID: VirtualDeviceChannels.micUID)
        for dest in routingState.outputDestinations {
            setDeviceChannels(dest.channelCount, deviceUID: dest.virtualDeviceUID)
        }
    }

    private func setDeviceChannels(_ count: Int, deviceUID: String) {
        audioRouter.setVirtualDeviceChannels(count, deviceUID: deviceUID,
                                             appCaptureService: appCaptureService) { [audioDeviceManager] _ in
            audioDeviceManager.enumerateDevices()
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
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system

    private var actions: StudioActions {
        StudioActions(routingState: routingState, audioRouter: audioRouter,
                      audioDeviceManager: audioDeviceManager, driverInstaller: driverInstaller)
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
                Button("Quit and Stop Routing", systemImage: "power") { AppDelegate.forceQuit() }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .help("Devices, test tone, appearance, driver")
        }
    }
}
