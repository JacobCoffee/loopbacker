import SwiftUI

// MARK: - Hosted-plugin spec safety

/// A hosted plugin's reported parameter bounds (AU v2/v3 `minValue`/`maxValue`, JSFX
/// `slider1:...<min,max,...>`) come straight from untrusted/third-party code: ysfx doesn't
/// validate `curve.min`/`curve.max`, and neither AU API validates its bounds either. Building
/// `spec.min...spec.max` directly traps when reversed or non-finite — LB-UI-001.
extension FXParamSpec {
    /// `min...max`, safe to pass to `ClosedRange`/`Slider`: non-finite bounds fall back to
    /// `0...1`, reversed bounds are swapped.
    var safeRange: ClosedRange<Float> {
        guard min.isFinite, max.isFinite else { return 0...1 }
        return Swift.min(min, max)...Swift.max(min, max)
    }

    /// `defaultValue` clamped into `safeRange`, for the same untrusted-bounds reason.
    var safeDefaultValue: Float {
        let range = safeRange
        guard defaultValue.isFinite else { return range.lowerBound }
        return Swift.min(Swift.max(defaultValue, range.lowerBound), range.upperBound)
    }
}

// MARK: - Live stage visuals
//
// Each visual polls its node's `FXMeters` at display rate via `TimelineView(.periodic)` rather
// than touching SwiftUI state from the IO thread: the meters are lock-free atomics the engine
// writes, and polling only runs while the view is actually on screen, satisfying "pause when
// window not visible" without any extra bookkeeping. When no voice chain is running (no mic
// routed yet, or this is an offscreen preview), `FXEngine.liveNode` returns nil and every visual
// below falls back to a resting state instead of crashing or showing stale numbers.

private let meterTick: TimeInterval = 1.0 / 20.0

// MARK: - Preview overrides (offscreen render tests)

private struct PreviewMetersKey: EnvironmentKey {
    static let defaultValue: [UUID: FXMeters] = [:]
}
private struct PreviewLoadErrorsKey: EnvironmentKey {
    static let defaultValue: [UUID: String] = [:]
}

extension EnvironmentValues {
    /// Offscreen render tests only: substitutes a node's live `FXMeters` so a render can show
    /// mid-level activity without a real audio chain running. Empty (no override) in the app.
    var previewMeters: [UUID: FXMeters] {
        get { self[PreviewMetersKey.self] }
        set { self[PreviewMetersKey.self] = newValue }
    }
    /// Offscreen render tests only: substitutes `FXEngine.nodeLoadErrors` so a render can show
    /// the hosted-node load-error state without actually failing to load a plugin.
    var previewLoadErrors: [UUID: String] {
        get { self[PreviewLoadErrorsKey.self] }
        set { self[PreviewLoadErrorsKey.self] = newValue }
    }
}

/// Shared "no live signal" caption, shown under a resting visual.
private struct RestingCaption: View {
    var body: some View {
        Text("Not processing audio — route a mic to see live levels.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}

// MARK: - Gate

/// Live input level bar with a draggable threshold and hysteresis band, and an open/closed
/// state readout.
struct GateVisual: View {
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var fxEngine: FXEngine
    @Environment(\.previewMeters) private var previewMeters
    let nodeID: UUID

    private var thresholdSpec: FXParamSpec { FXBuiltinSpecs.gate.first { $0.id == "threshold" }! }
    private var hysteresisSpec: FXParamSpec { FXBuiltinSpecs.gate.first { $0.id == "hysteresis" }! }

    private func value(_ id: String) -> Float {
        routingState.effectsPreset.nodes.first(where: { $0.id == nodeID })?.params[id]
            ?? FXBuiltinSpecs.defaultValue(.gate, id) ?? 0
    }

    private func setValue(_ id: String, _ v: Float) {
        guard let idx = routingState.effectsPreset.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        routingState.effectsPreset.nodes[idx].params[id] = v
        routingState.save()
    }

    /// Maps a dB value (-80...0) to a 0...1 bar position.
    private func position(_ db: Float) -> CGFloat { CGFloat((db + 80) / 80) }
    private func dB(forPosition x: CGFloat, width: CGFloat) -> Float {
        Float(max(0, min(1, x / width))) * 80 - 80
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: meterTick)) { _ in
            let meters = previewMeters[nodeID] ?? fxEngine.liveNode(id: nodeID)?.meters
            let inputDB = meters.map { fxLinearToDB($0.inputPeak) } ?? -80
            let openness = meters?.activity ?? 0
            let isOpen = openness > 0.5

            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    let width = geo.size.width
                    let threshold = value("threshold")
                    let hysteresis = value("hysteresis")
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5))

                        // Live input level fill.
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.loopbacker.opacity(0.6))
                            .frame(width: max(2, position(inputDB) * width))
                            .animation(.linear(duration: 0.08), value: inputDB)

