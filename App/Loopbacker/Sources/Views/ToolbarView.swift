import SwiftUI
import AppKit

struct ToolbarView: View {
    @EnvironmentObject var driverInstaller: DriverInstaller
    @EnvironmentObject var audioDeviceManager: AudioDeviceManager
    @EnvironmentObject var audioRouter: AudioRouter
    @EnvironmentObject var routingState: RoutingState
    @State private var showScenesPopover = false

    var body: some View {
        HStack(spacing: 6) {
            // Left: Panic/Recovery (icon-only)
            iconButton("speaker.slash", color: LoopbackerTheme.danger,
                       tooltip: "Stop all audio routing and disconnect") {
                withAnimation { audioRouter.stopAll(); routingState.disconnectAll() }
            }

            iconButton("arrow.clockwise", color: LoopbackerTheme.accent,
                       tooltip: "Reconnect audio (fixes glitches after sleep)") {
                audioRouter.restartAllRoutes()
            }

            iconButton("arrow.triangle.2.circlepath", color: LoopbackerTheme.accent,
                       tooltip: "Rescan audio devices") {
                audioDeviceManager.enumerateDevices()
            }

            sectionDivider

            // Status: compact inline
            statusPill

            sectionDivider

            // Scenes (labeled -- primary action)
            Button(action: { showScenesPopover.toggle() }) {
                Label("Scenes", systemImage: "square.stack.3d.up")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(LoopbackerTheme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(LoopbackerTheme.accent.opacity(0.1)))
                    .overlay(Capsule().strokeBorder(LoopbackerTheme.accent.opacity(0.3), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .tooltip("Save, load, or delete routing presets")
            .popover(isPresented: $showScenesPopover) { ScenesView() }

            Spacer()

            // Quick actions (icon-only)
            iconButton("arrow.left.arrow.right", color: LoopbackerTheme.accent,
                       tooltip: "Auto-route first stereo input to outputs 1 & 2") {
                autoRouteStereo()
            }

            iconButton("xmark.circle", color: LoopbackerTheme.warning,
                       tooltip: "Disconnect all routes (keeps sources)") {
                withAnimation { audioRouter.stopAll(); routingState.disconnectAll() }
            }

            sectionDivider

            // Utilities (icon-only)
            iconButton("tuningfork", color: LoopbackerTheme.textSecondary,
                       tooltip: "Play 1kHz test tone for 2 seconds") {
                audioRouter.playTestTone(duration: 2.0)
            }

            iconButton("doc.on.clipboard", color: LoopbackerTheme.textSecondary,
                       tooltip: "Copy debug info to clipboard") {
                copyDebugSnapshot()
            }

            sectionDivider

            // System (labeled -- destructive/important)
            Button(action: {
                driverInstaller.isInstalled ? driverInstaller.uninstall() : driverInstaller.install()
            }) {
                HStack(spacing: 3) {
                    if driverInstaller.isProcessing {
                        ProgressView().controlSize(.mini).scaleEffect(0.7)
                    } else {
                        Image(systemName: driverInstaller.isInstalled ? "minus.circle" : "arrow.down.circle")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text(driverInstaller.isInstalled ? "Uninstall" : "Install")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(driverInstaller.isInstalled ? LoopbackerTheme.danger : LoopbackerTheme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(
                    (driverInstaller.isInstalled ? LoopbackerTheme.danger : LoopbackerTheme.accent).opacity(0.1)
                ))
                .overlay(Capsule().strokeBorder(
                    (driverInstaller.isInstalled ? LoopbackerTheme.danger : LoopbackerTheme.accent).opacity(0.3),
                    lineWidth: 0.5
                ))
            }
            .buttonStyle(.plain)
            .disabled(driverInstaller.isProcessing)
            .tooltip(driverInstaller.isInstalled ? "Uninstall audio driver" : "Install audio driver")

            iconButton("power", color: LoopbackerTheme.textMuted,
                       tooltip: "Quit Loopbacker (stops all routing)") {
                AppDelegate.forceQuit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(height: 36)
        .background(LoopbackerTheme.bgSurface)
        .overlay(Rectangle().fill(LoopbackerTheme.border).frame(height: 0.5), alignment: .top)
    }

    // MARK: - Components

    private func iconButton(_ icon: String, color: Color, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(color)
                .frame(width: 26, height: 26)
                .background(Circle().fill(color.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .tooltip(tooltip)
    }

    private var sectionDivider: some View {
        Divider().frame(height: 16).padding(.horizontal, 2)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            // Driver dot
            Circle()
                .fill(driverStatusColor)
                .frame(width: 6, height: 6)
                .shadow(color: driverStatusColor.opacity(0.5), radius: 2)

            // Route count
            HStack(spacing: 2) {
                Image(systemName: "cable.connector.horizontal")
                    .font(.system(size: 9))
                Text("\(routingState.routes.count)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
            }
            .foregroundColor(routingState.routes.isEmpty ? LoopbackerTheme.textMuted : LoopbackerTheme.textPrimary)

            // Sample rate
            Text("48k")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundColor(LoopbackerTheme.textMuted)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(LoopbackerTheme.bgInset))
        .overlay(Capsule().strokeBorder(LoopbackerTheme.border, lineWidth: 0.5))
        .tooltip(driverStatusTooltip)
    }

    // MARK: - Driver status

    private var driverStatusColor: Color {
        if driverInstaller.isProcessing { return LoopbackerTheme.warning }
        if !driverInstaller.isInstalled { return LoopbackerTheme.danger }
        return audioDeviceManager.loopbackerDevicePresent ? LoopbackerTheme.accent : LoopbackerTheme.warning
    }

    private var driverStatusTooltip: String {
        if driverInstaller.isProcessing { return "Driver operation in progress..." }
        if !driverInstaller.isInstalled { return "Driver not installed" }
        return audioDeviceManager.loopbackerDevicePresent
            ? "\(routingState.routes.count) routes active · 48kHz · Driver OK"
            : "Driver installed but virtual device not found"
    }

    // MARK: - Auto Route Stereo

    private func autoRouteStereo() {
        while routingState.outputChannels.count < 2 { routingState.addOutputChannel() }

        guard let source = routingState.sources.first(where: { $0.channels.count >= 2 && $0.isEnabled }) else {
            let inputDevices = audioDeviceManager.systemDevices.filter {
                $0.isInput && !$0.name.contains("Loopbacker") && $0.inputChannelCount >= 2
            }
            guard let device = inputDevices.first else { return }
            let newSource = audioDeviceManager.createSource(from: device)
            withAnimation { routingState.sources.append(newSource); addStereoRoutes(for: newSource) }
            return
        }
        withAnimation { addStereoRoutes(for: source) }
    }

    private func addStereoRoutes(for source: AudioSource) {
        let outChannels = routingState.outputChannels.sorted(by: { $0.id < $1.id })
        guard outChannels.count >= 2, source.channels.count >= 2 else { return }
        routingState.addRoute(sourceId: source.id, sourceChannelId: source.channels[0].id, outputChannelId: outChannels[0].id)
        routingState.addRoute(sourceId: source.id, sourceChannelId: source.channels[1].id, outputChannelId: outChannels[1].id)
    }

    // MARK: - Debug Snapshot

    private func copyDebugSnapshot() {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        var l = ["=== Loopbacker \(v) (\(b)) ===", ""]

        l.append("Driver: \(driverInstaller.isInstalled ? "installed" : "missing"), Virtual: \(audioDeviceManager.loopbackerDevicePresent ? "active" : "not found")")
        l.append("")

        for s in routingState.sources {
            l.append("[\(s.isEnabled ? (s.isMuted ? "MUTED" : "ON") : "OFF")] \(s.name) (\(s.channels.count)ch) uid=\(s.deviceUID)")
        }
        l.append("")

        for r in routingState.routes {
            let n = routingState.sources.first { $0.id == r.sourceId }?.name ?? "?"
            l.append("\(n) ch\(r.sourceChannelId) → out\(r.outputChannelId)")
        }
        l.append("")

        for d in routingState.outputDestinations {
            l.append("[\(d.isEnabled ? "ON" : "OFF")] \(d.virtualDeviceName) → \(d.physicalOutputName)")
        }
        l.append("")

        for d in audioDeviceManager.systemDevices {
            let io = [d.isInput ? "in:\(d.inputChannelCount)" : nil, d.isOutput ? "out:\(d.outputChannelCount)" : nil].compactMap{$0}.joined(separator: " ")
            l.append("\(d.name) [\(io)]")
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(l.joined(separator: "\n"), forType: .string)
    }
}
