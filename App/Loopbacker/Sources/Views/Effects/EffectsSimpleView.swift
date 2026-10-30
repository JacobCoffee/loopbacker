import SwiftUI

// MARK: - Simple mode
//
// Four macro sliders rewrite the underlying chain via `FXMacros.apply`; noise suppression and
// echo cancellation sit alongside since they're the other two always-on cleanup stages. A big
// live meter shows input vs. processed output against the leveler's loudness target, and Auto
// Setup is the one-tap path into a measured, tuned chain.
struct EffectsSimpleView: View {
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var fxEngine: FXEngine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.previewMeters) private var previewMeters

    @Binding var showingAutoSetup: Bool

    private var macros: FXMacroValues {
        FXMacros.estimate(preset: routingState.effectsPreset, noise: routingState.noiseSuppression)
    }

    private func macroBinding(_ keyPath: WritableKeyPath<FXMacroValues, Float>) -> Binding<Float> {
        Binding(
            get: { macros[keyPath: keyPath] },
            set: { newValue in
                var v = macros
                v[keyPath: keyPath] = newValue
                let (preset, noise) = FXMacros.apply(v, to: routingState.effectsPreset, noise: routingState.noiseSuppression)
                routingState.effectsPreset = preset
                routingState.noiseSuppression = noise
                routingState.save()
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.panelSpacing) {
            macroPanel
            liveMeterPanel

            NoiseEnginePicker(selection: Binding(
                get: { routingState.noiseSuppression.engine },
                set: { routingState.noiseSuppression.engine = $0; routingState.save() }
            ), isActive: routingState.noiseSuppression.isEnabled)
            .padding(Metrics.panelPadding)
            .glassPanel(cornerRadius: Metrics.panelRadius)

            EchoCancellationSection()
                .padding(Metrics.panelPadding)
                .glassPanel(cornerRadius: Metrics.panelRadius)

            autoSetupPanel
        }
    }

    private var macroPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Voice Shaping")
                .font(.headline)

            macroSlider(label: "Clarity", icon: "waveform.badge.magnifyingglass",
                       detail: "Presence and de-essing for intelligible speech",
                       binding: macroBinding(\.clarity))
            macroSlider(label: "Warmth", icon: "flame",
                       detail: "Low-mid body vs. a thinner, brighter tone",
                       binding: macroBinding(\.warmth))
            macroSlider(label: "Noise", icon: "waveform.badge.minus",
                       detail: "How aggressively background noise is removed",
                       binding: macroBinding(\.noise))
            macroSlider(label: "Loudness", icon: "speaker.wave.3",
                       detail: "How hard the compressor and limiter work",
                       binding: macroBinding(\.loudness))
        }
        .padding(Metrics.panelPadding)
        .glassPanel(cornerRadius: Metrics.panelRadius)
    }

    private func macroSlider(label: String, icon: String, detail: String, binding: Binding<Float>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Label(label, systemImage: icon)
                    .font(.body.weight(.medium))
                Spacer()
                Text("\(Int(binding.wrappedValue * 100))%")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.loopbacker)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: binding, in: 0...1) { Text(label) }
                .tint(.loopbacker)
                .accessibilityValue("\(Int(binding.wrappedValue * 100)) percent")
        }
        .padding(.vertical, 4)
    }

    // MARK: - Live meter

    private var liveMeterPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Live Voice Level").font(.headline)
            TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { _ in
                let firstID = routingState.effectsPreset.nodes.first(where: \.enabled)?.id
                let lastID = routingState.effectsPreset.nodes.last(where: \.enabled)?.id
                let inputPeak = firstID.flatMap { previewMeters[$0]?.inputPeak ?? fxEngine.liveNode(id: $0)?.meters.inputPeak } ?? 0
                let outputPeak = lastID.flatMap { previewMeters[$0]?.outputPeak ?? fxEngine.liveNode(id: $0)?.meters.outputPeak } ?? 0
                let target = routingState.effectsPreset.nodes.first(where: { $0.kind == .leveler })?.params["target"] ?? -18

                VStack(alignment: .leading, spacing: 8) {
                    meterRow(label: "Input", peak: inputPeak, target: target)
                    meterRow(label: "Output", peak: outputPeak, target: target)
                }
            }
            if previewMeters.isEmpty, fxEngine.liveNode(id: routingState.effectsPreset.nodes.first?.id ?? UUID()) == nil {
                Text("Not processing audio — route a mic to see live levels.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(Metrics.panelPadding)
        .glassPanel(cornerRadius: Metrics.panelRadius)
    }

    private func meterRow(label: String, peak: Float, target: Float) -> some View {
        let db = fxLinearToDB(peak)
        return HStack(spacing: 10) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            GeometryReader { geo in
                let width = geo.size.width
                let minDB: Float = -60, maxDB: Float = 0
                let px: (Float) -> CGFloat = { v in CGFloat((v - minDB) / (maxDB - minDB)) * width }
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5))
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.loopbacker.opacity(0.65))
                        .frame(width: max(2, px(max(minDB, db))))
                        .animation(.linear(duration: 0.08), value: db)
                    Rectangle()
                        .fill(Color.primary.opacity(0.5))
                        .frame(width: 2)
                        .offset(x: px(target) - 1)
                }
            }
            .frame(height: 16)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(db <= -59.5 ? "Silent" : ParameterSliderRow.formatDisplayValue(db, unit: "dB"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) level")
        .accessibilityValue(db <= -59.5 ? "Silent" : ParameterSliderRow.formatDisplayValue(db, unit: "dB"))
    }

    // MARK: - Auto Setup entry

    private var autoSetupPanel: some View {
        HStack(spacing: 12) {
            Image(systemName: "wand.and.stars")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.loopbacker)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Auto Setup").font(.headline)
                Text("Records a short sample of your room and voice, then tunes the whole chain to match.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Run Auto Setup") { showingAutoSetup = true }
                .buttonStyle(.glassProminent)
                .tint(.loopbacker)
        }
        .padding(Metrics.panelPadding)
        .glassPanel(cornerRadius: Metrics.panelRadius)
    }
}
