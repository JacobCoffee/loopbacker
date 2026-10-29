import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Effects section: a left-to-right signal chain of glass slots (Input → 9 stages → Output)
/// plus a detail panel for the selected stage's parameters. Signal is the light source: active
/// stages and the lines between them glow Loopbacker green only while the chain is enabled.
struct EffectsView: View {
    @EnvironmentObject var routingState: RoutingState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var chainNamespace

    @State private var selectedEffect: String?

    // Preset management state
    @State private var savedPresetNames: [String] = []
    @State private var showingSavePopover = false
    @State private var newPresetName: String = ""

    private var preset: EffectsPreset {
        routingState.effectsPreset
    }

    /// The ordered pipeline stages.
    private var stages: [(name: String, icon: String, enabled: Bool, toggle: () -> Void)] {
        [
            ("Gate", "waveform.path.ecg", preset.gateEnabled, {
                routingState.effectsPreset.gateEnabled.toggle(); routingState.save()
            }),
            ("EQ", "slider.vertical.3", preset.eqEnabled, {
                routingState.effectsPreset.eqEnabled.toggle(); routingState.save()
            }),
            ("Compressor", "arrow.down.right.and.arrow.up.left", preset.compressorEnabled, {
                routingState.effectsPreset.compressorEnabled.toggle(); routingState.save()
            }),
            ("De-Esser", "s.circle", preset.deEsserEnabled, {
                routingState.effectsPreset.deEsserEnabled.toggle(); routingState.save()
            }),
            ("Chorus", "waveform.path", preset.chorusEnabled, {
                routingState.effectsPreset.chorusEnabled.toggle(); routingState.save()
            }),
            ("Pitch Shift", "arrow.up.arrow.down", preset.pitchShiftEnabled, {
                routingState.effectsPreset.pitchShiftEnabled.toggle(); routingState.save()
            }),
            ("Reverb", "drop.halffull", preset.reverbEnabled, {
                routingState.effectsPreset.reverbEnabled.toggle(); routingState.save()
            }),
            ("Delay", "repeat", preset.delayEnabled, {
                routingState.effectsPreset.delayEnabled.toggle(); routingState.save()
            }),
            ("Limiter", "gauge.with.dots.needle.67percent", preset.limiterEnabled, {
                routingState.effectsPreset.limiterEnabled.toggle(); routingState.save()
            }),
        ]
    }

    private var activeCount: Int { stages.filter(\.enabled).count }

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

