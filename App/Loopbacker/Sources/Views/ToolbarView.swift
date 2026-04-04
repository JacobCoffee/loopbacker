import SwiftUI
import AppKit

struct ToolbarView: View {
    @EnvironmentObject var driverInstaller: DriverInstaller
    @EnvironmentObject var audioDeviceManager: AudioDeviceManager
    @EnvironmentObject var audioRouter: AudioRouter
    @EnvironmentObject var routingState: RoutingState
    @State private var showScenesPopover = false

    var body: some View {
        HStack(spacing: 0) {
            // MARK: - Left: Panic / Reset

            panicSection

            sectionDivider

            // MARK: - Center: Live Status

            statusSection

            sectionDivider

            // MARK: - Scenes

            scenesSection

            Spacer()

            // MARK: - Quick Route Actions

            quickRouteSection

            sectionDivider

            // MARK: - Utility: Test / Debug

            utilitySection

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
                color: LoopbackerTheme.danger,
                tooltip: "Stop all audio routing and disconnect all routes"
            ) {
                withAnimation {
                    audioRouter.stopAll()
                    routingState.disconnectAll()
                }
            }

            dockButton(
                label: "Reconnect",
                icon: "arrow.clockwise",
                color: LoopbackerTheme.accent,
                tooltip: "Restart audio routing (fixes glitches after sleep/wake)"
            ) {
                audioRouter.restartAllRoutes()
            }

            dockButton(
                label: "Reload",
                icon: "arrow.triangle.2.circlepath",
                color: LoopbackerTheme.accent,
                tooltip: "Re-scan system audio devices for hotplugged hardware"
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
            .help("\(routingState.routes.count) active route\(routingState.routes.count == 1 ? "" : "s") between sources and outputs")

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
            .help("Virtual device sample rate")

            // Underrun / health indicator
            HStack(spacing: 3) {
                Image(systemName: routingState.routes.isEmpty ? "minus.circle" : "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(routingState.routes.isEmpty
                        ? LoopbackerTheme.textMuted
                        : LoopbackerTheme.accent)
            }
            .help(routingState.routes.isEmpty ? "No active routes -- add sources and connect channels" : "Audio engine healthy, all routes active")

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
            .help(driverStatusTooltip)
        }
    }

    // MARK: - Scenes Section

    private var scenesSection: some View {
        HStack(spacing: 6) {
            Button(action: { showScenesPopover.toggle() }) {
                HStack(spacing: 3) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Scenes")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(LoopbackerTheme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(LoopbackerTheme.accent.opacity(0.1)))
                .overlay(Capsule().strokeBorder(LoopbackerTheme.accent.opacity(0.3), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help("Save, load, or delete routing presets (e.g. Podcast, Streaming, Discord)")
            .popover(isPresented: $showScenesPopover) {
                ScenesView()
            }
        }
    }

    // MARK: - Quick Route Section

    private var quickRouteSection: some View {
        HStack(spacing: 6) {
            dockButton(
                label: "Auto Stereo",
                icon: "arrow.left.arrow.right",
                color: LoopbackerTheme.accent,
                tooltip: "Auto-route first stereo input to output channels 1 & 2"
            ) {
                autoRouteStereo()
            }

            dockButton(
                label: "Disconnect",
                icon: "xmark.circle",
                color: LoopbackerTheme.warning,
                tooltip: "Remove all cable connections (keeps sources and outputs intact)"
            ) {
                withAnimation {
                    audioRouter.stopAll()
                    routingState.disconnectAll()
                }
            }
        }
    }

    // MARK: - Utility Section (Test Tone / Debug)

    private var utilitySection: some View {
        HStack(spacing: 6) {
            dockButton(
                label: "Test",
                icon: "tuningfork",
                color: LoopbackerTheme.accent,
                tooltip: "Play a 1kHz test tone through the virtual device for 2 seconds"
            ) {
                audioRouter.playTestTone(duration: 2.0)
            }

            dockButton(
                label: "Copy Debug",
                icon: "doc.on.clipboard",
                color: LoopbackerTheme.textSecondary,
                tooltip: "Copy a diagnostic snapshot to the clipboard for troubleshooting"
            ) {
                copyDebugSnapshot()
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
            .help(driverInstaller.isInstalled
                  ? "Uninstall the Loopbacker audio driver (requires admin)"
                  : "Install the Loopbacker audio driver (requires admin)")

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
            .help("Quit Loopbacker completely (stops all audio routing)")
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
        tooltip: String,
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
        .help(tooltip)
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

    private var driverStatusTooltip: String {
        if driverInstaller.isProcessing {
            return "Driver operation in progress..."
        }
        if !driverInstaller.isInstalled {
            return "Audio driver not installed -- click Install to set up"
        }
        return audioDeviceManager.loopbackerDevicePresent
            ? "Loopbacker virtual audio device is active and visible to the system"
            : "Driver installed but virtual device not detected -- try Reload"
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

    // MARK: - Debug Snapshot

    private func copyDebugSnapshot() {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"

        var lines: [String] = []
        lines.append("=== Loopbacker Debug Snapshot ===")
        lines.append("App Version: \(appVersion) (\(buildNumber))")
        lines.append("Date: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")

        // Driver status
        lines.append("-- Driver --")
        lines.append("Installed: \(driverInstaller.isInstalled)")
        lines.append("Virtual Device Present: \(audioDeviceManager.loopbackerDevicePresent)")
        lines.append("")

        // Sources
        lines.append("-- Sources (\(routingState.sources.count)) --")
        for source in routingState.sources {
            let status = source.isEnabled ? (source.isMuted ? "MUTED" : "ON") : "OFF"
            lines.append("  [\(status)] \(source.name) (\(source.channels.count)ch) uid=\(source.deviceUID)")
        }
        lines.append("")

        // Routes
        lines.append("-- Routes (\(routingState.routes.count)) --")
        for route in routingState.routes {
            let sourceName = routingState.sources.first(where: { $0.id == route.sourceId })?.name ?? "?"
            lines.append("  \(sourceName) ch\(route.sourceChannelId) -> out ch\(route.outputChannelId)")
        }
        lines.append("")

        // Output channels
        lines.append("-- Output Channels (\(routingState.outputChannels.count)) --")
        for ch in routingState.outputChannels {
            lines.append("  ch\(ch.id) \(ch.label) active=\(ch.isActive)")
        }
        lines.append("")

        // Output destinations
        lines.append("-- Output Destinations (\(routingState.outputDestinations.count)) --")
        for dest in routingState.outputDestinations {
            let status = dest.isEnabled ? "ON" : "OFF"
            lines.append("  [\(status)] \(dest.virtualDeviceName) -> \(dest.physicalOutputName) (\(dest.physicalOutputUID))")
        }
        lines.append("")

        // System audio devices
        lines.append("-- System Audio Devices (\(audioDeviceManager.systemDevices.count)) --")
        for device in audioDeviceManager.systemDevices {
            let io = [device.isInput ? "in:\(device.inputChannelCount)" : nil,
                       device.isOutput ? "out:\(device.outputChannelCount)" : nil]
                .compactMap { $0 }.joined(separator: " ")
            lines.append("  \(device.name) [\(io)] uid=\(device.uid)")
        }

        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
