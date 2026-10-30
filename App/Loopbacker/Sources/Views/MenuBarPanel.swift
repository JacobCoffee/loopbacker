import SwiftUI

/// Compact status console shown from the menu bar extra. Mirrors the engine status and sources
/// from the main window so the signal stays legible without opening it.
struct MenuBarPanel: View {
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var audioDeviceManager: AudioDeviceManager
    @EnvironmentObject var driverInstaller: DriverInstaller
    @EnvironmentObject var audioRouter: AudioRouter
    @EnvironmentObject var appCaptureService: AppCaptureService
    @EnvironmentObject var appUpdater: AppUpdater

    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var loginItem = LoginItem.shared

    private var engineStatus: EngineStatus {
        EngineStatus(driverInstaller: driverInstaller, audioDeviceManager: audioDeviceManager, routingState: routingState)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 12)
            if appUpdater.availableUpdate != nil || driverInstaller.updateAvailable {
                updateBanner
                Divider()
                    .padding(.vertical, 12)
            }
            sourcesList
            Divider()
                .padding(.vertical, 12)
            noiseSuppressionRow
            Divider()
                .padding(.vertical, 12)
            actions
            Divider()
                .padding(.vertical, 12)
            footer
        }
        .padding(Metrics.panelPadding)
        .frame(width: 300)
        .onAppear { loginItem.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        let status = engineStatus
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Loopbacker")
                    .font(.headline)
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                LiveDot(color: status.color, isLive: status.isLive)
                Text(status.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(status.isLive ? AnyShapeStyle(.loopbacker) : AnyShapeStyle(.primary))
            }
            .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Updates

    /// Non-modal "update available" row for the app and/or the driver. Never pops a window;
    /// installing only happens when the user taps a button here (or the app quits with the
    /// app update already downloaded).
    @ViewBuilder
    private var updateBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let update = appUpdater.availableUpdate {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.body)
                        .foregroundStyle(.loopbacker)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Update available")
                            .font(.callout)
                        Text("Loopbacker \(update.displayVersion)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Install") { appUpdater.installAvailableUpdate() }
                        .buttonStyle(.glassProminent)
                        .tint(.loopbacker)
                        .controlSize(.small)
                        .help("Install now and relaunch, or it installs automatically on quit")
                }
            }
            if driverInstaller.updateAvailable {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.body)
                        .foregroundStyle(Color.signalWarm)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Driver update available")
                            .font(.callout)
                        Text("Needs admin; briefly drops audio")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Install") { driverInstaller.install() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(driverInstaller.isProcessing)
                        .help("Reinstalls the driver and restarts coreaudiod")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Sources

    @ViewBuilder
    private var sourcesList: some View {
        if routingState.sources.isEmpty {
            Label("No sources", systemImage: "speaker.slash")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(routingState.sources) { source in
                    sourceRow(source)
                }
            }
        }
    }

    private func sourceRow(_ source: AudioSource) -> some View {
        let isLive = source.isEnabled && !source.isMuted
        return HStack(spacing: 10) {
            Image(systemName: source.icon)
                .font(.body)
                .foregroundStyle(isLive ? AnyShapeStyle(.loopbacker) : AnyShapeStyle(.secondary))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(source.name)
                        .font(.callout)
                        .foregroundStyle(source.isEnabled ? .primary : .secondary)
                        .lineLimit(1)
                    if source.isMuted {
                        StatusTag(title: "Muted", tint: .signalWarm)
                    }
                }
                SourcePeakMeter(key: source.deviceUID, isLive: isLive)
            }

            Toggle(source.isEnabled ? "Turn off \(source.name)" : "Turn on \(source.name)", isOn: Binding(
                get: { source.isEnabled },
                set: { _ in routingState.toggleSource(source.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(.loopbacker)
            .help("Turn \(source.name) on or off")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(source.name), \(source.isMuted ? "muted" : source.isEnabled ? "on" : "off")")
    }

    // MARK: - Noise suppression

    private var noiseSuppressionRow: some View {
        let settings = routingState.noiseSuppression
        let on = settings.isEnabled
        return HStack(spacing: 10) {
            Image(systemName: "waveform.badge.minus")
                .font(.body)
                .foregroundStyle(on ? AnyShapeStyle(.loopbacker) : AnyShapeStyle(.secondary))
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text("Noise Suppression")
                    .font(.callout)
                Picker("Engine", selection: Binding(
                    get: { settings.engine },
                    set: { engine in
                        routingState.noiseSuppression.engine = engine
                        routingState.save()
                    }
                )) {
                    ForEach(NoiseSuppressionEngine.allCases) { engine in
                        let profile = NoiseEngineProfile.of(engine)
                        Text("\(profile.name) · \(profile.latencyMs) ms").tag(engine)
                    }
                }
                .pickerStyle(.menu)
                .menuStyle(.borderlessButton)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
                .help("Noise suppression engine: DPDFNet cleans up more, RNNoise adds less delay")
            }

            Spacer(minLength: 8)

            Toggle(on ? "Turn off noise suppression" : "Turn on noise suppression", isOn: Binding(
                get: { on },
                set: { newValue in
                    routingState.noiseSuppression.isEnabled = newValue
                    routingState.save()
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(.loopbacker)
            .help("Remove background noise from mic inputs")
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    audioRouter.restartAllRoutes()
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .help("Reconnect audio (fixes glitches after sleep)")

                Button {
                    audioRouter.playTestTone(duration: 2.0)
                } label: {
                    Label("Test Tone", systemImage: "tuningfork")
                        .frame(maxWidth: .infinity)
                }
                .help("Play a 1 kHz test tone for 2 seconds")
            }
            .buttonStyle(.glass)

            Button {
                openWindow(id: WindowID.main)
                NSApp.activate()
            } label: {
                Label("Open Loopbacker", systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(.loopbacker)
            .help("Open the Loopbacker window")
        }
        .controlSize(.large)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Open at Login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.callout)
            .help("Start Loopbacker in the menu bar when you log in, so routing is live without opening it")

            if loginItem.needsApproval {
                Button("Allow in Login Items…") { loginItem.openSystemSettings() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("macOS needs your OK in System Settings › General › Login Items")
            } else if let error = loginItem.error {
                Text("Couldn't change Open at Login: \(error)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("\(routingState.outputDestinations.count) output route\(routingState.outputDestinations.count == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit", role: .destructive) {
                    AppDelegate.forceQuit()
                }
                .buttonStyle(.borderless)
                .font(.callout)
                .help("Quit Loopbacker and stop all routing")
            }
        }
    }
}
