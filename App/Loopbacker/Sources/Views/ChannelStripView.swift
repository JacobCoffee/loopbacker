import SwiftUI

// MARK: - Channel strip (meter bar + label + connector port)

struct ChannelStripView: View {
    let channel: AudioChannel
    let side: StripSide
    let isSourceEnabled: Bool
    var connectorEnd: ConnectorEnd
    @EnvironmentObject var routingState: RoutingState

    enum StripSide {
        case source  // connector port on right
        case output  // connector port on left
    }

    private var isConnected: Bool {
        switch connectorEnd {
        case .source(let sid, let ch):
            return routingState.routes.contains { $0.sourceId == sid && $0.sourceChannelId == ch }
        case .output(let ch):
            return routingState.routes.contains { $0.outputChannelId == ch }
        }
    }

    private var isPending: Bool {
        routingState.pendingConnector == connectorEnd
    }

    var body: some View {
        HStack(spacing: 8) {
            if side == .output {
                connectorPort
            }

            Text(channel.label)
                .font(.callout.monospacedDigit())
                .foregroundStyle(isSourceEnabled ? .primary : .tertiary)
                .frame(width: 44, alignment: side == .source ? .leading : .trailing)

            SignalMeter(level: isSourceEnabled ? channel.meterLevel : 0, axis: .horizontal, thickness: 6)
                .frame(height: 16)

            if side == .source {
                connectorPort
            }
        }
        .frame(height: 28)
    }

    // MARK: - Connector port

    private var connectorPort: some View {
        ConnectorPortView(isConnected: isConnected, isPending: isPending)
            .onTapGesture { handleTap() }
            .contextMenu {
                if isConnected {
                    Button(role: .destructive) {
                        withAnimation {
                            routingState.removeRoutesFor(connector: connectorEnd)
                        }
                    } label: {
                        Label("Disconnect All", systemImage: "xmark.circle")
                    }
                }
            }
            .help(isConnected
                ? "Click to start a new route from this channel, right-click to disconnect all routes"
                : "Click to connect this channel to a source or output")
            .accessibilityLabel(Text(channel.label + " connector"))
            .accessibilityValue(Text(isConnected ? "Connected" : (isPending ? "Pending" : "Not connected")))
            .accessibilityAddTraits(.isButton)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .preference(
                            key: ConnectorPositionKey.self,
                            value: [connectorEnd: geo.frame(in: .named("routing"))]
                        )
                }
            )
    }

    private func handleTap() {
        withAnimation(.easeInOut(duration: 0.15)) {
            if routingState.pendingConnector == connectorEnd {
                routingState.cancelPendingConnection()
            } else if let pending = routingState.pendingConnector {
                let existingRoute = routingState.findRoute(from: pending, to: connectorEnd)
                if existingRoute != nil {
                    routingState.removeRouteBetween(from: pending, to: connectorEnd)
                    routingState.cancelPendingConnection()
                } else {
                    routingState.handleConnectorTap(connectorEnd)
                }
            } else {
                routingState.handleConnectorTap(connectorEnd)
            }
        }
    }
}

// MARK: - Connector port visual

/// A small glassy patch-bay port: hollow ring idle, filled green when connected,
/// pulsing ring when a connection is pending (respects Reduce Motion).
private struct ConnectorPortView: View {
    let isConnected: Bool
    let isPending: Bool

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isPending {
                Circle()
                    .stroke(Color.loopbacker.opacity(0.5), lineWidth: 1.5)
                    .frame(width: pulse && !reduceMotion ? 22 : 14, height: pulse && !reduceMotion ? 22 : 14)
                    .opacity(pulse && !reduceMotion ? 0 : 1)
            }

            Circle()
                .fill(isConnected ? Color.loopbacker : Color.clear)
                .overlay(
                    Circle().strokeBorder(isConnected ? Color.clear : Color.secondary.opacity(0.5), lineWidth: 1.25)
                )
                .frame(width: 12, height: 12)

            if isConnected {
                Circle()
                    .fill(.white.opacity(0.9))
                    .frame(width: 4, height: 4)
            }
        }
        .frame(width: 20, height: 20)
        .contentShape(Circle().inset(by: -4))
        .onAppear { startPulse() }
        .onChange(of: isPending) { _, _ in startPulse() }
    }

    private func startPulse() {
        pulse = false
        guard isPending, !reduceMotion else { return }
        withAnimation(.easeOut(duration: 0.9).repeatForever(autoreverses: false)) { pulse = true }
    }
}

// MARK: - Preference key for connector positions

struct ConnectorPositionKey: PreferenceKey {
    static let defaultValue: [ConnectorEnd: CGRect] = [:]

    static func reduce(value: inout [ConnectorEnd: CGRect], nextValue: () -> [ConnectorEnd: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// ConnectorEnd already conforms to Hashable via its Equatable+Hashable declaration in AudioRoute.swift
