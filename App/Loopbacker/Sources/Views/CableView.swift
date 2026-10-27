import SwiftUI

/// Draws bezier "cables" between connected channel ports, beneath the glass cards.
/// Live cables (source enabled, unmuted) glow in `Color.loopbacker` with intensity
/// following the source's current level; idle or disabled cables stay dim graphite.
struct CableView: View {
    @EnvironmentObject var routingState: RoutingState
    let connectorPositions: [ConnectorEnd: CGRect]

    var body: some View {
        Canvas { context, size in
            // Canvas resolves Color shading against the view's environment, so the adaptive
            // accent follows light/dark appearance.
            let accent = Color.loopbacker
            let idle = Color.secondary

            for route in routingState.routes {
                let sourceEnd = ConnectorEnd.source(sourceId: route.sourceId, channelId: route.sourceChannelId)
                let outputEnd = ConnectorEnd.output(channelId: route.outputChannelId)

                guard let sourceRect = connectorPositions[sourceEnd],
                      let outputRect = connectorPositions[outputEnd] else { continue }

                let start = CGPoint(x: sourceRect.midX, y: sourceRect.midY)
                let end = CGPoint(x: outputRect.midX, y: outputRect.midY)

                drawCable(context: &context, from: start, to: end,
                          level: sourceLevel(route), accent: accent, idle: idle)
            }

            // Soft bloom under each live source's connectors.
            for source in routingState.sources where source.isEnabled && !source.isMuted {
                let level = source.channels.map(\.meterLevel).max() ?? 0
                guard level > 0.02 else { continue }
                for channel in source.channels {
                    guard let rect = connectorPositions[.source(sourceId: source.id, channelId: channel.id)] else { continue }
                    drawBloom(context: &context, at: CGPoint(x: rect.midX, y: rect.midY), level: level, accent: accent)
                }
            }

            // Pending connection pulse indicator.
            if let pending = routingState.pendingConnector,
               let pendingRect = connectorPositions[pending] {
                let pendingPoint = CGPoint(x: pendingRect.midX, y: pendingRect.midY)
                drawPendingIndicator(context: &context, at: pendingPoint, accent: accent)
            }
        }
        // CRITICAL: hit testing must be off so clicks pass through to cards/buttons
        .allowsHitTesting(false)
    }

    private func sourceLevel(_ route: AudioRoute) -> Float {
        guard let source = routingState.sources.first(where: { $0.id == route.sourceId }),
              source.isEnabled, !source.isMuted else { return 0 }
        return source.channels.map(\.meterLevel).max() ?? 0
    }

    // MARK: - Cable drawing

    private func drawCable(
        context: inout GraphicsContext,
        from start: CGPoint,
        to end: CGPoint,
        level: Float,
        accent: Color,
        idle: Color
    ) {
        let isLive = level > 0
        let dx = end.x - start.x
        let controlOffset = max(abs(dx) * 0.5, 60)

        var path = Path()
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + controlOffset, y: start.y),
            control2: CGPoint(x: end.x - controlOffset, y: end.y)
        )

        guard isLive else {
            // Idle/disabled: dim graphite, no glow.
            context.stroke(path, with: .color(idle.opacity(0.22)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            drawDots(context: &context, start: start, end: end, color: idle.opacity(0.35))
            return
        }

        let intensity = CGFloat(min(max(level, 0.12), 1))

        // Glow layer, brighter with level.
        var glowContext = context
        glowContext.addFilter(.blur(radius: 4 + intensity * 6))
        glowContext.stroke(path, with: .color(accent.opacity(0.12 + 0.18 * intensity)), lineWidth: 6 + intensity * 8)

        // Shadow layer.
        context.stroke(path, with: .color(accent.opacity(0.3)), lineWidth: 4)

        // Main cable.
        context.stroke(path, with: .color(accent.opacity(0.55 + 0.3 * intensity)), style: StrokeStyle(lineWidth: 2, lineCap: .round))

        // Bright core highlight.
        context.stroke(path, with: .color(accent.opacity(0.5 + 0.3 * intensity)), style: StrokeStyle(lineWidth: 1, lineCap: .round))

        drawDots(context: &context, start: start, end: end, color: accent.opacity(0.9))
    }

    private func drawDots(context: inout GraphicsContext, start: CGPoint, end: CGPoint, color: Color) {
        let dotRadius: CGFloat = 3
        context.fill(
            Circle().path(in: CGRect(x: start.x - dotRadius, y: start.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)),
            with: .color(color)
        )
        context.fill(
            Circle().path(in: CGRect(x: end.x - dotRadius, y: end.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)),
            with: .color(color)
        )
    }

    // MARK: - Signal bloom

    private func drawBloom(context: inout GraphicsContext, at point: CGPoint, level: Float, accent: Color) {
        let intensity = CGFloat(min(max(level, 0), 1))
        let radius: CGFloat = 36 + intensity * 48
        let gradient = Gradient(stops: [
            .init(color: accent.opacity(0.10 * intensity), location: 0),
            .init(color: .clear, location: 1),
        ])
        context.fill(
            Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
            with: .radialGradient(gradient, center: point, startRadius: 0, endRadius: radius)
        )
    }

    // MARK: - Pending connection indicator

    private func drawPendingIndicator(context: inout GraphicsContext, at point: CGPoint, accent: Color) {
        context.fill(
            Circle().path(in: CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24)),
            with: .color(accent.opacity(0.2))
        )
        context.fill(
            Circle().path(in: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)),
            with: .color(accent.opacity(0.5))
        )
    }
}
