import Combine
import Foundation

/// Keeps the audio engine in step with `RoutingState` for the lifetime of the app. Loopbacker
/// lives in the menu bar and its main window may never open, so this runs from
/// `LoopbackerApp.init()`, not from a view.
///
/// `@Published` emits before the property changes, so sinks use the emitted value, never a
/// re-read of the property they observe.
@MainActor
final class RoutingSync: ObservableObject {
    private let routingState: RoutingState
    private let audioDeviceManager: AudioDeviceManager
    private let audioRouter: AudioRouter
    private let appCaptureService: AppCaptureService

    private var cancellables: Set<AnyCancellable> = []

    init(
        routingState: RoutingState,
        audioDeviceManager: AudioDeviceManager,
        audioRouter: AudioRouter,
        appCaptureService: AppCaptureService
    ) {
        self.routingState = routingState
        self.audioDeviceManager = audioDeviceManager
        self.audioRouter = audioRouter
        self.appCaptureService = appCaptureService

        start()
    }

    private func start() {
        audioDeviceManager.populateInitialSources(into: routingState)
        // Apply saved effects preset to the audio router
        audioRouter.currentEffectsPreset = routingState.effectsPreset
        audioRouter.updateEffectsPreset(routingState.effectsPreset)
        push(NoisePush(settings: routingState.noiseSuppression, sources: routingState.sources))

        // Start routing for saved state after the audio system settles.
        // After a driver reinstall, coreaudiod can take 2-3s to fully
        // re-initialize. Starting too early blocks and hangs the app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            // Size the virtual devices first; the router queue runs these before the
            // route starts below, so routes open the devices at their final width.
            self.applyVirtualDeviceChannels()
            self.rebindMissingDeviceSources(devices: self.audioDeviceManager.systemDevices)
            self.syncAudioRouting(sources: self.routingState.sources, routes: self.routingState.routes)
            self.syncOutputRouting(destinations: self.routingState.outputDestinations)
            // Start monitoring for any sources that have a saved monitor output
            for source in self.routingState.sources where !source.monitorOutputUID.isEmpty && source.isEnabled && !source.isMuted {
                self.audioRouter.startMonitoring(sourceDeviceUID: source.deviceUID, outputDeviceUID: source.monitorOutputUID)
            }
        }

