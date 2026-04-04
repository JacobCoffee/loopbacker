import SwiftUI

/// Card-style view for routing Loopbacker virtual devices to physical outputs.
/// Users can add/remove virtual devices dynamically (Loopbacker 2 through 8).
struct OutputRoutingView: View {
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var audioDeviceManager: AudioDeviceManager
    @EnvironmentObject var audioRouter: AudioRouter

    /// All available virtual devices (indices 2-8, device 1 is the main loopback)
    private static let allVirtualDevices: [(uid: String, name: String)] = (2...8).map { i in
        ("LoopbackerDevice_UID_\(i)", "Loopbacker \(i)")
    }

    /// How many virtual output devices are currently shown
    private var activeCount: Int {
        routingState.outputDestinations.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header with +/- buttons
            HStack {
                Spacer()

                if activeCount > 0 {
                    Text("\(activeCount) device\(activeCount == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundColor(LoopbackerTheme.textMuted)
                }

                // Remove button
                if activeCount > 0 {
                    Button(action: removeLastDevice) {
                        Image(systemName: "minus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(LoopbackerTheme.textSecondary)
                            .frame(width: 22, height: 22)
                            .background(LoopbackerTheme.bgInset)
                            .clipShape(Circle())
                            .overlay(Circle().strokeBorder(LoopbackerTheme.border, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Remove the last virtual output device and stop its routing")
                }

                // Add button
                if activeCount < Self.allVirtualDevices.count {
                    Button(action: addNextDevice) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(LoopbackerTheme.accent)
                            .frame(width: 22, height: 22)
                            .background(LoopbackerTheme.accent.opacity(0.1))
                            .clipShape(Circle())
                            .overlay(Circle().strokeBorder(LoopbackerTheme.accent.opacity(0.3), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Add a new virtual output device (Loopbacker \(activeCount + 2)) for routing to a physical output")
                }
            }

            // Device cards
            ForEach(routingState.outputDestinations) { dest in
                outputCard(dest: dest)
            }

            if activeCount == 0 {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.right.circle.dashed")
                            .font(.system(size: 22))
                            .foregroundColor(LoopbackerTheme.textMuted)
                        Text("Click + to add an output route")
                            .font(.system(size: 11))
                            .foregroundColor(LoopbackerTheme.textMuted)
                    }
                    .padding(.vertical, 20)
                    Spacer()
                }
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
        // Stop routing if active
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
            // Header
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? LoopbackerTheme.accent.opacity(0.15) : LoopbackerTheme.bgInset)
                        .frame(width: 32, height: 32)

                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(isActive ? LoopbackerTheme.accent : LoopbackerTheme.textMuted)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(dest.virtualDeviceName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(LoopbackerTheme.textPrimary)

                    Text("Virtual Device")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(LoopbackerTheme.textSecondary)
                }

                Spacer()

                enableToggle(dest: dest)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().background(LoopbackerTheme.border)

            // Output device picker
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 11))
                    .foregroundColor(LoopbackerTheme.textSecondary)

                Text("Output:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(LoopbackerTheme.textSecondary)

                outputPicker(dest: dest)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: LoopbackerTheme.cardCornerRadius)
                .fill(LoopbackerTheme.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LoopbackerTheme.cardCornerRadius)
                .strokeBorder(
                    isActive ? LoopbackerTheme.borderActive : LoopbackerTheme.border,
                    lineWidth: isActive ? 1.5 : 0.5
                )
        )
        .shadow(
            color: isActive ? LoopbackerTheme.accentGlow.opacity(0.15) : Color.clear,
            radius: 8
        )
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(LoopbackerTheme.accent)
        .help("Select the physical audio output device for this virtual device")
    }

    // MARK: - Enable toggle

    private func enableToggle(dest: OutputDestination) -> some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                routingState.toggleOutputDestination(id: dest.id)
                if dest.isEnabled {
                    audioRouter.stopOutputRouting(virtualDeviceUID: dest.virtualDeviceUID)
                } else {
                    if !dest.physicalOutputUID.isEmpty {
                        audioRouter.startOutputRouting(
                            virtualDeviceUID: dest.virtualDeviceUID,
                            physicalOutputUID: dest.physicalOutputUID
                        )
                    }
                }
            }
        }) {
            HStack(spacing: 4) {
                Circle()
                    .fill(dest.isEnabled ? LoopbackerTheme.accent : LoopbackerTheme.textMuted)
                    .frame(width: 6, height: 6)
                    .shadow(color: dest.isEnabled ? LoopbackerTheme.accentGlow : .clear, radius: 3)

                Text(dest.isEnabled ? "ON" : "OFF")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(dest.isEnabled ? LoopbackerTheme.accent : LoopbackerTheme.textMuted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(dest.isEnabled ? LoopbackerTheme.accent.opacity(0.12) : LoopbackerTheme.bgInset)
            )
            .overlay(
                Capsule().strokeBorder(
                    dest.isEnabled ? LoopbackerTheme.accent.opacity(0.3) : LoopbackerTheme.border,
                    lineWidth: 0.5
                )
            )
        }
        .buttonStyle(.plain)
        .help(dest.isEnabled ? "Disable output routing for this virtual device" : "Enable output routing for this virtual device")
    }

    // MARK: - Helpers

    private func updateDestination(dest: OutputDestination, physicalOutputUID: String, physicalOutputName: String) {
        // Stop old route
        if !dest.physicalOutputUID.isEmpty {
            audioRouter.stopOutputRouting(virtualDeviceUID: dest.virtualDeviceUID)
        }

        if let idx = routingState.outputDestinations.firstIndex(where: { $0.id == dest.id }) {
            routingState.outputDestinations[idx].physicalOutputUID = physicalOutputUID
            routingState.outputDestinations[idx].physicalOutputName = physicalOutputName
            routingState.save()
        }

        // Start new route
        if !physicalOutputUID.isEmpty, dest.isEnabled {
            audioRouter.startOutputRouting(virtualDeviceUID: dest.virtualDeviceUID, physicalOutputUID: physicalOutputUID)
        }
    }
}
