import SwiftUI

/// Chooses the noise suppression engine. Collapsed, it's one line naming the engine and its
/// cost; expanded, one row per engine with latency, CPU measured on this Mac, and what it
/// cleans up, plus a recommendation for this Mac. Picking an engine collapses it again.
struct NoiseEnginePicker: View {
    @Binding var selection: NoiseSuppressionEngine
    /// Suppression is on: the selected row lights up.
    var isActive: Bool

    @ObservedObject private var benchmark = NoiseEngineBenchmark.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isComparing = false

    /// Rows are buttons, so the numeric columns use fixed widths rather than a `Grid`.
    private enum Column {
        static let latency: CGFloat = 60
        static let cpu: CGFloat = 84
        static let cleanup: CGFloat = 76
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            summary

            if isComparing {
                comparison
                    .transition(.opacity)
            }
        }
        .onAppear { benchmark.measureIfNeeded() }
    }

    private var summary: some View {
        let profile = NoiseEngineProfile.of(selection)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Engine")
                .foregroundStyle(.secondary)
            Text(profile.name)
                .fontWeight(.semibold)
            if benchmark.recommended == selection {
                StatusTag(title: "Recommended", symbol: "checkmark.seal.fill")
            }
            let cpu = benchmark.coreLoad[selection] == nil ? "" : " · \(cpuText(selection)) CPU"
            Text("\(profile.latencyMs) ms\(cpu) · \(profile.cleanup) cleanup")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { isComparing.toggle() }
            } label: {
                Label(isComparing ? "Hide Engines" : "Compare Engines",
                      systemImage: isComparing ? "chevron.up" : "chevron.down")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .help(isComparing ? "Hide the engine comparison" : "Compare engines and switch")
        }
        .font(.callout)
        .padding(.horizontal, 10)
    }

    private var comparison: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text("Engine")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Latency").frame(width: Column.latency, alignment: .trailing)
                Text("CPU here").frame(width: Column.cpu, alignment: .trailing)
                Text("Cleanup").frame(width: Column.cleanup, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 8)

            ForEach(NoiseSuppressionEngine.allCases) { engine in
                row(NoiseEngineProfile.of(engine))
            }

            Text(recommendationNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.top, 2)
        }
    }

    private func row(_ profile: NoiseEngineProfile) -> some View {
        let selected = selection == profile.engine
        let recommended = benchmark.recommended == profile.engine
        let measured = benchmark.coreLoad[profile.engine] != nil
        return Button {
            selection = profile.engine
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { isComparing = false }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected && isActive ? Color.loopbacker : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(profile.name)
                                .fontWeight(.semibold)
                            if recommended {
                                StatusTag(title: "Recommended", symbol: "checkmark.seal.fill")
                            }
                        }
                        Text(profile.tradeoff)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("\(profile.latencyMs) ms")
                    .monospacedDigit()
                    .frame(width: Column.latency, alignment: .trailing)
                Text(cpuText(profile.engine))
                    .monospacedDigit()
                    .foregroundStyle(measured ? .primary : .secondary)
                    .frame(width: Column.cpu, alignment: .trailing)
                Text(profile.cleanup)
                    .frame(width: Column.cleanup, alignment: .leading)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: Metrics.innerRadius, style: .continuous)
                        .fill(isActive ? Color.loopbacker.opacity(0.12) : Color.secondary.opacity(0.08))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Metrics.innerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(selected ? "\(profile.name) is selected" : "Switch to \(profile.name)")
        .accessibilityLabel("\(profile.name)\(recommended ? ", recommended" : "")")
        .accessibilityValue("\(profile.latencyMs) milliseconds latency, \(cpuText(profile.engine)) CPU, \(profile.cleanup.lowercased()) cleanup. \(profile.tradeoff)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func cpuText(_ engine: NoiseSuppressionEngine) -> String {
        guard let load = benchmark.coreLoad[engine] else {
            return benchmark.isMeasuring ? "Measuring…" : "—"
        }
        let percent = load * 100
        if percent < 1 { return "<1%" }
        return percent < 10 ? String(format: "%.1f%%", percent) : String(format: "%.0f%%", percent)
    }

    private var recommendationNote: String {
        let chip = benchmark.chipName
        let basis = "CPU is the share of one core for one mic."
        guard let load = benchmark.coreLoad[.fastenhancer] else {
            return benchmark.isMeasuring ? "\(basis) Measuring all three engines on \(chip)…" : basis
        }
        let percent = Int((load * 100).rounded())
        switch benchmark.recommended {
        case .rnnoise:
            return "\(basis) FastEnhancer takes \(percent)% on \(chip), too close to the audio deadline, so RNNoise is recommended."
        default:
            return "\(basis) FastEnhancer is recommended: DPDFNet's cleanup at a third of the delay, and \(percent < 1 ? "under 1" : "\(percent)")% on \(chip)."
        }
    }
}