        observe()
    }

    private func observe() {
        routingState.$sources
            .dropFirst()
            .sink { [weak self] newSources in
                guard let self else { return }
                self.syncAudioRouting(sources: newSources, routes: self.routingState.routes)
            }
            .store(in: &cancellables)

        routingState.$routes
            .dropFirst()
            .sink { [weak self] newRoutes in
                guard let self else { return }
                self.syncAudioRouting(sources: self.routingState.sources, routes: newRoutes)
            }
            .store(in: &cancellables)

        // Re-sync when devices are hotplugged (e.g. M2 connected/disconnected)
        audioDeviceManager.$systemDevices
            .dropFirst()
            .sink { [weak self] devices in
                guard let self else { return }
                self.rebindMissingDeviceSources(devices: devices)
                self.syncAudioRouting(sources: self.routingState.sources, routes: self.routingState.routes)
            }
            .store(in: &cancellables)

        routingState.$effectsPreset
            .dropFirst()
            .sink { [weak self] newPreset in
                guard let self else { return }
                self.audioRouter.currentEffectsPreset = newPreset
                self.audioRouter.updateEffectsPreset(newPreset)
            }
            .store(in: &cancellables)

        routingState.$outputChannels
            .map { VirtualDeviceChannels.deviceCount(forChannels: $0.count) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] count in
                self?.setDeviceChannels(count, deviceUID: VirtualDeviceChannels.micUID)
            }
            .store(in: &cancellables)

        routingState.$streamOutputChannels
            .map { VirtualDeviceChannels.deviceCount(forChannels: $0.count) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] count in
                self?.setDeviceChannels(count, deviceUID: VirtualDeviceChannels.streamUID)
            }
            .store(in: &cancellables)

        // Push noise suppression settings (global toggle/engine/reduction, or a source's opt-out,
        // monitor choice or device UID changing) to the engine. `removeDuplicates` skips no-op
        // re-emissions; `dropFirst` skips the value already pushed in `start()`.
        Publishers.CombineLatest(routingState.$noiseSuppression, routingState.$sources)
            .map { NoisePush(settings: $0, sources: $1) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] in self?.push($0) }
            .store(in: &cancellables)
    }

    private func push(_ noise: NoisePush) {
        audioRouter.updateNoiseSuppression(noise.settings, excludedDeviceUIDs: noise.excludedDeviceUIDs,
                                           dryMonitorDeviceUIDs: noise.dryMonitorDeviceUIDs)
    }

    private struct NoisePush: Equatable {
        let settings: NoiseSuppressionSettings
        /// Device sources that opted out. App captures are never denoised, so they're left out.
        let excludedDeviceUIDs: Set<String>
        /// Device sources whose monitor stays dry.
        let dryMonitorDeviceUIDs: Set<String>

        init(settings: NoiseSuppressionSettings, sources: [AudioSource]) {
            self.settings = settings
            let devices = sources.filter { !$0.isAppCapture && !$0.deviceUID.isEmpty }
            excludedDeviceUIDs = Set(devices.filter { !$0.noiseSuppression }.map(\.deviceUID))
            dryMonitorDeviceUIDs = Set(devices.filter { !$0.denoiseMonitor }.map(\.deviceUID))
        }
    }

    // MARK: - Audio routing sync

    /// Re-points sources whose device UID changed (same hardware, different driver)
    /// and tears down any route/monitor still keyed by the old UID.
    private func rebindMissingDeviceSources(devices: [SystemAudioDevice]) {
        let changes = routingState.rebindMissingDeviceSources(to: devices)
        for change in changes {
            audioRouter.stopRouting(sourceDeviceUID: change.old, targetDeviceUID: VirtualDeviceChannels.micUID)
            audioRouter.stopRouting(sourceDeviceUID: change.old, targetDeviceUID: VirtualDeviceChannels.streamUID)
            audioRouter.stopOutputRouting(virtualDeviceUID: "monitor:\(change.old)")
            guard let source = routingState.sources.first(where: { $0.deviceUID == change.new }),
                  !source.monitorOutputUID.isEmpty, source.isEnabled, !source.isMuted else { continue }
            audioRouter.startMonitoring(sourceDeviceUID: change.new, outputDeviceUID: source.monitorOutputUID)
        }
    }

    /// Starts/stops audio routing based on which sources are enabled, not muted, and have
    /// routes into a given target. Each source → target pair (virtual mic, Stream Mix) is
    /// started/stopped independently: a source can feed one, the other, both, or neither.
    private func syncAudioRouting(sources: [AudioSource], routes: [AudioRoute]) {
        for source in sources {
            let mixUID = source.isAppCapture ? "app:\(source.appBundleID)" : source.deviceUID
            let baseEligible = source.isEnabled && !source.isMuted && !source.deviceUID.isEmpty

            for target in RouteTarget.allCases {
                let targetRoutes = routes.filter { $0.sourceId == source.id && $0.targetId == target }
                let shouldRoute = baseEligible && !targetRoutes.isEmpty

                // Push the per-source, per-target channel mix matrix so the engine knows how to
                // fan source channels into that target's output channels.
                let sourceRoutes: [(srcCh: Int, dstCh: Int)] = targetRoutes
                    .map { (srcCh: $0.sourceChannelId, dstCh: $0.outputChannelId) }
                if !mixUID.isEmpty {
                    audioRouter.setChannelMix(sourceDeviceUID: mixUID, targetDeviceUID: target.deviceUID, routes: sourceRoutes)
                }

                if shouldRoute {
                    if source.isAppCapture {
                        audioRouter.startAppCapture(bundleID: source.appBundleID, targetDeviceUID: target.deviceUID,
                                                    appCaptureService: appCaptureService)
                    } else {
                        audioRouter.startRouting(sourceDeviceUID: source.deviceUID, targetDeviceUID: target.deviceUID)
                    }
                } else {
                    if source.isAppCapture {
                        audioRouter.stopAppCapture(bundleID: source.appBundleID, targetDeviceUID: target.deviceUID,
                                                   appCaptureService: appCaptureService)
                    } else if !source.deviceUID.isEmpty {
                        audioRouter.stopRouting(sourceDeviceUID: source.deviceUID, targetDeviceUID: target.deviceUID)
                    }
                }
            }

            // Monitor: only manage stop. Start is handled by the picker in SourceCardView.
            // (Monitoring not supported for app capture sources — they don't have a CoreAudio device)
            let routedAnywhere = routes.contains { $0.sourceId == source.id }
            if !(baseEligible && routedAnywhere) && !source.monitorOutputUID.isEmpty && !source.isAppCapture {
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

    /// Push the saved channel counts to the driver (both virtual mics plus every output device).
    private func applyVirtualDeviceChannels() {
        setDeviceChannels(routingState.micChannelCount, deviceUID: VirtualDeviceChannels.micUID)
        setDeviceChannels(routingState.streamMicChannelCount, deviceUID: VirtualDeviceChannels.streamUID)
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
