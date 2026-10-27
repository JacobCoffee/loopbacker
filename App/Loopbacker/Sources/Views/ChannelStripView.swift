import SwiftUI
import AppKit

// MARK: - Design tokens (adaptive light/dark)

/// Colors are dynamic `NSColor`s resolved against the drawing view's effective
/// appearance at render time. Picking a variant in a computed property instead
/// would freeze whatever was current when a view body last ran, so views that
/// SwiftUI doesn't re-evaluate after an appearance toggle keep the old palette.
enum LoopbackerTheme {
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    // Backgrounds
    static let bgDeep = adaptive(light: rgb(0.94, 0.94, 0.96), dark: rgb(0.08, 0.08, 0.14))
    static let bgSurface = adaptive(light: rgb(0.97, 0.97, 0.98), dark: rgb(0.12, 0.12, 0.19))
    static let bgCard = adaptive(light: .white, dark: rgb(0.16, 0.16, 0.24))
    static let bgCardHover = adaptive(light: rgb(0.96, 0.97, 0.98), dark: rgb(0.19, 0.19, 0.28))
    static let bgInset = adaptive(light: rgb(0.91, 0.92, 0.94), dark: rgb(0.10, 0.10, 0.16))

    // Accent (darker in light mode for contrast)
    static let accent = adaptive(light: rgb(0.0, 0.60, 0.46), dark: rgb(0.0, 0.83, 0.67))
    static let accentDim = adaptive(light: rgb(0.0, 0.40, 0.30), dark: rgb(0.0, 0.50, 0.40))
    static var accentGlow: Color { accent.opacity(0.3) }

    // Text (dark-mode neutrals carry the backgrounds' blue tint)
    static let textPrimary = adaptive(light: rgb(0.10, 0.10, 0.15), dark: rgb(0.93, 0.93, 0.97))
    static let textSecondary = adaptive(light: rgb(0.40, 0.40, 0.40), dark: rgb(0.62, 0.63, 0.72))
    static let textMuted = adaptive(light: rgb(0.60, 0.60, 0.60), dark: rgb(0.44, 0.45, 0.55))

    // Borders (dark border must sit above bgCard, not below it, to read as an edge)
    static let border = adaptive(light: rgb(0.82, 0.82, 0.82), dark: rgb(0.24, 0.24, 0.34))
    static var borderActive: Color { accent.opacity(0.5) }
    static let gridLine = adaptive(
        light: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 0.3),
        dark: NSColor(srgbRed: 0.32, green: 0.32, blue: 0.46, alpha: 0.3))

    // Status
    static let danger = Color(red: 0.95, green: 0.30, blue: 0.35)
    static let warning = adaptive(light: rgb(0.72, 0.50, 0.0), dark: rgb(0.95, 0.75, 0.20))

    // Layout
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

            // Outer ring (outlined when idle so it reads against bgCard in dark mode)
            Circle()
                .fill(isConnected || isPending ? LoopbackerTheme.accent : LoopbackerTheme.bgInset)
                .overlay(Circle().strokeBorder(isConnected || isPending ? Color.clear : LoopbackerTheme.border, lineWidth: 1))
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
        .tooltip(isConnected ? "Click to start a new route from this channel, right-click to disconnect all routes" : "Click to connect this channel to a source or output")
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
