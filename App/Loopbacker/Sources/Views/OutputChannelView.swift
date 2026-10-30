import SwiftUI

/// One virtual mic's channel column: Virtual Mic or (when enabled) Stream Mix. Both targets
/// share the same add/remove-pair channel model, just against their own channel array and
/// device UID.
struct OutputChannelView: View {
    let target: RouteTarget

    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var audioDeviceManager: AudioDeviceManager

    private var channels: [AudioChannel] {
        target == .virtualMic ? routingState.outputChannels : routingState.streamOutputChannels
    }

    /// Channels the installed driver actually exposes on this target (nil until enumerated).
    private var deviceChannels: Int? {
        audioDeviceManager.systemDevices.first { $0.uid == target.deviceUID }?.outputChannelCount
    }

    private var hasActiveRoutes: Bool {
        routingState.routes.contains { $0.targetId == target }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().opacity(0.5)

            VStack(spacing: 4) {
                ForEach(channels) { channel in
                    ChannelStripView(
                        channel: channel,
                        side: .output(target: target),
                        isSourceEnabled: true,
                        connectorEnd: .output(target: target, channelId: channel.id)
                    )
                    .contextMenu {
                        Button(role: .destructive) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                removeChannel(channel.id)
                            }
                        } label: {
                            Label("Remove Channel \(channel.label)", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, Metrics.panelPadding)
            .padding(.vertical, 10)

            if let deviceChannels, deviceChannels < channels.count {
                Label("The installed driver provides \(deviceChannels) channels. Reinstall the driver to use channels \(deviceChannels + 1)\u{2013}\(channels.count).",
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
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            if channels.count > 2 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { removeLastPair() }
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
                withAnimation(.easeInOut(duration: 0.2)) { addPair() }
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .font(.title3)
            .foregroundStyle(.secondary)
            .disabled(channels.count >= VirtualDeviceChannels.maxCount)
            .help("Add a channel pair to this virtual mic (up to \(VirtualDeviceChannels.maxCount) channels)")
            .accessibilityLabel("Add channel pair")
        }
        .padding(.horizontal, Metrics.panelPadding)
        .padding(.vertical, 10)
    }

    private var subtitle: String {
        switch target {
        case .virtualMic: return "Virtual mic input for Discord, Zoom, etc."
        case .streamMix: return "Second virtual mic input, e.g. for OBS or a separate stream mix."
        }
    }

    private var outputTitle: String {
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
            let routeCount = routingState.routes.filter { $0.targetId == target }.count
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

    // MARK: - Target-dispatched channel mutations

    private func removeChannel(_ channelId: Int) {
        switch target {
        case .virtualMic: routingState.removeOutputChannel(channelId)
        case .streamMix: routingState.removeStreamOutputChannel(channelId)
        }
    }

    private func addPair() {
        switch target {
        case .virtualMic: routingState.addOutputChannelPair()
        case .streamMix: routingState.addStreamOutputChannelPair()
        }
    }

    private func removeLastPair() {
        switch target {
        case .virtualMic: routingState.removeLastOutputChannelPair()
        case .streamMix: routingState.removeLastStreamOutputChannelPair()
        }
    }
}
