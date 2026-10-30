import Foundation
import Testing
@testable import Loopbacker

@Suite("SceneDiff")
struct SceneDiffTests {
    private func source(
        name: String = "Mic", deviceUID: String = "mic-1", enabled: Bool = true, muted: Bool = false
    ) -> AudioSource {
        AudioSource(
            name: name, channels: [AudioChannel(id: 1, label: "1"), AudioChannel(id: 2, label: "2")],
            isEnabled: enabled, isMuted: muted, deviceUID: deviceUID
        )
    }

    private func config(sources: [AudioSource], routes: [AudioRoute],
                         outputDestinations: [OutputDestination] = [], outputChannelCount: Int = 2) -> RoutingConfig {
        RoutingConfig(
            sources: sources,
            outputChannels: (1...outputChannelCount).map { AudioChannel(id: $0, label: "\($0)") },
            routes: routes,
            outputDestinations: outputDestinations
        )
    }

    @Test("A route present in both configs, unchanged, produces no diff")
    func unchangedRouteUntouched() {
        let mic = source()
        let routes = [AudioRoute(sourceId: mic.id, sourceChannelId: 1, outputChannelId: 1)]
        let old = RoutingDesiredState.compute(from: config(sources: [mic], routes: routes))
        let new = RoutingDesiredState.compute(from: config(sources: [mic], routes: routes))

        let diff = SceneDiff.diff(from: old, to: new)

        #expect(diff.isEmpty)
    }

    @Test("A route only in the new scene starts; a route only in the old scene stops")
    func addedAndRemovedRoutes() {
        let shared = source(name: "Shared", deviceUID: "shared-uid")
        let onlyOld = source(name: "Old Only", deviceUID: "old-uid")
        let onlyNew = source(name: "New Only", deviceUID: "new-uid")

        let old = RoutingDesiredState.compute(from: config(
            sources: [shared, onlyOld],
            routes: [
                AudioRoute(sourceId: shared.id, sourceChannelId: 1, outputChannelId: 1),
                AudioRoute(sourceId: onlyOld.id, sourceChannelId: 1, outputChannelId: 1)
            ]
        ))
        let new = RoutingDesiredState.compute(from: config(
            sources: [shared, onlyNew],
            routes: [
                AudioRoute(sourceId: shared.id, sourceChannelId: 1, outputChannelId: 1),
                AudioRoute(sourceId: onlyNew.id, sourceChannelId: 1, outputChannelId: 1)
            ]
        ))

        let diff = SceneDiff.diff(from: old, to: new)

        #expect(diff.routesToStart.map(\.key) == ["new-uid"])
        #expect(diff.routesToStop == ["old-uid"])
        #expect(diff.routesToRetarget.isEmpty)
    }

    @Test("A route present in both but mixed differently retargets without stop/start")
    func retargetedRoute() {
        let mic = source()
        let old = RoutingDesiredState.compute(from: config(
            sources: [mic],
            routes: [AudioRoute(sourceId: mic.id, sourceChannelId: 1, outputChannelId: 1)]
        ))
        let new = RoutingDesiredState.compute(from: config(
            sources: [mic],
            routes: [AudioRoute(sourceId: mic.id, sourceChannelId: 1, outputChannelId: 2)]
        ))

        let diff = SceneDiff.diff(from: old, to: new)

        #expect(diff.routesToStart.isEmpty)
        #expect(diff.routesToStop.isEmpty)
        #expect(diff.routesToRetarget.count == 1)
        #expect(diff.routesToRetarget[0].key == "mic-1")
        #expect(diff.routesToRetarget[0].mix == [RoutingDesiredState.MixEntry(sourceChannel: 1, outputChannel: 2)])
    }

