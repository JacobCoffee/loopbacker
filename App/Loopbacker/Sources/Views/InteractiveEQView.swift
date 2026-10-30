import SwiftUI

// MARK: - Interactive EQ Visualization (draggable band dots)

/// Draggable parametric-EQ curve. Horizontal drag remaps frequency (log scale, 20 Hz...20 kHz),
/// vertical drag remaps gain (±12 dB, skipped for highpass/lowpass bands, which only have a
/// corner frequency and a slope). Writes directly into the EQ node's `eqBands` (identified by
/// `nodeID`) and saves when a drag ends. Double-click adds a peaking band at the tapped
/// frequency/gain (up to 16 bands); disabled bands still draw, dimmed, so you can re-enable them.
struct InteractiveEQView: View {
    @EnvironmentObject var routingState: RoutingState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let nodeID: UUID
    @State private var draggingBandID: Int? = nil
    @State private var dragLabel: String = ""
    @State private var dragLabelPosition: CGPoint = .zero

    static let maxBands = 16

    private var bands: [EQBandConfig] {
        routingState.effectsPreset.nodes.first(where: { $0.id == nodeID })?.eqBands ?? []
    }

    private func updateBand(_ bandID: Int, _ mutate: (inout EQBandConfig) -> Void) {
        guard let nodeIdx = routingState.effectsPreset.nodes.firstIndex(where: { $0.id == nodeID }),
              var bands = routingState.effectsPreset.nodes[nodeIdx].eqBands,
              let bandIdx = bands.firstIndex(where: { $0.id == bandID }) else { return }
        mutate(&bands[bandIdx])
        routingState.effectsPreset.nodes[nodeIdx].eqBands = bands
    }

    /// Adds a peaking band at the given normalized position, if under the 16-band cap.
    func addBand(atFreq freq: Float, gainDB: Float) {
        guard let nodeIdx = routingState.effectsPreset.nodes.firstIndex(where: { $0.id == nodeID }),
              var bands = routingState.effectsPreset.nodes[nodeIdx].eqBands,
              bands.count < Self.maxBands else { return }
        let nextID = (bands.map(\.id).max() ?? -1) + 1
        bands.append(EQBandConfig(id: nextID, type: .peaking, frequencyHz: freq, gainDB: gainDB, q: 1.0))
        routingState.effectsPreset.nodes[nodeIdx].eqBands = bands
        routingState.save()
    }

