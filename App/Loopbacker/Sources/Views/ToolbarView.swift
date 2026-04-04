import SwiftUI

struct ToolbarView: View {
    @EnvironmentObject var driverInstaller: DriverInstaller
    @EnvironmentObject var audioDeviceManager: AudioDeviceManager
    @EnvironmentObject var audioRouter: AudioRouter
    @EnvironmentObject var routingState: RoutingState

    var body: some View {
        HStack(spacing: 0) {
            // MARK: - Left: Panic / Reset

            panicSection

            sectionDivider

            // MARK: - Center: Live Status

            statusSection

            Spacer()

            // MARK: - Right: Quick Route Actions

            quickRouteSection

            sectionDivider

            // MARK: - Far Right: Install/Quit

            systemSection
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: 40)
        .background(LoopbackerTheme.bgSurface)
        .overlay(
            Rectangle()
                .fill(LoopbackerTheme.border)
                .frame(height: 0.5),
            alignment: .top
        )
    }

    // MARK: - Panic Section

    private var panicSection: some View {
        HStack(spacing: 6) {
            dockButton(
                label: "Stop All",
                icon: "speaker.slash",
                color: LoopbackerTheme.danger
            ) {
                withAnimation {
                    audioRouter.stopAll()
                    routingState.disconnectAll()
                }
            }

            dockButton(
                label: "Reconnect",
                icon: "arrow.clockwise",
                color: LoopbackerTheme.accent
            ) {
                audioRouter.restartAllRoutes()
            }

            dockButton(
                label: "Reload",
                icon: "arrow.triangle.2.circlepath",
                color: LoopbackerTheme.accent
            ) {
                audioDeviceManager.enumerateDevices()
            }
        }
    }

    // MARK: - Status Section

    private var statusSection: some View {
        HStack(spacing: 10) {
            // Active route count
            HStack(spacing: 4) {
                Image(systemName: "cable.connector.horizontal")
                    .font(.system(size: 10))
                    .foregroundColor(LoopbackerTheme.textMuted)

                Text("\(routingState.routes.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(routingState.routes.isEmpty
                        ? LoopbackerTheme.textMuted
                        : LoopbackerTheme.textPrimary)
            }
            .help("\(routingState.routes.count) active route\(routingState.routes.count == 1 ? "" : "s")")

            // Sample rate badge
            HStack(spacing: 3) {
                Image(systemName: "waveform")
                    .font(.system(size: 9))
                Text("48kHz")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
            }
            .foregroundColor(LoopbackerTheme.textMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(LoopbackerTheme.bgInset)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(LoopbackerTheme.border, lineWidth: 0.5))

            // Underrun / health indicator
            HStack(spacing: 3) {
                Image(systemName: routingState.routes.isEmpty ? "minus.circle" : "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(routingState.routes.isEmpty
                        ? LoopbackerTheme.textMuted
                        : LoopbackerTheme.accent)
            }
            .help(routingState.routes.isEmpty ? "No active routes" : "Audio healthy")

            // Driver status dot
            HStack(spacing: 4) {
                Circle()
                    .fill(driverStatusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: driverStatusColor.opacity(0.6), radius: 3)

                Text(driverStatusLabel)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(LoopbackerTheme.textMuted)
            }
        }
    }

    // MARK: - Quick Route Section

    private var quickRouteSection: some View {
        HStack(spacing: 6) {
            dockButton(
                label: "Auto Stereo",
                icon: "arrow.left.arrow.right",
                color: LoopbackerTheme.accent
            ) {
                autoRouteStereo()
            }

            dockButton(
                label: "Disconnect",
                icon: "xmark.circle",
                color: LoopbackerTheme.warning
            ) {
                withAnimation {
                    audioRouter.stopAll()
                    routingState.disconnectAll()
                }
            }
        }
    }

    // MARK: - System Section (Install/Quit)

    private var systemSection: some View {
        HStack(spacing: 6) {
            // Install / Uninstall
            Button(action: {
                if driverInstaller.isInstalled {
                    driverInstaller.uninstall()
                } else {
                    driverInstaller.install()
                }
            }) {
                HStack(spacing: 4) {
                    if driverInstaller.isProcessing {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: driverInstaller.isInstalled ? "minus.circle" : "arrow.down.circle")
                            .font(.system(size: 10, weight: .semibold))
                    }

                    Text(driverInstaller.isInstalled ? "Uninstall" : "Install")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(driverInstaller.isInstalled ? LoopbackerTheme.danger : LoopbackerTheme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(
                            driverInstaller.isInstalled
                                ? LoopbackerTheme.danger.opacity(0.1)
                                : LoopbackerTheme.accent.opacity(0.1)
                        )
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            driverInstaller.isInstalled
                                ? LoopbackerTheme.danger.opacity(0.3)
                                : LoopbackerTheme.accent.opacity(0.3),
                            lineWidth: 0.5
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(driverInstaller.isProcessing)

            // Quit
            Button(action: {
                AppDelegate.forceQuit()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "power")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Quit")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(LoopbackerTheme.textMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(LoopbackerTheme.bgInset))
                .overlay(Capsule().strokeBorder(LoopbackerTheme.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    private var sectionDivider: some View {
        Divider()
            .frame(height: 14)
            .padding(.horizontal, 8)
    }

    private func dockButton(
        label: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.1)))
            .overlay(Capsule().strokeBorder(color.opacity(0.3), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(label)
    }

    // MARK: - Driver status

    private var driverStatusColor: Color {
        if driverInstaller.isProcessing {
            return LoopbackerTheme.warning
        }
        if !driverInstaller.isInstalled {
            return LoopbackerTheme.danger
        }
        return audioDeviceManager.loopbackerDevicePresent
            ? LoopbackerTheme.accent
            : LoopbackerTheme.warning
    }

    private var driverStatusLabel: String {
        if !driverInstaller.isInstalled {
            return "No driver"
        }
        return audioDeviceManager.loopbackerDevicePresent ? "Active" : "No device"
    }

    // MARK: - Auto Route Stereo

    /// Find the first input source with 2+ channels and route ch1->out1, ch2->out2
    private func autoRouteStereo() {
        // Ensure at least 2 output channels exist
        while routingState.outputChannels.count < 2 {
            routingState.addOutputChannel()
        }

        // Find first source with 2+ channels
        guard let source = routingState.sources.first(where: { $0.channels.count >= 2 && $0.isEnabled }) else {
            // No suitable source found -- try adding one from system devices
            let inputDevices = audioDeviceManager.systemDevices.filter {
                $0.isInput && !$0.name.contains("Loopbacker") && $0.inputChannelCount >= 2
            }
            guard let device = inputDevices.first else { return }

            let newSource = audioDeviceManager.createSource(from: device)
            withAnimation {
                routingState.sources.append(newSource)
                addStereoRoutes(for: newSource)
            }
            return
        }

        withAnimation {
            addStereoRoutes(for: source)
        }
    }

    private func addStereoRoutes(for source: AudioSource) {
        let outChannels = routingState.outputChannels.sorted(by: { $0.id < $1.id })
        guard outChannels.count >= 2, source.channels.count >= 2 else { return }

        routingState.addRoute(
            sourceId: source.id,
            sourceChannelId: source.channels[0].id,
            outputChannelId: outChannels[0].id
        )
        routingState.addRoute(
            sourceId: source.id,
            sourceChannelId: source.channels[1].id,
            outputChannelId: outChannels[1].id
        )
    }
}
