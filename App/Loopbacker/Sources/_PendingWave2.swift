import Accelerate
import AppKit
import Foundation
import SwiftUI

// MARK: - Pending wave-2 stand-ins
//
// This file exists only because the Presets and Comms slices (see
// `local://fx-contract-wave2.md`) have not landed in this worktree yet. Every type below
// implements the EXACT public signature its contract promises, with real (not mocked) behavior,
// so the Effects UI can be built and tested against it now. The integration owner deletes this
// file wholesale once `Sources/Models/FactoryPresets.swift`, `Sources/Services/FX/FXMacros.swift`,
// `Sources/Services/FX/AutoSetup.swift`, `Sources/Models/CallAppAdvice.swift` and
// `Sources/Views/EchoCancellationSection.swift` land for real.
//
// Known gap: `NoiseSuppressionSettings.echoCancellation` (Comms slice's model field) does not
// exist yet, so `EchoCancellationSection` below persists its own toggle under
// `fxPendingWave2.echoCancellationEnabled` instead of the real settings struct. See report.

// MARK: - Presets slice: FactoryPresets.swift

enum FactoryPresetCategory: String, CaseIterable, Sendable {
    case business, gaming, streaming, creative

    var title: String {
        switch self {
        case .business: "Business"
        case .gaming: "Gaming"
        case .streaming: "Streaming"
        case .creative: "Creative"
        }
    }
}

struct FactoryPreset: Identifiable, Sendable {
    let id: String
    let name: String
    let category: FactoryPresetCategory
    let summary: String
    let symbol: String
    let preset: EffectsPreset
    /// Noise suppression this preset is designed around (engine/reduction), nil = leave as is.
    let noiseSuppression: NoiseSuppressionSettings?
    /// Echo cancellation recommendation for this preset, nil = leave as is.
    let echoCancellation: Bool?
}

enum FactoryPresets {
    static let all: [FactoryPreset] = [
        FactoryPreset(id: "meeting-natural", name: "Meeting – Natural", category: .business,
                      summary: "Clean, intelligible voice for daily video calls.",
                      symbol: "person.wave.2.fill", preset: .broadcastVoice,
                      noiseSuppression: NoiseSuppressionSettings(isEnabled: true, engine: .fastenhancer, maxReductionDB: -30),
                      echoCancellation: true),
        FactoryPreset(id: "boardroom", name: "Boardroom", category: .business,
                      summary: "Authoritative, de-essed voice for presentations.",
                      symbol: "building.2.fill", preset: .radioAnnouncer,
                      noiseSuppression: NoiseSuppressionSettings(isEnabled: true, engine: .dpdfnet, maxReductionDB: -40),
                      echoCancellation: true),
        FactoryPreset(id: "podcast-interview", name: "Podcast – Interview", category: .business,
                      summary: "Warm, even levels for remote interviews.",
                      symbol: "mic.fill", preset: .podcastClean,
                      noiseSuppression: NoiseSuppressionSettings(isEnabled: true, engine: .fastenhancer, maxReductionDB: -24),
                      echoCancellation: true),
        FactoryPreset(id: "ranked-comms", name: "Ranked Comms", category: .gaming,
                      summary: "Fast gate and limiter for terse team callouts.",
                      symbol: "gamecontroller.fill", preset: .minimal,
                      noiseSuppression: NoiseSuppressionSettings(isEnabled: true, engine: .rnnoise, maxReductionDB: -18),
                      echoCancellation: false),
        FactoryPreset(id: "heavy-chat", name: "Heavy Compression", category: .gaming,
                      summary: "Squashed, consistent level for loud sessions.",
                      symbol: "waveform.path.badge.plus", preset: .heavyCompression,
                      noiseSuppression: NoiseSuppressionSettings(isEnabled: true, engine: .fastenhancer, maxReductionDB: -24),
                      echoCancellation: false),
        FactoryPreset(id: "stream-broadcast", name: "Broadcast Stream", category: .streaming,
                      summary: "Radio-ready voice with a touch of room.",
                      symbol: "antenna.radiowaves.left.and.right", preset: .cathedral,
                      noiseSuppression: NoiseSuppressionSettings(isEnabled: true, engine: .dpdfnet, maxReductionDB: -36),
                      echoCancellation: false),
        FactoryPreset(id: "stream-hype", name: "Hype Voice", category: .streaming,
                      summary: "Bright, forward presence that cuts through hype moments.",
                      symbol: "waveform.badge.exclamationmark", preset: .deepVoice,
                      noiseSuppression: NoiseSuppressionSettings(isEnabled: true, engine: .fastenhancer, maxReductionDB: -24),
                      echoCancellation: false),
        FactoryPreset(id: "creative-character", name: "Character Voice", category: .creative,
                      summary: "Pitched, modulated voice for bits and sketches.",
                      symbol: "theatermasks.fill", preset: .robot,
                      noiseSuppression: NoiseSuppressionSettings(isEnabled: true, engine: .rnnoise, maxReductionDB: -18),
                      echoCancellation: false),
        FactoryPreset(id: "creative-dreamy", name: "Dreamy", category: .creative,
                      summary: "Lush modulation and space for ambient content.",
                      symbol: "sparkles", preset: .dreamy,
                      noiseSuppression: nil, echoCancellation: false),
    ]