    func removeBand(_ bandID: Int) {
        guard let nodeIdx = routingState.effectsPreset.nodes.firstIndex(where: { $0.id == nodeID }),
              var bands = routingState.effectsPreset.nodes[nodeIdx].eqBands, bands.count > 1 else { return }
        bands.removeAll { $0.id == bandID }
        routingState.effectsPreset.nodes[nodeIdx].eqBands = bands
        routingState.save()
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

    /// Whether a band type carries a gain (peaking/shelf/notch) vs. just a corner frequency
    /// and slope (high/low pass).
    private func hasGain(_ type: EQBandConfig.BandType) -> Bool {
        type != .highpass && type != .lowpass
    }

    /// Compute the total EQ gain at a given frequency. High/low pass contribute a rolloff
    /// approximation (their slope, past the corner) rather than a bell.
    private func totalGain(at freq: Float) -> Float {
        var total: Float = 0
        for band in bands where band.enabled {
            switch band.type {
            case .highpass:
                if freq < band.frequencyHz {
                    let octaves = log2(band.frequencyHz / max(freq, 1))
                    total -= octaves * Float(band.slopeDBPerOctave)
                }
            case .lowpass:
                if freq > band.frequencyHz {
                    let octaves = log2(freq / band.frequencyHz)
                    total -= octaves * Float(band.slopeDBPerOctave)
                }
            case .notch:
                let dist = log2(freq / band.frequencyHz)
                total -= 18 * exp(-dist * dist * band.q * 8)
            default:
                let dist = log2(freq / band.frequencyHz)
                total += band.gainDB * exp(-dist * dist * band.q * 2)
            }
        }
        return max(-30, min(18, total))
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
                ForEach(bands) { band in
                    let normX = logNormalize(band.frequencyHz, min: 20, max: 20000)
                    let x = CGFloat(normX) * size.width
                    let yNorm = hasGain(band.type)
                        ? CGFloat(0.5 - band.gainDB / (maxGain * 2))
                        : 0.5
                    let y = yNorm * size.height
                    let isDragging = draggingBandID == band.id
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
                                .fill(band.enabled ? Color.loopbacker : Color.secondary)
                                .opacity(band.enabled ? 1 : 0.5)
                                .frame(width: radius * 0.9, height: radius * 0.9)
                        )
                        .shadow(color: isDragging ? Color.loopbacker.opacity(0.5) : .clear, radius: isDragging ? 8 : 0)
                        .opacity(band.enabled ? 1 : 0.5)
                        .position(x: x, y: y)
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { value in
                                    withAnimation(.interactiveSpring()) {
                                        draggingBandID = band.id
                                    }

                                    // Horizontal -> frequency (log scale)
                                    let clampedX = Swift.max(0, Swift.min(Float(value.location.x / size.width), 1))
                                    let newFreq = logDenormalize(clampedX, min: 20, max: 20000)
                                    var newGainValue: Float?
                                    if hasGain(band.type) {
                                        let clampedY = Swift.max(0, Swift.min(Float(value.location.y / size.height), 1))
                                        let newGain = (0.5 - clampedY) * maxGain * 2
                                        newGainValue = Swift.max(-12, Swift.min(12, newGain))
                                    }
                                    updateBand(band.id) { b in
                                        b.frequencyHz = newFreq
                                        if let newGainValue { b.gainDB = newGainValue }
                                    }

                                    // Update label
                                    let freqStr = newFreq >= 1000
                                        ? String(format: "%.1fkHz", newFreq / 1000)
                                        : String(format: "%.0fHz", newFreq)
                                    let gainStr = hasGain(band.type) ? String(format: "%+.1fdB", newGainValue ?? band.gainDB) : ""
                                    dragLabel = "\(freqStr) \(gainStr)"
                                    dragLabelPosition = CGPoint(
                                        x: Swift.max(40, Swift.min(Double(size.width) - 40, Double(value.location.x))),
                                        y: Swift.max(16, Double(value.location.y) - 20)
                                    )
                                }
                                .onEnded { _ in
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        draggingBandID = nil
                                    }
                                    routingState.save()
                                }
                        )
                        .onTapGesture(count: 2) {
                            removeBand(band.id)
                        }
                        .accessibilityElement()
                        .accessibilityLabel("\(bandTypeLabel(band.type)) band at \(band.frequencyHz >= 1000 ? String(format: "%.1f kilohertz", band.frequencyHz / 1000) : String(format: "%.0f hertz", band.frequencyHz))")
                        .accessibilityValue(hasGain(band.type) ? String(format: "%+.1f dB", band.gainDB) : "No gain, slope only")
                        .accessibilityAdjustableAction { direction in
                            guard hasGain(band.type) else { return }
                            let step: Float = 0.5
                            let delta: Float = direction == .increment ? step : -step
                            let newGain = Swift.max(-12, Swift.min(12, band.gainDB + delta))
                            updateBand(band.id) { $0.gainDB = newGain }
                            routingState.save()
                        }
                }

                // Drag tooltip
                if draggingBandID != nil {
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
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { location in
                guard bands.count < Self.maxBands else { return }
                let normX = Swift.max(0, Swift.min(Float(location.x / size.width), 1))
                let freq = logDenormalize(normX, min: 20, max: 20000)
                let normY = Swift.max(0, Swift.min(Float(location.y / size.height), 1))
                let gain = (0.5 - normY) * maxGain * 2
                addBand(atFreq: freq, gainDB: Swift.max(-12, Swift.min(12, gain)))
            }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.innerRadius - 4))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.innerRadius - 4)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            )
            .accessibilityElement(children: .contain)
            .help("Drag a band to adjust it; double-click to add a band, double-click a band to remove it")
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

private extension View {
    /// `.onTapGesture(count:perform:)` doesn't hand back a location; this wraps a
    /// `SpatialTapGesture` so the EQ canvas's double-click-to-add can read where the tap landed.
    func onTapGesture(count: Int, perform action: @escaping (CGPoint) -> Void) -> some View {
        gesture(
            SpatialTapGesture(count: count)
                .onEnded { value in action(value.location) }
        )
    }
}
