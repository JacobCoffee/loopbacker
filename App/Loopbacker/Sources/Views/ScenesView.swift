import SwiftUI

struct ScenesView: View {
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var audioRouter: AudioRouter
    @State private var presetNames: [String] = []
    @State private var newPresetName: String = ""
    @State private var showSaveField = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SCENES / PRESETS")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(LoopbackerTheme.textSecondary)
                .tracking(1.5)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider().background(LoopbackerTheme.border)

            // Save new preset
            if showSaveField {
                saveField
            } else {
                Button(action: { showSaveField = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(LoopbackerTheme.accent)

                        Text("Save Current Config")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(LoopbackerTheme.textPrimary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Save the current routing configuration as a named preset")
            }

            Divider().background(LoopbackerTheme.border)

            // Preset list
            if presetNames.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 20))
                            .foregroundColor(LoopbackerTheme.textMuted)
                        Text("No saved presets")
                            .font(.system(size: 11))
                            .foregroundColor(LoopbackerTheme.textMuted)
                    }
                    .padding(.vertical, 16)
                    Spacer()
                }
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(presetNames, id: \.self) { name in
                            presetRow(name: name)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 260)
            }
        }
        .frame(width: 260)
        .background(LoopbackerTheme.bgCard)
        .onAppear {
            presetNames = PresetManager.list()
        }
    }

    // MARK: - Save field

    private var saveField: some View {
        HStack(spacing: 6) {
            TextField("Preset name", text: $newPresetName)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(LoopbackerTheme.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(LoopbackerTheme.bgInset)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(LoopbackerTheme.border, lineWidth: 0.5)
                )
                .onSubmit {
                    savePreset()
                }

            Button(action: savePreset) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(newPresetName.isEmpty ? LoopbackerTheme.textMuted : LoopbackerTheme.accent)
            }
            .buttonStyle(.plain)
            .disabled(newPresetName.isEmpty)
            .help("Confirm and save this preset")

            Button(action: {
                showSaveField = false
                newPresetName = ""
            }) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 14))
                    .foregroundColor(LoopbackerTheme.textMuted)
            }
            .buttonStyle(.plain)
            .help("Cancel saving preset")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Preset row

    private func presetRow(name: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 11))
                .foregroundColor(LoopbackerTheme.accent)
                .frame(width: 18)

            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(LoopbackerTheme.textPrimary)
                .lineLimit(1)

            Spacer()

            Button(action: { loadPreset(name: name) }) {
                Text("Load")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(LoopbackerTheme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(LoopbackerTheme.accent.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(LoopbackerTheme.accent.opacity(0.3), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help("Load the '\(name)' preset, replacing current config")

            Button(action: { deletePreset(name: name) }) {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundColor(LoopbackerTheme.danger)
            }
            .buttonStyle(.plain)
            .help("Delete the '\(name)' preset")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    private func savePreset() {
        guard !newPresetName.isEmpty else { return }
        let data = routingState.exportConfig()
        PresetManager.save(name: newPresetName, data: data)
        presetNames = PresetManager.list()
        newPresetName = ""
        showSaveField = false
    }

    private func loadPreset(name: String) {
        guard let data = PresetManager.load(name: name) else { return }
        // Stop all existing routes before importing
        audioRouter.stopAll()
        withAnimation(.easeInOut(duration: 0.2)) {
            routingState.importConfig(data)
        }
    }

    private func deletePreset(name: String) {
        PresetManager.delete(name: name)
        withAnimation(.easeInOut(duration: 0.2)) {
            presetNames = PresetManager.list()
        }
    }
}