    static func preset(id: String) -> FactoryPreset? { all.first { $0.id == id } }
}

/// Named presets for automation (auto-switch rules, Shortcuts, URL scheme): factory + saved.
struct NamedPreset: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isFactory: Bool
}

enum EffectsPresetLibrary {
    static func all() -> [NamedPreset] {
        FactoryPresets.all.map { NamedPreset(id: $0.id, name: $0.name, isFactory: true) }
            + EffectsPresetManager.list().map { NamedPreset(id: "saved:\($0)", name: $0, isFactory: false) }
    }

    @MainActor static func apply(id: String, to state: RoutingState) -> Bool {
        if let factory = FactoryPresets.preset(id: id) {
            var applied = factory.preset
            applied.isEnabled = true
            state.effectsPreset = applied
            if let ns = factory.noiseSuppression { state.noiseSuppression = ns }
            state.save()
            return true
        }
        if id.hasPrefix("saved:"), let loaded = EffectsPresetManager.load(name: String(id.dropFirst("saved:".count))) {
            var applied = loaded
            applied.isEnabled = true
            state.effectsPreset = applied
            state.save()
            return true
        }
        return false
    }
}

// MARK: - Presets slice: FXMacros.swift

struct FXMacroValues: Equatable, Sendable {
    var clarity: Float = 0.5
    var warmth: Float = 0.5
    var noise: Float = 0.5
    var loudness: Float = 0.5
}

/// Rewrites a handful of built-in parameters in response to four 0...1 macro sliders. Never
/// touches hosted nodes; adds a missing core node (gate/eq/compressor/deEsser/limiter) only when
/// a macro needs it and the chain doesn't already have one.
enum FXMacros {
    static func apply(_ v: FXMacroValues, to preset: EffectsPreset, noise: NoiseSuppressionSettings) -> (EffectsPreset, NoiseSuppressionSettings) {
        var p = preset
        var n = noise

        func ensure(_ kind: FXNodeKind) -> Int {
            if let idx = p.nodes.firstIndex(where: { $0.kind == kind }) { return idx }
            var config = FXNodeConfig(kind: kind)
            if kind == .eq { config.eqBands = EQBandConfig.broadcastMasculine }
            p.nodes.append(config)
            return p.nodes.count - 1
        }

        // Clarity: presence boost (EQ high shelf + 3.5kHz peak) and de-essing to keep it clean.
        let clarityIdx = ensure(.eq)
        if var bands = p.nodes[clarityIdx].eqBands, bands.count >= 5 {
            bands[3].gainDB = -4 + v.clarity * 8 // -4...+4 dB around 3.5 kHz
            bands[4].gainDB = -2 + v.clarity * 6 // -2...+4 dB high shelf
            p.nodes[clarityIdx].eqBands = bands
        }
        let deEsserIdx = ensure(.deEsser)
        p.nodes[deEsserIdx].enabled = true
        p.nodes[deEsserIdx].params["range"] = 2 + v.clarity * 8 // 2...10 dB

        // Warmth: low shelf lift, trims the same high shelf clarity reaches for.
        if var bands = p.nodes[clarityIdx].eqBands, bands.count >= 2 {
            bands[1].gainDB = -3 + v.warmth * 6 // -3...+3 dB around 220 Hz
            p.nodes[clarityIdx].eqBands = bands
        }

        // Noise: on-device suppression depth plus a light gate behind it.
        n.isEnabled = v.noise > 0.02
        n.maxReductionDB = -6 - v.noise * 54 // -6...-60 dB
        let gateIdx = ensure(.gate)
        p.nodes[gateIdx].enabled = v.noise > 0.3
        p.nodes[gateIdx].params["threshold"] = -30 - v.noise * 30 // -30...-60 dB
        p.nodes[gateIdx].params["range"] = -6 - v.noise * 14 // -6...-20 dB

        // Loudness: compressor drive/makeup plus a limiter ceiling that tightens as it climbs.
        let compIdx = ensure(.compressor)
        p.nodes[compIdx].enabled = true
        p.nodes[compIdx].params["ratio"] = 1.5 + v.loudness * 4.5 // 1.5...6
        p.nodes[compIdx].params["makeup"] = v.loudness * 8 // 0...8 dB
        let limiterIdx = ensure(.limiter)
        p.nodes[limiterIdx].enabled = true
        p.nodes[limiterIdx].params["ceiling"] = -2.5 + v.loudness * 1.5 // -2.5...-1.0 dB

        return (p, n)
    }

