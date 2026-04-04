import SwiftUI

// MARK: - Design tokens

enum LoopbackerTheme {
    static let bgDeep = Color(red: 0.08, green: 0.08, blue: 0.14)       // #141423
    static let bgSurface = Color(red: 0.13, green: 0.13, blue: 0.20)    // #212133
    static let bgCard = Color(red: 0.16, green: 0.16, blue: 0.24)       // #28283D
    static let bgCardHover = Color(red: 0.19, green: 0.19, blue: 0.28)  // #303047
    static let bgInset = Color(red: 0.10, green: 0.10, blue: 0.16)      // #1A1A29

    static let accent = Color(red: 0.0, green: 0.83, blue: 0.67)        // #00D4AA
    static let accentDim = Color(red: 0.0, green: 0.50, blue: 0.40)     // #008066
    static let accentGlow = Color(red: 0.0, green: 0.83, blue: 0.67).opacity(0.3)

    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.55)
    static let textMuted = Color(white: 0.35)

    static let border = Color(white: 0.15)
    static let borderActive = Color(red: 0.0, green: 0.83, blue: 0.67).opacity(0.5)

    static let danger = Color(red: 0.95, green: 0.30, blue: 0.35)
    static let warning = Color(red: 0.95, green: 0.75, blue: 0.20)

    static let connectorRadius: CGFloat = 5
    static let cardCornerRadius: CGFloat = 10
    static let stripHeight: CGFloat = 24
    static let stripCornerRadius: CGFloat = 4
}

// MARK: - Channel strip (meter bar + label + connector dot)

struct ChannelStripView: View {
    let channel: AudioChannel
    let side: StripSide
    let isSourceEnabled: Bool
    var connectorEnd: ConnectorEnd
    @EnvironmentObject var routingState: RoutingState

    enum StripSide {
        case source  // connector dot on right
        case output  // connector dot on left
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
                connectorDot
            }

            // Channel label
            Text(channel.label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(isSourceEnabled ? LoopbackerTheme.textPrimary : LoopbackerTheme.textMuted)
                .frame(width: 36, alignment: side == .source ? .leading : .trailing)

            // Meter bar
            meterBar
                .frame(height: LoopbackerTheme.stripHeight)

            if side == .source {
                connectorDot
            }
        }
        .frame(height: 28)
    }

    // MARK: - Meter bar

    private var meterBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: LoopbackerTheme.stripCornerRadius)
                    .fill(LoopbackerTheme.bgInset)

                // Subtle grid lines
                HStack(spacing: 0) {
                    ForEach(0..<10, id: \.self) { i in
                        Rectangle()
                            .fill(LoopbackerTheme.border.opacity(0.3))
                            .frame(width: 1)
                            .frame(maxWidth: .infinity)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: LoopbackerTheme.stripCornerRadius))

                // Fill
                if isSourceEnabled && channel.meterLevel > 0 {
                    let fillWidth = geo.size.width * CGFloat(channel.meterLevel)
                    RoundedRectangle(cornerRadius: LoopbackerTheme.stripCornerRadius)
                        .fill(
                            LinearGradient(
                                colors: meterGradientColors,
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: fillWidth)
                        .shadow(color: LoopbackerTheme.accentGlow, radius: 4, x: 0, y: 0)
                }

                // Border
                RoundedRectangle(cornerRadius: LoopbackerTheme.stripCornerRadius)
                    .strokeBorder(LoopbackerTheme.border, lineWidth: 0.5)
            }
        }
    }

    private var meterGradientColors: [Color] {
        if channel.meterLevel > 0.85 {
            return [LoopbackerTheme.accent, LoopbackerTheme.warning, LoopbackerTheme.danger]
        } else if channel.meterLevel > 0.7 {
            return [LoopbackerTheme.accent, LoopbackerTheme.warning]
        } else {
            return [LoopbackerTheme.accent.opacity(0.7), LoopbackerTheme.accent]
        }
    }

    // MARK: - Connector dot

    private var connectorDot: some View {
        ZStack {
            // Glow ring when pending
            if isPending {
                Circle()
                    .fill(LoopbackerTheme.accent.opacity(0.3))
                    .frame(width: 18, height: 18)
                    .blur(radius: 4)
            }

            // Outer ring
            Circle()
                .fill(isConnected || isPending ? LoopbackerTheme.accent : LoopbackerTheme.bgInset)
                .frame(width: 12, height: 12)

            // Inner dot
            Circle()
                .fill(isConnected || isPending ? LoopbackerTheme.accent : LoopbackerTheme.bgCard)
                .frame(width: 6, height: 6)

            if isConnected {
                Circle()
                    .fill(LoopbackerTheme.accent)
                    .frame(width: 6, height: 6)
                    .shadow(color: LoopbackerTheme.accentGlow, radius: 3)
            }
        }
        .frame(width: 20, height: 20)
        .contentShape(Circle().inset(by: -4))
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                if routingState.pendingConnector == connectorEnd {
                    // Same dot again → cancel
                    routingState.cancelPendingConnection()
                } else if let pending = routingState.pendingConnector {
                    // Check if this route already exists → toggle it off
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
        .help(isConnected ? "Click to start a new route from this channel, right-click to disconnect all routes" : "Click to connect this channel to a source or output")
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
}

// MARK: - Preference key for connector positions

struct ConnectorPositionKey: PreferenceKey {
    static var defaultValue: [ConnectorEnd: CGRect] = [:]

    static func reduce(value: inout [ConnectorEnd: CGRect], nextValue: () -> [ConnectorEnd: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// ConnectorEnd already conforms to Hashable via its Equatable+Hashable declaration in AudioRoute.swift
