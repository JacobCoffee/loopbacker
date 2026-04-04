import SwiftUI

struct OutputChannelView: View {
    @EnvironmentObject var routingState: RoutingState
    @State private var isHovering = false

    private var hasActiveRoutes: Bool {
        !routingState.routes.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            header

            Divider()
                .background(LoopbackerTheme.border)

            // Output channel strips
            VStack(spacing: 4) {
                ForEach(routingState.outputChannels) { channel in
                    ChannelStripView(
                        channel: channel,
                        side: .output,
                        isSourceEnabled: true,
                        connectorEnd: .output(channelId: channel.id)
                    )
                    .contextMenu {
                        Button(role: .destructive) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                routingState.removeOutputChannel(channel.id)
                            }
                        } label: {
                            Label("Remove Channel \(channel.label)", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Spacer(minLength: 0)

            // Channel pair label at bottom
            channelSummary
        }
        .background(
            RoundedRectangle(cornerRadius: LoopbackerTheme.cardCornerRadius)
                .fill(isHovering ? LoopbackerTheme.bgCardHover : LoopbackerTheme.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LoopbackerTheme.cardCornerRadius)
                .strokeBorder(
                    hasActiveRoutes ? LoopbackerTheme.borderActive : LoopbackerTheme.border,
                    lineWidth: hasActiveRoutes ? 1.5 : 0.5
                )
        )
        .shadow(
            color: hasActiveRoutes
                ? LoopbackerTheme.accentGlow.opacity(0.15)
                : Color.clear,
            radius: 8
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(LoopbackerTheme.accent.opacity(0.15))
                    .frame(width: 32, height: 32)

                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(LoopbackerTheme.accent)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(outputTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(LoopbackerTheme.textPrimary)

                Text("Virtual mic input for Discord, Zoom, etc.")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(LoopbackerTheme.textSecondary)
            }

            Spacer()

            // Remove channel button
            if routingState.outputChannels.count > 1 {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if let last = routingState.outputChannels.last {
                            routingState.removeOutputChannel(last.id)
                        }
                    }
                }) {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(LoopbackerTheme.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(LoopbackerTheme.bgInset)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(LoopbackerTheme.border, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .tooltip("Remove the last output channel and its routes")
            }

            // Add channel button
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    routingState.addOutputChannel()
                }
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(LoopbackerTheme.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(LoopbackerTheme.bgInset)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(LoopbackerTheme.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .tooltip("Add a new output channel to the virtual device")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var outputTitle: String {
        let channels = routingState.outputChannels
        if channels.count == 2 {
            return "Channels 1 & 2"
        } else if channels.count == 1 {
            return "Channel 1"
        } else {
            return "Channels 1\u{2013}\(channels.count)"
        }
    }

    // MARK: - Summary footer

    private var channelSummary: some View {
        HStack {
            let routeCount = routingState.routes.count
            Image(systemName: "cable.connector")
                .font(.system(size: 9))
            Text("\(routeCount) route\(routeCount == 1 ? "" : "s") active")
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(LoopbackerTheme.textMuted)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(LoopbackerTheme.bgInset.opacity(0.5))
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: LoopbackerTheme.cardCornerRadius,
                bottomTrailingRadius: LoopbackerTheme.cardCornerRadius,
                topTrailingRadius: 0
            )
        )
    }
}
