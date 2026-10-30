import SwiftUI

// MARK: - Chain slot

/// One insert slot in the vertical signal chain, like a channel strip's plug-in slot.
/// Clicking selects it for the detail panel; the power button bypasses it without opening it;
/// a context menu mirrors the same action.
struct ChainSlotTile: View {
    let name: String
    let icon: String
    let enabled: Bool
    let isSelected: Bool
    let toggle: () -> Void
    let select: () -> Void
    var namespace: Namespace.ID
    /// Live 0...1 processing activity (gate openness, GR normalized, de-esser activity, ...),
    /// drawn as a small glowing dot next to the power button. Nil hides it.
    var activity: Float? = nil
    /// Hosted stages only: the plugin failed to load. Shown as a warning badge; `select` still
    /// opens the detail panel so the user can remove/replace it.
    var loadError: String? = nil
    var isHosted: Bool = false
    var onDuplicate: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil
    var onReset: (() -> Void)? = nil
    var onOpenEditor: (() -> Void)? = nil
    var onMoveUp: (() -> Void)? = nil
    var onMoveDown: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: loadError != nil ? "exclamationmark.triangle.fill" : icon)
                .font(.body.weight(.medium))
                .foregroundStyle(loadError != nil ? AnyShapeStyle(Color.signalWarm)
                                 : (enabled ? AnyShapeStyle(.loopbacker) : AnyShapeStyle(.secondary)))
                .frame(width: 22)

            Text(name)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(enabled ? .primary : .secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if let activity, enabled, loadError == nil {
                Circle()
                    .fill(Color.loopbacker.opacity(0.35 + Double(activity) * 0.65))
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }

            Button(action: toggle) {
                Image(systemName: "power")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(enabled ? AnyShapeStyle(.loopbacker) : AnyShapeStyle(.tertiary))
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.borderless)
            .help(enabled ? "Bypass \(name)" : "Enable \(name)")
            .accessibilityLabel(enabled ? "Bypass \(name)" : "Enable \(name)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 40)
        .contentShape(.rect(cornerRadius: Metrics.innerRadius))
        .glassPanel(cornerRadius: Metrics.innerRadius,
                    tint: isSelected ? Color.loopbacker.opacity(0.35) : (enabled ? Color.loopbacker.opacity(0.10) : nil),
                    interactive: true)
        .glassEffectID(name, in: namespace)
        .onTapGesture { select() }
        .contextMenu {
            Button(action: toggle) {
                Label(enabled ? "Bypass \(name)" : "Enable \(name)", systemImage: "power")
            }
            if let onMoveUp {
                Button(action: onMoveUp) { Label("Move Up", systemImage: "arrow.up") }
            }
            if let onMoveDown {
                Button(action: onMoveDown) { Label("Move Down", systemImage: "arrow.down") }
            }
            if let onDuplicate {
                Button(action: onDuplicate) { Label("Duplicate", systemImage: "plus.square.on.square") }
            }
            if isHosted, let onOpenEditor {
                Button(action: onOpenEditor) { Label("Open Plugin Window", systemImage: "macwindow") }
            }
            if let onReset {
                Button(action: onReset) { Label("Reset", systemImage: "arrow.counterclockwise") }
            }
            if let onRemove {
                Divider()
                Button(role: .destructive, action: onRemove) { Label("Remove", systemImage: "trash") }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
        .accessibilityValue(loadError != nil ? "Failed to load: \(loadError!)" : (enabled ? "Active" : "Bypassed"))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { select() }
        .accessibilityAction(named: "Move Up") { onMoveUp?() }
        .accessibilityAction(named: "Move Down") { onMoveDown?() }
    }
}

// MARK: - Terminal (Input / Output)

struct ChainTerminalTile: View {
    let label: String
    let icon: String
    var namespace: Namespace.ID

    var body: some View {
        Label(label, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassMaterial(Capsule())
            .glassEffectID(label, in: namespace)
            .accessibilityElement(children: .combine)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Signal line connector

/// Vertical line between two chain slots, aligned with the slot icons. Lit only while the
/// signal actually passes (chain enabled, both neighbors active); a dot travels down it unless
/// Reduce Motion is on.
struct SignalLineConnector: View {
    var active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.snapshotRendering) private var snapshotRendering

    private let length: CGFloat = 12

    var body: some View {
        ZStack(alignment: .top) {
            Capsule()
                .fill(active ? AnyShapeStyle(Color.loopbacker.opacity(0.7)) : AnyShapeStyle(.quaternary))
                .frame(width: active ? 2 : 1.5, height: length)
                .shadow(color: active ? Color.loopbacker.opacity(0.6) : .clear, radius: 3)

            if active && !reduceMotion {
                // `LoopingDot` is an `NSViewRepresentable` driven by `CAAnimation` so the
                // repeating fall animation never re-enters the SwiftUI view graph; that AppKit
                // bridge doesn't render in a headless offscreen snapshot, so snapshot captures
                // fall back to a plain static dot that still conveys "signal is flowing" without
                // the animation.
                if snapshotRendering {
                    Circle()
                        .fill(Color.loopbacker)
                        .frame(width: 4, height: 4)
                        .offset(y: length / 2 - 2)
                } else {
                    LoopingDot(color: .loopbacker, diameter: 4, loop: .fall)
                }
            }
        }
        .frame(width: 22, height: length)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
        .accessibilityHidden(true)
    }
}

// MARK: - Quick presets row

struct QuickPresetsRow: View {
    struct Preset {
        let name: String
        let apply: () -> Void
    }

    let presets: [Preset]
    @Environment(\.snapshotRendering) private var snapshotRendering

    var body: some View {
        if !presets.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Quick Presets")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                let row = HStack(spacing: 6) {
                    ForEach(presets, id: \.name) { preset in
                        Button(preset.name, action: preset.apply)
                            .buttonStyle(.glass)
                            .tint(nil)
                            .controlSize(.small)
                    }
                }

                // `ScrollView` renders blank offscreen (confirmed repro); the plain row wraps
                // instead of scrolling in render tests, which is fine at the Advanced panel's
                // 760pt width.
                if snapshotRendering {
                    row
                } else {
                    ScrollView(.horizontal, showsIndicators: false) { row }
                }
            }
        }
    }
}

// MARK: - Parameter slider row

/// A real, labeled `Slider` with a monospaced value readout and min/max labels. Replaces the
/// old invisible-slider-under-painted-track hack.
struct ParameterSliderRow: View {
    let label: String
    var description: String = ""
    @Binding var value: Float
    let range: ClosedRange<Float>
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.body.weight(.medium))
                Spacer()
                Text(Self.formatDisplayValue(value, unit: unit))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.loopbacker)
                    .contentTransition(.numericText(value: Double(value)))
            }

            if !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Slider(value: $value, in: range) {
                Text(label)
            } minimumValueLabel: {
                Text(Self.formatDisplayValue(range.lowerBound, unit: unit))
            } maximumValueLabel: {
                Text(Self.formatDisplayValue(range.upperBound, unit: unit))
            }
            .labelsHidden()
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .tint(.loopbacker)
            .padding(.top, 2)
            .accessibilityValue(Self.formatDisplayValue(value, unit: unit))
        }
        .padding(.vertical, 6)
    }

    static func formatDisplayValue(_ v: Float, unit: String) -> String {
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
}

