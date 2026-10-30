import SwiftUI

// MARK: - Channel strip (meter bar + label + connector port)

struct ChannelStripView: View {
    let channel: AudioChannel
    let side: StripSide
    let isSourceEnabled: Bool
    var connectorEnd: ConnectorEnd
    @EnvironmentObject var routingState: RoutingState
    @Environment(MeterLevels.self) private var meters

    /// Polled (not observed) at low frequency only while connected, so VoiceOver's accessibility
    /// value can include a live dB reading without the per-tick SwiftUI re-render `MeterLevels`'
    /// doc comment warns about -- reading `meters` here happens outside a SwiftUI body, so it
    /// never registers Observation tracking; only the explicit `liveLevelText` write does.
    @State private var liveLevelText: String = "Silent"

    enum StripSide {
        /// Connector port on the right; meter reads the source's route key (`AudioSource.deviceUID`).
        case source(meterKey: String)
        /// Connector port on the left; meter reads the virtual mic's post-mix level.
        case output
    }

    private var isSourceSide: Bool {
        if case .source = side { return true }
        return false
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
            if !isSourceSide {
                connectorPort
            }

            Text(channel.label)
                .font(.callout.monospacedDigit())
                .foregroundStyle(isSourceEnabled ? .primary : .tertiary)
                .frame(width: 44, alignment: isSourceSide ? .leading : .trailing)

            ChannelLevelMeter(side: side, channel: channel.id, isLive: isSourceEnabled)
                .frame(height: 16)

            if isSourceSide {
                connectorPort
            }
        }
        .frame(height: 28)
    }

    /// Restarts (or stops) the live-level poll when either the connection state or the shared
    /// meter-window-visibility signal changes.
    private struct LivePollKey: Equatable {
        let connected: Bool
        let visible: Bool
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
            .accessibilityLabel(Text(channel.label + " connector, " + connectionSummary))
            .accessibilityValue(Text(accessibilityValueText))
            .accessibilityAddTraits(.isButton)
            // VoiceOver's default activation gesture: `onTapGesture` alone isn't wired to it.
            .accessibilityAction(.default) { handleTap() }
            .accessibilityActions {
                ForEach(connectableTargets, id: \.end) { target in
                    Button("Connect to \(target.label)") { connect(to: target.end) }
                }
                ForEach(connectedTargets, id: \.end) { target in
                    Button("Disconnect from \(target.label)") {
                        withAnimation { routingState.removeRouteBetween(from: connectorEnd, to: target.end) }
                    }
                }
            }
            // Polled (not observed) at low frequency, only while this port is part of a live
            // route AND a window that shows meters is actually on screen -- the same visibility
            // signal `AudioRouter` gates publishing `MeterLevels` on, via `MeterWindowVisibility`.
            // SwiftUI cancels and restarts this task whenever either input changes, so a hidden/
            // minimized/occluded window stops polling instead of running forever in the background.
            .task(id: LivePollKey(connected: isConnected, visible: MeterWindowVisibility.shared.isVisible)) {
                guard isConnected, MeterWindowVisibility.shared.isVisible else {
                    if !isConnected { liveLevelText = "Silent" }
                    return
                }
                while !Task.isCancelled {
                    liveLevelText = SignalMeter.dbString(currentLevel())
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
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

    private func currentLevel() -> Float {
        switch side {
        case .source(let key): return meters.level(source: key, channel: channel.id)
        case .output: return meters.output(channel: channel.id)
        }
    }

    // MARK: - Accessibility: opposite-side targets

    private struct ConnectorTarget {
        let end: ConnectorEnd
        let label: String
    }

    /// Every opposite-side port this connector could reach: output channels for a source port,
    /// or every source's channels for an output port.
    private var oppositeEnds: [ConnectorTarget] {
        switch connectorEnd {
        case .source:
            return routingState.outputChannels.map {
                ConnectorTarget(end: .output(channelId: $0.id), label: "Channel \($0.label)")
            }
        case .output:
            return routingState.sources.flatMap { source in
                source.channels.map {
                    ConnectorTarget(end: .source(sourceId: source.id, channelId: $0.id),
                                     label: "\(source.name) input \($0.label)")
                }
            }
        }
    }

    private var connectableTargets: [ConnectorTarget] {
        oppositeEnds.filter { routingState.findRoute(from: connectorEnd, to: $0.end) == nil }
    }

    private var connectedTargets: [ConnectorTarget] {
        oppositeEnds.filter { routingState.findRoute(from: connectorEnd, to: $0.end) != nil }
    }

    private var connectionSummary: String {
        let names = connectedTargets.map(\.label)
        return names.isEmpty ? "not connected" : "connected to \(names.joined(separator: ", "))"
    }

    private var accessibilityValueText: String {
        if isPending { return "Pending connection" }
        guard isConnected else { return "Not connected" }
        return "Connected, \(liveLevelText)"
    }

    private func connect(to target: ConnectorEnd) {
        switch (connectorEnd, target) {
        case (.source(let sid, let sch), .output(let och)):
            withAnimation { routingState.addRoute(sourceId: sid, sourceChannelId: sch, outputChannelId: och) }
        case (.output(let och), .source(let sid, let sch)):
            withAnimation { routingState.addRoute(sourceId: sid, sourceChannelId: sch, outputChannelId: och) }
        default:
            break
        }
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

// MARK: - Live meter

/// The only part of a strip that reads `MeterLevels`. The meter follows the level itself, so
/// 30 Hz meter updates never re-render this view or the card around it.
private struct ChannelLevelMeter: View {
    @Environment(MeterLevels.self) private var meters
    let side: ChannelStripView.StripSide
    let channel: Int
    let isLive: Bool

    var body: some View {
        LiveSignalMeter(thickness: 6) { [meters, side, channel, isLive] in
            guard isLive else { return 0 }
            switch side {
            case .source(let key): return meters.level(source: key, channel: channel)
            case .output: return meters.output(channel: channel)
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
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let highContrast = contrast == .increased
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
                    Circle().strokeBorder(
                        isConnected ? Color.primary.opacity(highContrast ? 0.6 : 0) : Color.secondary.opacity(highContrast ? 0.85 : 0.5),
                        lineWidth: highContrast ? 1.75 : 1.25
                    )
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
