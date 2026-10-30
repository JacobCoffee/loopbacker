import Foundation
import Testing
@testable import Loopbacker

/// Covers decoding/migration of the Stream Mix fields added to `RoutingConfig`/`AudioRoute`,
/// and the per-(source, target) route grouping `RoutingSync`/`AudioRouter` rely on.
@Suite("Stream Mix routing")
struct StreamMixRoutingTests {
    // MARK: - AudioRoute decoding

    @Test("A route saved before Stream Mix existed (no targetId) decodes as the virtual mic")
    func routeMissingTargetDecodesAsVirtualMic() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","sourceId":"00000000-0000-0000-0000-000000000002",
         "sourceChannelId":1,"outputChannelId":1}
        """
        let route = try JSONDecoder().decode(AudioRoute.self, from: json.data(using: .utf8)!)
        #expect(route.targetId == .virtualMic)
        #expect(route.sourceChannelId == 1)
        #expect(route.outputChannelId == 1)
    }

    @Test("A route with an explicit targetId round-trips through encode/decode")
    func routeWithTargetRoundTrips() throws {
        let route = AudioRoute(sourceId: UUID(), sourceChannelId: 2, targetId: .streamMix, outputChannelId: 3)
        let data = try JSONEncoder().encode(route)
        let decoded = try JSONDecoder().decode(AudioRoute.self, from: data)
        #expect(decoded.targetId == .streamMix)
        #expect(decoded.sourceChannelId == 2)
        #expect(decoded.outputChannelId == 3)
    }

    @Test("RouteTarget.deviceUID matches the driver's device UIDs")
    func routeTargetDeviceUIDs() {
        #expect(RouteTarget.virtualMic.deviceUID == "LoopbackerDevice_UID")
        #expect(RouteTarget.streamMix.deviceUID == "LoopbackerDevice_UID_Stream")
    }

    // MARK: - RoutingConfig decoding/migration

    @Test("A RoutingConfig saved before Stream Mix existed decodes with Stream Mix hidden and empty")
    func routingConfigMissingStreamFieldsDecodesHidden() throws {
        let json = """
        {
          "sources": [],
          "outputChannels": [{"id":1,"label":"1 (L)","volume":1,"isActive":true}],
          "routes": []
        }
        """
        let config = try JSONDecoder().decode(RoutingConfig.self, from: json.data(using: .utf8)!)
        #expect(config.streamMixEnabled == false)
        #expect(config.streamOutputChannels.isEmpty)
        #expect(config.outputChannels.count == 1)
    }

    @Test("A RoutingConfig with Stream Mix enabled round-trips its channels and routes")
    func routingConfigWithStreamMixRoundTrips() throws {
        let sourceId = UUID()
        let config = RoutingConfig(
            sources: [],
            outputChannels: [AudioChannel(id: 1, label: "1 (L)"), AudioChannel(id: 2, label: "2 (R)")],
            streamOutputChannels: [AudioChannel(id: 1, label: "1 (L)"), AudioChannel(id: 2, label: "2 (R)")],
            streamMixEnabled: true,
            routes: [
                AudioRoute(sourceId: sourceId, sourceChannelId: 1, targetId: .virtualMic, outputChannelId: 1),
                AudioRoute(sourceId: sourceId, sourceChannelId: 1, targetId: .streamMix, outputChannelId: 1),
            ]
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(RoutingConfig.self, from: data)
        #expect(decoded.streamMixEnabled == true)
        #expect(decoded.streamOutputChannels.count == 2)
        #expect(decoded.routes.count == 2)
        #expect(Set(decoded.routes.map(\.targetId)) == [.virtualMic, .streamMix])
    }

    // MARK: - RoutingState: Stream Mix channel model mirrors the virtual mic's

    @MainActor
    @Test("Enabling Stream Mix seeds a default stereo pair; disabling keeps it")
    func enablingStreamMixSeedsChannels() {
        let state = RoutingState.empty()
        #expect(state.streamOutputChannels.isEmpty)
        state.setStreamMixEnabled(true)
        #expect(state.streamMixEnabled)
        #expect(state.streamOutputChannels.map(\.id) == [1, 2])
        state.setStreamMixEnabled(false)
        // Hiding the column keeps the channels (and any routes into them) intact.
        #expect(state.streamOutputChannels.map(\.id) == [1, 2])
        #expect(state.streamMixEnabled == false)
    }

    @MainActor
    @Test("Adding/removing a Stream Mix channel pair never touches the virtual mic's channels")
    func streamMixChannelPairsAreIndependent() {
        let state = RoutingState.empty()
        let micChannelsBefore = state.outputChannels.count
        state.setStreamMixEnabled(true)
        state.addStreamOutputChannelPair()
        #expect(state.streamOutputChannels.count == 4)
        #expect(state.outputChannels.count == micChannelsBefore)

        state.removeLastStreamOutputChannelPair()
        #expect(state.streamOutputChannels.count == 2)
        #expect(state.outputChannels.count == micChannelsBefore)
    }

    // MARK: - Route grouping by (source, target)

    @MainActor
    @Test("A source can route into the virtual mic and Stream Mix independently")
    func sourceCanRouteToBothTargets() {
        let state = RoutingState.empty()
        state.setStreamMixEnabled(true)
        let sourceId = UUID()

        state.addRoute(sourceId: sourceId, sourceChannelId: 1, targetId: .virtualMic, outputChannelId: 1)
        state.addRoute(sourceId: sourceId, sourceChannelId: 1, targetId: .streamMix, outputChannelId: 1)

        let micRoutes = state.routes.filter { $0.sourceId == sourceId && $0.targetId == .virtualMic }
        let streamRoutes = state.routes.filter { $0.sourceId == sourceId && $0.targetId == .streamMix }
        #expect(micRoutes.count == 1)
        #expect(streamRoutes.count == 1)
        #expect(state.routes.count == 2)
    }

    @MainActor
    @Test("Removing the virtual mic's output channel only drops virtual mic routes")
    func removingVirtualMicChannelLeavesStreamMixRoutesIntact() {
        let state = RoutingState.empty()
        state.setStreamMixEnabled(true)
        let sourceId = UUID()
        state.addRoute(sourceId: sourceId, sourceChannelId: 1, targetId: .virtualMic, outputChannelId: 1)
        state.addRoute(sourceId: sourceId, sourceChannelId: 1, targetId: .streamMix, outputChannelId: 1)

        state.removeOutputChannel(1)

        #expect(state.routes.contains { $0.targetId == .streamMix && $0.outputChannelId == 1 })
        #expect(!state.routes.contains { $0.targetId == .virtualMic })
    }

    @MainActor
    @Test("Removing a Stream Mix channel only drops Stream Mix routes")
    func removingStreamMixChannelLeavesVirtualMicRoutesIntact() {
        let state = RoutingState.empty()
        state.setStreamMixEnabled(true)
        let sourceId = UUID()
        state.addRoute(sourceId: sourceId, sourceChannelId: 1, targetId: .virtualMic, outputChannelId: 1)
        state.addRoute(sourceId: sourceId, sourceChannelId: 1, targetId: .streamMix, outputChannelId: 1)

        state.removeStreamOutputChannel(1)

        #expect(state.routes.contains { $0.targetId == .virtualMic && $0.outputChannelId == 1 })
        #expect(!state.routes.contains { $0.targetId == .streamMix })
    }

    @Test("ConnectorEnd.output hashes/equates by target, so the two columns' channel 1 never collide")
    func connectorEndDistinguishesTargets() {
        let micEnd = ConnectorEnd.output(target: .virtualMic, channelId: 1)
        let streamEnd = ConnectorEnd.output(target: .streamMix, channelId: 1)
        #expect(micEnd != streamEnd)

        var positions: [ConnectorEnd: Int] = [:]
        positions[micEnd] = 10
        positions[streamEnd] = 20
        #expect(positions[micEnd] == 10)
        #expect(positions[streamEnd] == 20)
    }
}
