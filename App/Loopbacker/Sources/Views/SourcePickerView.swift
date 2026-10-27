import SwiftUI

/// Popover listing input devices and running apps that can be added as sources.
struct SourcePickerView: View {
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var audioDeviceManager: AudioDeviceManager
    @EnvironmentObject var appCaptureService: AppCaptureService
    let onDone: () -> Void

    private var inputDevices: [SystemAudioDevice] {
        audioDeviceManager.systemDevices.filter { $0.isInput && !$0.name.contains("Loopbacker") }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("Devices") {
                    if inputDevices.isEmpty {
                        placeholder("No input devices found", symbol: "mic.slash")
                    } else {
                        ForEach(inputDevices) { device in
                            deviceRow(device)
                        }
                    }
                }

                section("App Audio") {
                    if !appCaptureService.permissionGranted {
                        permissionRow
                    } else if appCaptureService.availableApps.isEmpty {
                        VStack(spacing: 6) {
                            placeholder("No apps detected", symbol: "app.dashed")
                            Button("Refresh") {
                                Task { await appCaptureService.refreshApps() }
                            }
                            .buttonStyle(.glass)
                            .tint(nil)
                            .controlSize(.small)
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        ForEach(appCaptureService.availableApps) { app in
                            appRow(app)
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 320)
        .frame(maxHeight: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            Task { await appCaptureService.refreshApps() }
        }
    }

    // MARK: - Layout pieces

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            content()
        }
    }

    private func placeholder(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }

    private func row<Icon: View>(title: String, subtitle: String, added: Bool,
                                 @ViewBuilder icon: () -> Icon,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon()
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(added ? .secondary : .primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if added {
                    Label("Added", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.loopbacker)
                        .imageScale(.large)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(.rect(cornerRadius: Metrics.innerRadius))
        }
        .buttonStyle(PickerRowStyle())
        .disabled(added)
    }

    // MARK: - Rows

    private func deviceRow(_ device: SystemAudioDevice) -> some View {
        let added = routingState.sources.contains { $0.name == device.name }
        return row(title: device.name,
                   subtitle: "\(device.inputChannelCount) in · \(device.outputChannelCount) out",
                   added: added) {
            Image(systemName: "mic.fill")
                .foregroundStyle(added ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.loopbacker))
        } action: {
            let newSource = audioDeviceManager.createSource(from: device)
            withAnimation(.easeOut(duration: 0.2)) {
                routingState.sources.append(newSource)
                routingState.save()
            }
            onDone()
        }
    }

    private func appRow(_ app: CaptureApp) -> some View {
        let added = routingState.sources.contains { $0.appBundleID == app.id }
        return row(title: app.name, subtitle: "App Audio", added: added) {
            if let icon = app.icon {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app.fill").foregroundStyle(.secondary)
            }
        } action: {
            let newSource = AudioSource.fromApp(app)
            withAnimation(.easeOut(duration: 0.2)) {
                routingState.sources.append(newSource)
                routingState.save()
            }
            onDone()
        }
    }

    private var permissionRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screen Recording Permission")
                        .font(.body.weight(.medium))
                    Text("Required to capture audio from apps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(Color.loopbacker)
            }

            HStack(spacing: 8) {
                Button("Grant Access") {
                    Task {
                        if await appCaptureService.checkPermission() {
                            await appCaptureService.refreshApps()
                        }
                    }
                }
                .buttonStyle(.glassProminent)
                .tint(.loopbacker)

                Button("Open Settings") {
                    appCaptureService.openPermissionSettings()
                }
                .buttonStyle(.glass)
                .tint(nil)
            }
            .controlSize(.small)
        }
        .padding(8)
    }
}

/// Plain row button with a native-feeling hover/press highlight.
private struct PickerRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PickerRow(configuration: configuration)
    }

    private struct PickerRow: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: Metrics.innerRadius)
                        .fill(.quaternary)
                        .opacity(isEnabled && (hovering || configuration.isPressed) ? (configuration.isPressed ? 1 : 0.6) : 0)
                }
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }
}
