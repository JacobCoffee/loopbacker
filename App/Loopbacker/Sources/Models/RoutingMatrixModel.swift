import Foundation

/// Pure mapping from routing state to a keyboard-navigable connection matrix: source channels
/// as rows (grouped by source, in source order), virtual-mic output channels as columns.
///
/// Deliberately holds no reference to `RoutingState`: it only reads plain `AudioSource` /
/// `AudioChannel` / `AudioRoute` values and reports what a cell toggle *should* do as a
/// `CellAction`, rather than mutating anything itself. The view applies that action through
/// `RoutingState`'s own `addRoute`/`removeRouteBetween` APIs, so routes created from the matrix
/// sync exactly like ones created by dragging a cable, and this type can be unit tested without
/// touching `RoutingState.save()` (which writes the user's real config to disk).
struct RoutingMatrixModel: Equatable {
    struct Row: Identifiable, Equatable, Hashable {
        let sourceId: UUID
        let sourceName: String
        let channelId: Int
        let channelLabel: String

        var id: String { "\(sourceId)#\(channelId)" }
    }

    struct Column: Identifiable, Equatable, Hashable {
        let channelId: Int
        let channelLabel: String

        var id: Int { channelId }
    }

    /// What a cell's toggle (Space, click, or the matrix's own tap handler) should do to
    /// routing state. The caller applies this through `RoutingState`.
    enum CellAction: Equatable {
        case connect(sourceId: UUID, sourceChannelId: Int, outputChannelId: Int)
        case disconnect(sourceId: UUID, sourceChannelId: Int, outputChannelId: Int)
    }

    let rows: [Row]
    let columns: [Column]

    private struct RouteKey: Hashable {
        let sourceId: UUID
        let sourceChannelId: Int
        let outputChannelId: Int
    }

    private let routeSet: Set<RouteKey>

    init(sources: [AudioSource], outputChannels: [AudioChannel], routes: [AudioRoute]) {
        rows = sources.flatMap { source in
            source.channels.map { channel in
                Row(sourceId: source.id, sourceName: source.name, channelId: channel.id, channelLabel: channel.label)
            }
        }
        columns = outputChannels.map { Column(channelId: $0.id, channelLabel: $0.label) }
        routeSet = Set(routes.map {
            RouteKey(sourceId: $0.sourceId, sourceChannelId: $0.sourceChannelId, outputChannelId: $0.outputChannelId)
        })
    }

    func isConnected(row: Row, column: Column) -> Bool {
        routeSet.contains(RouteKey(sourceId: row.sourceId, sourceChannelId: row.channelId, outputChannelId: column.channelId))
    }

    /// The action toggling this cell should perform: disconnect if it's already routed,
    /// otherwise connect.
    func action(row: Row, column: Column) -> CellAction {
        isConnected(row: row, column: column)
            ? .disconnect(sourceId: row.sourceId, sourceChannelId: row.channelId, outputChannelId: column.channelId)
            : .connect(sourceId: row.sourceId, sourceChannelId: row.channelId, outputChannelId: column.channelId)
    }

    /// "MOTU M2 input 1 to Loopbacker channel 1, connected" — read by VoiceOver for the cell.
    func accessibilityLabel(row: Row, column: Column) -> String {
        let state = isConnected(row: row, column: column) ? "connected" : "not connected"
        return "\(row.sourceName) input \(row.channelLabel) to Loopbacker channel \(column.channelLabel), \(state)"
    }

    /// Row indices (into `rows`) where a new group starts, keyed by that row's source name —
    /// used by the view to insert a source header before the first channel of each source.
    var groupStarts: [(rowIndex: Int, sourceName: String)] {
        var result: [(Int, String)] = []
        var lastSourceId: UUID?
        for (index, row) in rows.enumerated() where row.sourceId != lastSourceId {
            result.append((index, row.sourceName))
            lastSourceId = row.sourceId
        }
        return result
    }
}
