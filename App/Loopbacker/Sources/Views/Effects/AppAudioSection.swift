import SwiftUI

/// Ducking and leveling for app-capture routes (game, music, browser), separate from the voice
/// chain. A live duck-gain meter shows how far app audio is currently pulled down.
struct AppAudioSection: View {
    @EnvironmentObject var routingState: RoutingState

    private var appAudio: AppAudioFX { routingState.effectsPreset.appAudio }

    private func binding<T>(_ keyPath: WritableKeyPath<AppAudioFX, T>) -> Binding<T> {
        Binding(
            get: { routingState.effectsPreset.appAudio[keyPath: keyPath] },
            set: { routingState.effectsPreset.appAudio[keyPath: keyPath] = $0; routingState.save() }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.panelSpacing) {
            Text("App Audio").font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.to.line.compact")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(appAudio.duckingEnabled ? Color.loopbacker : Color.secondary)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Ducking").font(.headline)
                        Text("Pulls game/music/browser audio down while you're talking.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(isOn: binding(\.duckingEnabled)) {
                        Text(appAudio.duckingEnabled ? "On" : "Off").font(.caption.weight(.semibold))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(.loopbacker)
                }

                if appAudio.duckingEnabled {
                    duckGainMeter
                    ParameterSliderRow(label: "Amount", description: "How far app audio is pulled down while you speak",
                                       value: binding(\.duckAmountDB), range: AppAudioFX.duckAmountRange, unit: "dB")
                    ParameterSliderRow(label: "Attack", description: "How fast ducking kicks in",
                                       value: binding(\.duckAttackMs), range: 5...500, unit: "ms")
                    ParameterSliderRow(label: "Release", description: "How fast app audio returns after you stop talking",
                                       value: binding(\.duckReleaseMs), range: 50...2000, unit: "ms")
                }
            }
            .padding(Metrics.panelPadding)
            .glassPanel(cornerRadius: Metrics.panelRadius, tint: appAudio.duckingEnabled ? Color.loopbacker.opacity(0.08) : nil)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "chart.bar.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(appAudio.levelerEnabled ? Color.loopbacker : Color.secondary)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("App Leveler").font(.headline)
                        Text("Holds app audio at a consistent loudness.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(isOn: binding(\.levelerEnabled)) {
                        Text(appAudio.levelerEnabled ? "On" : "Off").font(.caption.weight(.semibold))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(.loopbacker)
                }

                if appAudio.levelerEnabled {
                    ParameterSliderRow(label: "Target", description: "Loudness to hold app audio at",
                                       value: binding(\.levelerTarget), range: -30 ... -10, unit: "LUFS")
                }
            }
            .padding(Metrics.panelPadding)
            .glassPanel(cornerRadius: Metrics.panelRadius, tint: appAudio.levelerEnabled ? Color.loopbacker.opacity(0.08) : nil)
        }
    }

    /// Live duck-gain meter driven by `AppAudioDuckBus`, the actual gain `AppAudioProcessor`
    /// applied on its IO thread (not inferred from app-signal presence: silent app audio or a
    /// release still in progress both show the real current reduction).
    private var duckGainMeter: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { _ in
            let duckGainDB = min(0, fxLinearToDB(AppAudioDuckBus.gain()))
            let lowerBound = AppAudioFX.duckAmountRange.lowerBound
            let fraction = lowerBound == 0 ? 0 : min(max(duckGainDB / lowerBound, 0), 1)

            HStack(spacing: 10) {
                Text("Duck Gain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                GeometryReader { geo in
                    ZStack(alignment: .trailing) {
                        RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.5))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.loopbacker.opacity(0.65))
                            .frame(width: max(2, CGFloat(fraction) * geo.size.width))
                            .animation(.linear(duration: 0.15), value: duckGainDB)
                    }
                }
                .frame(height: 10)
                Text(String(format: "%.1f dB", duckGainDB))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Current duck gain, \(String(format: "%.1f", duckGainDB)) dB")
        }
    }
}
