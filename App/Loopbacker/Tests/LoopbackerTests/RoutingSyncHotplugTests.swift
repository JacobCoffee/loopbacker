import Foundation
import Testing
@testable import Loopbacker

/// Regression coverage for the hotplug channel-clamping defect: `RoutingSync`'s `$systemDevices`
/// sink used to call `syncAudioRouting`, which re-read `audioDeviceManager.systemDevices` to
/// build the channel-clamp lookup instead of using the sink's own `devices` parameter. `@Published`
/// sends on `willSet`, so at the moment that sink runs the backing storage is still the
/// pre-hotplug inventory -- a newly connected mono fallback wasn't in it yet, `deviceChannelCount`
/// came back `nil`, clamping was skipped, and a route built for a wider device kept reading past
/// the end of the mono device's one channel (silence).
///
/// `AudioRouter`'s CoreAudio side effects aren't testable here (no mock seam, real hardware
/// queue), so this exercises the actual `AudioDeviceManager.$systemDevices` publisher -- the same
/// one `RoutingSync.observe()` subscribes to -- and the extracted `RoutingDesiredState.mixRoutes`
/// helper `RoutingSync.syncAudioRouting` now calls with the sink's emitted inventory. It proves,
/// through the real Combine publisher, that reading the property inside the sink is stale and
/// that using the emitted value instead produces the correct clamp.
@MainActor
@Suite("RoutingSync hotplug channel clamping")
struct RoutingSyncHotplugTests {
    private func device(uid: String, name: String, inputChannelCount: Int) -> SystemAudioDevice {
        SystemAudioDevice(id: 0, uid: uid, name: name, inputChannelCount: inputChannelCount, outputChannelCount: 0,
                           isInput: true, isOutput: false)
    }

    @Test("Reading `$systemDevices`'s stored property inside its own sink still sees the pre-hotplug inventory")
    func publishedEmitsBeforeStorageUpdates() throws {
        let manager = AudioDeviceManager()
        manager.systemDevices = [] // deterministic starting point, overriding any in-flight real enumeration

        var sawInsideSink: (emitted: [SystemAudioDevice], storedProperty: [SystemAudioDevice])?
        let cancellable = manager.$systemDevices
            .dropFirst()
            .sink { emitted in
                sawInsideSink = (emitted, manager.systemDevices)
            }

        let mono = device(uid: "fallback-uid", name: "Built-in Mic", inputChannelCount: 1)
        manager.systemDevices = [mono]

        let seen = try #require(sawInsideSink)
        #expect(seen.emitted.map(\.uid) == ["fallback-uid"])
        // The previously mishandled `@Published` timing: inside the sink the backing storage
        // hasn't been updated yet, so reading the property instead of using the emitted value
        // would still see the pre-hotplug (empty) inventory.
        #expect(seen.storedProperty.isEmpty)

        cancellable.cancel()
    }

    @Test("The sink's emitted inventory clamps a newly connected mono fallback; the stale property misses it")
    func mixRoutesUsesEmittedInventoryNotStaleProperty() throws {
        let manager = AudioDeviceManager()
        manager.systemDevices = []

        let source = AudioSource(
            name: "Interface",
            channels: [AudioChannel(id: 1, label: "1"), AudioChannel(id: 2, label: "2")],
            deviceUID: "fallback-uid"
        )
        // Built against a 2-channel device (reads source channel 2).
        let routes = [AudioRoute(sourceId: source.id, sourceChannelId: 2, outputChannelId: 1)]

        var mixWithEmitted: [(srcCh: Int, dstCh: Int)]?
        var mixWithStaleProperty: [(srcCh: Int, dstCh: Int)]?
        let cancellable = manager.$systemDevices
            .dropFirst()
            .sink { emitted in
                mixWithEmitted = RoutingDesiredState.mixRoutes(for: source, routes: routes, devices: emitted)
                mixWithStaleProperty = RoutingDesiredState.mixRoutes(for: source, routes: routes, devices: manager.systemDevices)
            }

        // The fallback that just connected only has 1 channel.
        manager.systemDevices = [device(uid: "fallback-uid", name: "Built-in Mic", inputChannelCount: 1)]

        let emitted = try #require(mixWithEmitted)
        #expect(emitted.count == 1)
        // Clamped onto the mono device's only channel -- correct, uses the emitted inventory.
        #expect(emitted.first?.srcCh == 1)
        #expect(emitted.first?.dstCh == 1)

        let stale = try #require(mixWithStaleProperty)
        #expect(stale.count == 1)
        // This is the defect being guarded against: reading the stale (still-empty) property
        // finds no device for "fallback-uid", so `deviceChannelCount` is `nil` and no clamp is
        // applied -- the route keeps reading channel 2 of a 1-channel device (silence), despite
        // the device having just connected.
        #expect(stale.first?.srcCh == 2)
        #expect(stale.first?.dstCh == 1)

        cancellable.cancel()
    }
}