    /// Reads the same handful of parameters back into macro space. Approximate by construction
    /// (`apply` is lossy), but round-trips to the same chain shape `apply` would have produced.
    static func estimate(preset: EffectsPreset, noise: NoiseSuppressionSettings) -> FXMacroValues {
        var v = FXMacroValues()
        if let eq = preset.nodes.first(where: { $0.kind == .eq }), let bands = eq.eqBands, bands.count >= 5 {
            v.clarity = Swift.min(1, Swift.max(0, (bands[3].gainDB + 4) / 8))
            v.warmth = Swift.min(1, Swift.max(0, (bands[1].gainDB + 3) / 6))
        }
        if noise.isEnabled {
            v.noise = Swift.min(1, Swift.max(0, (-noise.maxReductionDB - 6) / 54))
        } else {
            v.noise = 0
        }
        if let comp = preset.nodes.first(where: { $0.kind == .compressor }) {
            let ratio = comp.params["ratio"] ?? 3
            v.loudness = Swift.min(1, Swift.max(0, (ratio - 1.5) / 4.5))
        }
        return v
    }
}

// MARK: - Presets slice: AutoSetup.swift

struct AutoSetupResult: Sendable {
    let noiseFloorDBFS: Float
    let speechLUFS: Float
    let peakDBFS: Float
    /// 5–9 kHz energy relative to 200 Hz–4 kHz while speaking.
    let sibilanceDB: Float
    /// Spectral tilt, dB/octave, while speaking.
    let tiltDB: Float
    let findings: [String]
    let preset: EffectsPreset
    let noiseSuppression: NoiseSuppressionSettings
}

/// Measures a short room/voice recording and tunes `base` to match it. Real (FFT-backed, via
/// Accelerate) measurement so results vary meaningfully with the recording, not placeholder
/// numbers: peak/RMS from the raw samples, noise floor from the quietest 20% of 20 ms frames,
/// sibilance and spectral tilt from one windowed FFT of (up to) the whole clip.
enum AutoSetup {
    static func analyze(_ recording: FXRecording, base: EffectsPreset, noise: NoiseSuppressionSettings) -> AutoSetupResult {
        let samples = recording.raw
        let sampleRate = Float(max(recording.sampleRate, 1))
        guard samples.count > 256 else {
            return AutoSetupResult(noiseFloorDBFS: -60, speechLUFS: -23, peakDBFS: -6, sibilanceDB: 0, tiltDB: 0,
                                   findings: ["Not enough audio was captured to analyze."],
                                   preset: base, noiseSuppression: noise)
        }

        // Peak and overall RMS.
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        let peakDBFS = fxLinearToDB(peak)

        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(samples.count))
        let speechLUFS = fxLinearToDB(sqrtf(max(meanSquare, 1e-12))) - 0.691

        // Noise floor: RMS of the quietest fifth of 20 ms frames.
        let frameLen = max(1, Int(0.02 * sampleRate))
        var frameRMS: [Float] = []
        var i = 0
        while i + frameLen <= samples.count {
            var ms: Float = 0
            samples.withUnsafeBufferPointer { buf in
                vDSP_measqv(buf.baseAddress! + i, 1, &ms, vDSP_Length(frameLen))
            }
            frameRMS.append(sqrtf(max(ms, 1e-12)))
            i += frameLen
        }
        frameRMS.sort()
        let quietCount = max(1, frameRMS.count / 5)
        let quietMean = frameRMS.prefix(quietCount).reduce(0, +) / Float(quietCount)
        let noiseFloorDBFS = fxLinearToDB(quietMean)

