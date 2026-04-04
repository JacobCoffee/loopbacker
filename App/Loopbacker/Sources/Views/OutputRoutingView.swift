import SwiftUI

/// Card-style view for routing a Loopbacker virtual device to a physical output.
struct OutputRoutingView: View {
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var audioDeviceManager: AudioDeviceManager
    @EnvironmentObject var audioRouter: AudioRouter

    /// Available virtual devices for per-app routing (Loopbacker 2 and 3).
    private let virtualDevices: [(uid: String, name: String)] = [
        ("LoopbackerDevice_UID_2", "Loopbacker 2"),
        ("LoopbackerDevice_UID_3", "Loopbacker 3"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(virtualDevices, id: \.uid) { vd in
                outputCard(virtualDeviceUID: vd.uid, virtualDeviceName: vd.name)
            }
        }
    }

    // MARK: - Per-device card

    @ViewBuilder
    private func outputCard(virtualDeviceUID: String, virtualDeviceName: String) -> some View {
        let destIndex = routingState.outputDestinations.firstIndex(where: { $0.virtualDeviceUID == virtualDeviceUID })

        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LoopbackerTheme.accent.opacity(0.15))
                        .frame(width: 32, height: 32)

                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(LoopbackerTheme.accent)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(virtualDeviceName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(LoopbackerTheme.textPrimary)

                    Text("Virtual Device")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(LoopbackerTheme.textSecondary)
                }

                Spacer()

                // Enable/disable toggle
                if let idx = destIndex {
                    enableToggle(destIndex: idx)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()
                .background(LoopbackerTheme.border)

            // Output device picker
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 11))
                    .foregroundColor(LoopbackerTheme.textSecondary)

                Text("Output:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(LoopbackerTheme.textSecondary)

                outputPicker(virtualDeviceUID: virtualDeviceUID, virtualDeviceName: virtualDeviceName, destIndex: destIndex)
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
                    isActiveRoute(virtualDeviceUID: virtualDeviceUID, destIndex: destIndex)
                        ? LoopbackerTheme.borderActive
                        : LoopbackerTheme.border,
                    lineWidth: isActiveRoute(virtualDeviceUID: virtualDeviceUID, destIndex: destIndex) ? 1.5 : 0.5
                )
        )
        .shadow(
            color: isActiveRoute(virtualDeviceUID: virtualDeviceUID, destIndex: destIndex)
                ? LoopbackerTheme.accentGlow.opacity(0.15)
                : Color.clear,
            radius: 8
        )
    }

    // MARK: - Output device picker

    @ViewBuilder
    private func outputPicker(virtualDeviceUID: String, virtualDeviceName: String, destIndex: Int?) -> some View {
        let selectedUID = destIndex.map { routingState.outputDestinations[$0].physicalOutputUID } ?? ""
        let devices = audioDeviceManager.outputDevices

        Picker("", selection: Binding(
            get: { selectedUID },
            set: { newUID in
                let deviceName = devices.first(where: { $0.uid == newUID })?.name ?? "None"
                updateOutputDestination(
                    virtualDeviceUID: virtualDeviceUID,
                    virtualDeviceName: virtualDeviceName,
                    physicalOutputUID: newUID,
                    physicalOutputName: deviceName
                )
            }
        )) {
            Text("None")
                .tag("")

            ForEach(devices) { device in
                Text(device.name)
                    .tag(device.uid)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(LoopbackerTheme.accent)
    }

    // MARK: - Enable toggle

    private func enableToggle(destIndex: Int) -> some View {
        let dest = routingState.outputDestinations[destIndex]
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                routingState.toggleOutputDestination(id: dest.id)
                if dest.isEnabled {
                    // Was enabled, now disabled -- stop
                    audioRouter.stopOutputRouting(virtualDeviceUID: dest.virtualDeviceUID)
                } else {
                    // Was disabled, now enabled -- start if has a physical output
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
                Capsule()
                    .fill(dest.isEnabled ? LoopbackerTheme.accent.opacity(0.12) : LoopbackerTheme.bgInset)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        dest.isEnabled ? LoopbackerTheme.accent.opacity(0.3) : LoopbackerTheme.border,
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func isActiveRoute(virtualDeviceUID: String, destIndex: Int?) -> Bool {
        guard let idx = destIndex else { return false }
        let dest = routingState.outputDestinations[idx]
        return dest.isEnabled && !dest.physicalOutputUID.isEmpty
    }

    private func updateOutputDestination(virtualDeviceUID: String, virtualDeviceName: String,
                                         physicalOutputUID: String, physicalOutputName: String) {
        if let idx = routingState.outputDestinations.firstIndex(where: { $0.virtualDeviceUID == virtualDeviceUID }) {
            let oldDest = routingState.outputDestinations[idx]

            // Stop old route if running
            if !oldDest.physicalOutputUID.isEmpty {
                audioRouter.stopOutputRouting(virtualDeviceUID: virtualDeviceUID)
            }

            routingState.outputDestinations[idx].physicalOutputUID = physicalOutputUID
            routingState.outputDestinations[idx].physicalOutputName = physicalOutputName
            routingState.save()

            // Start new route if enabled and has output
            if routingState.outputDestinations[idx].isEnabled && !physicalOutputUID.isEmpty {
                audioRouter.startOutputRouting(virtualDeviceUID: virtualDeviceUID, physicalOutputUID: physicalOutputUID)
            }
        } else {
            // Create new destination entry
            routingState.addOutputDestination(
                virtualDeviceUID: virtualDeviceUID,
                virtualDeviceName: virtualDeviceName,
                physicalOutputUID: physicalOutputUID,
                physicalOutputName: physicalOutputName
            )
            // Start routing if has output
            if !physicalOutputUID.isEmpty {
                audioRouter.startOutputRouting(virtualDeviceUID: virtualDeviceUID, physicalOutputUID: physicalOutputUID)
            }
        }
    }
}