                        // Hysteresis band (threshold down to threshold - hysteresis).
                        Rectangle()
                            .fill(Color.secondary.opacity(0.25))
                            .frame(width: max(1, position(threshold) * width - position(threshold - hysteresis) * width))
                            .offset(x: position(threshold - hysteresis) * width)

                        // Threshold line, draggable.
                        Rectangle()
                            .fill(Color.loopbacker)
                            .frame(width: 2)
                            .offset(x: position(threshold) * width - 1)
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { v in
                                        setValue("threshold", min(0, max(-80, dB(forPosition: v.location.x, width: width))))
                                    }
                            )
                    }
                }
                .frame(height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Gate threshold")
                .accessibilityValue(ParameterSliderRow.formatDisplayValue(value("threshold"), unit: "dB"))
                .accessibilityAdjustableAction { direction in
                    let delta: Float = direction == .increment ? 1 : -1
                    setValue("threshold", min(0, max(-80, value("threshold") + delta)))
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(isOpen ? Color.loopbacker : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                    Text(isOpen ? "Open" : "Closed")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isOpen ? Color.loopbacker : .secondary)
                    Spacer()
                    Text(inputDB <= -79.5 ? "Silent" : ParameterSliderRow.formatDisplayValue(inputDB, unit: "dB"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if meters == nil { RestingCaption() }
            }
        }
    }
}

// MARK: - Compressor

/// A static threshold/ratio/knee transfer curve with the live input level plotted as a dot,
/// plus a gain-reduction meter.
struct CompressorVisual: View {
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var fxEngine: FXEngine
    @Environment(\.previewMeters) private var previewMeters
    let nodeID: UUID

    private func value(_ id: String) -> Float {
        routingState.effectsPreset.nodes.first(where: { $0.id == nodeID })?.params[id]
            ?? FXBuiltinSpecs.defaultValue(.compressor, id) ?? 0
    }