        // One FFT over the largest power-of-two prefix (capped) for sibilance + tilt.
        var log2n = 0
        var fftLen = 1
        while fftLen * 2 <= samples.count && fftLen < 65536 { fftLen *= 2; log2n += 1 }
        var sibilanceDB: Float = 0
        var tiltDB: Float = 0
        if fftLen >= 1024, let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) {
            defer { vDSP_destroy_fftsetup(setup) }
            var window = [Float](repeating: 0, count: fftLen)
            vDSP_hann_window(&window, vDSP_Length(fftLen), Int32(vDSP_HANN_NORM))
            var windowed = [Float](repeating: 0, count: fftLen)
            vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftLen))

            var real = [Float](repeating: 0, count: fftLen / 2)
            var imag = [Float](repeating: 0, count: fftLen / 2)
            var magnitude = [Float](repeating: 0, count: fftLen / 2)
            real.withUnsafeMutableBufferPointer { realPtr in
                imag.withUnsafeMutableBufferPointer { imagPtr in
                    var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                    windowed.withUnsafeBufferPointer { src in
                        src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftLen / 2) { complexPtr in
                            vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(fftLen / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &magnitude, 1, vDSP_Length(fftLen / 2))
                }
            }

            let binHz = sampleRate / Float(fftLen)
            func bandEnergy(_ loHz: Float, _ hiHz: Float) -> Float {
                let lo = max(1, Int(loHz / binHz))
                let hi = min(magnitude.count - 1, Int(hiHz / binHz))
                guard hi > lo else { return 1e-12 }
                return magnitude[lo...hi].reduce(0, +) / Float(hi - lo + 1)
            }
            let presence = bandEnergy(200, 4000)
            let sibilance = bandEnergy(5000, 9000)
            sibilanceDB = 10 * log10f(max(sibilance, 1e-12) / max(presence, 1e-12))

            // Spectral tilt: least-squares slope of 10*log10(magnitude) vs log2(freq), dB/octave.
            var xs: [Float] = []
            var ys: [Float] = []
            for bin in 1..<magnitude.count {
                let freq = Float(bin) * binHz
                guard freq >= 100, freq <= 16000 else { continue }
                xs.append(log2f(freq))
                ys.append(10 * log10f(max(magnitude[bin], 1e-12)))
            }
            if xs.count > 8 {
                let n = Float(xs.count)
                let sumX = xs.reduce(0, +), sumY = ys.reduce(0, +)
                let sumXY = zip(xs, ys).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                let sumXX = xs.reduce(Float(0)) { $0 + $1 * $1 }
                let denom = n * sumXX - sumX * sumX
                tiltDB = denom != 0 ? (n * sumXY - sumX * sumY) / denom : 0
            }
        }

        var findings: [String] = []
        if noiseFloorDBFS < -50 { findings.append("Your room is quiet — a light touch of noise suppression will do.") }
        else if noiseFloorDBFS < -35 { findings.append("Moderate room noise detected; noise suppression is set to a medium depth.") }
        else { findings.append("Noticeable background noise — noise suppression is set deep, and the gate will help between words.") }

        if speechLUFS < -26 { findings.append("Your voice is on the quiet side; the leveler and compressor makeup are turned up.") }
        else if speechLUFS > -16 { findings.append("Your voice is already loud and close to the mic; levels were eased back.") }
        else { findings.append("Your speaking level is in a healthy range.") }

        if sibilanceDB > 3 { findings.append("Sibilance ('s'/'sh' sounds) is forward; the de-esser was tightened.") }
        if tiltDB < -6 { findings.append("Your mic sounds dark; a presence and high-shelf lift were added.") }
        else if tiltDB > 2 { findings.append("Your mic sounds bright/thin; the top end was eased back slightly.") }

        var tunedPreset = base
        var tunedNoise = noise
        tunedNoise.isEnabled = true
        tunedNoise.maxReductionDB = Swift.min(-6, Swift.max(-60, noiseFloorDBFS - 6))

        if let gateIdx = tunedPreset.nodes.firstIndex(where: { $0.kind == .gate }) {
            tunedPreset.nodes[gateIdx].params["threshold"] = Swift.min(-10, noiseFloorDBFS + 12)
        }
        if let compIdx = tunedPreset.nodes.firstIndex(where: { $0.kind == .compressor }) {
            tunedPreset.nodes[compIdx].params["threshold"] = Swift.min(-6, speechLUFS + 6)
            tunedPreset.nodes[compIdx].params["makeup"] = speechLUFS < -26 ? 6 : (speechLUFS > -16 ? 0 : 3)
        }
        if let deEsserIdx = tunedPreset.nodes.firstIndex(where: { $0.kind == .deEsser }) {
            tunedPreset.nodes[deEsserIdx].enabled = sibilanceDB > 1
            tunedPreset.nodes[deEsserIdx].params["range"] = Swift.min(16, Swift.max(2, sibilanceDB + 4))
        }
        if let eqIdx = tunedPreset.nodes.firstIndex(where: { $0.kind == .eq }), var bands = tunedPreset.nodes[eqIdx].eqBands, bands.count >= 5 {
            let tiltCorrection = Swift.min(4, Swift.max(-4, -tiltDB / 2))
            bands[4].gainDB = Swift.min(8, Swift.max(-8, bands[4].gainDB + tiltCorrection))
            tunedPreset.nodes[eqIdx].eqBands = bands
        }

        return AutoSetupResult(noiseFloorDBFS: noiseFloorDBFS, speechLUFS: speechLUFS, peakDBFS: peakDBFS,
                               sibilanceDB: sibilanceDB, tiltDB: tiltDB, findings: findings,
                               preset: tunedPreset, noiseSuppression: tunedNoise)
    }
}

