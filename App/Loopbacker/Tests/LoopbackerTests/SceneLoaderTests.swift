import Foundation
import Combine
import Testing
@testable import Loopbacker

@Suite("SceneLoadPlanner")
struct SceneLoadPlannerTests {
    private func device(uid: String, name: String, inputChannelCount: Int = 2) -> SystemAudioDevice {
        SystemAudioDevice(id: 0, uid: uid, name: name, inputChannelCount: inputChannelCount, outputChannelCount: 0,
                           isInput: true, isOutput: false)
    }

    private func config(sources: [AudioSource], routes: [AudioRoute]) -> RoutingConfig {
        RoutingConfig(
            sources: sources,
            outputChannels: [AudioChannel(id: 1, label: "1"), AudioChannel(id: 2, label: "2")],
            routes: routes
        )
    }

    @Test("A route on the same device UID with the same mix, saved under a different AudioSource UUID, produces zero stop/start")
    func sameDeviceDifferentSourceUUIDProducesNoChurn() {
        // The running config and the saved scene both target "mic-uid", but as two entirely
        // different AudioSource instances (as happens in practice: each scene save/load
        // round-trip creates fresh UUIDs). The plan must recognize the underlying device route
        // is unchanged.
        let runningSource = AudioSource(name: "Mic", channels: [AudioChannel(id: 1, label: "1")], deviceUID: "mic-uid")
        let running = config(
            sources: [runningSource],
            routes: [AudioRoute(sourceId: runningSource.id, sourceChannelId: 1, outputChannelId: 1)]
        )

        let savedSource = AudioSource(name: "Mic", channels: [AudioChannel(id: 1, label: "1")], deviceUID: "mic-uid")
        let target = config(
            sources: [savedSource],
            routes: [AudioRoute(sourceId: savedSource.id, sourceChannelId: 1, outputChannelId: 1)]
        )

        let plan = SceneLoadPlanner.plan(loading: target, over: running, presentDevices: [device(uid: "mic-uid", name: "Mic")])

        #expect(plan.diff.routesToStart.isEmpty)
        #expect(plan.diff.routesToStop.isEmpty)
        #expect(plan.diff.routesToRetarget.isEmpty)
        #expect(plan.diff.monitorsToStart.isEmpty)
        #expect(plan.diff.monitorsToStop.isEmpty)
    }

    @Test("A scene saved against a now-missing device whose fallback is already running diffs to no change")
    func normalizesAgainstPresentDevicesBeforeDiffing() {
        // The scene was saved while "primary-uid" was connected. It's gone now; the source is
        // currently (and correctly) running on "fallback-uid" instead.
        var runningSource = AudioSource(name: "Interface", channels: [AudioChannel(id: 1, label: "1")], deviceUID: "fallback-uid")
        runningSource.fallbackDevices = [
            DeviceFallbackEntry(uid: "primary-uid", name: "Interface"),
            DeviceFallbackEntry(uid: "fallback-uid", name: "Built-in Mic")
        ]
        let running = config(
            sources: [runningSource],
            routes: [AudioRoute(sourceId: runningSource.id, sourceChannelId: 1, outputChannelId: 1)]
        )

        var savedSource = AudioSource(name: "Interface", channels: [AudioChannel(id: 1, label: "1")], deviceUID: "primary-uid")
        savedSource.fallbackDevices = runningSource.fallbackDevices
        let target = config(
            sources: [savedSource],
            routes: [AudioRoute(sourceId: savedSource.id, sourceChannelId: 1, outputChannelId: 1)]
        )

        // Only the fallback device is actually present.
        let plan = SceneLoadPlanner.plan(loading: target, over: running, presentDevices: [device(uid: "fallback-uid", name: "Built-in Mic")])

        #expect(plan.normalizedConfig.sources[0].deviceUID == "fallback-uid")
        // The saved scene genuinely points at "primary-uid"; normalizing reports that rebind...
        #expect(plan.deviceChanges.map(\.old) == ["primary-uid"])
        #expect(plan.deviceChanges.map(\.newUID) == ["fallback-uid"])
        // ...but because the running config was already on "fallback-uid", the normalized
        // target matches it exactly: no route churn, no stop of the working fallback.
        #expect(plan.diff.routesToStart.isEmpty)
        #expect(plan.diff.routesToStop.isEmpty)
    }

    @Test("Channels are clamped to the bound device's real width, and restored automatically once the wider device returns")
    func channelClampingAndAutomaticRestore() {
        let source = AudioSource(name: "Interface", channels: [AudioChannel(id: 1, label: "1"), AudioChannel(id: 2, label: "2")], deviceUID: "stereo-uid")
        let routes = [
            AudioRoute(sourceId: source.id, sourceChannelId: 1, outputChannelId: 1),
            AudioRoute(sourceId: source.id, sourceChannelId: 2, outputChannelId: 2)
        ]
        let running = config(sources: [], routes: [])
        let target = config(sources: [source], routes: routes)

        // Bound to a mono device: channel 2 has nowhere to read from and must clamp to channel 1,
        // so the mono input feeds both destinations instead of going silent on channel 2.
        let monoPlan = SceneLoadPlanner.plan(loading: target, over: running, presentDevices: [device(uid: "stereo-uid", name: "Mono Fallback", inputChannelCount: 1)])
        let monoMix = Set(monoPlan.diff.routesToStart.first?.mix ?? [])
        #expect(monoMix == [
            RoutingDesiredState.MixEntry(sourceChannel: 1, outputChannel: 1),
            RoutingDesiredState.MixEntry(sourceChannel: 1, outputChannel: 2)
        ])

        // The same routes, unmodified, against the real stereo device: no clamping, original
        // mapping restored automatically because nothing was ever mutated to produce the mono mix.
        let stereoPlan = SceneLoadPlanner.plan(loading: target, over: running, presentDevices: [device(uid: "stereo-uid", name: "Interface", inputChannelCount: 2)])
        let stereoMix = Set(stereoPlan.diff.routesToStart.first?.mix ?? [])
        #expect(stereoMix == [
            RoutingDesiredState.MixEntry(sourceChannel: 1, outputChannel: 1),
            RoutingDesiredState.MixEntry(sourceChannel: 2, outputChannel: 2)
        ])
    }
}

