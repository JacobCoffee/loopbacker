import SwiftUI

/// LUFS readout + target picker for the virtual mic's loudness meter, shared by the Routing
/// page and the menu bar panel. Text-driven (not Core Animation layers): readings update at
/// most every 100 ms, far below the 30 Hz continuous-bar-meter cost `DesignSystem`'s
/// `LiveSignalMeter` avoids, so ordinary `@Observable`-tracked SwiftUI body re-evaluation is
/// cheap here.
struct LoudnessPanelView: View {
    var deviceUID: String = VirtualDeviceChannels.micUID
    var compact: Bool = false

    @EnvironmentObject var audioRouter: AudioRouter

    private var loudness: LoudnessLevels { audioRouter.loudness }
    private var reading: LoudnessReading { loudness.reading(deviceUID: deviceUID) }
    private var status: LoudnessStatus { loudness.status(deviceUID: deviceUID) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            header
            readoutGrid
            if !compact {
                targetPicker
            }
        }
        .padding(compact ? 8 : Metrics.panelPadding)
        .glassPanel(cornerRadius: Metrics.innerRadius)
    }

    // MARK: - Header: status pill + reset

    private var header: some View {
        HStack {
            Text("Loudness")
                .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
            statusPill
            Spacer()
            Button {
                audioRouter.resetIntegratedLoudness(deviceUID: deviceUID)
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.plain)
            .help("Reset integrated loudness")
            .foregroundStyle(.secondary)
        }
    }

    private var statusPill: some View {
        Text(status.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.2), in: Capsule())
            .foregroundStyle(statusColor)
    }

    private var statusColor: Color {
        switch status {
        case .tooQuiet: .yellow
        case .onTarget: .green
        case .tooLoud: .red
        case .noSignal: .secondary
        }
    }

    // MARK: - Readouts

    private var readoutGrid: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            readout("Momentary", reading.momentaryLUFS)
            readout("Short-term", reading.shortTermLUFS)
            readout("Integrated", reading.integratedLUFS)
            readout("True Peak", reading.truePeakDBTP, unit: "dBTP")
        }
    }

    private func readout(_ label: String, _ value: Float, unit: String = "LUFS") -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(Self.format(value, unit: unit))
                .font(.caption.monospacedDigit())
        }
    }

    private static func format(_ value: Float, unit: String) -> String {
        guard value.isFinite else { return "— \(unit)" }
        return String(format: "%.1f %@", value, unit)
    }

    // MARK: - Target picker

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Target", selection: Binding(
                get: { loudness.target },
                set: { loudness.target = $0 }
            )) {
                ForEach(LoudnessTarget.allCases) { target in
                    Text(target.displayName).tag(target)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            if loudness.target == .custom {
                HStack {
                    Slider(
                        value: Binding(
                            get: { loudness.customTargetLUFS },
                            set: { loudness.customTargetLUFS = $0 }
                        ),
                        in: -36...(-6)
                    )
                    Text("\(Int(loudness.customTargetLUFS)) LUFS")
                        .font(.caption.monospacedDigit())
                        .frame(width: 64, alignment: .trailing)
                }
            }
        }
    }
}