    /// Classic soft-knee compressor transfer function, in dB.
    private func output(forInput x: Float, threshold: Float, ratio: Float, knee: Float) -> Float {
        let overshoot = x - threshold
        if knee > 0, abs(overshoot) <= knee / 2 {
            let kneeOvershoot = overshoot + knee / 2
            return x + (1 / ratio - 1) * (kneeOvershoot * kneeOvershoot) / (2 * knee)
        }
        return overshoot > 0 ? threshold + overshoot / ratio : x
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: meterTick)) { _ in
            let meters = previewMeters[nodeID] ?? fxEngine.liveNode(id: nodeID)?.meters
            let inputDB = meters.map { fxLinearToDB($0.inputPeak) } ?? -60
            let gr = meters?.gainReductionDB ?? 0
            let threshold = value("threshold")
            let ratio = max(1, value("ratio"))
            let knee = value("knee")

            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { geo in
                    let size = geo.size
                    let minDB: Float = -60, maxDB: Float = 0
                    let px: (Float) -> CGFloat = { db in CGFloat((db - minDB) / (maxDB - minDB)) * size.width }
                    let py: (Float) -> CGFloat = { db in size.height - CGFloat((db - minDB) / (maxDB - minDB)) * size.height }

                    ZStack {
                        RoundedRectangle(cornerRadius: Metrics.innerRadius - 4).fill(.quaternary.opacity(0.4))

                        Path { p in p.move(to: .init(x: 0, y: size.height)); p.addLine(to: .init(x: size.width, y: 0)) }
                            .stroke(.tertiary, style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))

                        Path { p in
                            var started = false
                            var db = minDB
                            while db <= maxDB {
                                let out = output(forInput: db, threshold: threshold, ratio: ratio, knee: knee)
                                let pt = CGPoint(x: px(db), y: py(out))
                                if !started { p.move(to: pt); started = true } else { p.addLine(to: pt) }
                                db += 0.5
                            }
                        }
                        .stroke(Color.loopbacker, lineWidth: 2)

                        // Live input dot.
                        let outDB = output(forInput: inputDB, threshold: threshold, ratio: ratio, knee: knee)
                        Circle()
                            .fill(Color.loopbacker)
                            .frame(width: 8, height: 8)
                            .position(x: px(inputDB), y: py(outDB))
                            .shadow(color: .loopbacker.opacity(0.6), radius: 4)
                            .animation(.linear(duration: 0.08), value: inputDB)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.innerRadius - 4))
                }
                .frame(height: 140)
                .accessibilityLabel("Compressor transfer curve")
                .accessibilityValue("Threshold \(ParameterSliderRow.formatDisplayValue(threshold, unit: "dB")), ratio \(String(format: "%.1f:1", ratio))")

                HStack(spacing: 8) {
                    Text("Gain Reduction")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    GeometryReader { geo in
                        let maxGR: Float = 24
                        ZStack(alignment: .trailing) {
                            RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.5))
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.7))
                                .frame(width: max(2, CGFloat(min(1, gr / maxGR)) * geo.size.width))
                        }
                    }
                    .frame(height: 10)
                    Text(String(format: "-%.1f dB", gr))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Gain reduction, \(String(format: "%.1f", gr)) dB")

                if meters == nil { RestingCaption() }
            }
        }
    }
}

// MARK: - Leveler

/// Momentary loudness vs. target with the current applied gain.
struct LevelerVisual: View {
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var fxEngine: FXEngine
    @Environment(\.previewMeters) private var previewMeters
    let nodeID: UUID

    private func value(_ id: String) -> Float {
        routingState.effectsPreset.nodes.first(where: { $0.id == nodeID })?.params[id]
            ?? FXBuiltinSpecs.defaultValue(.leveler, id) ?? 0
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: meterTick)) { _ in
            let meters = previewMeters[nodeID] ?? fxEngine.liveNode(id: nodeID)?.meters
            // `activity` documented per-stage: the leveler reports measured short-term loudness
            // mapped into -40...0 LUFS-ish range for display.
            let measured = meters.map { -40 + $0.activity * 40 } ?? value("target")
            let gain = meters?.gainReductionDB ?? 0
            let target = value("target")

            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { geo in
                    let width = geo.size.width
                    let minL: Float = -40, maxL: Float = 0
                    let px: (Float) -> CGFloat = { l in CGFloat((l - minL) / (maxL - minL)) * width }

                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5))
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.loopbacker.opacity(0.6))
                            .frame(width: max(2, px(measured)))
                            .animation(.linear(duration: 0.2), value: measured)
                        Rectangle()
                            .fill(Color.primary.opacity(0.6))
                            .frame(width: 2)
                            .offset(x: px(target) - 1)
                    }
                }
                .frame(height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Measured loudness vs target")
                .accessibilityValue("\(String(format: "%.1f", measured)) LUFS, target \(String(format: "%.1f", target)) LUFS")

                HStack {
                    Text("Target \(String(format: "%.0f", target)) LUFS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "Gain %+.1f dB", -gain))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if meters == nil { RestingCaption() }
            }
        }
    }
}

// MARK: - De-Esser

/// Sibilance-reduction activity meter.
struct DeEsserVisual: View {
    @EnvironmentObject var fxEngine: FXEngine
    @Environment(\.previewMeters) private var previewMeters
    let nodeID: UUID

