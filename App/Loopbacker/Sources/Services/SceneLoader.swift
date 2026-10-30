import Foundation
import Combine
import os.log

private let logger = Logger(subsystem: "com.jacobcoffee.loopbacker", category: "SceneLoader")

/// Loads a saved scene by diffing it against the running configuration and only
/// starting/stopping/retargeting what changed, so routes the two scenes share (e.g. the same
/// mic) keep running on the same AUHAL instance without a restart.
@MainActor
final class SceneLoader: ObservableObject {
    private let routingState: RoutingState
    private let audioRouter: AudioRouter
    private let appCaptureService: AppCaptureService
    private let audioDeviceManager: AudioDeviceManager

    init(routingState: RoutingState, audioRouter: AudioRouter, appCaptureService: AppCaptureService,
         audioDeviceManager: AudioDeviceManager) {
        self.routingState = routingState
        self.audioRouter = audioRouter
        self.appCaptureService = appCaptureService
        self.audioDeviceManager = audioDeviceManager
    }

    /// Loads a scene saved under `name`. Returns `nil` if no such scene exists, otherwise the
    /// diff that was applied.
    @discardableResult
    func loadScene(name: String) -> SceneDiff? {
        guard let data = PresetManager.load(name: name),
              let config = try? JSONDecoder().decode(RoutingConfig.self, from: data) else {
            logger.error("Scene '\(name, privacy: .public)' not found or unreadable")
            return nil
        }
        return load(config)
    }

    /// Applies `config` as the running configuration: starts routes present only in `config`,
    /// stops routes present only in the current state, and retargets (channel mix only, no
    /// restart) routes present in both but mixed differently. See `SceneLoadPlanner` for the
    /// device normalization/diffing logic.
    @discardableResult
    func load(_ config: RoutingConfig) -> SceneDiff {
        let plan = SceneLoadPlanner.plan(
            loading: config, over: routingState.currentConfig(), presentDevices: audioDeviceManager.systemDevices
        )
        for change in plan.deviceChanges {
            SceneNotifier.shared.deviceFallback(sourceName: change.sourceName, toDeviceName: change.newName)
        }
        apply(plan.diff)
        routingState.applyConfig(plan.normalizedConfig)
        return plan.diff
    }

    private func apply(_ diff: SceneDiff) {
        for route in diff.routesToStart {
            if route.isAppCapture {
                audioRouter.startAppCapture(bundleID: route.bundleID, appCaptureService: appCaptureService)
            } else {
                audioRouter.startRouting(sourceDeviceUID: route.deviceUID)
            }
            audioRouter.setChannelMix(
                sourceDeviceUID: route.key,
                routes: route.mix.map { (srcCh: $0.sourceChannel, dstCh: $0.outputChannel) }
            )
        }
        for retarget in diff.routesToRetarget {
            audioRouter.setChannelMix(
                sourceDeviceUID: retarget.key,
                routes: retarget.mix.map { (srcCh: $0.sourceChannel, dstCh: $0.outputChannel) }
            )
        }
        for key in diff.routesToStop {
            if key.hasPrefix("app:") {
                audioRouter.stopAppCapture(bundleID: String(key.dropFirst("app:".count)), appCaptureService: appCaptureService)
            } else {
                audioRouter.stopRouting(sourceDeviceUID: key)
            }
        }
        for monitor in diff.monitorsToStart {
            audioRouter.startMonitoring(sourceDeviceUID: monitor.sourceDeviceUID, outputDeviceUID: monitor.outputDeviceUID)
        }
        for deviceUID in diff.monitorsToStop {
            audioRouter.stopOutputRouting(virtualDeviceUID: "monitor:\(deviceUID)")
        }
        for dest in diff.outputsToStart {
            audioRouter.startOutputRouting(
                virtualDeviceUID: dest.virtualDeviceUID, physicalOutputUID: dest.physicalOutputUID,
                monitorChannel: dest.monitorChannel
            )
        }
        for uid in diff.outputsToStop {
            audioRouter.stopOutputRouting(virtualDeviceUID: uid)
        }
        for (uid, count) in diff.channelCountChanges {
            audioRouter.setVirtualDeviceChannels(count, deviceUID: uid, appCaptureService: appCaptureService) { [audioDeviceManager] _ in
                audioDeviceManager.enumerateDevices()
            }
        }
    }
}
