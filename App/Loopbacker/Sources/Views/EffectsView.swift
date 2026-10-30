import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Effects section redesign: a header (master toggle, preset picker, A/B compare, latency,
/// call-app advice), a Simple/Advanced switch, and either four macro sliders with a live meter
/// (Simple) or the insert-chain editor with a per-stage detail panel (Advanced). Signal is the
/// light source: active stages and the lines between them glow Loopbacker green only while the
/// chain is enabled.
struct EffectsView: View {
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var fxEngine: FXEngine
    @EnvironmentObject var presetAutoSwitchState: PresetAutoSwitchState
    /// False once the user switches to another app, so app-based preset switching resumes even
    /// if this page stays open in the background.
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.snapshotRendering) private var snapshotRendering
    @Environment(\.previewMeters) private var previewMeters
    @Environment(\.previewLoadErrors) private var previewLoadErrors
    @Namespace private var chainNamespace

    private enum Mode: String, CaseIterable, Identifiable {
        case simple = "Simple"
        case advanced = "Advanced"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .simple
    @State private var selectedNodeID: UUID?

    init() {}

    /// Drives the view straight into a given mode/selection, for offscreen render tests and
    /// previews — normal app navigation always starts in Simple mode with no node selected.
    init(previewAdvanced: Bool, previewSelectedNodeID: UUID?) {
        _mode = State(initialValue: previewAdvanced ? .advanced : .simple)
        _selectedNodeID = State(initialValue: previewSelectedNodeID)
    }

    // Preset management state
    @State private var savedPresetNames: [String] = []
    @State private var showingSavePopover = false
    @State private var newPresetName: String = ""

    // Add/replace effect
    @State private var showingEffectBrowser = false
    @State private var replacingNodeID: UUID?

    // Mic check / auto setup
    @State private var showingMicCheck = false
    @State private var showingAutoSetup = false

    // Call app advice
    @AppStorage("fxPendingWave2.dismissedCallAppAdvice") private var dismissedAdviceCSV = ""

    private var preset: EffectsPreset {
        routingState.effectsPreset
    }

    private var nodes: [FXNodeConfig] { preset.nodes }
    private var activeCount: Int { nodes.filter(\.enabled).count }

    var body: some View {
        Group {
            if snapshotRendering {
                // `ImageRenderer` renders `ScrollView` content as a blank rect (confirmed with
                // an isolated repro: identical content inside vs. outside a `ScrollView` offscreen
                // renders content vs. nothing) — swap in a plain, non-scrolling container so
                // offscreen render tests still see the real page instead of an empty canvas.
                pageContent
            } else {
                ScrollView(.vertical) { pageContent }
                    .scrollEdgeEffectStyle(.soft, for: .top)
            }
        }
        .navigationSubtitle(preset.isEnabled ? "\(activeCount) of \(nodes.count) active" : "Bypassed")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Mode")
                .frame(maxWidth: 200)

                Toggle(isOn: masterBinding) {
                    Label(preset.isEnabled ? "Effects On" : "Effects Off", systemImage: "power")
                }
                .toggleStyle(.button)
                .help(preset.isEnabled ? "Bypass the whole effects chain" : "Enable the effects chain")

                presetMenu

                ABCompareControl()

                latencyReadout

                Button {
                    showingMicCheck = true
                } label: {
                    Label("Mic Check", systemImage: "waveform.and.mic")
                }
                .help("Record and compare raw vs. processed voice")
            }
            GlobalToolbar()
        }
        .sheet(isPresented: $showingMicCheck) { MicCheckView() }
        .sheet(isPresented: $showingAutoSetup) { AutoSetupView() }
        .sheet(isPresented: $showingEffectBrowser) {
            EffectBrowserSheet(
                onInsertBuiltin: { kind in insertOrReplace(builtin: kind) },
                onInsertHosted: { plugin in insertOrReplace(hosted: plugin) }
            )
        }
        .onAppear {
            refreshSavedPresets()
            if selectedNodeID == nil {
                selectedNodeID = nodes.first(where: \.enabled)?.id ?? nodes.first?.id
            }
            presetAutoSwitchState.isSuppressedByEditing = appearsActive
        }
        .onChange(of: appearsActive) { _, active in
            presetAutoSwitchState.isSuppressedByEditing = active
        }
        .onDisappear {
            presetAutoSwitchState.isSuppressedByEditing = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .fxPluginEditorClosed)) { _ in
            Task { await captureHostedStatesIntoPreset() }
        }
    }

    private var pageContent: some View {
        VStack(alignment: .leading, spacing: Metrics.panelSpacing) {
            adviceBanner

            noiseSuppressionCard

            if !preset.isEnabled {
                disabledPrompt
            }

            switch mode {
            case .simple:
                EffectsSimpleView(showingAutoSetup: $showingAutoSetup)
                    .opacity(preset.isEnabled ? 1 : 0.6)
            case .advanced:
                advancedBody
            }

            AppAudioSection()
        }
        .padding(Metrics.canvasMargin)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var masterBinding: Binding<Bool> {
        Binding(
            get: { preset.isEnabled },
            set: { newValue in
                withAnimation(.easeInOut(duration: 0.25)) {
                    routingState.effectsPreset.isEnabled = newValue
                }
                routingState.save()
            }
        )
    }

    private var latencyReadout: some View {
        Text(String(format: "%.1f ms", fxEngine.totalLatencyMs))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.4), in: Capsule())
            .accessibilityLabel("Chain latency")
            .accessibilityValue(String(format: "%.1f milliseconds", fxEngine.totalLatencyMs))
            .help("Total added latency from the effects chain")
    }

    // MARK: - Call app advice banner

    private var dismissedAdviceIDs: Set<String> {
        Set(dismissedAdviceCSV.split(separator: ",").map(String.init))
    }

    private var adviceBanner: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            let advice = CallAppAdviceCatalog.running().filter { !dismissedAdviceIDs.contains($0.id) }
            if let first = advice.first {
                CallAppAdviceBanner(advice: first, onDismiss: {
                    var ids = dismissedAdviceIDs
                    ids.insert(first.id)
                    dismissedAdviceCSV = ids.joined(separator: ",")
                })
                .transition(.opacity)
            }
        }
    }

    // MARK: - Display metadata

    private func icon(for kind: FXNodeKind) -> String {
        switch kind {
        case .gate: "waveform.path.ecg"
        case .eq: "slider.vertical.3"
        case .compressor: "arrow.down.right.and.arrow.up.left"
        case .leveler: "chart.bar.fill"
        case .deEsser: "s.circle"
        case .chorus: "waveform.path"
        case .pitchShift: "arrow.up.arrow.down"
        case .reverb: "drop.halffull"
        case .delay: "repeat"
        case .limiter: "gauge.with.dots.needle.67percent"
        case .audioUnit, .jsfx, .airwindows: "puzzlepiece.extension"
        }
    }

    private func displayName(for kind: FXNodeKind) -> String {
        switch kind {
        case .gate: "Gate"
        case .eq: "EQ"
        case .compressor: "Compressor"
        case .leveler: "Leveler"
        case .deEsser: "De-Esser"
        case .chorus: "Chorus"
        case .pitchShift: "Pitch Shift"
        case .reverb: "Reverb"
        case .delay: "Delay"
        case .limiter: "Limiter"
        case .audioUnit: "Audio Unit"
        case .jsfx: "JSFX"
        case .airwindows: "Airwindows"
        }
    }

    private func displayName(for node: FXNodeConfig) -> String {
        node.kind.isHosted ? (node.pluginRef?.name ?? displayName(for: node.kind)) : displayName(for: node.kind)
    }

    private func effectDescription(_ kind: FXNodeKind) -> String {
        switch kind {
        case .gate: "Reduces background noise below a threshold"
        case .eq: "Shape tonal balance with parametric bands"
        case .compressor: "Tames dynamic range for consistent levels"
        case .leveler: "Holds your voice at a target loudness"
        case .deEsser: "Reduces harsh sibilance in vocals"
        case .chorus: "Thickens voice with modulated detuning"
        case .pitchShift: "Shift voice pitch up or down in semitones"
        case .reverb: "Adds room/hall spatial ambience"
        case .delay: "Echo effect with adjustable feedback"
        case .limiter: "Prevents clipping with a hard ceiling"
        case .audioUnit, .jsfx, .airwindows: "Hosted third-party effect"
        }
    }

    // MARK: - Noise suppression

    /// Sits above the chain and outside its bypass dimming: suppression runs whenever it's on,
    /// whether or not the effects chain is enabled.
    private var noiseSuppressionCard: some View {
        let settings = routingState.noiseSuppression
        let on = settings.isEnabled
        return VStack(alignment: .leading, spacing: Metrics.panelSpacing) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.badge.minus")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(on ? Color.loopbacker : Color.secondary)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Noise Suppression")
                        .font(.headline)
                    Text("Removes background noise from mic inputs on-device, before the effects chain (even when it's bypassed).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Toggle(isOn: noiseSuppressionBinding(\.isEnabled)) {
                    Text(on ? "Active" : "Off")
                        .font(.caption.weight(.semibold))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.loopbacker)
                .help(on ? "Turn off noise suppression" : "Turn on noise suppression")
            }

            if on {
                ParameterSliderRow(label: "Max Reduction",
                                   description: "How far noise is pulled down. Ease off to keep some room tone.",
                                   value: noiseSuppressionBinding(\.maxReductionDB),
                                   range: NoiseSuppressionSettings.reductionRange, unit: "dB")
                    .transition(.opacity)
            }
        }
        .padding(Metrics.panelPadding)
        .glassPanel(cornerRadius: Metrics.panelRadius, tint: on ? Color.loopbacker.opacity(0.08) : nil)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: on)
    }

    private func noiseSuppressionBinding<T>(_ keyPath: WritableKeyPath<NoiseSuppressionSettings, T>) -> Binding<T> {
        Binding(
            get: { routingState.noiseSuppression[keyPath: keyPath] },
            set: {
                routingState.noiseSuppression[keyPath: keyPath] = $0
                routingState.save()
            }
        )
    }

    // MARK: - Disabled prompt

    private var disabledPrompt: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text("Effects Chain Disabled")
                    .font(.subheadline.weight(.semibold))
                Text("The chain below is configured but not processing audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Enable Effects") {
                masterBinding.wrappedValue = true
            }
            .buttonStyle(.glassProminent)
            .tint(.loopbacker)
        }
        .padding(.horizontal, Metrics.panelPadding)
        .padding(.vertical, 10)
        .glassPanel(cornerRadius: Metrics.innerRadius)
    }

    // MARK: - Refresh saved presets list

    private func refreshSavedPresets() {
        savedPresetNames = EffectsPresetManager.list()
    }

    // MARK: - Apply a preset (preserving isEnabled state)

    private func applyPreset(_ newPreset: EffectsPreset) {
        var applied = newPreset
        applied.isEnabled = true
        routingState.effectsPreset = applied
        selectedNodeID = applied.nodes.first?.id
        routingState.save()
    }

    // MARK: - Preset menu

    private var presetMenu: some View {
        Menu {
            ForEach(FactoryPresetCategory.allCases, id: \.self) { category in
                Section(category.title) {
                    ForEach(FactoryPresets.all.filter { $0.category == category }) { factory in
                        Button {
                            _ = EffectsPresetLibrary.apply(id: factory.id, to: routingState)
                            selectedNodeID = routingState.effectsPreset.nodes.first?.id
                        } label: {
                            Label(factory.name, systemImage: factory.symbol)
                        }
                        .help(factory.summary)
                    }
                }
            }

            Section("Saved Presets") {
                if savedPresetNames.isEmpty {
                    Text("No saved presets")
                } else {
                    ForEach(savedPresetNames, id: \.self) { name in
                        Button(name) {
                            if let loaded = EffectsPresetManager.load(name: name) {
                                applyPreset(loaded)
                            }
                        }
                    }
                }
            }

            Divider()

            Button("Save Current...") {
                newPresetName = ""
                showingSavePopover = true
            }

            Button("Import from File...") {
                importPresetFromFile()
            }

            Button("Export to File...") {
                exportPresetToFile()
            }

            Divider()

            Button("Reset to Defaults") {
                applyPreset(EffectsPreset(isEnabled: true))
            }

            if !savedPresetNames.isEmpty {
                Divider()
                Menu("Delete Saved Preset") {
                    ForEach(savedPresetNames, id: \.self) { name in
                        Button(name, role: .destructive) {
                            EffectsPresetManager.delete(name: name)
                            refreshSavedPresets()
                        }
                    }
                }
            }
        } label: {
            Label("Presets", systemImage: "tray.2")
        }
        .popover(isPresented: $showingSavePopover, arrowEdge: .bottom) {
            SavePresetPopover(
                name: $newPresetName,
                onCancel: { showingSavePopover = false },
                onSave: {
                    guard !newPresetName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    EffectsPresetManager.save(name: newPresetName, preset: routingState.effectsPreset)
                    refreshSavedPresets()
                    showingSavePopover = false
                }
            )
        }
    }

    // MARK: - Import / Export

    private func importPresetFromFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Effects Preset"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            if let data = try? Data(contentsOf: url),
               let imported = EffectsPresetManager.importData(data) {
                applyPreset(imported)
            }
        }
    }

    private func exportPresetToFile() {
        let panel = NSSavePanel()
        panel.title = "Export Effects Preset"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "LoopbackerPreset.json"
        if panel.runModal() == .OK, let url = panel.url {
            if let data = EffectsPresetManager.exportData(preset: routingState.effectsPreset) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - Advanced: signal chain + detail panel

    private var advancedBody: some View {
        HStack(alignment: .top, spacing: Metrics.panelSpacing + 6) {
            chainSection
                .frame(width: 220)
                .opacity(preset.isEnabled ? 1 : 0.45)

            if let selected = selectedNodeID, let node = nodes.first(where: { $0.id == selected }) {
                detailPanel(for: node)
                    .frame(maxWidth: 760, alignment: .topLeading)
                    .id(selected)
                    .transition(.opacity)
            }
        }
    }

    private var chainSection: some View {
        GlassEffectContainer(spacing: 0) {
            VStack(spacing: 0) {
                ChainTerminalTile(label: "Input", icon: "mic.fill", namespace: chainNamespace)

                ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                    SignalLineConnector(active: preset.isEnabled && previousActive(before: index) && node.enabled)
                    ChainSlotTile(
                        name: displayName(for: node),
                        icon: icon(for: node.kind),
                        enabled: node.enabled,
                        isSelected: selectedNodeID == node.id,
                        toggle: { toggleNode(node.id) },
                        select: {
                            withAnimation(.easeOut(duration: 0.2)) {
                                selectedNodeID = node.id
                            }
                        },
                        namespace: chainNamespace,
                        activity: activityValue(for: node),
                        loadError: nodeLoadError(for: node.id),
                        isHosted: node.kind.isHosted,
                        onDuplicate: { duplicateNode(node.id) },
                        onRemove: nodes.count > 1 ? { removeNode(node.id) } : nil,
                        onReset: { resetNode(node.id) },
                        onOpenEditor: node.kind.isHosted ? { Task { await openEditor(node.id) } } : nil,
                        onMoveUp: index > 0 ? { moveNode(node.id, by: -1) } : nil,
                        onMoveDown: index < nodes.count - 1 ? { moveNode(node.id, by: 1) } : nil
                    )
                    .draggable(node.id.uuidString)
                    .dropDestination(for: String.self) { items, _ in
                        handleDrop(items, ontoIndex: index)
                    }
                }

                SignalLineConnector(active: preset.isEnabled && (nodes.last?.enabled ?? false))

                Button {
                    replacingNodeID = nil
                    showingEffectBrowser = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Effect")
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.loopbacker)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                }
                .buttonStyle(.plain)
                .contentShape(.rect(cornerRadius: Metrics.innerRadius))
                .glassPanel(cornerRadius: Metrics.innerRadius, interactive: true)
                .accessibilityLabel("Add Effect")

                SignalLineConnector(active: preset.isEnabled && (nodes.last?.enabled ?? false))
                ChainTerminalTile(label: "Output", icon: "speaker.wave.2.fill", namespace: chainNamespace)
            }
        }
    }

    /// Whether the segment feeding into `index` should glow: both the upstream node and this
    /// stage must be active (the input terminal is always "active").
    private func previousActive(before index: Int) -> Bool {
        index == 0 ? true : nodes[index - 1].enabled
    }

    /// A 0...1 processing-activity readout for the chain tile's indicator dot, mapped per kind
    /// from that stage's `FXMeters` (gate openness, de-esser/leveler activity, normalized gain
    /// reduction for compressor/limiter). Nil when no voice chain is running.
    private func activityValue(for node: FXNodeConfig) -> Float? {
        guard let meters = previewMeters[node.id] ?? fxEngine.liveNode(id: node.id)?.meters else { return nil }
        switch node.kind {
        case .gate, .deEsser, .leveler: return meters.activity
        case .compressor, .limiter: return min(1, meters.gainReductionDB / 18)
        default: return min(1, meters.outputPeak)
        }
    }

    /// A hosted node's load-error message, preferring an offscreen-render-test override (see
    /// `EnvironmentValues.previewLoadErrors`) over the live engine's `nodeLoadErrors`.
    private func nodeLoadError(for id: UUID) -> String? {
        previewLoadErrors[id] ?? fxEngine.nodeLoadErrors[id]
    }

    private func handleDrop(_ items: [String], ontoIndex index: Int) -> Bool {
        guard let idString = items.first, let draggedID = UUID(uuidString: idString),
              let fromIdx = routingState.effectsPreset.nodes.firstIndex(where: { $0.id == draggedID }),
              fromIdx != index else { return false }
        withAnimation(.easeInOut(duration: 0.2)) {
            let item = routingState.effectsPreset.nodes.remove(at: fromIdx)
            let insertIdx = fromIdx < index ? index : index
            routingState.effectsPreset.nodes.insert(item, at: min(insertIdx, routingState.effectsPreset.nodes.count))
        }
        routingState.save()
        return true
    }

    private func toggleNode(_ id: UUID) {
        guard let idx = routingState.effectsPreset.nodes.firstIndex(where: { $0.id == id }) else { return }
        routingState.effectsPreset.nodes[idx].enabled.toggle()
        routingState.save()
    }

    private func moveNode(_ id: UUID, by offset: Int) {
        guard let idx = routingState.effectsPreset.nodes.firstIndex(where: { $0.id == id }) else { return }
        let newIdx = idx + offset
        guard newIdx >= 0, newIdx < routingState.effectsPreset.nodes.count else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            routingState.effectsPreset.nodes.swapAt(idx, newIdx)
        }
        routingState.save()
    }

    private func duplicateNode(_ id: UUID) {
        guard let idx = routingState.effectsPreset.nodes.firstIndex(where: { $0.id == id }) else { return }
        var copy = routingState.effectsPreset.nodes[idx]
        copy.id = UUID()
        routingState.effectsPreset.nodes.insert(copy, at: idx + 1)
        routingState.save()
    }

    private func removeNode(_ id: UUID) {
        routingState.effectsPreset.nodes.removeAll { $0.id == id }
        if selectedNodeID == id { selectedNodeID = routingState.effectsPreset.nodes.first?.id }
        routingState.save()
    }

    private func openEditor(_ id: UUID) async {
        guard let node = routingState.effectsPreset.nodes.first(where: { $0.id == id }),
              let hosted = fxEngine.liveNode(id: id) as? any FXHostedNode else { return }
        await PluginEditorWindowController.show(for: hosted, title: node.pluginRef?.name ?? displayName(for: node.kind))
    }

    private func captureHostedStatesIntoPreset() async {
        let states = await fxEngine.captureHostedStates()
        guard !states.isEmpty else { return }
        for (id, data) in states {
            guard let idx = routingState.effectsPreset.nodes.firstIndex(where: { $0.id == id }) else { continue }
            routingState.effectsPreset.nodes[idx].pluginState = data
        }
        routingState.save()
    }

    // MARK: - Add / replace effect

    private func insertOrReplace(builtin kind: FXNodeKind) {
        var config = FXNodeConfig(kind: kind)
        if kind == .eq { config.eqBands = EQBandConfig.broadcast }
        insertOrReplace(config)
    }

    private func insertOrReplace(hosted plugin: FXPluginInfo) {
        let config = FXNodeConfig(kind: plugin.ref.format, pluginRef: plugin.ref)
        insertOrReplace(config)
    }

    private func insertOrReplace(_ config: FXNodeConfig) {
        if let replacingNodeID, let idx = routingState.effectsPreset.nodes.firstIndex(where: { $0.id == replacingNodeID }) {
            var replaced = config
            replaced.id = replacingNodeID
            routingState.effectsPreset.nodes[idx] = replaced
            selectedNodeID = replacingNodeID
        } else {
            let insertIdx = selectedNodeID
                .flatMap { id in routingState.effectsPreset.nodes.firstIndex(where: { $0.id == id }) }
                .map { $0 + 1 } ?? routingState.effectsPreset.nodes.count
            routingState.effectsPreset.nodes.insert(config, at: insertIdx)
            selectedNodeID = config.id
        }
        replacingNodeID = nil
        routingState.save()
    }

    // MARK: - Detail panel

    @ViewBuilder
    private func detailPanel(for node: FXNodeConfig) -> some View {
        VStack(alignment: .leading, spacing: Metrics.panelSpacing) {
            HStack(spacing: 10) {
                Image(systemName: icon(for: node.kind))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(node.enabled ? Color.loopbacker : Color.secondary)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName(for: node))
                        .font(.headline)
                    Text(effectDescription(node.kind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !node.kind.isHosted {
                    Button("Reset") {
                        resetNode(node.id)
                    }
                    .buttonStyle(.glass)
                    .tint(nil)
                    .controlSize(.small)
                    .help("Reset \(displayName(for: node)) to default values")
                }

                Toggle(isOn: Binding(
                    get: { node.enabled },
                    set: { _ in withAnimation(.easeInOut(duration: 0.2)) { toggleNode(node.id) } }
                )) {
                    Text(node.enabled ? "Active" : "Bypassed")
                        .font(.caption.weight(.semibold))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.loopbacker)
            }

            Divider()

            if let loadError = nodeLoadError(for: node.id) {
                hostedLoadErrorBanner(node, message: loadError)
            } else {
                if node.kind == .gate && node.enabled && routingState.noiseSuppression.isEnabled {
                    gateWithSuppressionHint(node.id)
                }

                quickPresetsRow(for: node)
                liveVisual(for: node)
                expandedControls(for: node)
            }
        }
        .padding(Metrics.panelPadding)
        .glassPanel(cornerRadius: Metrics.panelRadius, tint: node.enabled ? Color.loopbacker.opacity(0.08) : nil)
    }

    /// Hosted effect failed to load (missing Audio Unit, deleted JSFX file, ...): name it and
    /// offer the two recovery paths instead of a broken parameter panel.
    private func hostedLoadErrorBanner(_ node: FXNodeConfig, message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.signalWarm)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(node.pluginRef?.name ?? "This effect") couldn't load")
                        .font(.callout.weight(.semibold))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button("Replace...") {
                    replacingNodeID = node.id
                    showingEffectBrowser = true
                }
                .buttonStyle(.glass)
                .tint(nil)
                Button("Remove", role: .destructive) { removeNode(node.id) }
                    .buttonStyle(.glass)
                    .tint(nil)
            }
            .controlSize(.small)
        }
    }

    /// Noise suppression already pulls the room down, so a gate on top mostly clips quiet word
    /// endings. Shown in the Gate panel while both run.
    private func gateWithSuppressionHint(_ nodeID: UUID) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "waveform.badge.minus")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Noise suppression already removes background noise. On top of it, the gate mostly clips quiet word endings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Use Light Gate") {
                applyQuickPreset(nodeID, overrides: ["threshold": -45, "range": -6])
            }
            .help("Threshold -45 dB, range -6 dB: only trims what's left between words")
            Button("Turn Off Gate") {
                withAnimation(.easeInOut(duration: 0.2)) { toggleNode(nodeID) }
            }
            .help("Bypass the gate and let noise suppression handle the room")
        }
        .buttonStyle(.glass)
        .tint(nil)
        .controlSize(.small)
    }

    @ViewBuilder
    private func liveVisual(for node: FXNodeConfig) -> some View {
        switch node.kind {
        case .gate: GateVisual(nodeID: node.id)
        case .compressor: CompressorVisual(nodeID: node.id)
        case .leveler: LevelerVisual(nodeID: node.id)
        case .deEsser: DeEsserVisual(nodeID: node.id)
        case .limiter: LimiterVisual(nodeID: node.id)
        default: EmptyView()
        }
    }

    // MARK: - Reset / quick presets, driven by FXParamSpec ids

    private func resetNode(_ id: UUID) {
        guard let idx = routingState.effectsPreset.nodes.firstIndex(where: { $0.id == id }) else { return }
        let kind = routingState.effectsPreset.nodes[idx].kind
        var defaults: [String: Float] = [:]
        for spec in FXBuiltinSpecs.specs(for: kind) { defaults[spec.id] = spec.defaultValue }
        withAnimation(.easeInOut(duration: 0.2)) {
            routingState.effectsPreset.nodes[idx].params = defaults
            if kind == .eq { routingState.effectsPreset.nodes[idx].eqBands = EQBandConfig.broadcast }
            routingState.save()
        }
    }

    private func applyQuickPreset(_ id: UUID, overrides: [String: Float]) {
        guard let idx = routingState.effectsPreset.nodes.firstIndex(where: { $0.id == id }) else { return }
        for (key, value) in overrides { routingState.effectsPreset.nodes[idx].params[key] = value }
        routingState.save()
    }

    private func applyQuickEQBands(_ id: UUID, bands: [EQBandConfig]) {
        guard let idx = routingState.effectsPreset.nodes.firstIndex(where: { $0.id == id }) else { return }
        routingState.effectsPreset.nodes[idx].eqBands = bands
        routingState.save()
    }

    private struct QuickPreset {
        let name: String
        let overrides: [String: Float]
    }

    private func quickPresets(for kind: FXNodeKind) -> [QuickPreset] {
        switch kind {
        case .gate:
            return [
                QuickPreset(name: "Soft Gate", overrides: ["threshold": -36, "range": -12]),
                QuickPreset(name: "Hard Gate", overrides: ["threshold": -30, "range": -40]),
                QuickPreset(name: "Light", overrides: ["threshold": -45, "range": -6]),
            ]
        case .compressor:
            return [
                QuickPreset(name: "Gentle", overrides: ["ratio": 2, "threshold": -20, "makeup": 0]),
                QuickPreset(name: "Broadcast", overrides: ["ratio": 3, "threshold": -18, "makeup": 3]),
                QuickPreset(name: "Aggressive", overrides: ["ratio": 6, "threshold": -24, "makeup": 6]),
            ]
        case .deEsser:
            return [
                QuickPreset(name: "Light", overrides: ["range": 3]),
                QuickPreset(name: "Normal", overrides: ["range": 6]),
                QuickPreset(name: "Heavy", overrides: ["range": 10]),
            ]
        case .chorus:
            return [
                QuickPreset(name: "Subtle", overrides: ["rate": 1.0, "depth": 2, "mix": 20]),
                QuickPreset(name: "Thick", overrides: ["rate": 0.8, "depth": 5, "mix": 50]),
                QuickPreset(name: "Vibrato", overrides: ["rate": 5.0, "depth": 1, "mix": 80]),
            ]
        case .pitchShift:
            return [
                QuickPreset(name: "Down Octave", overrides: ["semitones": -12]),
                QuickPreset(name: "Up Fifth", overrides: ["semitones": 7]),
                QuickPreset(name: "Chipmunk", overrides: ["semitones": 12]),
                QuickPreset(name: "None", overrides: ["semitones": 0]),
            ]
        case .reverb:
            return [
                QuickPreset(name: "Small Room", overrides: ["size": 30, "damping": 60, "mix": 12]),
                QuickPreset(name: "Hall", overrides: ["size": 80, "damping": 30, "mix": 20]),
                QuickPreset(name: "Subtle", overrides: ["size": 40, "damping": 50, "mix": 8]),
            ]
        case .delay:
            return [
                QuickPreset(name: "Slapback", overrides: ["time": 80, "feedback": 10, "mix": 30]),
                QuickPreset(name: "Quarter", overrides: ["time": 500, "feedback": 30, "mix": 25]),
                QuickPreset(name: "Long Echo", overrides: ["time": 750, "feedback": 50, "mix": 20]),
            ]
        case .limiter:
            return [
                QuickPreset(name: "Safe", overrides: ["ceiling": -1.5]),
                QuickPreset(name: "Loud", overrides: ["ceiling": -0.5]),
                QuickPreset(name: "Broadcast", overrides: ["ceiling": -1.0]),
            ]
        case .eq, .leveler, .audioUnit, .jsfx, .airwindows:
            return []
        }
    }

    @ViewBuilder
    private func quickPresetsRow(for node: FXNodeConfig) -> some View {
        if node.kind == .eq {
            QuickPresetsRow(presets: [
                QuickPresetsRow.Preset(name: "Broadcast", apply: {
                    applyQuickEQBands(node.id, bands: EQBandConfig.broadcast)
                }),
                QuickPresetsRow.Preset(name: "Flat", apply: {
                    applyQuickEQBands(node.id, bands: EQBandConfig.broadcast.map {
                        var band = $0; band.gainDB = 0; return band
                    })
                }),
            ])
        } else {
            let presets = quickPresets(for: node.kind)
            if !presets.isEmpty {
                QuickPresetsRow(presets: presets.map { preset in
                    QuickPresetsRow.Preset(name: preset.name, apply: { applyQuickPreset(node.id, overrides: preset.overrides) })
                })
            }
        }
    }

    // MARK: - Parameter binding helpers (generic, by FXParamSpec id)

    private func paramValue(_ node: FXNodeConfig, _ spec: FXParamSpec) -> Float {
        node.params[spec.id] ?? spec.defaultValue
    }

    private func paramBinding(nodeID: UUID, spec: FXParamSpec) -> Binding<Float> {
        Binding(
            get: {
                guard let node = routingState.effectsPreset.nodes.first(where: { $0.id == nodeID }) else { return spec.defaultValue }
                return paramValue(node, spec)
            },
            set: { newValue in
                guard let idx = routingState.effectsPreset.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
                routingState.effectsPreset.nodes[idx].params[spec.id] = newValue
                routingState.save()
            }
        )
    }

    private func choiceBinding(nodeID: UUID, spec: FXParamSpec) -> Binding<Int> {
        Binding(
            get: { Int(paramBinding(nodeID: nodeID, spec: spec).wrappedValue.rounded()) },
            set: { paramBinding(nodeID: nodeID, spec: spec).wrappedValue = Float($0) }
        )
    }

    // MARK: - Generic + EQ-specific controls

    @ViewBuilder
    private func expandedControls(for node: FXNodeConfig) -> some View {
        if node.kind == .eq {
            eqDetailControls(node)
        } else if node.kind.isHosted {
            HostedStageControls(node: node)
        } else {
            genericDetailControls(node)
        }
    }

    private func genericDetailControls(_ node: FXNodeConfig) -> some View {
        VStack(spacing: 10) {
            ForEach(FXBuiltinSpecs.specs(for: node.kind)) { spec in
                if let choices = spec.choices {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(spec.name)
                            .font(.body.weight(.medium))
                        Picker(spec.name, selection: choiceBinding(nodeID: node.id, spec: spec)) {
                            ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                                Text(choice).tag(index)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        if !spec.detail.isEmpty {
                            Text(spec.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                } else {
                    ParameterSliderRow(label: spec.name, description: spec.detail,
                                       value: paramBinding(nodeID: node.id, spec: spec),
                                       range: spec.min...spec.max, unit: spec.unit.rawValue)
                }
            }
        }
    }

    private func eqDetailControls(_ node: FXNodeConfig) -> some View {
        VStack(spacing: 10) {
            InteractiveEQView(nodeID: node.id)
                .environmentObject(routingState)
                .frame(height: 110)

            let bands = node.eqBands ?? []
            ForEach(bands) { band in
                EQBandRow(nodeID: node.id, band: band, canRemove: bands.count > 1, onRemove: {
                    removeEQBand(node.id, bandID: band.id)
                })
                .environmentObject(routingState)
            }

            HStack {
                Spacer()
                Button {
                    addEQBand(node.id)
                } label: {
                    Label("Add Band", systemImage: "plus.circle")
                }
                .buttonStyle(.glass)
                .tint(nil)
                .controlSize(.small)
                .disabled(bands.count >= InteractiveEQView.maxBands)
            }

            if let outputGainSpec = FXBuiltinSpecs.eq.first(where: { $0.id == "outputGain" }) {
                ParameterSliderRow(label: outputGainSpec.name, description: outputGainSpec.detail,
                                   value: paramBinding(nodeID: node.id, spec: outputGainSpec),
                                   range: outputGainSpec.min...outputGainSpec.max, unit: outputGainSpec.unit.rawValue)
            }
        }
    }

    private func addEQBand(_ nodeID: UUID) {
        guard let idx = routingState.effectsPreset.nodes.firstIndex(where: { $0.id == nodeID }),
              var bands = routingState.effectsPreset.nodes[idx].eqBands,
              bands.count < InteractiveEQView.maxBands else { return }
        let nextID = (bands.map(\.id).max() ?? -1) + 1
        bands.append(EQBandConfig(id: nextID, type: .peaking, frequencyHz: 1000, gainDB: 0, q: 1.0))
        routingState.effectsPreset.nodes[idx].eqBands = bands
        routingState.save()
    }

    private func removeEQBand(_ nodeID: UUID, bandID: Int) {
        guard let idx = routingState.effectsPreset.nodes.firstIndex(where: { $0.id == nodeID }),
              var bands = routingState.effectsPreset.nodes[idx].eqBands, bands.count > 1 else { return }
        bands.removeAll { $0.id == bandID }
        routingState.effectsPreset.nodes[idx].eqBands = bands
        routingState.save()
    }
}

// MARK: - A/B compare control

/// Loudness-matched bypass compare. A quick click latches/unlatches bypass; press-and-hold
/// previews the bypassed (dry) signal only while held, then returns to the prior state on
/// release — the two gestures `FXEngine.setABBypass` is meant to support.
private struct ABCompareControl: View {
    @EnvironmentObject var fxEngine: FXEngine
    @State private var pressStart: Date?
    @State private var wasBypassedAtPress = false

    var body: some View {
        HStack(spacing: 4) {
            Text(fxEngine.abBypassed ? "B" : "A")
                .font(.caption.weight(.bold).monospacedDigit())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(fxEngine.abBypassed ? Color.signalWarm.opacity(0.18) : Color.loopbacker.opacity(0.12),
                    in: Capsule())
        .foregroundStyle(fxEngine.abBypassed ? Color.signalWarm : Color.loopbacker)
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard pressStart == nil else { return }
                    pressStart = Date()
                    wasBypassedAtPress = fxEngine.abBypassed
                    fxEngine.setABBypass(true)
                }
                .onEnded { _ in
                    defer { pressStart = nil }
                    guard let pressStart else { return }
                    let heldLong = Date().timeIntervalSince(pressStart) > 0.25
                    fxEngine.setABBypass(heldLong ? wasBypassedAtPress : !wasBypassedAtPress)
                }
        )
        .help("Click to toggle A/B; press and hold to preview bypassed")
        .accessibilityLabel("A/B compare")
        .accessibilityValue(fxEngine.abBypassed ? "Bypassed (B)" : "Processed (A)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { fxEngine.setABBypass(!fxEngine.abBypassed) }
    }
}

// MARK: - Call app advice banner (standalone for direct preview/render-test use)

struct CallAppAdviceBanner: View {
    let advice: CallAppAdvice
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color.loopbacker)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(advice.appName) is running").font(.callout.weight(.semibold))
                Text(advice.advice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .tint(nil)
            .help("Dismiss this tip")
            .accessibilityLabel("Dismiss \(advice.appName) tip")
        }
        .padding(.horizontal, Metrics.panelPadding)
        .padding(.vertical, 10)
        .glassPanel(cornerRadius: Metrics.innerRadius, tint: Color.loopbacker.opacity(0.06))
    }
}
