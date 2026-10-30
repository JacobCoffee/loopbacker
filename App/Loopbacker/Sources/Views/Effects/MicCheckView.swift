import AVFoundation
import SwiftUI

// MARK: - Mic Check
//
// Records 5–10 s via `FXEngine.record`, then lets you play back Raw vs. Processed through the
// default output (the user's own speakers) with an A/B toggle and both waveforms drawn so you
// can see, not just hear, the difference.
struct MicCheckView: View {
    @EnvironmentObject var fxEngine: FXEngine
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case idle
        case recording(secondsLeft: Int)
        case result(FXRecording)
    }

    @State private var phase: Phase = .idle
    @State private var recordSeconds: Double = 7
    @State private var player = MicCheckPlayer()
    @State private var playingProcessed = true
    @State private var isPlaying = false

    init() {}

    /// Drives the view straight to its result screen, for offscreen render tests and previews.
    init(previewResult recording: FXRecording) {
        _phase = State(initialValue: .result(recording))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.panelSpacing) {
            HStack {
                Text("Mic Check").font(.headline)
                Spacer()
                Button("Close") { player.stop(); dismiss() }
                    .buttonStyle(.glass)
                    .tint(nil)
                    .controlSize(.small)
            }

            switch phase {
            case .idle:
                idleContent
            case .recording(let secondsLeft):
                recordingContent(secondsLeft: secondsLeft)
            case .result(let recording):
                resultContent(recording)
            }
        }
        .padding(Metrics.panelPadding)
        .frame(width: 480)
        .onDisappear { player.stop() }
    }

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Say a sentence or two out loud. Loopbacker records \(Int(recordSeconds))s of your mic, raw and through the effects chain, so you can compare them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Slider(value: $recordSeconds, in: 5...10, step: 1) {
                Text("Duration")
            } minimumValueLabel: { Text("5s") } maximumValueLabel: { Text("10s") }
                .tint(.loopbacker)

            Button("Start Recording") { startRecording() }
                .buttonStyle(.glassProminent)
                .tint(.loopbacker)
        }
    }

    private func recordingContent(secondsLeft: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.fill")
                .font(.title2)
                .foregroundStyle(Color.signalHot)
                .symbolEffect(.pulse, isActive: true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording…").font(.body.weight(.semibold))
                Text("\(secondsLeft)s remaining").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private func resultContent(_ recording: FXRecording) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Source", selection: $playingProcessed) {
                Text("Raw").tag(false)
                Text("Processed").tag(true)
            }
            .pickerStyle(.segmented)
            .onChange(of: playingProcessed) { _, newValue in
                if isPlaying { player.play(recording, processed: newValue) }
            }

            WaveformView(samples: playingProcessed ? recording.processed : recording.raw)
                .frame(height: 90)
                .glassPanel(cornerRadius: Metrics.innerRadius)

            HStack {
                Button(isPlaying ? "Stop" : "Play") {
                    if isPlaying {
                        player.stop()
                        isPlaying = false
                    } else {
                        player.play(recording, processed: playingProcessed)
                        isPlaying = true
                    }
                }
                .buttonStyle(.glassProminent)
                .tint(.loopbacker)

                Button("Record Again") {
                    player.stop()
                    isPlaying = false
                    startRecording()
                }
                .buttonStyle(.glass)
                .tint(nil)

                Spacer()
            }
        }
    }

    private func startRecording() {
        let total = Int(recordSeconds)
        phase = .recording(secondsLeft: total)
        Task {
            let countdown = Task { @MainActor in
                for remaining in stride(from: total - 1, through: 0, by: -1) {
                    try? await Task.sleep(for: .seconds(1))
                    if case .recording = phase { phase = .recording(secondsLeft: remaining) }
                }
            }
            let recording = await fxEngine.record(seconds: recordSeconds)
            countdown.cancel()
            await MainActor.run { phase = .result(recording) }
        }
    }
}

// MARK: - Auto Setup

