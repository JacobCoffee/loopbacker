import SwiftUI

/// Main window sidebar: sections, live sources, and engine status.
struct SidebarView: View {
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var audioDeviceManager: AudioDeviceManager
    @EnvironmentObject var driverInstaller: DriverInstaller
    @EnvironmentObject var appCaptureService: AppCaptureService
    @EnvironmentObject var soundboardState: SoundboardState

    @Binding var section: StudioSection
    @State private var showSourcePicker = false

    private var selection: Binding<StudioSection?> {
        Binding(get: { section }, set: { if let new = $0 { section = new } })
    }

    var body: some View {
        List(selection: selection) {
            Section {
                ForEach(StudioSection.allCases) { item in
                    Label(item.title, systemImage: item.symbol)
                        .badge(badge(for: item))
                        .tag(item)
                }
            }

            Section {
                if routingState.sources.isEmpty {
                    Button {
                        showSourcePicker = true
                    } label: {
                        Label("Add a Source", systemImage: "plus.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                } else {
                    ForEach(routingState.sources) { source in
                        SidebarSourceRow(source: source, isMissing: isMissing(source),
                                         isAppStopped: isAppStopped(source))
                    }
                }
            } header: {
                HStack {
                    Text("Sources")
                    Spacer()
                    Button {
                        showSourcePicker = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Add an input device or app as a source")
                    .accessibilityLabel("Add Source")
                    .popover(isPresented: $showSourcePicker, arrowEdge: .trailing) {
                        SourcePickerView { showSourcePicker = false }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            EngineStatusFooter()
        }
    }

    private func badge(for item: StudioSection) -> Text? {
        switch item {
        case .routing:
            let n = routingState.routes.count
            return n > 0 ? Text("\(n)") : nil
        case .effects:
            return routingState.effectsPreset.isEnabled ? Text("On") : nil
        case .soundboard:
            let n = soundboardState.items.count
            return n > 0 ? Text("\(n)") : nil
        case .scenes:
            return nil
        }
    }

    private func isMissing(_ source: AudioSource) -> Bool {
        guard !source.isAppCapture, !source.deviceUID.isEmpty,
              !audioDeviceManager.systemDevices.isEmpty else { return false }
        return !audioDeviceManager.systemDevices.contains { $0.uid == source.deviceUID }
    }

    private func isAppStopped(_ source: AudioSource) -> Bool {
        source.isAppCapture && !appCaptureService.isAppRunning(bundleID: source.appBundleID)
    }
}

// MARK: - Source row

private struct SidebarSourceRow: View {
    @EnvironmentObject var routingState: RoutingState
    let source: AudioSource
    let isMissing: Bool
    let isAppStopped: Bool

    private var isLive: Bool { source.isEnabled && !source.isMuted }
    private var level: Float { source.channels.map(\.meterLevel).max() ?? 0 }

    private var enabled: Binding<Bool> {
        Binding(get: { source.isEnabled }, set: { _ in routingState.toggleSource(source.id) })
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: source.icon)
                .foregroundStyle(isLive ? AnyShapeStyle(Color.loopbacker) : AnyShapeStyle(.secondary))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(source.name)
                        .lineLimit(1)
                        .foregroundStyle(source.isEnabled ? .primary : .secondary)
                    if let tag = statusTag { tag }
                }
                SignalMeter(level: isLive ? level : 0, thickness: 3)
                    .opacity(isLive ? 1 : 0.5)
            }

            Toggle(source.isEnabled ? "Disable \(source.name)" : "Enable \(source.name)", isOn: enabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(.loopbacker)
                .help(source.isEnabled ? "Stop capturing \(source.name)" : "Start capturing \(source.name)")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(source.isMuted ? "Unmute" : "Mute") { routingState.muteSource(source.id) }
            Button("Solo") { routingState.soloSource(source.id) }
            Divider()
            Button("Remove \(source.name)", role: .destructive) {
                withAnimation { routingState.removeSource(source.id) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isLive ? SignalMeter.dbString(level) : (source.isEnabled ? "Muted" : "Off"))
    }

    private var statusTag: StatusTag? {
        if isMissing { return StatusTag(title: "Unavailable", tint: .signalWarm) }
        if isAppStopped { return StatusTag(title: "Not Running") }
        if source.isMuted { return StatusTag(title: "Muted", tint: .signalWarm) }
        return nil
    }
}

// MARK: - Engine status footer

private struct EngineStatusFooter: View {
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var audioDeviceManager: AudioDeviceManager
    @EnvironmentObject var driverInstaller: DriverInstaller

    private var status: EngineStatus {
        EngineStatus(driverInstaller: driverInstaller, audioDeviceManager: audioDeviceManager, routingState: routingState)
    }

    var body: some View {
        let status = status
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                LiveDot(color: status.color, isLive: status.isLive)
                VStack(alignment: .leading, spacing: 1) {
                    Text(status.title)
                        .font(.callout.weight(.semibold))
                    Text(status.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)

            if case .noDriver = status {
                Button {
                    driverInstaller.install()
                } label: {
                    Label("Install Driver", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(.loopbacker)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
