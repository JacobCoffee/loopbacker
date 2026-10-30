import SwiftUI

/// General settings: launch-at-login (reusing `LoginItem`, already surfaced in the menu bar
/// panel/toolbar), the Airwindows plugin library toggle, and the muted overlay's visibility and
/// screen corner.
struct GeneralSettingsView: View {
    @EnvironmentObject var micControl: MicControl
    @ObservedObject private var loginItem = LoginItem.shared

    @AppStorage("AirwindowsLibrary.isEnabled") private var airwindowsEnabled = true
    @AppStorage("MutedOverlay.isEnabled") private var overlayEnabled = true
    @AppStorage("MutedOverlay.corner") private var overlayCornerRaw = MutedOverlayCorner.bottomTrailing.rawValue

    private var overlayCorner: Binding<MutedOverlayCorner> {
        Binding(
            get: { MutedOverlayCorner(rawValue: overlayCornerRaw) ?? .bottomTrailing },
            set: { overlayCornerRaw = $0.rawValue; refreshOverlay() }
        )
    }

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open at Login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                .help("Start Loopbacker in the menu bar when you log in, so routing is live without opening it")

                if loginItem.needsApproval {
                    Button("Allow in Login Items…") { loginItem.openSystemSettings() }
                        .buttonStyle(.link)
                } else if let error = loginItem.error {
                    Text("Couldn't change Open at Login: \(error)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Plugins") {
                Toggle("Show Airwindows Effects", isOn: $airwindowsEnabled)
                    .help("Airwindows adds ~500 free effects to the plugin browser; turn off to declutter it")
            }

            Section("Muted Overlay") {
                Toggle("Show Muted/PTT Overlay", isOn: Binding(
                    get: { overlayEnabled },
                    set: { overlayEnabled = $0; refreshOverlay() }
                ))
                .help("A small floating badge, above every app and Space, that shows when the mic is muted or push-to-talk is live")

                Picker("Corner", selection: overlayCorner) {
                    ForEach(MutedOverlayCorner.allCases) { corner in
                        Text(corner.title).tag(corner)
                    }
                }
                .disabled(!overlayEnabled)
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItem.refresh() }
    }

    private func refreshOverlay() {
        MutedOverlayController.shared.refreshFromSettings(micControl: micControl)
    }
}
