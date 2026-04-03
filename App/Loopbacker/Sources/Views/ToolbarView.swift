import SwiftUI

struct ToolbarView: View {
    @EnvironmentObject var driverInstaller: DriverInstaller
    @EnvironmentObject var audioDeviceManager: AudioDeviceManager

    var body: some View {
        HStack(spacing: 16) {
            // Driver status indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: statusColor.opacity(0.6), radius: 3)

                Text(driverInstaller.statusMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(LoopbackerTheme.textSecondary)
            }

            Divider()
                .frame(height: 14)
                .background(LoopbackerTheme.border)

            // Virtual device status
            HStack(spacing: 6) {
                Image(systemName: audioDeviceManager.loopbackerDevicePresent ? "checkmark.circle.fill" : "xmark.circle")
                    .font(.system(size: 11))
                    .foregroundColor(audioDeviceManager.loopbackerDevicePresent ? LoopbackerTheme.accent : LoopbackerTheme.textMuted)

                Text(audioDeviceManager.loopbackerDevicePresent ? "Virtual device active" : "Virtual device not found")
                    .font(.system(size: 11))
                    .foregroundColor(LoopbackerTheme.textSecondary)
            }

            Spacer()

            // System device count
            HStack(spacing: 4) {
                Image(systemName: "hifispeaker.2.fill")
                    .font(.system(size: 10))
                    .foregroundColor(LoopbackerTheme.textMuted)

                Text("\(audioDeviceManager.systemDevices.count) devices")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(LoopbackerTheme.textMuted)
            }

            Divider()
                .frame(height: 14)
                .background(LoopbackerTheme.border)

            // Install/Uninstall button
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

                    Text(driverInstaller.isInstalled ? "Uninstall" : "Install Driver")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(driverInstaller.isInstalled ? LoopbackerTheme.danger : LoopbackerTheme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(LoopbackerTheme.bgSurface)
        .overlay(
            Rectangle()
                .fill(LoopbackerTheme.border)
                .frame(height: 0.5),
            alignment: .top
        )
    }

    private var statusColor: Color {
        if driverInstaller.isProcessing {
            return LoopbackerTheme.warning
        }
        return driverInstaller.isInstalled ? LoopbackerTheme.accent : LoopbackerTheme.danger
    }
}