                    if let selected = selectedEffect {
                        detailPanel(for: selected)
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
        .navigationSubtitle(preset.isEnabled ? "\(activeCount) of \(stages.count) active" : "Bypassed")
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
            if selectedEffect == nil {
                selectedEffect = stages.first(where: \.enabled)?.name ?? "Gate"
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

    // MARK: - Noise suppression

    /// Sits above the chain and outside its bypass dimming: suppression runs whenever it's on,
    /// whether or not the effects chain is enabled.
    private var noiseSuppressionCard: some View {
        let settings = routingState.noiseSuppression
        let on = settings.isEnabled
        let profile = NoiseEngineProfile.of(settings.engine)
        return VStack(alignment: .leading, spacing: Metrics.panelSpacing) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.badge.minus")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(on ? Color.loopbacker : Color.secondary)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Noise Suppression")
                        .font(.headline)
                    Text("Removes background noise from mic inputs on-device, before the effects chain (even when it's bypassed). \(profile.name) adds \(profile.latencyMs) ms of latency.")
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

                ForEach(Array(stages.enumerated()), id: \.element.name) { index, stage in
                    SignalLineConnector(active: preset.isEnabled && previousActive(before: index) && stage.enabled)
                    ChainSlotTile(
                        name: stage.name,
                        icon: stage.icon,
                        enabled: stage.enabled,
                        isSelected: selectedEffect == stage.name,
                        toggle: stage.toggle,
                        select: {
                            withAnimation(.easeOut(duration: 0.2)) {
                                selectedEffect = stage.name
                            }
                        },
                        namespace: chainNamespace
                    )
                }

                SignalLineConnector(active: preset.isEnabled && (stages.last?.enabled ?? false))
                ChainTerminalTile(label: "Output", icon: "speaker.wave.2.fill", namespace: chainNamespace)
            }
        }
    }

    /// Whether the segment feeding into `index` should glow: both the upstream node and this
    /// stage must be active (the input terminal is always "active").
    private func previousActive(before index: Int) -> Bool {
        index == 0 ? true : stages[index - 1].enabled
    }

    // MARK: - Detail panel

    @ViewBuilder
    private func detailPanel(for effectName: String) -> some View {
        let stage = stages.first { $0.name == effectName }
        let enabled = stage?.enabled ?? false
        let toggle = stage?.toggle ?? {}

        VStack(alignment: .leading, spacing: Metrics.panelSpacing) {
            HStack(spacing: 10) {
                if let icon = stage?.icon {
                    Image(systemName: icon)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(enabled ? Color.loopbacker : Color.secondary)
                        .frame(width: 28, height: 28)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(effectName)
                        .font(.headline)
                    Text(effectDescription(effectName))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Reset") {
                    resetEffect(effectName)
                }
                .buttonStyle(.glass)
                .tint(nil)
                .controlSize(.small)
                .help("Reset \(effectName) to default values")

                Toggle(isOn: Binding(
                    get: { enabled },
                    set: { _ in withAnimation(.easeInOut(duration: 0.2)) { toggle() } }
                )) {
                    Text(enabled ? "Active" : "Bypassed")
                        .font(.caption.weight(.semibold))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.loopbacker)
            }

            Divider()

            quickPresetsRow(for: effectName)

            expandedControls(for: effectName)
        }
        .padding(Metrics.panelPadding)
        .glassPanel(cornerRadius: Metrics.panelRadius, tint: enabled ? Color.loopbacker.opacity(0.08) : nil)
    }

    // MARK: - Reset effect to defaults

    private func resetEffect(_ name: String) {
        let defaults = EffectsPreset()
        withAnimation(.easeInOut(duration: 0.2)) {
            switch name {
            case "Gate":
                routingState.effectsPreset.gateThresholdDB = defaults.gateThresholdDB
                routingState.effectsPreset.gateAttackMs = defaults.gateAttackMs
                routingState.effectsPreset.gateReleaseMs = defaults.gateReleaseMs
                routingState.effectsPreset.gateReductionDB = defaults.gateReductionDB
            case "EQ":
                routingState.effectsPreset.eqBands = defaults.eqBands
            case "Compressor":
                routingState.effectsPreset.compressorThresholdDB = defaults.compressorThresholdDB
                routingState.effectsPreset.compressorRatio = defaults.compressorRatio
                routingState.effectsPreset.compressorAttackMs = defaults.compressorAttackMs
                routingState.effectsPreset.compressorReleaseMs = defaults.compressorReleaseMs
                routingState.effectsPreset.compressorMakeupDB = defaults.compressorMakeupDB
            case "De-Esser":
                routingState.effectsPreset.deEsserFrequencyHz = defaults.deEsserFrequencyHz
                routingState.effectsPreset.deEsserReductionDB = defaults.deEsserReductionDB
                routingState.effectsPreset.deEsserRatio = defaults.deEsserRatio
            case "Chorus":
                routingState.effectsPreset.chorusRate = defaults.chorusRate
                routingState.effectsPreset.chorusDepth = defaults.chorusDepth
                routingState.effectsPreset.chorusMix = defaults.chorusMix
            case "Pitch Shift":
                routingState.effectsPreset.pitchSemitones = defaults.pitchSemitones
                routingState.effectsPreset.pitchMix = defaults.pitchMix
            case "Reverb":
                routingState.effectsPreset.reverbRoomSize = defaults.reverbRoomSize
                routingState.effectsPreset.reverbDamping = defaults.reverbDamping
                routingState.effectsPreset.reverbMix = defaults.reverbMix
            case "Delay":
                routingState.effectsPreset.delayTimeMs = defaults.delayTimeMs
                routingState.effectsPreset.delayFeedback = defaults.delayFeedback
                routingState.effectsPreset.delayMix = defaults.delayMix
            case "Limiter":
                routingState.effectsPreset.limiterCeilingDB = defaults.limiterCeilingDB
                routingState.effectsPreset.limiterReleaseMs = defaults.limiterReleaseMs
            default:
                break
            }
            routingState.save()
        }
    }

    // MARK: - Quick presets row

    @ViewBuilder
    private func quickPresetsRow(for effectName: String) -> some View {
        QuickPresetsRow(presets: quickPresets(for: effectName).map {
            QuickPresetsRow.Preset(name: $0.name, apply: $0.apply)
        })
    }

    private struct QuickPreset {
        let name: String
        let apply: () -> Void
    }

    private func quickPresets(for effectName: String) -> [QuickPreset] {
        switch effectName {
        case "Gate":
            return [
                QuickPreset(name: "Soft Gate") {
                    routingState.effectsPreset.gateThresholdDB = -36
                    routingState.effectsPreset.gateReductionDB = -12
                    routingState.save()
                },
                QuickPreset(name: "Hard Gate") {
                    routingState.effectsPreset.gateThresholdDB = -30
                    routingState.effectsPreset.gateReductionDB = -40
                    routingState.save()
                },
                QuickPreset(name: "Light") {
                    routingState.effectsPreset.gateThresholdDB = -45
                    routingState.effectsPreset.gateReductionDB = -6
                    routingState.save()
                },
            ]
        case "EQ":
            return [
                QuickPreset(name: "Broadcast Masculine") {
                    routingState.effectsPreset.eqBands = EQBandConfig.broadcastMasculine
                    routingState.save()
                },
                QuickPreset(name: "Flat") {
                    routingState.effectsPreset.eqBands = [
                        EQBandConfig(id: 0, type: .highpass, frequencyHz: 80, gainDB: 0, q: 0.7),
                        EQBandConfig(id: 1, type: .peaking, frequencyHz: 220, gainDB: 0, q: 0.7),
                        EQBandConfig(id: 2, type: .peaking, frequencyHz: 350, gainDB: 0, q: 1.2),
                        EQBandConfig(id: 3, type: .peaking, frequencyHz: 3500, gainDB: 0, q: 0.9),
                        EQBandConfig(id: 4, type: .highshelf, frequencyHz: 10000, gainDB: 0, q: 0.7),
                    ]
                    routingState.save()
                },
                QuickPreset(name: "Warm") {
                    routingState.effectsPreset.eqBands = [
                        EQBandConfig(id: 0, type: .highpass, frequencyHz: 80, gainDB: 0, q: 0.7),
                        EQBandConfig(id: 1, type: .peaking, frequencyHz: 200, gainDB: 2, q: 0.8),
                        EQBandConfig(id: 2, type: .peaking, frequencyHz: 350, gainDB: 0, q: 1.2),
                        EQBandConfig(id: 3, type: .peaking, frequencyHz: 3000, gainDB: -1, q: 0.9),
                        EQBandConfig(id: 4, type: .highshelf, frequencyHz: 10000, gainDB: 0, q: 0.7),
                    ]
                    routingState.save()
                },
                QuickPreset(name: "Bright") {
                    routingState.effectsPreset.eqBands = [
                        EQBandConfig(id: 0, type: .highpass, frequencyHz: 80, gainDB: 0, q: 0.7),
                        EQBandConfig(id: 1, type: .peaking, frequencyHz: 220, gainDB: 0, q: 0.7),
                        EQBandConfig(id: 2, type: .peaking, frequencyHz: 350, gainDB: 0, q: 1.2),
                        EQBandConfig(id: 3, type: .peaking, frequencyHz: 5000, gainDB: 3, q: 0.9),
                        EQBandConfig(id: 4, type: .highshelf, frequencyHz: 10000, gainDB: 2, q: 0.7),
                    ]
                    routingState.save()
                },
            ]
        case "Compressor":
            return [
                QuickPreset(name: "Gentle") {
                    routingState.effectsPreset.compressorRatio = 2
                    routingState.effectsPreset.compressorThresholdDB = -20
                    routingState.effectsPreset.compressorMakeupDB = 0
                    routingState.save()
                },
                QuickPreset(name: "Broadcast") {
                    routingState.effectsPreset.compressorRatio = 3
                    routingState.effectsPreset.compressorThresholdDB = -18
                    routingState.effectsPreset.compressorMakeupDB = 3
                    routingState.save()
                },
                QuickPreset(name: "Aggressive") {
                    routingState.effectsPreset.compressorRatio = 6
                    routingState.effectsPreset.compressorThresholdDB = -24
                    routingState.effectsPreset.compressorMakeupDB = 6
                    routingState.save()
                },
            ]
        case "De-Esser":
            return [
                QuickPreset(name: "Light") {
                    routingState.effectsPreset.deEsserReductionDB = -3
                    routingState.save()
                },
                QuickPreset(name: "Normal") {
                    routingState.effectsPreset.deEsserReductionDB = -6
                    routingState.save()
                },
                QuickPreset(name: "Heavy") {
                    routingState.effectsPreset.deEsserReductionDB = -10
                    routingState.save()
                },
            ]
        case "Chorus":
            return [
                QuickPreset(name: "Subtle") {
                    routingState.effectsPreset.chorusRate = 1.0; routingState.effectsPreset.chorusDepth = 2; routingState.effectsPreset.chorusMix = 0.2; routingState.save()
                },
                QuickPreset(name: "Thick") {
                    routingState.effectsPreset.chorusRate = 0.8; routingState.effectsPreset.chorusDepth = 5; routingState.effectsPreset.chorusMix = 0.5; routingState.save()
                },
                QuickPreset(name: "Vibrato") {
                    routingState.effectsPreset.chorusRate = 5.0; routingState.effectsPreset.chorusDepth = 1; routingState.effectsPreset.chorusMix = 0.8; routingState.save()
                },
            ]
        case "Pitch Shift":
            return [
                QuickPreset(name: "Down Octave") {
                    routingState.effectsPreset.pitchSemitones = -12; routingState.save()
                },
                QuickPreset(name: "Up Fifth") {
                    routingState.effectsPreset.pitchSemitones = 7; routingState.save()
                },
                QuickPreset(name: "Chipmunk") {
                    routingState.effectsPreset.pitchSemitones = 12; routingState.save()
                },
                QuickPreset(name: "None") {
                    routingState.effectsPreset.pitchSemitones = 0; routingState.save()
                },
            ]
        case "Reverb":
            return [
                QuickPreset(name: "Small Room") {
                    routingState.effectsPreset.reverbRoomSize = 0.3; routingState.effectsPreset.reverbDamping = 0.6; routingState.effectsPreset.reverbMix = 0.12; routingState.save()
                },
                QuickPreset(name: "Hall") {
                    routingState.effectsPreset.reverbRoomSize = 0.8; routingState.effectsPreset.reverbDamping = 0.3; routingState.effectsPreset.reverbMix = 0.2; routingState.save()
                },
                QuickPreset(name: "Subtle") {
                    routingState.effectsPreset.reverbRoomSize = 0.4; routingState.effectsPreset.reverbDamping = 0.5; routingState.effectsPreset.reverbMix = 0.08; routingState.save()
                },
            ]
        case "Delay":
            return [
                QuickPreset(name: "Slapback") {
                    routingState.effectsPreset.delayTimeMs = 80; routingState.effectsPreset.delayFeedback = 0.1; routingState.effectsPreset.delayMix = 0.3; routingState.save()
                },
                QuickPreset(name: "Quarter") {
                    routingState.effectsPreset.delayTimeMs = 500; routingState.effectsPreset.delayFeedback = 0.3; routingState.effectsPreset.delayMix = 0.25; routingState.save()
                },
                QuickPreset(name: "Long Echo") {
                    routingState.effectsPreset.delayTimeMs = 750; routingState.effectsPreset.delayFeedback = 0.5; routingState.effectsPreset.delayMix = 0.2; routingState.save()
                },
            ]
        case "Limiter":
            return [
                QuickPreset(name: "Safe") {
                    routingState.effectsPreset.limiterCeilingDB = -1.5
                    routingState.save()
                },
                QuickPreset(name: "Loud") {
                    routingState.effectsPreset.limiterCeilingDB = -0.5
                    routingState.save()
                },
                QuickPreset(name: "Broadcast") {
                    routingState.effectsPreset.limiterCeilingDB = -1.0
                    routingState.save()
                },
            ]
        default:
            return []
        }
    }

    private func effectDescription(_ name: String) -> String {
        switch name {
        case "Gate": return "Reduces background noise below a threshold"
        case "EQ": return "Shape tonal balance with parametric bands"
        case "Compressor": return "Tames dynamic range for consistent levels"
        case "De-Esser": return "Reduces harsh sibilance in vocals"
        case "Chorus": return "Thickens voice with modulated detuning"
        case "Pitch Shift": return "Shift voice pitch up or down in semitones"
        case "Reverb": return "Adds room/hall spatial ambience"
        case "Delay": return "Echo effect with adjustable feedback"
        case "Limiter": return "Prevents clipping with a hard ceiling"
        default: return ""
        }
    }

    @ViewBuilder
    private func expandedControls(for effectName: String) -> some View {
        switch effectName {
        case "Gate": gateDetailControls
        case "EQ": eqDetailControls
        case "Compressor": compressorDetailControls
        case "De-Esser": deEsserDetailControls
        case "Chorus": chorusDetailControls
        case "Pitch Shift": pitchShiftDetailControls
        case "Reverb": reverbDetailControls
        case "Delay": delayDetailControls
        case "Limiter": limiterDetailControls
        default: EmptyView()
        }
    }

    // MARK: - Parameter binding helper

    private func boundParameter(_ keyPath: WritableKeyPath<EffectsPreset, Float>) -> Binding<Float> {
        Binding(
            get: { routingState.effectsPreset[keyPath: keyPath] },
            set: {
                routingState.effectsPreset[keyPath: keyPath] = $0
                routingState.save()
            }
        )
    }

    // MARK: - Gate detail controls

    private var gateDetailControls: some View {
        VStack(spacing: 10) {
            ParameterSliderRow(label: "Threshold", description: "Level below which audio is attenuated",
                                value: boundParameter(\.gateThresholdDB), range: -60...0, unit: "dB")
            ParameterSliderRow(label: "Attack", description: "How fast the gate opens",
                                value: boundParameter(\.gateAttackMs), range: 0.1...50, unit: "ms")
            ParameterSliderRow(label: "Release", description: "How fast the gate closes",
                                value: boundParameter(\.gateReleaseMs), range: 10...500, unit: "ms")
            ParameterSliderRow(label: "Reduction", description: "Attenuation applied when gate is closed",
                                value: boundParameter(\.gateReductionDB), range: -40...0, unit: "dB")
        }
    }

    // MARK: - EQ detail controls

    private var eqDetailControls: some View {
        VStack(spacing: 10) {
            InteractiveEQView()
                .environmentObject(routingState)
                .frame(height: 110)

            ForEach(0..<min(preset.eqBands.count, 5), id: \.self) { i in
                EQBandRow(band: preset.eqBands[i], index: i)
                    .environmentObject(routingState)
            }
        }
    }

    // MARK: - Compressor detail controls

    private var compressorDetailControls: some View {
        VStack(spacing: 10) {
            ParameterSliderRow(label: "Threshold", description: "Level above which compression starts",
                                value: boundParameter(\.compressorThresholdDB), range: -40...0, unit: "dB")
            ParameterSliderRow(label: "Ratio", description: "Amount of gain reduction applied",
                                value: boundParameter(\.compressorRatio), range: 1...20, unit: ":1")
            ParameterSliderRow(label: "Attack", description: "How fast compression engages",
                                value: boundParameter(\.compressorAttackMs), range: 0.1...100, unit: "ms")
            ParameterSliderRow(label: "Release", description: "How fast compression releases",
                                value: boundParameter(\.compressorReleaseMs), range: 10...500, unit: "ms")
            ParameterSliderRow(label: "Makeup", description: "Gain added after compression",
                                value: boundParameter(\.compressorMakeupDB), range: 0...12, unit: "dB")
        }
    }

    // MARK: - De-Esser detail controls

    private var deEsserDetailControls: some View {
        VStack(spacing: 10) {
            ParameterSliderRow(label: "Frequency", description: "Center frequency for sibilance detection",
                                value: boundParameter(\.deEsserFrequencyHz), range: 2000...12000, unit: "Hz")
            ParameterSliderRow(label: "Reduction", description: "Maximum sibilance attenuation",
                                value: boundParameter(\.deEsserReductionDB), range: -12...0, unit: "dB")
            ParameterSliderRow(label: "Ratio", description: "Compression ratio for detected sibilance",
                                value: boundParameter(\.deEsserRatio), range: 1...10, unit: ":1")
        }
    }

    // MARK: - Chorus detail controls

    private var chorusDetailControls: some View {
        VStack(spacing: 10) {
            ParameterSliderRow(label: "Rate", description: "LFO speed -- how fast the modulation sweeps",
                                value: boundParameter(\.chorusRate), range: 0.1...5.0, unit: "Hz")
            ParameterSliderRow(label: "Depth", description: "Modulation depth -- wider = more detuning",
                                value: boundParameter(\.chorusDepth), range: 0...10, unit: "ms")
            ParameterSliderRow(label: "Mix", description: "Wet/dry balance",
                                value: boundParameter(\.chorusMix), range: 0...1, unit: "")
        }
    }

    // MARK: - Pitch Shift detail controls

    private var pitchShiftDetailControls: some View {
        VStack(spacing: 10) {
            ParameterSliderRow(label: "Semitones", description: "Pitch shift amount (-12 = octave down, +12 = octave up)",
                                value: boundParameter(\.pitchSemitones), range: -12...12, unit: "st")
            ParameterSliderRow(label: "Mix", description: "Blend shifted signal with original",
                                value: boundParameter(\.pitchMix), range: 0...1, unit: "")
        }
    }

    // MARK: - Reverb detail controls

    private var reverbDetailControls: some View {
        VStack(spacing: 10) {
            ParameterSliderRow(label: "Room Size", description: "Size of the virtual space (0 = tiny, 1 = cathedral)",
                                value: boundParameter(\.reverbRoomSize), range: 0...1, unit: "")
            ParameterSliderRow(label: "Damping", description: "High-frequency absorption (higher = warmer)",
                                value: boundParameter(\.reverbDamping), range: 0...1, unit: "")
            ParameterSliderRow(label: "Mix", description: "Wet/dry balance (keep low for voice)",
                                value: boundParameter(\.reverbMix), range: 0...1, unit: "")
        }
    }

    // MARK: - Delay detail controls

    private var delayDetailControls: some View {
        VStack(spacing: 10) {
            ParameterSliderRow(label: "Time", description: "Delay time between echoes",
                                value: boundParameter(\.delayTimeMs), range: 10...1000, unit: "ms")
            ParameterSliderRow(label: "Feedback", description: "How many times the echo repeats (0.9 = long tail)",
                                value: boundParameter(\.delayFeedback), range: 0...0.9, unit: "")
            ParameterSliderRow(label: "Mix", description: "Wet/dry balance",
                                value: boundParameter(\.delayMix), range: 0...1, unit: "")
        }
    }

    // MARK: - Limiter detail controls

    private var limiterDetailControls: some View {
        VStack(spacing: 10) {
            ParameterSliderRow(label: "Ceiling", description: "Maximum output level -- prevents clipping",
                                value: boundParameter(\.limiterCeilingDB), range: -6...0, unit: "dB")
            ParameterSliderRow(label: "Release", description: "How fast the limiter recovers",
                                value: boundParameter(\.limiterReleaseMs), range: 10...200, unit: "ms")
        }
    }
}