@Suite("AudioSource fallback device list")
struct AudioSourceFallbackDeviceTests {
    @Test("The first fallback added seeds the list with the current device first")
    func seedsCurrentDeviceFirst() {
        var source = AudioSource(name: "Interface", channels: [AudioChannel(id: 1, label: "1")], deviceUID: "primary-uid")
        #expect(source.fallbackDevices.isEmpty)

        source.addFallbackDevice(DeviceFallbackEntry(uid: "backup-uid", name: "Backup Mic"))

        #expect(source.fallbackDevices.map(\.uid) == ["primary-uid", "backup-uid"])
    }

    @Test("Adding a second fallback doesn't re-seed or duplicate")
    func secondAddDoesNotReseed() {
        var source = AudioSource(name: "Interface", channels: [AudioChannel(id: 1, label: "1")], deviceUID: "primary-uid")
        source.addFallbackDevice(DeviceFallbackEntry(uid: "backup-uid", name: "Backup Mic"))
        source.addFallbackDevice(DeviceFallbackEntry(uid: "backup2-uid", name: "Backup 2"))
        source.addFallbackDevice(DeviceFallbackEntry(uid: "backup-uid", name: "Backup Mic"))

        #expect(source.fallbackDevices.map(\.uid) == ["primary-uid", "backup-uid", "backup2-uid"])
    }
}

@Suite("DeviceRebinder claimed-device exclusion")
struct DeviceRebinderClaimTests {
    private func device(uid: String, name: String) -> SystemAudioDevice {
        SystemAudioDevice(id: 0, uid: uid, name: name, inputChannelCount: 2, outputChannelCount: 0, isInput: true, isOutput: false)
    }

    @Test("Two sources preferring the same fallback device never both resolve to it")
    func fallbackListExcludesClaimedDevices() {
        var sourceA = AudioSource(name: "A", channels: [AudioChannel(id: 1, label: "1")], deviceUID: "missing-a")
        sourceA.fallbackDevices = [
            DeviceFallbackEntry(uid: "missing-a", name: "A"),
            DeviceFallbackEntry(uid: "shared-fallback", name: "Shared")
        ]
        var sourceB = AudioSource(name: "B", channels: [AudioChannel(id: 1, label: "1")], deviceUID: "shared-fallback")
        sourceB.fallbackDevices = [
            DeviceFallbackEntry(uid: "missing-b", name: "B"),
            DeviceFallbackEntry(uid: "shared-fallback", name: "Shared")
        ]

        let result = DeviceRebinder.rebind(sources: [sourceA, sourceB], devices: [device(uid: "shared-fallback", name: "Shared")])

        // B is already (legitimately) on the shared device; A must not also be routed onto it.
        let boundUIDs = result.sources.map(\.deviceUID)
        #expect(Set(boundUIDs).count == boundUIDs.count, "two sources ended up on the same device UID")
        #expect(result.sources.first { $0.id == sourceB.id }?.deviceUID == "shared-fallback")
    }
}

@Suite("RoutingState.applyConfig atomicity")
@MainActor
struct RoutingStateAtomicityTests {
    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @Test("isReplacingConfig stays true for every intermediate property emission, and configReplaced fires once after, with it false")
    func replaceIsAtomicToObservers() {
        let state = RoutingState(persistenceDirectory: tempDirectory())
        var cancellables: Set<AnyCancellable> = []

        var sawTrueDuringSourcesEmission = false
        var sawTrueDuringRoutesEmission = false
        var configReplacedCount = 0
        var isReplacingConfigWhenConfigReplacedFired = true

        state.$sources.dropFirst().sink { _ in sawTrueDuringSourcesEmission = state.isReplacingConfig }.store(in: &cancellables)
        state.$routes.dropFirst().sink { _ in sawTrueDuringRoutesEmission = state.isReplacingConfig }.store(in: &cancellables)
        state.configReplaced.sink {
            configReplacedCount += 1
            isReplacingConfigWhenConfigReplacedFired = state.isReplacingConfig
        }.store(in: &cancellables)

        let source = AudioSource(name: "Mic", channels: [AudioChannel(id: 1, label: "1")], deviceUID: "mic-uid")
        let config = RoutingConfig(
            sources: [source],
            outputChannels: [AudioChannel(id: 1, label: "1"), AudioChannel(id: 2, label: "2")],
            routes: [AudioRoute(sourceId: source.id, sourceChannelId: 1, outputChannelId: 1)]
        )
        state.applyConfig(config)

        #expect(sawTrueDuringSourcesEmission, "a reconciler reading isReplacingConfig during the $sources emission must see true")
        #expect(sawTrueDuringRoutesEmission, "a reconciler reading isReplacingConfig during the $routes emission must see true")
        #expect(configReplacedCount == 1)
        #expect(!isReplacingConfigWhenConfigReplacedFired, "by the time configReplaced fires, the flag must already be cleared")
        #expect(!state.isReplacingConfig)
    }
}
