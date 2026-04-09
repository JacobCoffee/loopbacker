import SwiftUI

struct SourceCardView: View {
    @Binding var source: AudioSource
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var audioDeviceManager: AudioDeviceManager
    @EnvironmentObject var audioRouter: AudioRouter
    @EnvironmentObject var appCaptureService: AppCaptureService
    @State private var isHovering = false
    @State private var showOptions = false

    private var hasActiveRoutes: Bool {
        routingState.routes.contains { $0.sourceId == source.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            header

            Divider()
                .background(LoopbackerTheme.border)

            // Channel strips
            VStack(spacing: 4) {
                ForEach(source.channels) { channel in
                    ChannelStripView(
                        channel: channel,
                        side: .source,
                        isSourceEnabled: source.isEnabled && !source.isMuted,
                        connectorEnd: .source(sourceId: source.id, channelId: channel.id)
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // Options disclosure
            if showOptions {
                optionsSection
            }

            optionsToggle
        }
        .background(
            RoundedRectangle(cornerRadius: LoopbackerTheme.cardCornerRadius)
                .fill(isHovering ? LoopbackerTheme.bgCardHover : LoopbackerTheme.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LoopbackerTheme.cardCornerRadius)
                .strokeBorder(
                    source.isEnabled && hasActiveRoutes
                        ? LoopbackerTheme.borderActive
                        : LoopbackerTheme.border,
                    lineWidth: source.isEnabled && hasActiveRoutes ? 1.5 : 0.5
                )
        )
        .shadow(
            color: source.isEnabled && hasActiveRoutes
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
            // Device icon
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(source.isEnabled && !source.isMuted ? LoopbackerTheme.accent.opacity(0.15) : LoopbackerTheme.bgInset)
                    .frame(width: 32, height: 32)

                Image(systemName: source.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(source.isEnabled && !source.isMuted ? LoopbackerTheme.accent : LoopbackerTheme.textMuted)
            }

            // Device name
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(source.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(source.isEnabled ? LoopbackerTheme.textPrimary : LoopbackerTheme.textMuted)

                    if source.isMuted {
                        Text("MUTED")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(LoopbackerTheme.warning)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(LoopbackerTheme.warning.opacity(0.15))
                            .clipShape(Capsule())
                    }

                    if source.isAppCapture && !appCaptureService.isAppRunning(bundleID: source.appBundleID) {
                        Text("NOT RUNNING")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(LoopbackerTheme.textMuted)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(LoopbackerTheme.bgInset)
                            .clipShape(Capsule())
                    }
                }

                Text(source.isAppCapture ? "App Audio" : "\(source.channels.count) channel\(source.channels.count == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(LoopbackerTheme.textSecondary)
            }

            Spacer()

            // On/Off toggle
            enableToggle
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Custom toggle

    private var enableToggle: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                routingState.toggleSource(source.id)
            }
        }) {
            HStack(spacing: 4) {
                Circle()
                    .fill(source.isEnabled ? LoopbackerTheme.accent : LoopbackerTheme.textMuted)
                    .frame(width: 6, height: 6)
                    .shadow(color: source.isEnabled ? LoopbackerTheme.accentGlow : .clear, radius: 3)

                Text(source.isEnabled ? "ON" : "OFF")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(source.isEnabled ? LoopbackerTheme.accent : LoopbackerTheme.textMuted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(source.isEnabled ? LoopbackerTheme.accent.opacity(0.12) : LoopbackerTheme.bgInset)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        source.isEnabled ? LoopbackerTheme.accent.opacity(0.3) : LoopbackerTheme.border,
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .tooltip(source.isEnabled ? "Disable this audio source (stops routing)" : "Enable this audio source (starts routing)")
    }

    // MARK: - Options section

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
                .background(LoopbackerTheme.border)

            // Monitor output picker (not available for app capture sources)
            if !source.isAppCapture {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 10))
                        .foregroundColor(LoopbackerTheme.textSecondary)

                    Text("Monitor:")
                        .font(.system(size: 11))
                        .foregroundColor(LoopbackerTheme.textSecondary)

                    monitorPicker
                }
                .tooltip("Hear this source through a physical output (speakers/headphones)")
            }

            // Mute toggle
            HStack {
                Text("Mute")
                    .font(.system(size: 11))
                    .foregroundColor(LoopbackerTheme.textSecondary)

                Spacer()

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        routingState.muteSource(source.id)
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: source.isMuted ? "speaker.slash.fill" : "speaker.wave.1")
                            .font(.system(size: 9, weight: .semibold))
                        Text(source.isMuted ? "MUTED" : "UNMUTED")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(source.isMuted ? LoopbackerTheme.warning : LoopbackerTheme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(source.isMuted ? LoopbackerTheme.warning.opacity(0.12) : LoopbackerTheme.bgInset)
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            source.isMuted ? LoopbackerTheme.warning.opacity(0.3) : LoopbackerTheme.border,
                            lineWidth: 0.5
                        )
                    )
                }
                .buttonStyle(.plain)
                .tooltip(source.isMuted ? "Unmute this source to resume audio routing" : "Mute this source (silences output without disconnecting routes)")
            }

            // Solo button
            HStack {
                Text("Solo")
                    .font(.system(size: 11))
                    .foregroundColor(LoopbackerTheme.textSecondary)

                Spacer()

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        routingState.soloSource(source.id)
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "headphones")
                            .font(.system(size: 9, weight: .semibold))
                        Text("SOLO")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(LoopbackerTheme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(LoopbackerTheme.accent.opacity(0.12)))
                    .overlay(
                        Capsule().strokeBorder(LoopbackerTheme.accent.opacity(0.3), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .tooltip("Mute all other sources and listen to only this one")
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(LoopbackerTheme.accent)
    }

    // MARK: - Options toggle button

    private var optionsToggle: some View {
        HStack(spacing: 4) {
            Image(systemName: showOptions ? "chevron.up" : "chevron.down")
                .font(.system(size: 8, weight: .bold))
            Text("Options")
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(LoopbackerTheme.textMuted)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(LoopbackerTheme.bgInset.opacity(0.5))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                showOptions.toggle()
            }
        }
        .tooltip(showOptions ? "Hide source options (mute, solo, pass-through)" : "Show source options (mute, solo, pass-through)")
    }
}
