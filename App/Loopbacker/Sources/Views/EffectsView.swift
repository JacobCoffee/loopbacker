import SwiftUI

// MARK: - Interactive EQ Visualization (draggable band dots)

struct InteractiveEQView: View {
    @EnvironmentObject var routingState: RoutingState
    @State private var draggingIndex: Int? = nil
    @State private var dragLabel: String = ""
    @State private var dragLabelPosition: CGPoint = .zero

    private var bands: [EQBandConfig] {
        routingState.effectsPreset.eqBands
    }

    /// Log-normalize a frequency value to 0...1 range.
    private func logNormalize(_ value: Float, min: Float, max: Float) -> Float {
        let logMin = log10(min)
        let logMax = log10(max)
        let logVal = log10(Swift.max(value, min))
        return (logVal - logMin) / (logMax - logMin)
    }

    /// Inverse of logNormalize: 0...1 -> frequency in Hz (log scale).
    private func logDenormalize(_ norm: Float, min: Float, max: Float) -> Float {
        let logMin = log10(min)
        let logMax = log10(max)
        let logVal = logMin + norm * (logMax - logMin)
        return pow(10, logVal)
    }

    /// Compute the total EQ gain at a given frequency.
    private func totalGain(at freq: Float) -> Float {
        var total: Float = 0
        for band in bands {
            let dist = log2(freq / band.frequencyHz)
            let contribution = band.gainDB * exp(-dist * dist * band.q * 2)
            total += contribution
        }
        return total
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let maxGain: Float = 14

            ZStack {
                // Background
                RoundedRectangle(cornerRadius: 6)
                    .fill(LoopbackerTheme.bgInset)

                // Zero line
                Path { path in
                    let zeroY = size.height / 2
                    path.move(to: CGPoint(x: 0, y: zeroY))
                    path.addLine(to: CGPoint(x: size.width, y: zeroY))
                }
                .stroke(LoopbackerTheme.border, lineWidth: 0.5)

                // dB grid lines (-6, +6)
                ForEach([-6, 6], id: \.self) { db in
                    let yNorm = CGFloat(0.5 - Float(db) / (maxGain * 2))
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: yNorm * size.height))
                        path.addLine(to: CGPoint(x: size.width, y: yNorm * size.height))
                    }
                    .stroke(LoopbackerTheme.border.opacity(0.3), lineWidth: 0.5)
                }

                // Frequency tick marks
                let freqs: [Float] = [100, 500, 1000, 5000, 10000]
                ForEach(freqs, id: \.self) { freq in
                    let normX = logNormalize(freq, min: 20, max: 20000)
                    Path { path in
                        let x = CGFloat(normX) * size.width
                        path.move(to: CGPoint(x: x, y: size.height - 4))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    .stroke(LoopbackerTheme.textMuted.opacity(0.3), lineWidth: 0.5)
                }

                // EQ curve + fill
                curvePaths(size: size, maxGain: maxGain)

                // Band dots (draggable)
                ForEach(Array(bands.enumerated()), id: \.offset) { index, band in
                    let normX = logNormalize(band.frequencyHz, min: 20, max: 20000)
                    let x = CGFloat(normX) * size.width
                    let yNorm = CGFloat(0.5 - band.gainDB / (maxGain * 2))
                    let y = yNorm * size.height
                    let isDragging = draggingIndex == index
                    let radius: CGFloat = isDragging ? 8 : 6

                    Circle()
                        .fill(LoopbackerTheme.accent)
                        .frame(width: radius * 2, height: radius * 2)
                        .shadow(color: isDragging ? LoopbackerTheme.accentGlow : .clear, radius: isDragging ? 10 : 0)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(isDragging ? 0.4 : 0.15), lineWidth: isDragging ? 1.5 : 0.5)
                        )
                        .position(x: x, y: y)
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { value in
                                    withAnimation(.interactiveSpring()) {
                                        draggingIndex = index
                                    }

                                    // Horizontal -> frequency (log scale)
                                    let clampedX = Swift.max(0, Swift.min(Float(value.location.x / size.width), 1))
                                    let newFreq = logDenormalize(clampedX, min: 20, max: 20000)
                                    routingState.effectsPreset.eqBands[index].frequencyHz = newFreq

                                    // Vertical -> gain (skip for highpass band id 0)
                                    if band.id != 0 {
                                        let clampedY = Swift.max(0, Swift.min(Float(value.location.y / size.height), 1))
                                        let newGain = (0.5 - clampedY) * maxGain * 2
                                        let clampedGain = Swift.max(-12, Swift.min(12, newGain))
                                        routingState.effectsPreset.eqBands[index].gainDB = clampedGain
                                    }

                                    // Update label
                                    let currentBand = routingState.effectsPreset.eqBands[index]
                                    let freqStr = currentBand.frequencyHz >= 1000
                                        ? String(format: "%.1fkHz", currentBand.frequencyHz / 1000)
                                        : String(format: "%.0fHz", currentBand.frequencyHz)
                                    let gainStr = band.id == 0 ? "HP" : String(format: "%+.1fdB", currentBand.gainDB)
                                    dragLabel = "\(freqStr) \(gainStr)"
                                    dragLabelPosition = CGPoint(
                                        x: Swift.max(40, Swift.min(Double(size.width) - 40, Double(value.location.x))),
                                        y: Swift.max(16, Double(value.location.y) - 20)
                                    )
                                }
                                .onEnded { _ in
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        draggingIndex = nil
                                    }
                                    routingState.save()
                                }
                        )
                }

                // Drag tooltip
                if draggingIndex != nil {
                    Text(dragLabel)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(LoopbackerTheme.textPrimary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(LoopbackerTheme.bgCard)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(LoopbackerTheme.accent.opacity(0.4), lineWidth: 0.5)
                        )
                        .shadow(color: Color.black.opacity(0.2), radius: 4, x: 0, y: 2)
                        .position(dragLabelPosition)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(LoopbackerTheme.border, lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private func curvePaths(size: CGSize, maxGain: Float) -> some View {
        let steps = Int(size.width)

        // Curve path
        let curvePath = Path { path in
            for step in 0...steps {
                let normX = Float(step) / Float(steps)
                let freq = pow(10, normX * (log10(20000) - log10(20)) + log10(20))
                let gain = totalGain(at: freq)
                let yNorm = CGFloat(0.5 - gain / (maxGain * 2))
                let y = yNorm * size.height
                let x = CGFloat(step)
                if step == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
        }

        // Fill under curve
        let fillPath = Path { path in
            for step in 0...steps {
                let normX = Float(step) / Float(steps)
                let freq = pow(10, normX * (log10(20000) - log10(20)) + log10(20))
                let gain = totalGain(at: freq)
                let yNorm = CGFloat(0.5 - gain / (maxGain * 2))
                let y = yNorm * size.height
                let x = CGFloat(step)
                if step == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: size.height))
            path.closeSubpath()
        }

        fillPath.fill(LoopbackerTheme.accent.opacity(0.08))
        curvePath.stroke(LoopbackerTheme.accent.opacity(0.6), lineWidth: 1.5)
    }
}

// MARK: - Effects pipeline view (full-page, Audio Hijack-inspired)

struct EffectsView: View {
    @EnvironmentObject var routingState: RoutingState
    @State private var expandedEffect: String?
    @State private var hoveredEffect: String?
    @State private var pipelineAppeared = false
    @State private var signalPhase: CGFloat = 0

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
            ("Reverb", "waveform.path.ecg.rectangle", preset.reverbEnabled, {
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

    var body: some View {
        ZStack {
            // Background with subtle grid
            pipelineBackground

            VStack(spacing: 0) {
                effectsHeader
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 16)

                if preset.isEnabled {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 0) {
                            // Signal flow pipeline
                            ScrollView(.horizontal, showsIndicators: false) {
                                pipelineRow
                                    .padding(.horizontal, 32)
                                    .padding(.top, 8)
                            }

                            // Expanded detail panel (below the pipeline)
                            if let expanded = expandedEffect {
                                expandedPanel(for: expanded)
                                    .padding(.horizontal, 32)
                                    .padding(.top, 20)
                                    .transition(.asymmetric(
                                        insertion: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.98, anchor: .top)),
                                        removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
                                    ))
                            }
                        }
                        .padding(.bottom, 20)
                    }

                    // Signal flow legend
                    signalFlowLegend
                        .padding(.horizontal, 32)
                        .padding(.bottom, 20)
                } else {
                    disabledState
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.6).delay(0.1)) {
                pipelineAppeared = true
            }
            // Animate the signal flow dashes
            withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) {
                signalPhase = 1.0
            }
            refreshSavedPresets()
        }
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

    // MARK: - Pipeline background

    private var pipelineBackground: some View {
        Canvas { context, size in
            let gridSpacing: CGFloat = 24
            let lineColor = Color(white: 0.12).opacity(0.15)

            var x: CGFloat = 0
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(lineColor), lineWidth: 0.5)
                x += gridSpacing
            }

            var y: CGFloat = 0
            while y < size.height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(lineColor), lineWidth: 0.5)
                y += gridSpacing
            }

            // Accent radial glow at center-top
            let glowCenter = CGPoint(x: size.width / 2, y: size.height * 0.3)
            let gradient = Gradient(colors: [
                Color(red: 0.0, green: 0.83, blue: 0.67).opacity(0.04),
                Color.clear
            ])
            context.fill(
                Path(ellipseIn: CGRect(
                    x: glowCenter.x - 400, y: glowCenter.y - 200,
                    width: 800, height: 400
                )),
                with: .radialGradient(gradient, center: glowCenter, startRadius: 0, endRadius: 400)
            )
        }
        .background(LoopbackerTheme.bgDeep)
    }

    // MARK: - Effects header

    private var effectsHeader: some View {
        HStack(spacing: 14) {
            // Icon with glow
            ZStack {
                if preset.isEnabled {
                    Circle()
                        .fill(LoopbackerTheme.accent.opacity(0.15))
                        .frame(width: 48, height: 48)
                        .blur(radius: 8)
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(preset.isEnabled ? LoopbackerTheme.accent.opacity(0.15) : LoopbackerTheme.bgInset)
                        .frame(width: 40, height: 40)

                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(preset.isEnabled ? LoopbackerTheme.accent : LoopbackerTheme.textMuted)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Effects Chain")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(preset.isEnabled ? LoopbackerTheme.textPrimary : LoopbackerTheme.textMuted)

                Text("Broadcast Voice Processing Pipeline")
                    .font(.system(size: 11))
                    .foregroundColor(LoopbackerTheme.textSecondary)
            }

            Spacer()

            // Active effects count
            if preset.isEnabled {
                let activeCount = stages.filter(\.enabled).count
                HStack(spacing: 4) {
                    Text("\(activeCount)/\(stages.count)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                    Text("ACTIVE")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(1.0)
                }
                .foregroundColor(LoopbackerTheme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(LoopbackerTheme.accent.opacity(0.08))
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(LoopbackerTheme.accent.opacity(0.2), lineWidth: 0.5))
            }

            // Preset management menu
            presetMenu

            masterToggle
        }
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
            HStack(spacing: 4) {
                Image(systemName: "tray.2")
                    .font(.system(size: 10, weight: .semibold))
                Text("PRESETS")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .foregroundColor(LoopbackerTheme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(LoopbackerTheme.bgInset)
            )
            .overlay(
                Capsule().strokeBorder(LoopbackerTheme.border, lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .popover(isPresented: $showingSavePopover, arrowEdge: .bottom) {
            savePresetPopover
        }
        .onAppear {
            refreshSavedPresets()
        }
    }

    // MARK: - Save preset popover

    private var savePresetPopover: some View {
        VStack(spacing: 12) {
            Text("Save Preset")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(LoopbackerTheme.textPrimary)

            TextField("Preset name", text: $newPresetName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)

            HStack(spacing: 8) {
                Button("Cancel") {
                    showingSavePopover = false
                }
                .buttonStyle(.plain)
                .foregroundColor(LoopbackerTheme.textSecondary)

                Button("Save") {
                    guard !newPresetName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    EffectsPresetManager.save(name: newPresetName, preset: routingState.effectsPreset)
                    refreshSavedPresets()
                    showingSavePopover = false
                }
                .buttonStyle(.plain)
                .foregroundColor(LoopbackerTheme.accent)
                .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .background(LoopbackerTheme.bgCard)
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

    private var masterToggle: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.3)) {
                routingState.effectsPreset.isEnabled.toggle()
                if !routingState.effectsPreset.isEnabled {
                    expandedEffect = nil
                }
                routingState.save()
            }
        }) {
            HStack(spacing: 6) {
                Circle()
                    .fill(preset.isEnabled ? LoopbackerTheme.accent : LoopbackerTheme.textMuted)
                    .frame(width: 8, height: 8)
                    .shadow(color: preset.isEnabled ? LoopbackerTheme.accentGlow : .clear, radius: 4)

                Text(preset.isEnabled ? "ON" : "OFF")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(preset.isEnabled ? LoopbackerTheme.accent : LoopbackerTheme.textMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(preset.isEnabled ? LoopbackerTheme.accent.opacity(0.12) : LoopbackerTheme.bgInset)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        preset.isEnabled ? LoopbackerTheme.accent.opacity(0.3) : LoopbackerTheme.border,
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .tooltip("Toggle broadcast voice processing effects chain")
    }

    // MARK: - Disabled state

    private var disabledState: some View {
        VStack(spacing: 16) {
            Spacer()

            ZStack {
                Circle()
                    .fill(LoopbackerTheme.bgInset)
                    .frame(width: 80, height: 80)

                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 32))
                    .foregroundColor(LoopbackerTheme.textMuted.opacity(0.5))
            }

            Text("Effects Chain Disabled")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(LoopbackerTheme.textMuted)

            Text("Enable to apply broadcast voice processing")
                .font(.system(size: 12))
                .foregroundColor(LoopbackerTheme.textMuted.opacity(0.7))

            Button(action: {
                withAnimation(.easeInOut(duration: 0.3)) {
                    routingState.effectsPreset.isEnabled = true
                    routingState.save()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .semibold))
                    Text("ENABLE EFFECTS")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1.0)
                }
                .foregroundColor(LoopbackerTheme.accent)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LoopbackerTheme.accent.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(LoopbackerTheme.accent.opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Pipeline row (Input -> blocks -> Output)

    private var pipelineRow: some View {
        HStack(spacing: 0) {
            // Input terminal
            terminalBlock(label: "INPUT", icon: "mic.fill", isInput: true)

            // Cable from input
            cableSegment(active: preset.isEnabled)

            // Effect blocks with cables between them
            ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                effectPipelineBlock(
                    name: stage.name,
                    icon: stage.icon,
                    enabled: stage.enabled,
                    toggle: stage.toggle,
                    index: index
                )

                if index < stages.count - 1 {
                    cableSegment(active: stage.enabled && stages[index + 1].enabled)
                }
            }

            // Cable to output
            cableSegment(active: stages.last?.enabled ?? false)

            // Output terminal
            terminalBlock(label: "OUTPUT", icon: "speaker.wave.2.fill", isInput: false)
        }
        .padding(.vertical, 16)
        .opacity(pipelineAppeared ? 1.0 : 0.0)
        .offset(y: pipelineAppeared ? 0 : 12)
    }

    // MARK: - Terminal block (Input / Output)

    private func terminalBlock(label: String, icon: String, isInput: Bool) -> some View {
        VStack(spacing: 6) {
            ZStack {
                // Glow
                RoundedRectangle(cornerRadius: 10)
                    .fill(LoopbackerTheme.accent.opacity(0.06))
                    .frame(width: 72, height: 72)
                    .blur(radius: 6)

                RoundedRectangle(cornerRadius: 10)
                    .fill(LoopbackerTheme.bgCard)
                    .frame(width: 64, height: 64)

                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(LoopbackerTheme.accent.opacity(0.3), lineWidth: 1)
                    .frame(width: 64, height: 64)

                VStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(LoopbackerTheme.accent)

                    Text(label)
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundColor(LoopbackerTheme.accent.opacity(0.7))
                        .tracking(1.0)
                }
            }
        }
    }

    // MARK: - Cable segment between blocks

    private func cableSegment(active: Bool) -> some View {
        ZStack {
            // Cable line
            Rectangle()
                .fill(active ? LoopbackerTheme.accent.opacity(0.3) : LoopbackerTheme.border.opacity(0.5))
                .frame(width: 40, height: 2)

            // Animated signal dots when active
            if active && preset.isEnabled {
                Circle()
                    .fill(LoopbackerTheme.accent)
                    .frame(width: 4, height: 4)
                    .shadow(color: LoopbackerTheme.accentGlow, radius: 3)
                    .offset(x: -18 + (signalPhase * 36))
                    .opacity(0.8)

                Circle()
                    .fill(LoopbackerTheme.accent.opacity(0.5))
                    .frame(width: 3, height: 3)
                    .offset(x: -18 + (((signalPhase + 0.5).truncatingRemainder(dividingBy: 1.0)) * 36))
                    .opacity(0.5)
            }
        }
        .frame(width: 40, height: 64)
    }

    // MARK: - Effect pipeline block

    private func effectPipelineBlock(
        name: String,
        icon: String,
        enabled: Bool,
        toggle: @escaping () -> Void,
        index: Int
    ) -> some View {
        let isExpanded = expandedEffect == name
        let isHovered = hoveredEffect == name

        return VStack(spacing: 0) {
            Button(action: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    expandedEffect = expandedEffect == name ? nil : name
                }
            }) {
                ZStack {
                    // Outer glow when enabled
                    if enabled {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(LoopbackerTheme.accent.opacity(isExpanded ? 0.12 : (isHovered ? 0.08 : 0.04)))
                            .frame(width: 108, height: 88)
                            .blur(radius: 8)
                    }

                    // Main block
                    VStack(spacing: 6) {
                        // Status indicator bar
                        HStack {
                            Circle()
                                .fill(enabled ? LoopbackerTheme.accent : LoopbackerTheme.textMuted.opacity(0.4))
                                .frame(width: 5, height: 5)
                                .shadow(color: enabled ? LoopbackerTheme.accentGlow : .clear, radius: 3)

                            Spacer()

                            if isExpanded {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundColor(LoopbackerTheme.textMuted)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 8)

                        // Icon
                        Image(systemName: icon)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(enabled ? LoopbackerTheme.accent : LoopbackerTheme.textMuted)
                            .shadow(color: enabled ? LoopbackerTheme.accentGlow.opacity(0.5) : .clear, radius: 6)

                        // Name
                        Text(name.uppercased())
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(enabled ? LoopbackerTheme.textPrimary : LoopbackerTheme.textMuted)
                            .tracking(0.8)
                            .lineLimit(1)

                        Spacer(minLength: 0)
                    }
                    .frame(width: 96, height: 80)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(enabled
                                  ? LoopbackerTheme.bgCard
                                  : LoopbackerTheme.bgInset)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                enabled
                                    ? (isExpanded ? LoopbackerTheme.accent.opacity(0.6) : LoopbackerTheme.accent.opacity(0.25))
                                    : LoopbackerTheme.border,
                                lineWidth: isExpanded ? 1.5 : 0.5
                            )
                    )
                    .shadow(
                        color: enabled ? LoopbackerTheme.accent.opacity(isHovered ? 0.15 : 0.05) : .clear,
                        radius: isHovered ? 12 : 6,
                        x: 0, y: 2
                    )
                }
            }
            .buttonStyle(.plain)
            .onHover { isHovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    hoveredEffect = isHovering ? name : nil
                }
            }
            .contextMenu {
                Button(action: toggle) {
                    Label(enabled ? "Bypass \(name)" : "Enable \(name)",
                          systemImage: enabled ? "xmark.circle" : "checkmark.circle")
                }
            }

            // Block order indicator
            Text("\(index + 1)")
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundColor(LoopbackerTheme.textMuted.opacity(0.4))
                .padding(.top, 4)
        }
    }

    // MARK: - Expanded detail panel

    @ViewBuilder
    private func expandedPanel(for effectName: String) -> some View {
        let stage = stages.first { $0.name == effectName }
        let enabled = stage?.enabled ?? false
        let toggle = stage?.toggle ?? {}

        VStack(spacing: 0) {
            // Panel header
            HStack(spacing: 10) {
                // Effect icon
                if let icon = stage?.icon {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(enabled ? LoopbackerTheme.accent.opacity(0.12) : LoopbackerTheme.bgInset)
                            .frame(width: 28, height: 28)

                        Image(systemName: icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(enabled ? LoopbackerTheme.accent : LoopbackerTheme.textMuted)
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(effectName.uppercased())
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(LoopbackerTheme.textPrimary)
                        .tracking(1.0)

                    Text(effectDescription(effectName))
                        .font(.system(size: 10))
                        .foregroundColor(LoopbackerTheme.textSecondary)
                }

                Spacer()

                // Reset button
                Button(action: {
                    resetEffect(effectName)
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 8, weight: .bold))
                        Text("RESET")
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .tracking(0.5)
                    }
                    .foregroundColor(LoopbackerTheme.textMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(LoopbackerTheme.bgInset)
                    )
                    .overlay(
                        Capsule().strokeBorder(LoopbackerTheme.border, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .tooltip("Reset \(effectName) to default values")

                // Bypass / Enable button
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) { toggle() }
                }) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(enabled ? LoopbackerTheme.accent : LoopbackerTheme.textMuted)
                            .frame(width: 5, height: 5)
                            .shadow(color: enabled ? LoopbackerTheme.accentGlow : .clear, radius: 2)

                        Text(enabled ? "ACTIVE" : "BYPASSED")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(enabled ? LoopbackerTheme.accent : LoopbackerTheme.warning)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(
                            enabled ? LoopbackerTheme.accent.opacity(0.1) : LoopbackerTheme.warning.opacity(0.1)
                        )
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            enabled ? LoopbackerTheme.accent.opacity(0.25) : LoopbackerTheme.warning.opacity(0.25),
                            lineWidth: 0.5
                        )
                    )
                }
                .buttonStyle(.plain)

                // Close
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        expandedEffect = nil
                    }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(LoopbackerTheme.textMuted)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(LoopbackerTheme.bgInset))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().background(LoopbackerTheme.border)

            // Controls
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // Quick presets row
                    quickPresetsRow(for: effectName)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 6)

                    expandedControls(for: effectName)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                }
            }
            .frame(maxHeight: 300)
        }
        .background(
            RoundedRectangle(cornerRadius: LoopbackerTheme.cardCornerRadius)
                .fill(LoopbackerTheme.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LoopbackerTheme.cardCornerRadius)
                .strokeBorder(
                    enabled ? LoopbackerTheme.accent.opacity(0.2) : LoopbackerTheme.border,
                    lineWidth: 0.5
                )
        )
        .shadow(color: Color.black.opacity(0.15), radius: 12, x: 0, y: 4)
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
        let presets = quickPresets(for: effectName)
        if !presets.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("QUICK PRESETS")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundColor(LoopbackerTheme.textMuted)
                    .tracking(1.0)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(presets, id: \.name) { qp in
                            Button(action: qp.apply) {
                                Text(qp.name)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(LoopbackerTheme.accent)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule().fill(LoopbackerTheme.accent.opacity(0.08))
                                    )
                                    .overlay(
                                        Capsule().strokeBorder(LoopbackerTheme.accent.opacity(0.2), lineWidth: 0.5)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
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

    // MARK: - Gate detail controls

    private var gateDetailControls: some View {
        VStack(spacing: 14) {
            parameterRow("Threshold", value: $routingState.effectsPreset.gateThresholdDB, range: -60...0, unit: "dB",
                          description: "Level below which audio is attenuated")
            parameterRow("Attack", value: $routingState.effectsPreset.gateAttackMs, range: 0.1...50, unit: "ms",
                          description: "How fast the gate opens")
            parameterRow("Release", value: $routingState.effectsPreset.gateReleaseMs, range: 10...500, unit: "ms",
                          description: "How fast the gate closes")
            parameterRow("Reduction", value: $routingState.effectsPreset.gateReductionDB, range: -40...0, unit: "dB",
                          description: "Attenuation applied when gate is closed")
        }
    }

    // MARK: - EQ detail controls

    private var eqDetailControls: some View {
        VStack(spacing: 12) {
            // Interactive EQ curve visualization
            InteractiveEQView()
                .environmentObject(routingState)
                .frame(height: 100)
                .padding(.bottom, 4)

            ForEach(0..<min(preset.eqBands.count, 5), id: \.self) { i in
                let band = preset.eqBands[i]
                eqBandRow(band: band, index: i)
            }
        }
    }

    private func logNormalize(_ value: Float, min: Float, max: Float) -> Float {
        let logMin = log10(min)
        let logMax = log10(max)
        let logVal = log10(Swift.max(value, min))
        return (logVal - logMin) / (logMax - logMin)
    }

    private func eqBandRow(band: EQBandConfig, index: Int) -> some View {
        HStack(spacing: 12) {
            // Band type badge
            Text(bandTypeLabel(band.type))
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundColor(LoopbackerTheme.accent)
                .tracking(0.5)
                .frame(width: 28)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LoopbackerTheme.accent.opacity(0.08))
                )

            // Frequency
            VStack(alignment: .leading, spacing: 1) {
                Text("FREQ")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundColor(LoopbackerTheme.textMuted)
                    .tracking(0.5)

                Text(formatFrequency(band.frequencyHz))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(LoopbackerTheme.textPrimary)
            }
            .frame(width: 50)

            // Gain slider (not for highpass)
            if band.type != .highpass {
                VStack(alignment: .leading, spacing: 1) {
                    Text("GAIN")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundColor(LoopbackerTheme.textMuted)
                        .tracking(0.5)

                    HStack(spacing: 6) {
                        Slider(
                            value: Binding(
                                get: { routingState.effectsPreset.eqBands[index].gainDB },
                                set: {
                                    routingState.effectsPreset.eqBands[index].gainDB = $0
                                    routingState.save()
                                }
                            ),
                            in: -12...12
                        )
                        .tint(band.gainDB >= 0 ? LoopbackerTheme.accent : LoopbackerTheme.warning)

                        Text(String(format: "%+.1f", band.gainDB))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(band.gainDB >= 0 ? LoopbackerTheme.accent : LoopbackerTheme.warning)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text("TYPE")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundColor(LoopbackerTheme.textMuted)
                        .tracking(0.5)

                    Text("High Pass Filter")
                        .font(.system(size: 10))
                        .foregroundColor(LoopbackerTheme.textSecondary)
                }
            }

            Spacer()

            // Q value
            VStack(alignment: .trailing, spacing: 1) {
                Text("Q")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundColor(LoopbackerTheme.textMuted)
                    .tracking(0.5)

                Text(String(format: "%.2f", band.q))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(LoopbackerTheme.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(LoopbackerTheme.bgInset.opacity(0.5))
        )
    }

    private func bandTypeLabel(_ type: EQBandConfig.BandType) -> String {
        switch type {
        case .highpass: return "HP"
        case .lowshelf: return "LS"
        case .peaking: return "PK"
        case .highshelf: return "HS"
        }
    }

    private func formatFrequency(_ freq: Float) -> String {
        if freq >= 1000 {
            return String(format: "%.1fk", freq / 1000)
        } else {
            return String(format: "%.0f", freq)
        }
    }

    // MARK: - Compressor detail controls

    private var compressorDetailControls: some View {
        VStack(spacing: 14) {
            parameterRow("Threshold", value: $routingState.effectsPreset.compressorThresholdDB, range: -40...0, unit: "dB",
                          description: "Level above which compression starts")
            parameterRow("Ratio", value: $routingState.effectsPreset.compressorRatio, range: 1...20, unit: ":1",
                          description: "Amount of gain reduction applied")
            parameterRow("Attack", value: $routingState.effectsPreset.compressorAttackMs, range: 0.1...100, unit: "ms",
                          description: "How fast compression engages")
            parameterRow("Release", value: $routingState.effectsPreset.compressorReleaseMs, range: 10...500, unit: "ms",
                          description: "How fast compression releases")
            parameterRow("Makeup", value: $routingState.effectsPreset.compressorMakeupDB, range: 0...12, unit: "dB",
                          description: "Gain added after compression")
        }
    }

    // MARK: - De-Esser detail controls

    private var deEsserDetailControls: some View {
        VStack(spacing: 14) {
            parameterRow("Frequency", value: $routingState.effectsPreset.deEsserFrequencyHz, range: 2000...12000, unit: "Hz",
                          description: "Center frequency for sibilance detection")
            parameterRow("Reduction", value: $routingState.effectsPreset.deEsserReductionDB, range: -12...0, unit: "dB",
                          description: "Maximum sibilance attenuation")
            parameterRow("Ratio", value: $routingState.effectsPreset.deEsserRatio, range: 1...10, unit: ":1",
                          description: "Compression ratio for detected sibilance")
        }
    }

    // MARK: - Limiter detail controls

    private var chorusDetailControls: some View {
        VStack(spacing: 14) {
            parameterRow("Rate", value: $routingState.effectsPreset.chorusRate, range: 0.1...5.0, unit: "Hz",
                          description: "LFO speed -- how fast the modulation sweeps")
            parameterRow("Depth", value: $routingState.effectsPreset.chorusDepth, range: 0...10, unit: "ms",
                          description: "Modulation depth -- wider = more detuning")
            parameterRow("Mix", value: $routingState.effectsPreset.chorusMix, range: 0...1, unit: "",
                          description: "Wet/dry balance")
        }
    }

    private var pitchShiftDetailControls: some View {
        VStack(spacing: 14) {
            parameterRow("Semitones", value: $routingState.effectsPreset.pitchSemitones, range: -12...12, unit: "st",
                          description: "Pitch shift amount (-12 = octave down, +12 = octave up)")
            parameterRow("Mix", value: $routingState.effectsPreset.pitchMix, range: 0...1, unit: "",
                          description: "Blend shifted signal with original")
        }
    }

    private var reverbDetailControls: some View {
        VStack(spacing: 14) {
            parameterRow("Room Size", value: $routingState.effectsPreset.reverbRoomSize, range: 0...1, unit: "",
                          description: "Size of the virtual space (0 = tiny, 1 = cathedral)")
            parameterRow("Damping", value: $routingState.effectsPreset.reverbDamping, range: 0...1, unit: "",
                          description: "High-frequency absorption (higher = warmer)")
            parameterRow("Mix", value: $routingState.effectsPreset.reverbMix, range: 0...1, unit: "",
                          description: "Wet/dry balance (keep low for voice)")
        }
    }

    private var delayDetailControls: some View {
        VStack(spacing: 14) {
            parameterRow("Time", value: $routingState.effectsPreset.delayTimeMs, range: 10...1000, unit: "ms",
                          description: "Delay time between echoes")
            parameterRow("Feedback", value: $routingState.effectsPreset.delayFeedback, range: 0...0.9, unit: "",
                          description: "How many times the echo repeats (0.9 = long tail)")
            parameterRow("Mix", value: $routingState.effectsPreset.delayMix, range: 0...1, unit: "",
                          description: "Wet/dry balance")
        }
    }

    private var limiterDetailControls: some View {
        VStack(spacing: 14) {
            parameterRow("Ceiling", value: $routingState.effectsPreset.limiterCeilingDB, range: -6...0, unit: "dB",
                          description: "Maximum output level -- prevents clipping")
            parameterRow("Release", value: $routingState.effectsPreset.limiterReleaseMs, range: 10...200, unit: "ms",
                          description: "How fast the limiter recovers")
        }
    }

    // MARK: - Parameter row (pro-style)

    private func parameterRow(
        _ label: String,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        unit: String,
        description: String = ""
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label.uppercased())
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(LoopbackerTheme.textSecondary)
                    .tracking(1.0)

                if !description.isEmpty {
                    Text(description)
                        .font(.system(size: 9))
                        .foregroundColor(LoopbackerTheme.textMuted)
                        .lineLimit(1)
                }

                Spacer()

                // Value readout
                Text(formatDisplayValue(value.wrappedValue, unit: unit))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(LoopbackerTheme.accent)
                    .frame(minWidth: 60, alignment: .trailing)
            }

            // Slider with track visualization
            ZStack(alignment: .leading) {
                // Custom track background
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // Track
                        RoundedRectangle(cornerRadius: 2)
                            .fill(LoopbackerTheme.bgInset)
                            .frame(height: 4)

                        // Fill
                        let normalized = CGFloat((value.wrappedValue - range.lowerBound) / (range.upperBound - range.lowerBound))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(
                                LinearGradient(
                                    colors: [LoopbackerTheme.accent.opacity(0.4), LoopbackerTheme.accent],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * normalized, height: 4)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 20)
                .allowsHitTesting(false)

                Slider(value: Binding(
                    get: { value.wrappedValue },
                    set: {
                        value.wrappedValue = $0
                        routingState.save()
                    }
                ), in: range)
                .tint(.clear)
                .frame(height: 20)
            }

            // Range labels
            HStack {
                Text(formatDisplayValue(range.lowerBound, unit: unit))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(LoopbackerTheme.textMuted.opacity(0.5))

                Spacer()

                Text(formatDisplayValue(range.upperBound, unit: unit))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(LoopbackerTheme.textMuted.opacity(0.5))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(LoopbackerTheme.bgInset.opacity(0.4))
        )
    }

    private func formatDisplayValue(_ v: Float, unit: String) -> String {
        if unit == "Hz" {
            if v >= 1000 {
                return String(format: "%.1f kHz", v / 1000)
            } else {
                return String(format: "%.0f Hz", v)
            }
        } else if unit == ":1" {
            return String(format: "%.1f:1", v)
        } else if unit == "dB" {
            return String(format: "%+.1f dB", v)
        } else {
            return String(format: "%.1f %@", v, unit)
        }
    }

    // MARK: - Signal flow legend

    private var signalFlowLegend: some View {
        HStack(spacing: 16) {
            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(LoopbackerTheme.accent)
                    .frame(width: 5, height: 5)
                    .shadow(color: LoopbackerTheme.accentGlow, radius: 2)
                Text("Active")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(LoopbackerTheme.textSecondary)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(LoopbackerTheme.textMuted.opacity(0.4))
                    .frame(width: 5, height: 5)
                Text("Bypassed")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(LoopbackerTheme.textSecondary)
            }

            Rectangle()
                .fill(LoopbackerTheme.border)
                .frame(width: 1, height: 12)

            HStack(spacing: 4) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(LoopbackerTheme.textMuted)
                Text("Signal Flow: Left to Right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(LoopbackerTheme.textSecondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(LoopbackerTheme.bgSurface.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(LoopbackerTheme.border.opacity(0.5), lineWidth: 0.5)
        )
    }
}
