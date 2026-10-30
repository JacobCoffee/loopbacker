import SwiftUI

// MARK: - View mode

/// Which routing surface is shown: the cable canvas (mouse-first) or the connection matrix
/// (keyboard- and VoiceOver-first). Persisted via `AppStorage` so the choice survives relaunch.
enum RoutingViewMode: String, CaseIterable, Identifiable {
    case canvas, matrix

    static let storageKey = "routingViewMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .canvas: "Canvas"
        case .matrix: "Matrix"
        }
    }

    var symbol: String {
        switch self {
        case .canvas: "cable.connector"
        case .matrix: "grid"
        }
    }
}

// MARK: - Matrix view

/// Alternative to `RoutingCanvasView`'s cable canvas: source channels as rows, virtual-mic
/// channels as columns, each cell a togglable connection. Fully keyboard-navigable (arrow keys
/// move focus between cells, Space/Return toggles the focused one) and VoiceOver-friendly since
/// every cell is a real `Button` with a descriptive label, rather than a tap gesture on a shape.
///
/// Reads `RoutingMatrixModel` for the row/column layout and connection state, and applies cell
/// toggles through `RoutingState.addRoute`/`removeRouteBetween` — the same APIs the cable canvas
/// uses — so routes created here sync through `RoutingSync` identically to cable-drawn ones.
struct RoutingMatrixView: View {
    @EnvironmentObject var routingState: RoutingState

    private struct CellCoordinate: Hashable {
        let row: Int
        let column: Int
    }

    @FocusState private var focusedCell: CellCoordinate?
    @Environment(\.colorSchemeContrast) private var contrast
    /// Which virtual device's channels are the columns. Only selectable while Stream Mix is
    /// shown; otherwise the matrix always edits the virtual mic.
    @State private var selectedTarget: RouteTarget = .virtualMic

    private var target: RouteTarget {
        routingState.streamMixEnabled ? selectedTarget : .virtualMic
    }

    private var model: RoutingMatrixModel {
        RoutingMatrixModel(
            sources: routingState.sources,
            outputChannels: target == .virtualMic ? routingState.outputChannels : routingState.streamOutputChannels,
            routes: routingState.routes,
            target: target
        )
    }

