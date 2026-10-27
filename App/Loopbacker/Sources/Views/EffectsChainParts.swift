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

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(enabled ? AnyShapeStyle(.loopbacker) : AnyShapeStyle(.secondary))
                .frame(width: 22)

            Text(name)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(enabled ? .primary : .secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

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
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
        .accessibilityValue(enabled ? "Active" : "Bypassed")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { select() }
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
            .glassEffect(.regular, in: .capsule)
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

    @State private var travel = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let length: CGFloat = 12

    var body: some View {
        ZStack(alignment: .top) {
            Capsule()
                .fill(active ? AnyShapeStyle(Color.loopbacker.opacity(0.7)) : AnyShapeStyle(.quaternary))
                .frame(width: active ? 2 : 1.5, height: length)
                .shadow(color: active ? Color.loopbacker.opacity(0.6) : .clear, radius: 3)

            if active && !reduceMotion {
                Circle()
                    .fill(Color.loopbacker)
                    .frame(width: 4, height: 4)
                    .offset(y: travel ? length - 2 : -2)
                    .opacity(travel ? 0 : 1)
            }
        }
        .frame(width: 22, height: length)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
        .onAppear { startTravel() }
        .onChange(of: active) { _, _ in startTravel() }
        .onChange(of: reduceMotion) { _, _ in startTravel() }
        .accessibilityHidden(true)
    }

    private func startTravel() {
        travel = false
        guard active, !reduceMotion else { return }
        withAnimation(.easeIn(duration: 0.6).repeatForever(autoreverses: false)) {
            travel = true
        }
    }
}

// MARK: - Quick presets row

struct QuickPresetsRow: View {
    struct Preset {
        let name: String
        let apply: () -> Void
    }

    let presets: [Preset]

    var body: some View {
        if !presets.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Quick Presets")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(presets, id: \.name) { preset in
                            Button(preset.name, action: preset.apply)
                                .buttonStyle(.glass)
                                .tint(nil)
                                .controlSize(.small)
                        }
                    }
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
    let band: EQBandConfig
    let index: Int

    var body: some View {
        HStack(spacing: 12) {
            Text(Self.bandTypeLabel(band.type))
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.loopbacker)
                .frame(width: 30)
                .padding(.vertical, 3)
                .background(Color.loopbacker.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 1) {
                Text("Freq")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(Self.formatFrequency(band.frequencyHz))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
            }
            .frame(width: 54, alignment: .leading)

            if band.type != .highpass {
                Slider(
                    value: Binding(
                        get: { routingState.effectsPreset.eqBands[index].gainDB },
                        set: {
                            routingState.effectsPreset.eqBands[index].gainDB = $0
                            routingState.save()
                        }
                    ),
                    in: -12...12
                ) {
                    Text("Gain")
                }
                .tint(.loopbacker)
                .accessibilityLabel("\(Self.bandTypeLabel(band.type)) band at \(Self.formatFrequency(band.frequencyHz)) gain")

                Text(String(format: "%+.1f dB", band.gainDB))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            } else {
                Text("High Pass Filter")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Text("Q \(String(format: "%.2f", band.q))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
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
