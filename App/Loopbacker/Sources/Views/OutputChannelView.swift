import SwiftUI

struct OutputChannelView: View {
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var audioDeviceManager: AudioDeviceManager

    /// Channels the installed driver actually exposes on the virtual mic (nil until enumerated).
    private var deviceChannels: Int? {
        audioDeviceManager.systemDevices.first { $0.uid == VirtualDeviceChannels.micUID }?.outputChannelCount
    }

    private var hasActiveRoutes: Bool {
        !routingState.routes.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().opacity(0.5)

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
            .padding(.horizontal, Metrics.panelPadding)
            .padding(.vertical, 10)

            if let deviceChannels, deviceChannels < routingState.outputChannels.count {
                Label("The installed driver provides \(deviceChannels) channels. Reinstall the driver to use channels \(deviceChannels + 1)\u{2013}\(routingState.outputChannels.count).",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, Metrics.panelPadding)
                    .padding(.bottom, 10)
            }

            channelSummary
        }
        .glassPanel(tint: hasActiveRoutes ? .loopbacker.opacity(0.08) : nil)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.loopbacker.opacity(0.18))
                    .frame(width: 32, height: 32)

                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.loopbacker)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(outputTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text("Virtual mic input for Discord, Zoom, etc.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            if routingState.outputChannels.count > 2 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { routingState.removeLastOutputChannelPair() }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .font(.title3)
                .foregroundStyle(.secondary)
                .help("Remove the last channel pair and its routes")
                .accessibilityLabel("Remove last channel pair")
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { routingState.addOutputChannelPair() }
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .font(.title3)
            .foregroundStyle(.secondary)
            .disabled(routingState.outputChannels.count >= VirtualDeviceChannels.maxCount)
            .help("Add a channel pair to the virtual mic (up to \(VirtualDeviceChannels.maxCount) channels)")
            .accessibilityLabel("Add channel pair")
        }
        .padding(.horizontal, Metrics.panelPadding)
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
        HStack(spacing: 6) {
            Image(systemName: "cable.connector")
                .font(.caption2)
            let routeCount = routingState.routes.count
            Text("\(routeCount) route\(routeCount == 1 ? "" : "s") active")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.quaternary, in: UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: Metrics.panelRadius,
            bottomTrailingRadius: Metrics.panelRadius,
            topTrailingRadius: 0
        ))
    }
}
