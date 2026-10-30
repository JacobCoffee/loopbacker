import Testing
@testable import Loopbacker
import Foundation

@Suite("RoutingMatrixModel")
struct RoutingMatrixModelTests {
    private func mic(_ name: String, channels: Int) -> AudioSource {
        AudioSource(name: name, channels: (1...channels).map { AudioChannel(id: $0, label: "\($0)") })
    }

    private func outputs(_ count: Int) -> [AudioChannel] {
        (1...count).map { AudioChannel(id: $0, label: "\($0)") }
    }

    @Test("Rows are flattened source channels in source order, grouped per source")
    func rowsFollowSourceOrder() {
        let micA = mic("MOTU M2", channels: 2)
        let micB = mic("USB Mic", channels: 1)
        let model = RoutingMatrixModel(sources: [micA, micB], outputChannels: outputs(2), routes: [])

        #expect(model.rows.count == 3)
        #expect(model.rows[0].sourceId == micA.id && model.rows[0].channelId == 1)
        #expect(model.rows[1].sourceId == micA.id && model.rows[1].channelId == 2)
        #expect(model.rows[2].sourceId == micB.id && model.rows[2].channelId == 1)

        let starts = model.groupStarts
        #expect(starts.count == 2)
        #expect(starts[0] == (0, "MOTU M2"))
        #expect(starts[1] == (2, "USB Mic"))
    }

    @Test("An unconnected cell reports not connected and a connect action")
    func disconnectedCellConnects() {
        let micA = mic("MOTU M2", channels: 2)
        let model = RoutingMatrixModel(sources: [micA], outputChannels: outputs(2), routes: [])
        let row = model.rows[0]
        let column = model.columns[0]

        #expect(!model.isConnected(row: row, column: column))
        #expect(model.action(row: row, column: column) == .connect(sourceId: micA.id, sourceChannelId: 1, outputChannelId: 1))
    }

    @Test("A connected cell reports connected and a disconnect action")
    func connectedCellDisconnects() {
        let micA = mic("MOTU M2", channels: 2)
        let route = AudioRoute(sourceId: micA.id, sourceChannelId: 1, outputChannelId: 1)
        let model = RoutingMatrixModel(sources: [micA], outputChannels: outputs(2), routes: [route])
        let row = model.rows[0]
        let column = model.columns[0]

        #expect(model.isConnected(row: row, column: column))
        #expect(model.action(row: row, column: column) == .disconnect(sourceId: micA.id, sourceChannelId: 1, outputChannelId: 1))
    }

    @Test("Multichannel source: connecting one channel never affects its sibling channels")
    func multichannelChannelsAreIndependent() {
        let mic = mic("8-Channel Interface", channels: 8)
        let route = AudioRoute(sourceId: mic.id, sourceChannelId: 3, outputChannelId: 2)
        let model = RoutingMatrixModel(sources: [mic], outputChannels: outputs(2), routes: [route])

        for channel in mic.channels {
            let row = model.rows.first { $0.channelId == channel.id }!
            let column = model.columns[1] // output channel 2
            let expected = channel.id == 3
            #expect(model.isConnected(row: row, column: column) == expected)
        }
    }

    @Test("Stereo pair: left and right source channels route to the matching output columns independently")
    func stereoPairRoutesIndependently() {
        let mic = mic("Stereo Mic", channels: 2)
        let routes = [
            AudioRoute(sourceId: mic.id, sourceChannelId: 1, outputChannelId: 1),
            AudioRoute(sourceId: mic.id, sourceChannelId: 2, outputChannelId: 2)
        ]
        let model = RoutingMatrixModel(sources: [mic], outputChannels: outputs(2), routes: routes)

        let left = model.rows[0]
        let right = model.rows[1]
        let col1 = model.columns[0]
        let col2 = model.columns[1]

        #expect(model.isConnected(row: left, column: col1))
        #expect(!model.isConnected(row: left, column: col2))
        #expect(!model.isConnected(row: right, column: col1))
        #expect(model.isConnected(row: right, column: col2))
    }

    @Test("Two sources with the same channel numbering are not conflated")
    func sameChannelNumberAcrossSourcesStaysDistinct() {
        let micA = mic("MOTU M2", channels: 2)
        let micB = mic("USB Mic", channels: 2)
        let route = AudioRoute(sourceId: micA.id, sourceChannelId: 1, outputChannelId: 1)
        let model = RoutingMatrixModel(sources: [micA, micB], outputChannels: outputs(2), routes: [route])

        let rowA = model.rows.first { $0.sourceId == micA.id && $0.channelId == 1 }!
        let rowB = model.rows.first { $0.sourceId == micB.id && $0.channelId == 1 }!
        let column = model.columns[0]

        #expect(model.isConnected(row: rowA, column: column))
        #expect(!model.isConnected(row: rowB, column: column))
    }

    @Test("A source can fan out to more than one output channel at once")
    func fanOutToMultipleOutputs() {
        let mic = mic("Mono Mic", channels: 1)
        let routes = [
            AudioRoute(sourceId: mic.id, sourceChannelId: 1, outputChannelId: 1),
            AudioRoute(sourceId: mic.id, sourceChannelId: 1, outputChannelId: 2)
        ]
        let model = RoutingMatrixModel(sources: [mic], outputChannels: outputs(2), routes: routes)
        let row = model.rows[0]

        #expect(model.isConnected(row: row, column: model.columns[0]))
        #expect(model.isConnected(row: row, column: model.columns[1]))
    }

    @Test("Accessibility label names the source, input channel, output channel and state")
    func accessibilityLabelWording() {
        let mic = mic("MOTU M2", channels: 1)
        let route = AudioRoute(sourceId: mic.id, sourceChannelId: 1, outputChannelId: 1)
        let model = RoutingMatrixModel(sources: [mic], outputChannels: outputs(1), routes: [route])
        let row = model.rows[0]
        let column = model.columns[0]

        #expect(model.accessibilityLabel(row: row, column: column) == "MOTU M2 input 1 to Loopbacker channel 1, connected")

        let empty = RoutingMatrixModel(sources: [mic], outputChannels: outputs(1), routes: [])
        #expect(empty.accessibilityLabel(row: row, column: column) == "MOTU M2 input 1 to Loopbacker channel 1, not connected")
    }

    @Test("No sources or no output channels produce an empty matrix without crashing")
    func emptyMatrix() {
        let noSources = RoutingMatrixModel(sources: [], outputChannels: outputs(2), routes: [])
        #expect(noSources.rows.isEmpty)
        #expect(noSources.columns.count == 2)

        let noOutputs = RoutingMatrixModel(sources: [mic("MOTU M2", channels: 2)], outputChannels: [], routes: [])
        #expect(noOutputs.rows.count == 2)
        #expect(noOutputs.columns.isEmpty)
    }
}