/// Records a measurement clip (reading a short prompt), analyzes it with `AutoSetup.analyze`,
/// and shows findings plus a before/after summary before letting the user apply the tuned chain.
struct AutoSetupView: View {
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var fxEngine: FXEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.snapshotRendering) private var snapshotRendering

    private enum Phase {
        case idle
        case recording(secondsLeft: Int)
        case result(AutoSetupResult)
    }

    @State private var phase: Phase = .idle

    init() {}

    /// Drives the view straight to its result screen, for offscreen render tests and previews.
    init(previewResult result: AutoSetupResult) {
        _phase = State(initialValue: .result(result))
    }

    static let prompt = "The quick brown fox jumps over the lazy dog. Please read this sentence naturally, then pause, then read it again a little louder."

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.panelSpacing) {
            HStack {
                Text("Auto Setup").font(.headline)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.glass)
                    .tint(nil)
                    .controlSize(.small)
            }

            switch phase {
            case .idle: idleContent
            case .recording(let secondsLeft): recordingContent(secondsLeft: secondsLeft)
            case .result(let result): resultContent(result)
            }
        }
        .padding(Metrics.panelPadding)
        .frame(width: 520)
    }

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Read this out loud at your normal speaking level while Loopbacker measures your room and voice:")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("“\(Self.prompt)”")
                .font(.body.italic())
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Metrics.innerRadius - 4))

            Button("Start") { startRecording() }
                .buttonStyle(.glassProminent)
                .tint(.loopbacker)
        }
    }

    private func recordingContent(secondsLeft: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.fill")
                .font(.title2)
                .foregroundStyle(Color.signalHot)
                .symbolEffect(.pulse, isActive: true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Listening…").font(.body.weight(.semibold))
                Text("\(secondsLeft)s remaining").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private func resultContent(_ result: AutoSetupResult) -> some View {
        // `ScrollView` renders blank offscreen (confirmed repro); skip it in render tests.
        if snapshotRendering {
            resultInnerContent(result)
        } else {
            ScrollView { resultInnerContent(result) }
        }
    }

    @ViewBuilder
    private func resultInnerContent(_ result: AutoSetupResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Measurements").font(.subheadline.weight(.semibold))
                measurementRow("Noise Floor", value: result.noiseFloorDBFS, unit: "dB")
                measurementRow("Speech Loudness", value: result.speechLUFS, unit: "LUFS")
                measurementRow("Peak", value: result.peakDBFS, unit: "dB")
                measurementRow("Sibilance", value: result.sibilanceDB, unit: "dB")
                measurementRow("Tonal Tilt", value: result.tiltDB, unit: "dB/oct")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Findings").font(.subheadline.weight(.semibold))
                ForEach(result.findings, id: \.self) { finding in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.loopbacker)
                            .font(.caption)
                        Text(finding).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            beforeAfterSummary(result)

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                    .tint(nil)
                Spacer()
                Button("Apply") {
                    var applied = result.preset
                    applied.isEnabled = true
                    routingState.effectsPreset = applied
                    routingState.noiseSuppression = result.noiseSuppression
                    routingState.save()
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .tint(.loopbacker)
            }
        }
    }

    private func measurementRow(_ label: String, value: Float, unit: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%+.1f %@", value, unit))
                .font(.caption.weight(.semibold).monospacedDigit())
        }
    }

    private func beforeAfterSummary(_ result: AutoSetupResult) -> some View {
        let before = FXMacros.estimate(preset: routingState.effectsPreset, noise: routingState.noiseSuppression)
        let after = FXMacros.estimate(preset: result.preset, noise: result.noiseSuppression)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Before / After").font(.subheadline.weight(.semibold))
            summaryRow("Clarity", before.clarity, after.clarity)
            summaryRow("Warmth", before.warmth, after.warmth)
            summaryRow("Noise", before.noise, after.noise)
            summaryRow("Loudness", before.loudness, after.loudness)
        }
    }

    private func summaryRow(_ label: String, _ before: Float, _ after: Float) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text("\(Int(before * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
            Text("\(Int(after * 100))%").font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.loopbacker)
        }
    }

    private func startRecording() {
        let total = 10
        phase = .recording(secondsLeft: total)
        Task {
            let countdown = Task { @MainActor in
                for remaining in stride(from: total - 1, through: 0, by: -1) {
                    try? await Task.sleep(for: .seconds(1))
                    if case .recording = phase { phase = .recording(secondsLeft: remaining) }
                }
            }
            let recording = await fxEngine.record(seconds: Double(total))
            countdown.cancel()
            let result = AutoSetup.analyze(recording, base: routingState.effectsPreset, noise: routingState.noiseSuppression)
            await MainActor.run { phase = .result(result) }
        }
    }
}

// MARK: - Waveform

/// Static min/max waveform, downsampled to a few hundred columns.
struct WaveformView: View {
    let samples: [Float]

    var body: some View {
        GeometryReader { geo in
            let columns = max(1, Int(geo.size.width / 2))
            let step = max(1, samples.count / columns)
            Path { path in
                let midY = geo.size.height / 2
                for col in 0..<columns {
                    let start = col * step
                    guard start < samples.count else { break }
                    let end = min(start + step, samples.count)
                    let slice = samples[start..<end]
                    let maxVal = slice.max() ?? 0
                    let minVal = slice.min() ?? 0
                    let x = CGFloat(col) * 2
                    path.move(to: CGPoint(x: x, y: midY - CGFloat(maxVal) * midY))
                    path.addLine(to: CGPoint(x: x, y: midY - CGFloat(minVal) * midY))
                }
            }
            .stroke(Color.loopbacker, lineWidth: 1.5)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Playback

/// Plays a recorded mono clip through the default output device (the user's speakers), not
/// Loopbacker's virtual device, so Mic Check's A/B comparison is heard the way a call partner
/// would hear it.
@MainActor
final class MicCheckPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isAttached = false

    func play(_ recording: FXRecording, processed: Bool) {
        stop()
        let samples = processed ? recording.processed : recording.raw
        guard !samples.isEmpty, let format = AVAudioFormat(standardFormatWithSampleRate: recording.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData?[0].update(from: src.baseAddress!, count: samples.count)
        }

        if !isAttached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            isAttached = true
        }
        do {
            try engine.start()
            player.scheduleBuffer(buffer, completionHandler: nil)
            player.play()
        } catch {
            // Playback is best-effort for an A/B preview; a failure here just means silence,
            // not a crash.
        }
    }

    func stop() {
        player.stop()
        if engine.isRunning { engine.stop() }
    }
}