    @Test("Widening the virtual mic reports a channel-count change for its UID")
    func channelCountChange() {
        let mic = source()
        let routes = [AudioRoute(sourceId: mic.id, sourceChannelId: 1, outputChannelId: 1)]
        let old = RoutingDesiredState.compute(from: config(sources: [mic], routes: routes, outputChannelCount: 2))
        let new = RoutingDesiredState.compute(from: config(sources: [mic], routes: routes, outputChannelCount: 4))

        let diff = SceneDiff.diff(from: old, to: new)

        #expect(diff.channelCountChanges[VirtualDeviceChannels.micUID] == 4)
        // The route itself didn't change, so it isn't touched.
        #expect(diff.routesToStart.isEmpty && diff.routesToStop.isEmpty && diff.routesToRetarget.isEmpty)
    }

    @Test("Disabling a source stops its route; enabling one with routes starts it")
    func sourcesToggled() {
        let mic = source(enabled: true)
        let routes = [AudioRoute(sourceId: mic.id, sourceChannelId: 1, outputChannelId: 1)]
        let old = RoutingDesiredState.compute(from: config(sources: [mic], routes: routes))

        var disabledMic = mic
        disabledMic.isEnabled = false
        let newDisabled = RoutingDesiredState.compute(from: config(sources: [disabledMic], routes: routes))
        let diffDisable = SceneDiff.diff(from: old, to: newDisabled)
        #expect(diffDisable.routesToStop == ["mic-1"])
        #expect(diffDisable.routesToStart.isEmpty)

        var mutedMic = mic
        mutedMic.isMuted = true
        let newMuted = RoutingDesiredState.compute(from: config(sources: [mutedMic], routes: routes))
        let diffMute = SceneDiff.diff(from: old, to: newMuted)
        #expect(diffMute.routesToStop == ["mic-1"])

        // Re-enabling from the muted state should start it again.
        let diffReenable = SceneDiff.diff(from: newMuted, to: old)
        #expect(diffReenable.routesToStart.map(\.key) == ["mic-1"])
    }

    @Test("An output destination added, removed, and retargeted produces the matching diff")
    func outputDestinations() {
        let dest = OutputDestination(virtualDeviceUID: "out-1", virtualDeviceName: "Out", physicalOutputUID: "speakers")
        let old = RoutingDesiredState.compute(from: config(sources: [], routes: [], outputDestinations: [dest]))
        let new = RoutingDesiredState.compute(from: config(sources: [], routes: [], outputDestinations: []))

        let removedDiff = SceneDiff.diff(from: old, to: new)
        #expect(removedDiff.outputsToStop == ["out-1"])
        #expect(removedDiff.outputsToStart.isEmpty)

        var retargeted = dest
        retargeted.physicalOutputUID = "headphones"
        let retargetState = RoutingDesiredState.compute(from: config(sources: [], routes: [], outputDestinations: [retargeted]))
        let retargetDiff = SceneDiff.diff(from: old, to: retargetState)
        #expect(retargetDiff.outputsToStart.map(\.virtualDeviceUID) == ["out-1"])
        #expect(retargetDiff.outputsToStop.isEmpty)
    }

    @Test("A monitor added, removed, and retargeted produces the matching diff")
    func monitors() {
        var mic = source()
        mic.monitorOutputUID = "speakers"
        let routes = [AudioRoute(sourceId: mic.id, sourceChannelId: 1, outputChannelId: 1)]
        let withMonitor = RoutingDesiredState.compute(from: config(sources: [mic], routes: routes))

        var noMonitorMic = mic
        noMonitorMic.monitorOutputUID = ""
        let withoutMonitor = RoutingDesiredState.compute(from: config(sources: [noMonitorMic], routes: routes))

        let removeDiff = SceneDiff.diff(from: withMonitor, to: withoutMonitor)
        #expect(removeDiff.monitorsToStop == ["mic-1"])
        #expect(removeDiff.monitorsToStart.isEmpty)

        let addDiff = SceneDiff.diff(from: withoutMonitor, to: withMonitor)
        #expect(addDiff.monitorsToStart.map(\.sourceDeviceUID) == ["mic-1"])
        #expect(addDiff.monitorsToStart.map(\.outputDeviceUID) == ["speakers"])
    }
}
