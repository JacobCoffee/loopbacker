import SwiftUI
import AVFoundation

/// Editor sheet for one soundboard pad: waveform trim, fades, play mode, choke group,
/// retrigger behavior, output target, and the measured loudness-match offset.
struct SoundPadEditorView: View {
    @Binding var item: SoundboardItem
    let onClose: () -> Void
    let onRemeasure: () -> Void

    @State private var peaks: [Float] = []
    @State private var duration: Double = 0
    @State private var isLoadingWaveform = true

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.panelSpacing) {
            header

            if isLoadingWaveform {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else if duration > 0 {
                WaveformTrimView(
                    peaks: peaks,
                    duration: duration,
                    trimStart: $item.trimStart,
                    trimEnd: trimEndBinding,
                    fadeInSeconds: $item.fadeInSeconds,
                    fadeOutSeconds: $item.fadeOutSeconds
                )
                .frame(height: 90)
                trimReadout
            } else {
                Text("Couldn't load this file's audio")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
            }

            Divider()

            playbackSection
            Divider()
            loudnessSection
        }
        .padding(Metrics.panelPadding)
        .frame(width: 420)
        .task { await loadWaveform() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(item.emoji.isEmpty ? item.name : "\(item.emoji) \(item.name)")
                .font(.headline)
            Spacer()
            Button("Done", action: onClose)
                .buttonStyle(.glassProminent)
                .tint(.loopbacker)
        }
    }

    // MARK: - Trim readout

    private var trimEndBinding: Binding<Double> {
        Binding(
            get: { item.trimEnd ?? duration },
            set: { item.trimEnd = $0 >= duration - 0.01 ? nil : $0 }
        )
    }

    private var trimReadout: some View {
        HStack {
            Text("Trim \(Self.formatSeconds(item.trimStart))–\(Self.formatSeconds(item.trimEnd ?? duration))")
            Spacer()
            Text("Fade \(Self.formatSeconds(item.fadeInSeconds)) in / \(Self.formatSeconds(item.fadeOutSeconds)) out")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        String(format: "%.2fs", seconds)
    }

    // MARK: - Playback section

    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Play mode", selection: $item.playMode) {
                ForEach(SoundboardPlayMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            Picker("Retrigger", selection: $item.retrigger) {
                ForEach(SoundboardRetrigger.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .help("What a second trigger does while this pad is already playing")

            Picker("Output", selection: $item.outputTarget) {
                ForEach(SoundboardOutputTarget.allCases) { target in
                    Text(target.displayName).tag(target)
                }
            }

            HStack {
                Text("Choke group")
                TextField("None", text: chokeGroupBinding)
                    .textFieldStyle(.roundedBorder)
            }
            .help("Pads sharing a choke group stop each other when one starts")

            HStack {
                Text("Volume")
                Slider(value: $item.volume, in: 0...1.5)
                Text("\(Int(item.volume * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .pickerStyle(.menu)
    }

    private var chokeGroupBinding: Binding<String> {
        Binding(
            get: { item.chokeGroup ?? "" },
            set: { item.chokeGroup = $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: - Loudness section

    private var loudnessSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Loudness match")
                    .font(.caption.weight(.semibold))
                if let offset = item.loudnessGainOffsetDB {
                    Text("\(offset >= 0 ? "+" : "")\(String(format: "%.1f", offset)) dB to reach \(Int(SoundboardItem.loudnessMatchTargetLUFS)) LUFS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not measured yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Re-measure") {
                item.loudnessGainOffsetDB = nil
                onRemeasure()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Clears the stored gain offset; it's re-measured in the background")
        }
    }

    // MARK: - Waveform loading

    private func loadWaveform() async {
        guard let url = item.resolveURL() else {
            isLoadingWaveform = false
            return
        }
        let result = await SoundboardWaveform.load(url: url, bucketCount: 240)
        peaks = result?.peaks ?? []
        duration = result?.duration ?? 0
        isLoadingWaveform = false
    }
}

// MARK: - Waveform data

/// Downsampled per-bucket peak amplitudes for display, computed off the main thread.
enum SoundboardWaveform {
    struct Result {
        let peaks: [Float]
        let duration: Double
    }

    static func load(url: URL, bucketCount: Int) async -> Result? {
        await Task.detached(priority: .utility) {
            guard let file = try? AVAudioFile(forReading: url) else { return nil }
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
            else { return nil }
            guard (try? file.read(into: buffer)) != nil, let channelData = buffer.floatChannelData else { return nil }

            let channels = Int(format.channelCount)
            let frames = Int(buffer.frameLength)
            guard channels > 0, frames > 0 else { return nil }

            let bucketSize = max(1, frames / bucketCount)
            var peaks = [Float](repeating: 0, count: (frames + bucketSize - 1) / bucketSize)
            for bucket in peaks.indices {
                var peak: Float = 0
                let start = bucket * bucketSize
                let end = min(start + bucketSize, frames)
                for ch in 0..<channels {
                    let data = channelData[ch]
                    for i in start..<end {
                        let s = abs(data[i])
                        if s > peak { peak = s }
                    }
                }
                peaks[bucket] = peak
            }
            let duration = Double(frames) / format.sampleRate
            return Result(peaks: peaks, duration: duration)
        }.value
    }
}

// MARK: - Waveform + trim handles view

/// A bar-chart waveform with draggable trim-start/trim-end handles and shaded fade regions.
struct WaveformTrimView: View {
    let peaks: [Float]
    let duration: Double
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    @Binding var fadeInSeconds: Double
    @Binding var fadeOutSeconds: Double

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            ZStack(alignment: .leading) {
                waveformBars(width: width, height: height)
                trimmedOverlay(width: width, height: height)
                fadeOverlay(width: width, height: height)
                handle(seconds: $trimStart, width: width, color: .loopbacker)
                handle(seconds: $trimEnd, width: width, color: .loopbacker)
                fadeHandle(seconds: fadeInHandleBinding, width: width)
                fadeHandle(seconds: fadeOutHandleBinding, width: width)
            }
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: Metrics.innerRadius))
        }
    }

    private func x(for seconds: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(seconds / duration) * width
    }

    private func seconds(forX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return max(0, min(duration, Double(x / width) * duration))
    }

    private func waveformBars(width: CGFloat, height: CGFloat) -> some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            let barWidth = size.width / CGFloat(peaks.count)
            for (i, peak) in peaks.enumerated() {
                let barHeight = max(1, CGFloat(peak) * size.height)
                let rect = CGRect(
                    x: CGFloat(i) * barWidth, y: (size.height - barHeight) / 2,
                    width: max(1, barWidth - 0.5), height: barHeight
                )
                context.fill(Path(rect), with: .color(.secondary.opacity(0.6)))
            }
        }
        .frame(width: width, height: height)
    }

    /// Dims the trimmed-away regions outside [trimStart, trimEnd].
    private func trimmedOverlay(width: CGFloat, height: CGFloat) -> some View {
        let startX = x(for: trimStart, width: width)
        let endX = x(for: trimEnd, width: width)
        return ZStack(alignment: .leading) {
            Rectangle().fill(.black.opacity(0.35)).frame(width: max(0, startX))
            Rectangle().fill(.black.opacity(0.35))
                .frame(width: max(0, width - endX))
                .offset(x: endX)
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }

    /// Shades the fade-in/fade-out ramps within the trim window: darkest at the trim edge,
    /// clear by the time the fade ends.
    private func fadeOverlay(width: CGFloat, height: CGFloat) -> some View {
        let fadeInStartX = x(for: trimStart, width: width)
        let fadeInEndX = x(for: trimStart + fadeInSeconds, width: width)
        let fadeOutStartX = x(for: trimEnd - fadeOutSeconds, width: width)
        let fadeOutEndX = x(for: trimEnd, width: width)
        return ZStack(alignment: .leading) {
            if fadeInSeconds > 0 {
                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: max(0, fadeInEndX - fadeInStartX), height: height)
                    .offset(x: fadeInStartX)
            }
            if fadeOutSeconds > 0 {
                LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: max(0, fadeOutEndX - fadeOutStartX), height: height)
                    .offset(x: fadeOutStartX)
            }
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }

    private func handle(seconds: Binding<Double>, width: CGFloat, color: Color) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: 3, height: 90)
            .offset(x: x(for: seconds.wrappedValue, width: width) - 1.5)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        seconds.wrappedValue = self.seconds(forX: value.location.x, width: width)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Trim handle")
            .accessibilityValue(Self.formatSeconds(seconds.wrappedValue))
    }

    /// A small draggable knob near the top of the waveform marking where a fade ends -- distinct
    /// from the full-height trim handles below it.
    private func fadeHandle(seconds: Binding<Double>, width: CGFloat) -> some View {
        Circle()
            .fill(Color.orange)
            .frame(width: 10, height: 10)
            .offset(x: x(for: seconds.wrappedValue, width: width) - 5, y: -40)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        seconds.wrappedValue = self.seconds(forX: value.location.x, width: width)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Fade handle")
            .accessibilityValue(Self.formatSeconds(seconds.wrappedValue))
    }

    /// Position (in seconds from the top of the file) of the fade-in handle: where the fade-in
    /// ramp ends, `fadeInSeconds` after `trimStart`. Dragging it sets `fadeInSeconds`, clamped to
    /// the active trim window.
    private var fadeInHandleBinding: Binding<Double> {
        Binding(
            get: { trimStart + fadeInSeconds },
            set: { fadeInSeconds = Self.fadeInSeconds(forHandleSeconds: $0, trimStart: trimStart, trimEnd: trimEnd) }
        )
    }

    /// Position of the fade-out handle: where the fade-out ramp begins, `fadeOutSeconds` before
    /// `trimEnd`. Dragging it sets `fadeOutSeconds`, clamped to the active trim window.
    private var fadeOutHandleBinding: Binding<Double> {
        Binding(
            get: { trimEnd - fadeOutSeconds },
            set: { fadeOutSeconds = Self.fadeOutSeconds(forHandleSeconds: $0, trimStart: trimStart, trimEnd: trimEnd) }
        )
    }

    /// Converts a fade-in handle's x-mapped seconds position into a `fadeInSeconds` duration,
    /// clamped so the handle can't be dragged outside `[trimStart, trimEnd]`. `nonisolated`: a
    /// pure computation that doesn't touch any `@MainActor`-isolated state (unlike `View`
    /// conformance would otherwise imply), so it's callable from a plain test context.
    nonisolated static func fadeInSeconds(forHandleSeconds seconds: Double, trimStart: Double, trimEnd: Double) -> Double {
        max(trimStart, min(trimEnd, seconds)) - trimStart
    }

    /// Converts a fade-out handle's x-mapped seconds position into a `fadeOutSeconds` duration,
    /// clamped so the handle can't be dragged outside `[trimStart, trimEnd]`. `nonisolated` for
    /// the same reason as `fadeInSeconds(forHandleSeconds:...)` above.
    nonisolated static func fadeOutSeconds(forHandleSeconds seconds: Double, trimStart: Double, trimEnd: Double) -> Double {
        trimEnd - max(trimStart, min(trimEnd, seconds))
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        String(format: "%.2f seconds", seconds)
    }
}
