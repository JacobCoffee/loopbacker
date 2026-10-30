import SwiftUI

// MARK: - Interactive EQ Visualization (draggable band dots)

/// Draggable parametric-EQ curve. Horizontal drag remaps frequency (log scale, 20 Hz...20 kHz),
/// vertical drag remaps gain (±12 dB, skipped for the highpass band). Writes directly into
/// `routingState.effectsPreset.eqBands` and saves when a drag ends.
struct InteractiveEQView: View {
    @EnvironmentObject var routingState: RoutingState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

    private func bandTypeLabel(_ type: EQBandConfig.BandType) -> String {
        switch type {
        case .highpass: return "High Pass"
        case .lowshelf: return "Low Shelf"
        case .peaking: return "Peaking"
        case .highshelf: return "High Shelf"
        case .lowpass: return "Low Pass"
        case .notch: return "Notch"
        }
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let maxGain: Float = 14

            ZStack {
                RoundedRectangle(cornerRadius: Metrics.innerRadius - 4)
                    .fill(.quaternary.opacity(0.4))

                // Zero line
                Path { path in
                    let zeroY = size.height / 2
                    path.move(to: CGPoint(x: 0, y: zeroY))
                    path.addLine(to: CGPoint(x: size.width, y: zeroY))
                }
                .stroke(.tertiary, lineWidth: 0.5)

                // dB grid lines (-6, +6)
                ForEach([-6, 6], id: \.self) { db in
                    let yNorm = CGFloat(0.5 - Float(db) / (maxGain * 2))
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: yNorm * size.height))
                        path.addLine(to: CGPoint(x: size.width, y: yNorm * size.height))
                    }
                    .stroke(.quaternary, lineWidth: 0.5)
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
                    .stroke(.quaternary, lineWidth: 0.5)
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
                        .fill(.background)
                        .frame(width: radius * 2, height: radius * 2)
                        .overlay(
                            Circle()
                                .strokeBorder(isDragging ? Color.loopbacker : Color.secondary.opacity(0.4),
                                              lineWidth: isDragging ? 1.5 : 1)
                        )
                        .overlay(
                            Circle()
                                .fill(Color.loopbacker)
                                .frame(width: radius * 0.9, height: radius * 0.9)
                        )
                        .shadow(color: isDragging ? Color.loopbacker.opacity(0.5) : .clear, radius: isDragging ? 8 : 0)
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
                        .accessibilityElement()
                        .accessibilityLabel("\(bandTypeLabel(band.type)) band at \(band.frequencyHz >= 1000 ? String(format: "%.1f kilohertz", band.frequencyHz / 1000) : String(format: "%.0f hertz", band.frequencyHz))")
                        .accessibilityValue(band.id == 0 ? "High pass, no gain" : String(format: "%+.1f dB", band.gainDB))
                        .accessibilityAdjustableAction { direction in
                            guard band.id != 0 else { return }
                            let step: Float = 0.5
                            let delta: Float = direction == .increment ? step : -step
                            let newGain = Swift.max(-12, Swift.min(12, band.gainDB + delta))
                            routingState.effectsPreset.eqBands[index].gainDB = newGain
                            routingState.save()
                        }
                }

                // Drag tooltip
                if draggingIndex != nil {
                    Text(dragLabel)
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.loopbacker.opacity(0.4), lineWidth: 0.5)
                        )
                        .shadow(radius: 4, y: 2)
                        .position(dragLabelPosition)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.innerRadius - 4))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.innerRadius - 4)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
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

        fillPath.fill(Color.loopbacker.opacity(0.12))
        curvePath.stroke(Color.loopbacker, lineWidth: 1.5)
    }
}
