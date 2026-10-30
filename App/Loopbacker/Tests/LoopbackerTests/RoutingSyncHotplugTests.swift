import Foundation
import Testing
@testable import Loopbacker

/// `RoutingSync` builds each source's channel mix with `RoutingDesiredState.mixRoutes`, passing
/// the inventory its `$systemDevices` sink just received (the published property itself is still
/// the pre-hotplug value inside that sink). These cover the clamp that mix applies when a source
/// lands on a narrower fallback device.
@Suite("RoutingDesiredState.mixRoutes channel clamping")
struct RoutingSyncHotplugTests {
    private func device(uid: String, inputChannelCount: Int) -> SystemAudioDevice {
        SystemAudioDevice(id: 0, uid: uid, name: uid, inputChannelCount: inputChannelCount, outputChannelCount: 0,
                          isInput: true, isOutput: false)
    }

    private let source = AudioSource(
        name: "Interface",
        channels: [AudioChannel(id: 1, label: "1"), AudioChannel(id: 2, label: "2")],
        deviceUID: "fallback-uid"
    )

    @Test("A route reading input 2 clamps onto the only channel of a newly connected mono device")
    func clampsOntoMonoFallback() {
        let routes = [AudioRoute(sourceId: source.id, sourceChannelId: 2, outputChannelId: 1)]
        let mix = RoutingDesiredState.mixRoutes(
            for: source, routes: routes, devices: [device(uid: "fallback-uid", inputChannelCount: 1)]
        )
        #expect(mix.map(\.srcCh) == [1])
        #expect(mix.map(\.dstCh) == [1])
    }

    @Test("The same routes keep their channels on a device wide enough for them")
    func keepsChannelsOnWideDevice() {
        let routes = [
            AudioRoute(sourceId: source.id, sourceChannelId: 1, outputChannelId: 1),
            AudioRoute(sourceId: source.id, sourceChannelId: 2, outputChannelId: 2),
        ]
        let mix = RoutingDesiredState.mixRoutes(
            for: source, routes: routes, devices: [device(uid: "fallback-uid", inputChannelCount: 2)]
        )
        #expect(mix.map(\.srcCh).sorted() == [1, 2])
        #expect(mix.map(\.dstCh).sorted() == [1, 2])
    }
}