// MARK: - EQ band row (type / frequency / gain / Q)

struct EQBandRow: View {
    @EnvironmentObject var routingState: RoutingState
    let nodeID: UUID
    let band: EQBandConfig
    /// Hidden when there's only one band left: the chain always needs at least one EQ band.
    var canRemove: Bool = true
    var onRemove: (() -> Void)? = nil

    private func bandBinding<T>(_ keyPath: WritableKeyPath<EQBandConfig, T>) -> Binding<T> {
        Binding(
            get: { band[keyPath: keyPath] },
            set: { newValue in
                guard let nodeIdx = routingState.effectsPreset.nodes.firstIndex(where: { $0.id == nodeID }),
                      var bands = routingState.effectsPreset.nodes[nodeIdx].eqBands,
                      let bandIdx = bands.firstIndex(where: { $0.id == band.id }) else { return }
                bands[bandIdx][keyPath: keyPath] = newValue
                routingState.effectsPreset.nodes[nodeIdx].eqBands = bands
                routingState.save()
            }
        )
    }

    private var hasGain: Bool { band.type != .highpass && band.type != .lowpass }

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: bandBinding(\.enabled)) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("\(Self.bandTypeLabel(band.type)) band enabled")

            Menu {
                ForEach(EQBandConfig.BandType.allCases, id: \.self) { type in
                    Button(Self.bandTypeLabel(type)) { bandBinding(\.type).wrappedValue = type }
                }
            } label: {
                Text(Self.bandTypeLabel(band.type))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.loopbacker)
                    .frame(width: 30)
                    .padding(.vertical, 3)
                    .background(Color.loopbacker.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Band type, currently \(Self.bandTypeLabel(band.type))")

            VStack(alignment: .leading, spacing: 1) {
                Text("Freq")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(Self.formatFrequency(band.frequencyHz))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
            }
            .frame(width: 54, alignment: .leading)

            if hasGain {
                Slider(value: bandBinding(\.gainDB), in: -12...12) {
                    Text("Gain")
                }
                .tint(.loopbacker)
                .accessibilityLabel("\(Self.bandTypeLabel(band.type)) band at \(Self.formatFrequency(band.frequencyHz)) gain")

                Text(String(format: "%+.1f dB", band.gainDB))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)

                Text("Q \(String(format: "%.2f", band.q))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            } else {
                Picker("Slope", selection: bandBinding(\.slopeDBPerOctave)) {
                    Text("12 dB/oct").tag(12)
                    Text("24 dB/oct").tag(24)
                    Text("48 dB/oct").tag(48)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .font(.caption)
                Spacer()
            }

            if canRemove, let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove this band")
                .accessibilityLabel("Remove \(Self.bandTypeLabel(band.type)) band")
            }
        }
        .opacity(band.enabled ? 1 : 0.5)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Metrics.innerRadius - 4))
    }

    static func bandTypeLabel(_ type: EQBandConfig.BandType) -> String {
        switch type {
        case .highpass: return "HP"
        case .lowshelf: return "LS"
        case .peaking: return "PK"
        case .highshelf: return "HS"
        case .lowpass: return "LP"
        case .notch: return "NT"
        }
    }

    static func formatFrequency(_ freq: Float) -> String {
        if freq >= 1000 {
            return String(format: "%.1fk", freq / 1000)
        } else {
            return String(format: "%.0f", freq)
        }
    }
}

// MARK: - Save preset popover

struct SavePresetPopover: View {
    @Binding var name: String
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Preset")
                .font(.headline)

            TextField("Preset name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit { if !trimmedEmpty { onSave() } }

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.glass)
                    .tint(nil)
                Spacer()
                Button("Save", action: onSave)
                    .buttonStyle(.glassProminent)
                    .tint(.loopbacker)
                    .disabled(trimmedEmpty)
            }
        }
        .padding(16)
        .frame(width: 252)
    }

    private var trimmedEmpty: Bool {
        name.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
