import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Effects section: a left-to-right signal chain of glass slots (Input → preset.nodes → Output)
/// plus a detail panel for the selected stage's parameters, generic over `FXParamSpec`. Signal
/// is the light source: active stages and the lines between them glow Loopbacker green only
/// while the chain is enabled.
struct EffectsView: View {
    @EnvironmentObject var routingState: RoutingState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var chainNamespace

    @State private var selectedNodeID: UUID?

    // Preset management state
    @State private var savedPresetNames: [String] = []
    @State private var showingSavePopover = false
    @State private var newPresetName: String = ""

    private var preset: EffectsPreset {
        routingState.effectsPreset
    }

    private var nodes: [FXNodeConfig] { preset.nodes }
    private var activeCount: Int { nodes.filter(\.enabled).count }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Metrics.panelSpacing) {
                noiseSuppressionCard

                if !preset.isEnabled {
                    disabledPrompt
                }

                HStack(alignment: .top, spacing: Metrics.panelSpacing + 6) {
                    chainSection
                        .frame(width: 210)
                        .opacity(preset.isEnabled ? 1 : 0.45)

                    if let selected = selectedNodeID, let node = nodes.first(where: { $0.id == selected }) {
                        detailPanel(for: node)
                            .frame(maxWidth: 760, alignment: .topLeading)
                            .id(selected)
                            .transition(.opacity)
                    }
                }
            }
            .padding(Metrics.canvasMargin)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationSubtitle(preset.isEnabled ? "\(activeCount) of \(nodes.count) active" : "Bypassed")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: masterBinding) {
                    Label(preset.isEnabled ? "Effects On" : "Effects Off", systemImage: "power")
                }
                .toggleStyle(.button)
                .help(preset.isEnabled ? "Bypass the whole effects chain" : "Enable the effects chain")
                presetMenu
            }
            GlobalToolbar()
        }
        .onAppear {
            refreshSavedPresets()
            if selectedNodeID == nil {
                selectedNodeID = nodes.first(where: \.enabled)?.id ?? nodes.first?.id
            }
        }
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

            NoiseEnginePicker(selection: noiseSuppressionBinding(\.engine), isActive: on)

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
            Section("Factory Presets") {
                ForEach(EffectsPreset.factoryPresets, id: \.name) { item in
                    Button(item.name) {
                        applyPreset(item.preset)
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
                applyPreset(EffectsPreset.broadcastVoice)
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

    // MARK: - Signal chain

    private var chainSection: some View {
        GlassEffectContainer(spacing: 0) {
            VStack(spacing: 0) {
                ChainTerminalTile(label: "Input", icon: "mic.fill", namespace: chainNamespace)

                ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                    SignalLineConnector(active: preset.isEnabled && previousActive(before: index) && node.enabled)
                    ChainSlotTile(
                        name: displayName(for: node.kind),
                        icon: icon(for: node.kind),
                        enabled: node.enabled,
                        isSelected: selectedNodeID == node.id,
                        toggle: { toggleNode(node.id) },
                        select: {
                            withAnimation(.easeOut(duration: 0.2)) {
                                selectedNodeID = node.id
                            }
                        },
                        namespace: chainNamespace
                    )
                }

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

    private func toggleNode(_ id: UUID) {
        guard let idx = routingState.effectsPreset.nodes.firstIndex(where: { $0.id == id }) else { return }
        routingState.effectsPreset.nodes[idx].enabled.toggle()
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
                    Text(displayName(for: node.kind))
                        .font(.headline)
                    Text(effectDescription(node.kind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Reset") {
                    resetNode(node.id)
                }
                .buttonStyle(.glass)
                .tint(nil)
                .controlSize(.small)
                .help("Reset \(displayName(for: node.kind)) to default values")

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

            if node.kind == .gate && node.enabled && routingState.noiseSuppression.isEnabled {
                gateWithSuppressionHint(node.id)
            }

            quickPresetsRow(for: node)

            expandedControls(for: node)
        }
        .padding(Metrics.panelPadding)
        .glassPanel(cornerRadius: Metrics.panelRadius, tint: node.enabled ? Color.loopbacker.opacity(0.08) : nil)
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

    // MARK: - Reset / quick presets, driven by FXParamSpec ids

    private func resetNode(_ id: UUID) {
        guard let idx = routingState.effectsPreset.nodes.firstIndex(where: { $0.id == id }) else { return }
        let kind = routingState.effectsPreset.nodes[idx].kind
        var defaults: [String: Float] = [:]
        for spec in FXBuiltinSpecs.specs(for: kind) { defaults[spec.id] = spec.defaultValue }
        withAnimation(.easeInOut(duration: 0.2)) {
            routingState.effectsPreset.nodes[idx].params = defaults
            if kind == .eq { routingState.effectsPreset.nodes[idx].eqBands = EQBandConfig.broadcastMasculine }
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
                QuickPresetsRow.Preset(name: "Broadcast Masculine", apply: {
                    applyQuickEQBands(node.id, bands: EQBandConfig.broadcastMasculine)
                }),
                QuickPresetsRow.Preset(name: "Flat", apply: {
                    applyQuickEQBands(node.id, bands: EQBandConfig.broadcastMasculine.map {
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
            Text("Open this effect's editor window to adjust its parameters.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            ForEach(Array(bands.prefix(16).enumerated()), id: \.element.id) { _, band in
                EQBandRow(nodeID: node.id, band: band)
                    .environmentObject(routingState)
            }

            if let outputGainSpec = FXBuiltinSpecs.eq.first(where: { $0.id == "outputGain" }) {
                ParameterSliderRow(label: outputGainSpec.name, description: outputGainSpec.detail,
                                   value: paramBinding(nodeID: node.id, spec: outputGainSpec),
                                   range: outputGainSpec.min...outputGainSpec.max, unit: outputGainSpec.unit.rawValue)
            }
        }
    }
}
