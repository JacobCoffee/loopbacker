import SwiftUI

/// Hotkeys settings: the global mic mute/push-to-talk/push-to-mute key, its mode, and the
/// push-to-talk release tail. Registers through `GlobalHotkeyManager` (Carbon, no Accessibility
/// permission) via `MicControl.refreshHotkeyRegistration()`.
struct HotkeysSettingsView: View {
    @EnvironmentObject var micControl: MicControl

    @AppStorage("MicHotkey.isEnabled") private var hotkeyEnabled = false
    @State private var chord: HotkeyChord? = MicHotkeySettings.chord
    @State private var mode: MicMode = MicHotkeySettings.mode
    @State private var releaseTailMs: Double = MicHotkeySettings.releaseTailMs

    var body: some View {
        Form {
            Section("Mic Hotkey") {
                Toggle("Enable Global Hotkey", isOn: Binding(
                    get: { hotkeyEnabled },
                    set: { hotkeyEnabled = $0; apply() }
                ))
                .help("Works system-wide without Accessibility permission")

                LabeledContent("Shortcut") {
                    ShortcutRecorderView(chord: Binding(
                        get: { chord },
                        set: { chord = $0; apply() }
                    ))
                }
                .disabled(!hotkeyEnabled)

                Picker("Mode", selection: Binding(
                    get: { mode },
                    set: { mode = $0; apply() }
                )) {
                    ForEach(MicMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .disabled(!hotkeyEnabled)

                Text(mode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Push to Talk / Push to Mute") {
                VStack(alignment: .leading, spacing: 4) {
                    Slider(value: Binding(
                        get: { releaseTailMs },
                        set: { releaseTailMs = $0; apply() }
                    ), in: MicHotkeySettings.releaseTailRange, step: 10)
                    Text("Release tail: \(Int(releaseTailMs)) ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!hotkeyEnabled || mode == .open)
                .help("How long the key can be released before the mic actually flips, so a brief gap between words doesn't clip")
            }
        }
        .formStyle(.grouped)
    }

    private func apply() {
        MicHotkeySettings.isEnabled = hotkeyEnabled
        MicHotkeySettings.chord = chord
        MicHotkeySettings.mode = mode
        MicHotkeySettings.releaseTailMs = releaseTailMs
        micControl.mode = mode
        micControl.refreshHotkeyRegistration()
    }
}