    var body: some View {
        let model = self.model
        VStack(alignment: .leading, spacing: Metrics.panelSpacing) {
            if routingState.streamMixEnabled {
                Picker("Target", selection: $selectedTarget) {
                    Text("Virtual Mic").tag(RouteTarget.virtualMic)
                    Text("Stream Mix").tag(RouteTarget.streamMix)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            Group {
                if model.rows.isEmpty {
                    EmptyStateView(
                        title: "No Sources",
                        message: "Add a source from the toolbar to route it here",
                        symbol: "grid"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.columns.isEmpty {
                    EmptyStateView(
                        title: "No Output Channels",
                        message: target == .virtualMic
                            ? "The virtual mic has no channels to route to"
                            : "Stream Mix has no channels to route to",
                        symbol: "grid"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    matrix(model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .padding(Metrics.canvasMargin)
        .backgroundExtensionEffect()
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        let n = routingState.routes.count
        return n == 0 ? "No routes · 48 kHz" : "\(n) route\(n == 1 ? "" : "s") · 48 kHz"
    }

    // MARK: - Grid

    @ViewBuilder
    private func matrix(_ model: RoutingMatrixModel) -> some View {
        let groupStarts = Dictionary(uniqueKeysWithValues: model.groupStarts.map { ($0.rowIndex, $0.sourceName) })

        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    Color.clear.frame(width: 180, height: 1).accessibilityHidden(true)
                    ForEach(model.columns) { column in
                        Text("Ch \(column.channelLabel)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 48)
                            .accessibilityHidden(true) // conveyed per-cell instead
                    }
                }

                ForEach(Array(model.rows.enumerated()), id: \.element.id) { rowIndex, row in
                    if let sourceName = groupStarts[rowIndex] {
                        GridRow {
                            Text(sourceName)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Color.loopbacker)
                                .gridCellColumns(model.columns.count + 1)
                                .accessibilityAddTraits(.isHeader)
                        }
                        .padding(.top, rowIndex == 0 ? 0 : 10)
                    }

                    GridRow {
                        Text("Input \(row.channelLabel)")
                            .font(.callout.monospacedDigit())
                            .frame(width: 180, alignment: .leading)
                            .lineLimit(1)
                            .accessibilityHidden(true) // conveyed per-cell instead

                        ForEach(Array(model.columns.enumerated()), id: \.element.id) { columnIndex, column in
                            cell(model: model, row: row, column: column, rowIndex: rowIndex, columnIndex: columnIndex)
                        }
                    }
                }
            }
            .padding(Metrics.panelPadding)
        }
        .glassPanel()
        .onKeyPress(.leftArrow) { moveFocus(dRow: 0, dColumn: -1, model: model); return .handled }
        .onKeyPress(.rightArrow) { moveFocus(dRow: 0, dColumn: 1, model: model); return .handled }
        .onKeyPress(.upArrow) { moveFocus(dRow: -1, dColumn: 0, model: model); return .handled }
        .onKeyPress(.downArrow) { moveFocus(dRow: 1, dColumn: 0, model: model); return .handled }
    }

    // MARK: - Cell
    private func cell(model: RoutingMatrixModel, row: RoutingMatrixModel.Row, column: RoutingMatrixModel.Column,
                       rowIndex: Int, columnIndex: Int) -> some View {
        let connected = model.isConnected(row: row, column: column)
        let highContrast = contrast == .increased

        return Button {
            apply(model.action(row: row, column: column))
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(connected ? Color.loopbacker.opacity(highContrast ? 0.32 : 0.18) : Color.secondary.opacity(highContrast ? 0.16 : 0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                connected ? Color.loopbacker : Color.secondary.opacity(highContrast ? 0.6 : 0.3),
                                lineWidth: connected ? 1.5 : (highContrast ? 1.5 : 1)
                            )
                    )

                // Shape, not just color, carries the connected state (Differentiate Without Color).
                if connected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.loopbacker)
                }
            }
            .frame(width: 48, height: 28)
        }
        .buttonStyle(.plain)
        .focused($focusedCell, equals: CellCoordinate(row: rowIndex, column: columnIndex))
        .accessibilityLabel(model.accessibilityLabel(row: row, column: column))
        .accessibilityAddTraits(.isButton)
        .help(connected
            ? "Disconnect \(row.sourceName) input \(row.channelLabel) from channel \(column.channelLabel)"
            : "Connect \(row.sourceName) input \(row.channelLabel) to channel \(column.channelLabel)")
    }

    // MARK: - Mutations

    /// Applies a cell's toggle through `RoutingState`'s own route APIs, so matrix-created routes
    /// sync exactly like cable-drawn ones.
    private func apply(_ action: RoutingMatrixModel.CellAction) {
        switch action {
        case .connect(let sourceId, let sourceChannelId, let target, let outputChannelId):
            routingState.addRoute(sourceId: sourceId, sourceChannelId: sourceChannelId, targetId: target,
                                  outputChannelId: outputChannelId)
        case .disconnect(let sourceId, let sourceChannelId, let target, let outputChannelId):
            routingState.removeRouteBetween(
                from: .source(sourceId: sourceId, channelId: sourceChannelId),
                to: .output(target: target, channelId: outputChannelId)
            )
        }
    }

    // MARK: - Keyboard navigation

    private func moveFocus(dRow: Int, dColumn: Int, model: RoutingMatrixModel) {
        guard !model.rows.isEmpty, !model.columns.isEmpty else { return }
        let current = focusedCell ?? CellCoordinate(row: 0, column: 0)
        let newRow = min(max(current.row + dRow, 0), model.rows.count - 1)
        let newColumn = min(max(current.column + dColumn, 0), model.columns.count - 1)
        focusedCell = CellCoordinate(row: newRow, column: newColumn)
    }
}
