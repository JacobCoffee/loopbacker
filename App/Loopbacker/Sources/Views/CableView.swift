import SwiftUI

struct CableView: View {
    @EnvironmentObject var routingState: RoutingState
    let connectorPositions: [ConnectorEnd: CGRect]

    var body: some View {
        Canvas { context, size in
            for route in routingState.routes {
                let sourceEnd = ConnectorEnd.source(sourceId: route.sourceId, channelId: route.sourceChannelId)
                let outputEnd = ConnectorEnd.output(channelId: route.outputChannelId)

                guard let sourceRect = connectorPositions[sourceEnd],
                      let outputRect = connectorPositions[outputEnd] else { continue }

                let start = CGPoint(x: sourceRect.midX, y: sourceRect.midY)
                let end = CGPoint(x: outputRect.midX, y: outputRect.midY)

                drawCable(context: &context, from: start, to: end, isSourceEnabled: isSourceEnabled(route))
            }

            // Draw pending connection ghost cable
            if let pending = routingState.pendingConnector,
               let pendingRect = connectorPositions[pending] {
                let pendingPoint = CGPoint(x: pendingRect.midX, y: pendingRect.midY)
                drawPendingIndicator(context: &context, at: pendingPoint)
            }
        }
        // CRITICAL: hit testing must be off so clicks pass through to cards/buttons
        .allowsHitTesting(false)
    }

    private func isSourceEnabled(_ route: AudioRoute) -> Bool {
        routingState.sources.first(where: { $0.id == route.sourceId })?.isEnabled ?? false
    }

    // MARK: - Cable drawing

    private func drawCable(context: inout GraphicsContext, from start: CGPoint, to end: CGPoint, isSourceEnabled: Bool) {
        let dx = end.x - start.x
        let controlOffset = max(abs(dx) * 0.5, 60)

        var path = Path()
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + controlOffset, y: start.y),
            control2: CGPoint(x: end.x - controlOffset, y: end.y)
        )

        let cableColor = isSourceEnabled
            ? Color(red: 0.0, green: 0.83, blue: 0.67)
            : Color(white: 0.3)

        // Glow layer
        if isSourceEnabled {
            var glowContext = context
            glowContext.addFilter(.blur(radius: 6))
            glowContext.stroke(
                path,
                with: .color(cableColor.opacity(0.15)),
                lineWidth: 10
            )
        }

        // Shadow layer
        context.stroke(
            path,
            with: .color(cableColor.opacity(0.3)),
            lineWidth: 4
        )

        // Main cable
        context.stroke(
            path,
            with: .color(cableColor.opacity(isSourceEnabled ? 0.85 : 0.4)),
            style: StrokeStyle(lineWidth: 2, lineCap: .round)
        )

        // Bright core highlight
        if isSourceEnabled {
            context.stroke(
                path,
                with: .color(cableColor.opacity(0.5)),
                style: StrokeStyle(lineWidth: 1, lineCap: .round)
            )
        }

        // Connector endpoint dots
        let dotRadius: CGFloat = 3
        let dotColor = isSourceEnabled ? cableColor : Color(white: 0.4)

        context.fill(
            Circle().path(in: CGRect(x: start.x - dotRadius, y: start.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)),
            with: .color(dotColor)
        )
        context.fill(
            Circle().path(in: CGRect(x: end.x - dotRadius, y: end.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)),
            with: .color(dotColor)
        )
    }

    // MARK: - Pending connection indicator

    private func drawPendingIndicator(context: inout GraphicsContext, at point: CGPoint) {
        let pulseColor = Color(red: 0.0, green: 0.83, blue: 0.67)

        context.fill(
            Circle().path(in: CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24)),
            with: .color(pulseColor.opacity(0.2))
        )

        context.fill(
            Circle().path(in: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)),
            with: .color(pulseColor.opacity(0.5))
        )
    }
}
