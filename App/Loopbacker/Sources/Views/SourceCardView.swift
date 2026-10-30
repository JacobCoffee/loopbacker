import SwiftUI

struct SourceCardView: View {
    @Binding var source: AudioSource
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var audioDeviceManager: AudioDeviceManager
    @EnvironmentObject var audioRouter: AudioRouter
    @EnvironmentObject var appCaptureService: AppCaptureService
    @State private var showOptions = false

    private var isLive: Bool { source.isEnabled && !source.isMuted }

    /// Device source whose CoreAudio UID isn't among the current system devices
    /// (unplugged, or re-enumerated under a different driver with no unique name match).
    private var isDeviceMissing: Bool {
        guard !source.isAppCapture, !source.deviceUID.isEmpty,
              !audioDeviceManager.systemDevices.isEmpty else { return false }
        return !audioDeviceManager.systemDevices.contains { $0.uid == source.deviceUID }
    }

    /// Noise suppression is on globally and this device source hasn't opted out.
    private var isDenoised: Bool {
        !source.isAppCapture && source.noiseSuppression && routingState.noiseSuppression.isEnabled
    }

    private var isNotRunning: Bool {
        source.isAppCapture && !appCaptureService.isAppRunning(bundleID: source.appBundleID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().opacity(0.5)

            VStack(spacing: 4) {
                ForEach(source.channels) { channel in
                    ChannelStripView(
                        channel: channel,
                        side: .source(meterKey: source.deviceUID),
                        isSourceEnabled: isLive,
                        connectorEnd: .source(sourceId: source.id, channelId: channel.id)
                    )
                }
            }
            .padding(.horizontal, Metrics.panelPadding)
            .padding(.vertical, 10)

            optionsDisclosure
        }
        .glassPanel(tint: isLive ? .loopbacker.opacity(0.08) : nil)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isLive ? Color.loopbacker.opacity(0.18) : Color.secondary.opacity(0.12))
                    .frame(width: 32, height: 32)

                Image(systemName: source.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isLive ? Color.loopbacker : .secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(source.name)
                        .font(.headline)
                        .foregroundStyle(source.isEnabled ? .primary : .secondary)
                        .lineLimit(1)

                    if source.isMuted {
                        StatusTag(title: "Muted", tint: .signalWarm, symbol: "speaker.slash.fill")
                    }
                    if isNotRunning {
                        StatusTag(title: "Not Running", tint: .secondary)
                    }
                    if isDeviceMissing {
                        StatusTag(title: "Unavailable", tint: .signalWarm, symbol: "exclamationmark.triangle.fill")
                            .help("No audio device with this source's ID is connected. Reconnect it, or remove and re-add the source.")
                    }
                    if isDenoised {
                        StatusTag(title: "Denoised", tint: .loopbacker, symbol: "waveform.badge.minus")
                            .help("Noise suppression (\(NoiseEngineProfile.of(routingState.noiseSuppression.engine).name)) cleans this mic before the effects chain")
                    }
                }

                Text(source.isAppCapture ? "App Audio" : "\(source.channels.count) channel\(source.channels.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Toggle(source.isEnabled ? "Disable \(source.name)" : "Enable \(source.name)", isOn: Binding(
                get: { source.isEnabled },
                set: { _ in withAnimation(.easeInOut(duration: 0.2)) { routingState.toggleSource(source.id) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .help(source.isEnabled ? "Disable this audio source (stops routing)" : "Enable this audio source (starts routing)")
        }
        .padding(.horizontal, Metrics.panelPadding)
        .padding(.vertical, 10)
    }

    // MARK: - Options disclosure

    private var optionsDisclosure: some View {
        DisclosureGroup(isExpanded: $showOptions) {
            optionsSection
        } label: {
            // Help on the label only: on the group it would override the controls' own help.
            Text("Options")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .help(showOptions ? "Hide source options (monitor, noise suppression, mute, solo)" : "Show source options (monitor, noise suppression, mute, solo)")
        }
        .padding(.horizontal, Metrics.panelPadding)
        .padding(.vertical, 8)
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !source.isAppCapture {
                HStack(spacing: 6) {
                    Text("Monitor")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    monitorPicker
                }
                .help("Hear this source through a physical output (speakers/headphones)")

                Toggle(isOn: Binding(
                    get: { source.noiseSuppression },
                    set: { source.noiseSuppression = $0; routingState.save() }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Noise Suppression")
                            .font(.callout)
                        if !routingState.noiseSuppression.isEnabled {
                            Text("Off for all mics. Turn it on in Effects.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(.loopbacker)
                .help(source.noiseSuppression ? "Don't denoise this mic" : "Denoise this mic when noise suppression is on")

                if source.noiseSuppression && routingState.noiseSuppression.isEnabled && !source.monitorOutputUID.isEmpty {
                    let latency = NoiseEngineProfile.of(routingState.noiseSuppression.engine).latencyMs
                    Toggle(isOn: Binding(
                        get: { source.denoiseMonitor },
                        set: { source.denoiseMonitor = $0; routingState.save() }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Denoise Monitor")
                                .font(.callout)
                            Text(source.denoiseMonitor
                                 ? "You hear what callers hear, \(latency) ms late."
                                 : "You hear yourself with no added delay. Callers still get the denoised mic.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(.loopbacker)
                    .padding(.leading, 12)
                    .help("Whether the monitor output gets noise suppression too")
                }
            }

            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { routingState.muteSource(source.id) }
                } label: {
                    Label(source.isMuted ? "Muted" : "Mute", systemImage: source.isMuted ? "speaker.slash.fill" : "speaker.wave.1")
                        .font(.caption)
                }
                .buttonStyle(.glass)
                .tint(source.isMuted ? Color.signalWarm : nil)
                .controlSize(.small)
                .help(source.isMuted ? "Unmute this source to resume audio routing" : "Mute this source (silences output without disconnecting routes)")

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { routingState.soloSource(source.id) }
                } label: {
                    Label("Solo", systemImage: "headphones")
                        .font(.caption)
                }
                .buttonStyle(.glass)
                .tint(nil)
                .controlSize(.small)
                .help("Mute all other sources and listen to only this one")

                Spacer()
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Monitor output picker

    @ViewBuilder
    private var monitorPicker: some View {
        let devices = audioDeviceManager.outputDevices

        Picker("", selection: Binding(
            get: { source.monitorOutputUID },
            set: { newUID in
                if !source.monitorOutputUID.isEmpty {
                    audioRouter.stopOutputRouting(virtualDeviceUID: "monitor:\(source.deviceUID)")
                }
                source.monitorOutputUID = newUID
                source.monitorOutputName = devices.first(where: { $0.uid == newUID })?.name ?? ""
                routingState.save()
                if !newUID.isEmpty && source.isEnabled && !source.isMuted {
                    audioRouter.startMonitoring(sourceDeviceUID: source.deviceUID, outputDeviceUID: newUID)
                }
            }
        )) {
            Text("None").tag("")
            ForEach(devices) { device in
                Text(device.name).tag(device.uid)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .tint(.loopbacker)
    }
}
