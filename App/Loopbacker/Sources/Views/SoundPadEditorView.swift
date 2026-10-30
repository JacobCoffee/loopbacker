import SwiftUI
import AVFoundation

/// Editor sheet for one soundboard pad: waveform trim, fades, play mode, choke group,
/// retrigger behavior, output target, and the measured loudness-match offset.
struct SoundPadEditorView: View {
    @Binding var item: SoundboardItem
    let onClose: () -> Void

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
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
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
                handle(seconds: $trimStart, width: width, color: .loopbacker)
                handle(seconds: $trimEnd, width: width, color: .loopbacker)
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

    private static func formatSeconds(_ seconds: Double) -> String {
        String(format: "%.2f seconds", seconds)
    }
}
