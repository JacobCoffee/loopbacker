import SwiftUI

struct ScenesView: View {
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var audioRouter: AudioRouter

    @State private var presetNames: [String] = []
    @State private var newPresetName: String = ""
    @State private var showSavePopover = false

    var body: some View {
        Group {
            if presetNames.isEmpty {
                emptyState
            } else {
                sceneList
            }
        }
        .navigationSubtitle("\(presetNames.count) saved")
        .toolbar { toolbarContent }
        .popover(isPresented: $showSavePopover, arrowEdge: .bottom) {
            savePopoverContent
        }
        .onAppear {
            presetNames = PresetManager.list()
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                newPresetName = ""
                showSavePopover = true
            } label: {
                Label("Save Current Config", systemImage: "plus.circle")
            }
        }
        GlobalToolbar()
    }

    private var savePopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save Scene")
                .font(.headline)

            TextField("Preset name", text: $newPresetName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit { savePreset() }

            HStack {
                Spacer()
                Button("Cancel") { showSavePopover = false }
                    .buttonStyle(.glass)
                    .tint(nil)
                Button("Save") { savePreset() }
                    .buttonStyle(.glassProminent)
                    .tint(.loopbacker)
                    .disabled(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }

    // MARK: - Scene list

    private var sceneList: some View {
        List {
            ForEach(presetNames, id: \.self) { name in
                sceneRow(name: name)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private func sceneRow(name: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(Color.loopbacker)
                .frame(width: 20)

            Text(name)
                .font(.body.weight(.medium))
                .lineLimit(1)

            Spacer()

            Button("Load") { loadPreset(name: name) }
                .buttonStyle(.glass)
                .tint(.loopbacker)
                .help("Load the '\(name)' scene, replacing the current configuration")

            Button(role: .destructive) {
                deletePreset(name: name)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete the '\(name)' scene")
            .accessibilityLabel("Delete \(name)")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Load") { loadPreset(name: name) }
            Button("Delete", role: .destructive) { deletePreset(name: name) }
        }
        .swipeActions {
            Button("Delete", role: .destructive) { deletePreset(name: name) }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        EmptyStateView(
            title: "No Scenes",
            message: "Save the current sources, routes and outputs as a scene to switch setups in one click.",
            symbol: "square.stack.3d.up"
        ) {
            Button("Save Current") {
                newPresetName = ""
                showSavePopover = true
            }
            .buttonStyle(.glassProminent)
            .tint(.loopbacker)
        }
    }

    // MARK: - Actions

    private func savePreset() {
        let trimmed = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let data = routingState.exportConfig()
        PresetManager.save(name: trimmed, data: data)
        presetNames = PresetManager.list()
        newPresetName = ""
        showSavePopover = false
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
