import SwiftUI
import AppKit
import Combine

/// Echo cancellation control: toggle, System Audio Recording permission flow, and tap/AEC
/// status. Embedded by the UI slice wherever noise suppression's card lives.
///
/// Reads `RoutingState` (the toggle and the settings `save()` writes to) and `SystemAudioTap`
/// (permission state, running state) from the environment -- both already injected app-wide by
/// `LoopbackerApp`. Also reads `AudioRouter` for a cheap live "echo removed" indicator
/// (`EchoCanceller.erleDB`, already computed every hop on the IO thread, just polled here).
struct EchoCancellationSection: View {
    @EnvironmentObject private var routingState: RoutingState
    @EnvironmentObject private var systemAudioTap: SystemAudioTap
    @EnvironmentObject private var audioRouter: AudioRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var erleDB: Float?

    private let erleTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var enabled: Bool { routingState.noiseSuppression.echoCancellation }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.panelSpacing) {
            header
            if enabled {
                statusRow
                    .transition(.opacity)
            }
        }
        .padding(Metrics.panelPadding)
        .glassPanel(cornerRadius: Metrics.panelRadius, tint: enabled ? Color.loopbacker.opacity(0.08) : nil)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: enabled)
        .onReceive(erleTimer) { _ in
            erleDB = audioRouter.echoCancellationERLE()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.badge.exclamationmark")
                .font(.title3.weight(.semibold))
                .foregroundStyle(enabled ? Color.loopbacker : Color.secondary)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("Echo Cancellation")
                    .font(.headline)
                Text("Removes your own voice from the mic after it plays back through your speakers, so other call participants don't hear themselves echoed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle(isOn: toggleBinding) {
                Text(enabled ? "Active" : "Off")
                    .font(.caption.weight(.semibold))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(.loopbacker)
            .help(enabled ? "Turn off echo cancellation" : "Turn on echo cancellation")
        }
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { enabled },
            set: { newValue in
                routingState.noiseSuppression.echoCancellation = newValue
                routingState.save()
            }
        )
    }

    // MARK: - Status row

    @ViewBuilder
    private var statusRow: some View {
        switch systemAudioTap.permission {
        case .unknown:
            explainer(
                icon: "mic.badge.plus",
                text: "Turning this on asks macOS for System Audio Recording permission, so Loopbacker can hear what plays through your speakers and cancel it out of your mic.",
                tint: .secondary
            )
        case .denied:
            deniedRow
        case .granted:
            grantedRow
        }
    }

    @ViewBuilder
    private var grantedRow: some View {
        switch systemAudioTap.state {
        case .running:
            runningRow
        case .stopped:
            explainer(
                icon: "pause.circle",
                text: "Waiting for an active voice route before starting the system audio tap.",
                tint: .secondary
            )
        case .noPhysicalOutput:
            explainer(
                icon: "speaker.slash",
                text: "Your default output isn't a physical speaker right now, so there's nothing to echo-cancel against. This turns back on automatically once you switch to real speakers or headphones.",
                tint: .secondary
            )
        case .failed(let error):
            explainer(
                icon: "exclamationmark.triangle.fill",
                text: error.errorDescription ?? "The system audio tap failed to start.",
                tint: .orange
            )
        }
    }

    private var deniedRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("System Audio Recording permission was denied. Echo cancellation can't hear your speakers without it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy & Security Settings") {
                    openSystemAudioRecordingSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var runningRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.loopbacker)
                .frame(width: 6, height: 6)
            if let erleDB, erleDB >= 1 {
                Text("Echo removed: \(Int(erleDB.rounded())) dB")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Text("Listening for echo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func explainer(icon: String, text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - System Settings deep link

    private func openSystemAudioRecordingSettings() {
        // "Privacy_AudioCapture" is the Security & Privacy pane anchor for the "System Audio
        // Recording Only" permission `SystemAudioTap` needs (a sibling of Screen Recording's
        // "Privacy_ScreenCapture", used the same way elsewhere in the app for app capture).
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}