    var body: some View {
        TimelineView(.periodic(from: .now, by: meterTick)) { _ in
            let meters = previewMeters[nodeID] ?? fxEngine.liveNode(id: nodeID)?.meters
            let activity = meters?.activity ?? 0

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Activity")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.5))
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.loopbacker)
                                .frame(width: max(2, CGFloat(min(max(activity, 0), 1)) * geo.size.width))
                                .animation(.linear(duration: 0.08), value: activity)
                        }
                    }
                    .frame(height: 10)
                    Text("\(Int(activity * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("De-esser activity, \(Int(activity * 100)) percent")

                if meters == nil { RestingCaption() }
            }
        }
    }
}

// MARK: - Limiter

/// Gain-reduction meter against the configured ceiling.
struct LimiterVisual: View {
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var fxEngine: FXEngine
    @Environment(\.previewMeters) private var previewMeters
    let nodeID: UUID

    private func value(_ id: String) -> Float {
        routingState.effectsPreset.nodes.first(where: { $0.id == nodeID })?.params[id]
            ?? FXBuiltinSpecs.defaultValue(.limiter, id) ?? 0
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: meterTick)) { _ in
            let meters = previewMeters[nodeID] ?? fxEngine.liveNode(id: nodeID)?.meters
            let gr = meters?.gainReductionDB ?? 0
            let ceiling = value("ceiling")

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Gain Reduction")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    GeometryReader { geo in
                        let maxGR: Float = 12
                        ZStack(alignment: .trailing) {
                            RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.5))
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.7))
                                .frame(width: max(2, CGFloat(min(1, gr / maxGR)) * geo.size.width))
                                .animation(.linear(duration: 0.08), value: gr)
                        }
                    }
                    .frame(height: 10)
                    Text(String(format: "-%.1f dB", gr))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Limiter gain reduction, \(String(format: "%.1f", gr)) dB")

                Text("Ceiling \(ParameterSliderRow.formatDisplayValue(ceiling, unit: "dB"))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if meters == nil { RestingCaption() }
            }
        }
    }
}

// MARK: - Hosted stage controls

/// Hosted (AU/JSFX/Airwindows) stage: generic parameter controls for any specs the plugin
/// reports, plus a button to open its native editor window.
struct HostedStageControls: View {
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var fxEngine: FXEngine
    let node: FXNodeConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let liveNode = fxEngine.liveNode(id: node.id), !liveNode.specs.isEmpty {
                ForEach(liveNode.specs) { spec in
                    if let choices = spec.choices {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(spec.name).font(.body.weight(.medium))
                            Picker(spec.name, selection: choiceBinding(spec: spec)) {
                                ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                                    Text(choice).tag(index)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                        .padding(.vertical, 6)
                    } else {
                        ParameterSliderRow(label: spec.name, description: spec.detail,
                                           value: paramBinding(spec: spec),
                                           range: spec.safeRange, unit: spec.unit.rawValue)
                    }
                }
            } else {
                Text("This effect's parameters aren't described yet; open its editor window to adjust it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task {
                    guard let hosted = fxEngine.liveNode(id: node.id) as? any FXHostedNode else { return }
                    await PluginEditorWindowController.show(for: hosted, title: node.pluginRef?.name ?? "Effect")
                }
            } label: {
                Label("Open Plugin Window", systemImage: "macwindow")
            }
            .buttonStyle(.glass)
            .tint(nil)
            .disabled(fxEngine.liveNode(id: node.id) == nil)
        }
    }

    private func paramBinding(spec: FXParamSpec) -> Binding<Float> {
        Binding(
            get: { routingState.effectsPreset.nodes.first(where: { $0.id == node.id })?.params[spec.id] ?? spec.safeDefaultValue },
            set: { newValue in
                guard let idx = routingState.effectsPreset.nodes.firstIndex(where: { $0.id == node.id }) else { return }
                routingState.effectsPreset.nodes[idx].params[spec.id] = newValue
                routingState.save()
            }
        )
    }

    private func choiceBinding(spec: FXParamSpec) -> Binding<Int> {
        Binding(
            get: {
                let raw = paramBinding(spec: spec).wrappedValue
                return Int(raw.isFinite ? raw.rounded() : 0)
            },
            set: { paramBinding(spec: spec).wrappedValue = Float($0) }
        )
    }
}
