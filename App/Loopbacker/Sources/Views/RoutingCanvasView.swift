import SwiftUI

/// The Routing section's canvas: sources on the left, virtual-mic output channels and
/// output routing on the right, with glowing cables drawn beneath the glass cards.
struct RoutingCanvasView: View {
    let onAddSource: () -> Void

    @EnvironmentObject var routingState: RoutingState
    @State private var connectorPositions: [ConnectorEnd: CGRect] = [:]

    private var routeCount: Int { routingState.routes.count }

    var body: some View {
        ZStack {
            gridBackground
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation { routingState.cancelPendingConnection() }
                }

            CableView(connectorPositions: connectorPositions)

            canvasContent
                .padding(Metrics.canvasMargin)

            pendingHint
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .backgroundExtensionEffect()
        .coordinateSpace(name: "routing")
        .onPreferenceChange(ConnectorPositionKey.self) { positions in
            self.connectorPositions = positions
        }
        .onExitCommand {
            routingState.cancelPendingConnection()
        }
        .navigationSubtitle(routeCount == 0 ? "No routes · 48 kHz" : "\(routeCount) route\(routeCount == 1 ? "" : "s") · 48 kHz")
    }

    // MARK: - Layout

    private var canvasContent: some View {
        HStack(alignment: .top, spacing: 0) {
            sourcesColumn
                .frame(minWidth: 280, idealWidth: 360, maxWidth: 440)

            Spacer(minLength: 64)

            ScrollView(.vertical) {
                VStack(alignment: .trailing, spacing: Metrics.panelSpacing) {
                    outputHeader
                    outputColumn
                    if routingState.streamMixEnabled {
                        streamMixHeader
                        streamMixColumn
                    }
                    outputRoutingSection
                }
                .padding(.bottom, Metrics.canvasMargin)
            }
            .frame(minWidth: 300, idealWidth: 360, maxWidth: 420)
        }
    }

    // MARK: - Sources column

    private var sourcesColumn: some View {
        VStack(alignment: .leading, spacing: Metrics.panelSpacing) {
            HStack(spacing: 8) {
                Text("Sources")
                    .font(.headline)

                Spacer()

                if !routingState.sources.isEmpty {
                    Text(sourceCountLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if routingState.sources.isEmpty {
                emptySourcesPlaceholder
            } else {
                ScrollView(.vertical) {
                    GlassEffectContainer(spacing: Metrics.panelSpacing) {
                        VStack(spacing: Metrics.panelSpacing) {
                            ForEach($routingState.sources) { $source in
                                SourceCardView(source: $source)
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            withAnimation { routingState.removeSource(source.id) }
                                        } label: {
                                            Label("Remove \(source.name)", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                }
            }
        }
    }

    private var sourceCountLabel: String {
        let deviceCount = routingState.sources.filter { !$0.isAppCapture }.count
        let appCount = routingState.sources.filter { $0.isAppCapture }.count
        let parts = [
            deviceCount > 0 ? "\(deviceCount) device\(deviceCount == 1 ? "" : "s")" : nil,
            appCount > 0 ? "\(appCount) app\(appCount == 1 ? "" : "s")" : nil,
        ].compactMap { $0 }
        return parts.joined(separator: ", ")
    }

    private var emptySourcesPlaceholder: some View {
        EmptyStateView(
            title: "No Sources",
            message: "Click + to add an audio source",
            symbol: "plus.circle.dashed"
        ) {
            Button("Add Source", action: onAddSource)
                .buttonStyle(.glassProminent)
                .tint(.loopbacker)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - Virtual Mic header + column

    /// The canvas header for the output side: the Virtual Mic title plus the Stream Mix toggle
    /// (so it's visible whether or not Stream Mix is currently shown).
    private var outputHeader: some View {
        HStack {
            Text("Virtual Mic")
                .font(.headline)
            Spacer()
            streamMixToggle
            Text("Loopbacker")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var outputColumn: some View {
        OutputChannelView(target: .virtualMic)
    }

    // MARK: - Stream Mix header + column

    private var streamMixHeader: some View {
        HStack {
            Text("Stream Mix")
                .font(.headline)
            Spacer()
            Text("Loopbacker Stream")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, Metrics.panelSpacing)
    }

    private var streamMixColumn: some View {
        OutputChannelView(target: .streamMix)
    }

    /// Shows/hides the Stream Mix column. Off by default: existing users see no change until
    /// they opt in here.
    private var streamMixToggle: some View {
        Toggle(isOn: Binding(
            get: { routingState.streamMixEnabled },
            set: { routingState.setStreamMixEnabled($0) }
        )) {
            Label("Stream Mix", systemImage: "music.mic")
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .labelsHidden()
        .help("Show a second virtual mic (\"Stream Mix\") you can route sources into separately, e.g. for OBS.")
    }

    // MARK: - Output routing section

    private var outputRoutingSection: some View {
        OutputRoutingView()
    }

    // MARK: - Pending connection hint

    @ViewBuilder
    private var pendingHint: some View {
        if routingState.pendingConnector != nil {
            VStack {
                Spacer()
                Text("Click a channel to connect, or Esc to cancel")
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(Glass.regular, in: .capsule)
                    .padding(.bottom, Metrics.canvasMargin)
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .animation(.easeOut(duration: 0.2), value: routingState.pendingConnector)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Grid background

    private var gridBackground: some View {
        Canvas { context, size in
            let spacing: CGFloat = 24
            let dotSize: CGFloat = 1.2

            var dots = Path()
            var y: CGFloat = spacing / 2
            while y < size.height {
                var x: CGFloat = spacing / 2
                while x < size.width {
                    dots.addEllipse(in: CGRect(x: x - dotSize / 2, y: y - dotSize / 2, width: dotSize, height: dotSize))
                    x += spacing
                }
                y += spacing
            }
            context.fill(dots, with: .color(Color.secondary.opacity(0.18)))
        }
    }
}