// MARK: - Presets slice: CallAppAdvice.swift

struct CallAppAdvice: Identifiable, Sendable {
    let id: String // bundle id
    let appName: String
    let advice: String
}

enum CallAppAdviceCatalog {
    static let all: [CallAppAdvice] = [
        CallAppAdvice(id: "us.zoom.xos", appName: "Zoom",
                      advice: "Zoom has its own noise suppression and auto-gain; turn those off in Zoom's audio settings so Loopbacker's chain isn't fighting a second processor."),
        CallAppAdvice(id: "com.hnc.Discord", appName: "Discord",
                      advice: "Disable Discord's Noise Suppression and Echo Cancellation in Voice & Video settings — Loopbacker already handles both before the signal reaches Discord."),
        CallAppAdvice(id: "com.google.Chrome", appName: "Chrome (Meet/Teams)",
                      advice: "Browser-based call tools (Meet, Teams Web) run their own noise suppression on the input stream; disable it in the call's in-browser audio settings if voice sounds over-processed."),
        CallAppAdvice(id: "com.microsoft.teams2", appName: "Microsoft Teams",
                      advice: "Set Teams' microphone noise suppression to \"Off\" or \"Low\" under Settings > Devices — Loopbacker is already cleaning the signal upstream."),
        CallAppAdvice(id: "com.skype.skype", appName: "Skype",
                      advice: "Skype's automatic audio tuning can undo Loopbacker's leveling; disable automatic adjustments under audio settings."),
    ]

    @MainActor static func running() -> [CallAppAdvice] {
        let runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return all.filter { runningBundleIDs.contains($0.id) }
    }
}

// MARK: - Comms slice: Sources/Views/EchoCancellationSection.swift
//
// Real file will read `RoutingState.noiseSuppression.echoCancellation` (a Bool the Comms slice
// adds to `NoiseSuppressionSettings`) and `SystemAudioTap`'s permission/tap-failure state from
// the environment. Until that field lands, this stand-in keeps its own persisted toggle.

struct EchoCancellationSection: View {
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var systemAudioTap: SystemAudioTap
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("fxPendingWave2.echoCancellationEnabled") private var enabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath.circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(enabled ? Color.loopbacker : Color.secondary)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Echo Cancellation")
                        .font(.headline)
                    Text("Removes your speakers' sound from your mic so the other side doesn't hear an echo of themselves.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Toggle(isOn: Binding(
                    get: { enabled },
                    set: { newValue in
                        enabled = newValue
                        if newValue { systemAudioTap.start() } else { systemAudioTap.stop() }
                    }
                )) {
                    Text(enabled ? "On" : "Off").font(.caption.weight(.semibold))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.loopbacker)
            }

            if enabled {
                permissionRow
            }
        }
    }

    @ViewBuilder
    private var permissionRow: some View {
        switch systemAudioTap.permission {
        case .granted:
            EmptyView()
        case .unknown:
            Text("Requesting System Audio Recording permission…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .denied:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.signalWarm)
                Text("Loopbacker needs System Audio Recording permission to hear your speakers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SystemAudioRecording") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.glass)
                .tint(nil)
                .controlSize(.small)
            }
        }
        if case .failed(let error) = systemAudioTap.state {
            Text(error.errorDescription ?? "The system audio tap failed to start.")
                .font(.caption)
                .foregroundStyle(Color.signalHot)
        }
    }
}
