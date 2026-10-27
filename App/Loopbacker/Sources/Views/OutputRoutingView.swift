import SwiftUI

/// Card-style view for routing Loopbacker virtual devices to physical outputs, with each
/// device's channel count and the monitored channel pair.
struct OutputRoutingView: View {
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var audioDeviceManager: AudioDeviceManager
    @EnvironmentObject var audioRouter: AudioRouter
    @EnvironmentObject var appCaptureService: AppCaptureService

    /// All available virtual devices (device 1 is the main loopback, device 2 is for output routing)
    private static let allVirtualDevices: [(uid: String, name: String)] = [
        ("LoopbackerDevice_UID_2", "Loopbacker 2"),
    ]

    /// How many virtual output devices are currently shown
    private var activeCount: Int {
        routingState.outputDestinations.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.panelSpacing) {
            header

            GlassEffectContainer(spacing: Metrics.panelSpacing) {
                VStack(spacing: Metrics.panelSpacing) {
                    ForEach(routingState.outputDestinations) { dest in
                        outputCard(dest: dest)
                    }

                    if activeCount == 0 {
                        EmptyStateView(
                            title: "No Output Routes",
                            message: "Click + to add an output route",
                            symbol: "arrow.right.circle.dashed"
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Output Routing")
                .font(.headline)

            Spacer()

            if activeCount > 0 {
                Text("\(activeCount) device\(activeCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if activeCount > 0 {
                Button(action: removeLastDevice) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .font(.title3)
                .foregroundStyle(.secondary)
                .help("Remove the last virtual output device and stop its routing")
                .accessibilityLabel("Remove last output device")
            }

            if activeCount < Self.allVirtualDevices.count {
                Button(action: addNextDevice) {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .font(.title3)
                .foregroundStyle(.secondary)
                .help("Add a new virtual output device (Loopbacker \(activeCount + 2)) for routing to a physical output")
                .accessibilityLabel("Add output device")
            }
        }
    }

    // MARK: - Add/Remove

    private func addNextDevice() {
        let idx = activeCount
        guard idx < Self.allVirtualDevices.count else { return }
        let vd = Self.allVirtualDevices[idx]
        withAnimation(.easeInOut(duration: 0.2)) {
            routingState.addOutputDestination(
                virtualDeviceUID: vd.uid,
                virtualDeviceName: vd.name,
                physicalOutputUID: "",
                physicalOutputName: "None"
            )
        }
    }

    private func removeLastDevice() {
        guard let last = routingState.outputDestinations.last else { return }
        audioRouter.stopOutputRouting(virtualDeviceUID: last.virtualDeviceUID)
        withAnimation(.easeInOut(duration: 0.2)) {
            routingState.removeOutputDestination(id: last.id)
        }
    }

    // MARK: - Per-device card

    @ViewBuilder
    private func outputCard(dest: OutputDestination) -> some View {
        let isActive = dest.isEnabled && !dest.physicalOutputUID.isEmpty

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isActive ? Color.loopbacker.opacity(0.18) : Color.secondary.opacity(0.12))
                        .frame(width: 32, height: 32)

                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isActive ? Color.loopbacker : .secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(dest.virtualDeviceName)
                        .font(.headline)
                    Text("Virtual Device")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Toggle(dest.isEnabled ? "Disable output routing for \(dest.virtualDeviceName)" : "Enable output routing for \(dest.virtualDeviceName)", isOn: Binding(
                    get: { dest.isEnabled },
                    set: { _ in toggleEnable(dest: dest) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help(dest.isEnabled ? "Disable output routing for this virtual device" : "Enable output routing for this virtual device")
            }
            .padding(.horizontal, Metrics.panelPadding)
            .padding(.vertical, 10)

            Divider().opacity(0.5)

            HStack(spacing: 8) {
                Text("Output")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                outputPicker(dest: dest)
            }
            .padding(.horizontal, Metrics.panelPadding)
            .padding(.top, 10)

            HStack(spacing: 8) {
                Text("Channels")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                channelCountPicker(dest: dest)
                Text("Monitor")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                monitorPairPicker(dest: dest)
            }
            .padding(.horizontal, Metrics.panelPadding)
            .padding(.vertical, 10)

            if let reported = reportedChannels(dest), reported < dest.channelCount {
                Label("The installed driver provides \(reported) channels. Reinstall the driver to use \(dest.channelCount).",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, Metrics.panelPadding)
                    .padding(.bottom, 10)
            }

            if isActive {
                SourcePeakMeter(key: "output:\(dest.virtualDeviceUID)", isLive: true)
                    .frame(height: 10)
                    .padding(.horizontal, Metrics.panelPadding)
                    .padding(.bottom, 10)
            }
        }
        .glassPanel()
    }

    // MARK: - Output device picker

    @ViewBuilder
    private func outputPicker(dest: OutputDestination) -> some View {
        let devices = audioDeviceManager.outputDevices

        Picker("", selection: Binding(
            get: { dest.physicalOutputUID },
            set: { newUID in
                let deviceName = devices.first(where: { $0.uid == newUID })?.name ?? "None"
                updateDestination(dest: dest, physicalOutputUID: newUID, physicalOutputName: deviceName)
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
        .help("Select the physical audio output device for this virtual device")
    }

    // MARK: - Channel pickers

    /// Width of the virtual device that apps (e.g. Resolve, a timecode reader) see.
    @ViewBuilder
    private func channelCountPicker(dest: OutputDestination) -> some View {
        Picker("Channels", selection: Binding(
            get: { dest.channelCount },
            set: { setChannelCount($0, dest: dest) }
        )) {
            ForEach(VirtualDeviceChannels.supportedCounts, id: \.self) { count in
                Text("\(count)").tag(count)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .help("How many channels \(dest.virtualDeviceName) offers to apps")
    }

    /// Which pair of the virtual device plays to the physical output.
    @ViewBuilder
    private func monitorPairPicker(dest: OutputDestination) -> some View {
        Picker("Monitor", selection: Binding(
            get: { dest.monitorChannel },
            set: { setMonitorChannel($0, dest: dest) }
        )) {
            ForEach(Array(stride(from: 1, to: dest.channelCount, by: 2)), id: \.self) { first in
                Text("\(first)\u{2013}\(first + 1)").tag(first)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .help("The channel pair of \(dest.virtualDeviceName) you hear on the output; other channels stay on the device for apps to record")
    }

    // MARK: - Enable toggle

    private func toggleEnable(dest: OutputDestination) {
        withAnimation(.easeInOut(duration: 0.2)) {
            routingState.toggleOutputDestination(id: dest.id)
            if dest.isEnabled {
                audioRouter.stopOutputRouting(virtualDeviceUID: dest.virtualDeviceUID)
            } else if !dest.physicalOutputUID.isEmpty {
                audioRouter.startOutputRouting(
                    virtualDeviceUID: dest.virtualDeviceUID,
                    physicalOutputUID: dest.physicalOutputUID,
                    monitorChannel: dest.monitorChannel
                )
            }
        }
    }

    // MARK: - Helpers

    private func updateDestination(dest: OutputDestination, physicalOutputUID: String, physicalOutputName: String) {
        if !dest.physicalOutputUID.isEmpty {
            audioRouter.stopOutputRouting(virtualDeviceUID: dest.virtualDeviceUID)
        }

        if let idx = routingState.outputDestinations.firstIndex(where: { $0.id == dest.id }) {
            routingState.outputDestinations[idx].physicalOutputUID = physicalOutputUID
            routingState.outputDestinations[idx].physicalOutputName = physicalOutputName
            routingState.save()
        }

        if !physicalOutputUID.isEmpty, dest.isEnabled {
            audioRouter.startOutputRouting(virtualDeviceUID: dest.virtualDeviceUID, physicalOutputUID: physicalOutputUID,
                                           monitorChannel: dest.monitorChannel)
        }
    }

    private func setChannelCount(_ count: Int, dest: OutputDestination) {
        routingState.setOutputDestinationChannels(id: dest.id, channelCount: count)
        audioRouter.setVirtualDeviceChannels(count, deviceUID: dest.virtualDeviceUID,
                                             appCaptureService: appCaptureService) { [audioDeviceManager] _ in
            audioDeviceManager.enumerateDevices()
        }
        // A narrower device may have pushed the monitor pair down; replay it.
        if let updated = routingState.outputDestinations.first(where: { $0.id == dest.id }),
           updated.monitorChannel != dest.monitorChannel {
            restartIfRouting(updated)
        }
    }

    private func setMonitorChannel(_ first: Int, dest: OutputDestination) {
        routingState.setOutputDestinationMonitorChannel(id: dest.id, monitorChannel: first)
        if let updated = routingState.outputDestinations.first(where: { $0.id == dest.id }) {
            restartIfRouting(updated)
        }
    }

    private func restartIfRouting(_ dest: OutputDestination) {
        guard dest.isEnabled, !dest.physicalOutputUID.isEmpty else { return }
        audioRouter.startOutputRouting(virtualDeviceUID: dest.virtualDeviceUID, physicalOutputUID: dest.physicalOutputUID,
                                       monitorChannel: dest.monitorChannel)
    }

    /// Input channels the installed driver reports for the destination's virtual device.
    private func reportedChannels(_ dest: OutputDestination) -> Int? {
        audioDeviceManager.systemDevices.first { $0.uid == dest.virtualDeviceUID }?.inputChannelCount
    }
}
