import Foundation

/// Measurements from a recording plus a preset tuned from them.
struct AutoSetupResult: Sendable {
    let noiseFloorDBFS: Float
    let speechLUFS: Float
    let peakDBFS: Float
    /// 5-9 kHz energy relative to 200 Hz-4 kHz energy while speaking, in dB (positive = bright).
    let sibilanceDB: Float
    /// Spectral tilt while speaking, dB/octave between a ~300 Hz and a ~6 kHz band (negative =
    /// darker than flat, the natural falloff of speech; positive = brighter than natural).
    let tiltDB: Float
    let findings: [String]
    let preset: EffectsPreset
    let noiseSuppression: NoiseSuppressionSettings
}

/// Measures a recording (K-weighted loudness while speaking, noise floor while not, peak,
/// sibilance, spectral tilt) and tunes `base`'s built-in stages from the result: the gate's
/// threshold sits between the noise floor and speech, the leveler keeps `base`'s own target (it
/// already encodes the preset's category -- streaming vs. calls/gaming), the EQ gets a tilt
/// correction capped at +/-4 dB, and the de-esser's threshold tightens with measured sibilance.
/// `base`'s node order and any hosted nodes are kept exactly; only built-in stage parameters
/// change (missing built-ins are added, same as `FXMacros`).
enum AutoSetup {
    /// K-weighting (ITU-R BS.1770): a ~+4 dB high-shelf above ~1.68 kHz, then a ~38 Hz
    /// high-pass -- the same two-stage filter `LevelerNode` uses, so "speech is at -18 LUFS"
    /// means the same thing in both places.
    private static let kShelf = FXBiquadCoeffs.make(type: .highshelf, frequency: 1681.9744509555319,
                                                     q: 0.7071752369554196, gainDB: 3.999843853973347, sampleRate: 48_000)
    private static let kHighpass = FXBiquadCoeffs.make(type: .highpass, frequency: 38.13547087602444,
                                                        q: 0.5003270373238773, gainDB: 0, sampleRate: 48_000)

    static func analyze(_ recording: FXRecording, base: EffectsPreset, noise: NoiseSuppressionSettings) -> AutoSetupResult {
        let sampleRate = Float(recording.sampleRate > 0 ? recording.sampleRate : 48_000)
        // The raw (pre-chain) signal characterizes the mic/room; the processed signal has
        // already had the chain's own cleanup applied, which would hide exactly what we're
        // trying to measure.
        let samples = recording.raw.isEmpty ? recording.processed : recording.raw
        guard !samples.isEmpty else {
            return AutoSetupResult(noiseFloorDBFS: -60, speechLUFS: -60, peakDBFS: -60, sibilanceDB: 0, tiltDB: 0,
                                   findings: ["No audio was recorded."], preset: base, noiseSuppression: noise)
        }

        let speechMask = speechMask(for: samples, sampleRate: sampleRate)
        let noiseFloor = rmsDBFS(samples, where: { !speechMask[$0] })
        let speechLUFS = kWeightedIntegratedLUFS(samples, where: { speechMask[$0] }, sampleRate: sampleRate)
        let peak = peakDBFS(samples)
        let sibilance = sibilanceDB(samples, where: { speechMask[$0] }, sampleRate: sampleRate)
        let tilt = spectralTiltDB(samples, where: { speechMask[$0] }, sampleRate: sampleRate)

        var findings: [String] = []
        if noiseFloor > -42 { findings.append("Your room is noisy -- stronger noise suppression will help.") }
        else if noiseFloor < -58 { findings.append("Your room is quiet.") }
        if sibilance > 4 { findings.append("Your voice is sibilant -- de-essing will tame harsh S and T sounds.") }
        if tilt > 2 { findings.append("Your mic sounds bright -- a touch less top end will sound more natural.") }
        else if tilt < -8 { findings.append("Your mic sounds muffled -- a presence boost will add clarity.") }
        let levelerTarget = base.nodes.first { $0.kind == .leveler }?.params["target"] ?? -18
        if speechLUFS < levelerTarget - 8 { findings.append("Your voice is quiet relative to your target -- a leveler will even it out.") }
        else if speechLUFS > levelerTarget + 8 { findings.append("Your voice is loud relative to your target -- a leveler will even it out.") }
        if findings.isEmpty { findings.append("Your setup already looks well balanced.") }

        let tuned = tune(base, noiseFloorDBFS: noiseFloor, peakDBFS: peak, speechLUFS: speechLUFS,
                         levelerTarget: levelerTarget, sibilanceDB: sibilance, tiltDB: tilt)
        let tunedNoise = tuneNoiseSuppression(noise, noiseFloorDBFS: noiseFloor)

        return AutoSetupResult(noiseFloorDBFS: noiseFloor, speechLUFS: speechLUFS, peakDBFS: peak,
                               sibilanceDB: sibilance, tiltDB: tilt, findings: findings,
                               preset: tuned, noiseSuppression: tunedNoise)
    }

    // MARK: - Tuning

    private static func tune(_ base: EffectsPreset, noiseFloorDBFS: Float, peakDBFS: Float, speechLUFS: Float,
                             levelerTarget: Float, sibilanceDB: Float, tiltDB: Float) -> EffectsPreset {
        var preset = base
        ensureNode(&preset, kind: .gate)
        ensureNode(&preset, kind: .leveler)
        ensureNode(&preset, kind: .eq)
        ensureNode(&preset, kind: .deEsser)

        setParams(&preset, kind: .gate) { config in
            config.enabled = true
            // Sits above the noise floor, at least 3 dB below the measured speech loudness (so
            // it doesn't gate into quiet speech itself), never above the recording's own peak
            // (a silent/near-silent recording would otherwise push the threshold past
            // everything and leave the gate permanently closed).
            let aboveNoise = noiseFloorDBFS + max(6, (speechLUFS - noiseFloorDBFS) * 0.3)
            let threshold = min(aboveNoise, speechLUFS - 3, peakDBFS - 6)
            config.params["threshold"] = min(0, max(-80, threshold))
        }

        setParams(&preset, kind: .leveler) { config in
            config.enabled = true
            config.params["target"] = levelerTarget // the category's own target, kept as-is
        }

        withEQBands(&preset) { bands in
            // Counter the measured tilt: bright mic (positive tilt) gets a high-shelf cut,
            // boomy/muffled mic (negative tilt) gets a high-shelf boost -- capped so a wildly
            // mismeasured tilt can't make the correction itself sound unnatural.
            let correction = min(4, max(-4, -tiltDB * 0.5))
            setBand(&bands, id: BandID.tiltCorrection, type: .highshelf, freq: 6000, q: 0.7, gainDB: correction)
        }

        setParams(&preset, kind: .deEsser) { config in
            config.enabled = sibilanceDB > 1
            let threshold = -30 - max(0, sibilanceDB) * 2
            config.params["threshold"] = min(0, max(-60, threshold))
        }

        return preset
    }

    private static func tuneNoiseSuppression(_ noise: NoiseSuppressionSettings, noiseFloorDBFS: Float) -> NoiseSuppressionSettings {
        var tuned = noise
        tuned.isEnabled = true
        let suggested = noiseFloorDBFS - 10
        tuned.maxReductionDB = min(NoiseSuppressionSettings.reductionRange.upperBound,
                                   max(NoiseSuppressionSettings.reductionRange.lowerBound, suggested))
        if noiseFloorDBFS > -40 { tuned.engine = .dpdfnet } // noisy room: use the strongest cleanup
        return tuned
    }

    private enum BandID {
        static let tiltCorrection = 950
    }

    private static func ensureNode(_ preset: inout EffectsPreset, kind: FXNodeKind) {
        guard !preset.nodes.contains(where: { $0.kind == kind }) else { return }
        let order: [FXNodeKind] = [.gate, .eq, .compressor, .leveler, .deEsser, .chorus, .pitchShift, .reverb, .delay, .limiter]
        guard let rank = order.firstIndex(of: kind) else { return }
        let insertAt = preset.nodes.firstIndex { config in
            guard let configRank = order.firstIndex(of: config.kind) else { return false }
            return configRank > rank
        } ?? preset.nodes.count
        preset.nodes.insert(FXNodeConfig(kind: kind, enabled: true), at: insertAt)
    }

    private static func setParams(_ preset: inout EffectsPreset, kind: FXNodeKind, _ body: (inout FXNodeConfig) -> Void) {
        guard let idx = preset.nodes.firstIndex(where: { $0.kind == kind }) else { return }
        body(&preset.nodes[idx])
    }

    private static func withEQBands(_ preset: inout EffectsPreset, _ body: (inout [EQBandConfig]) -> Void) {
        guard let idx = preset.nodes.firstIndex(where: { $0.kind == .eq }) else { return }
        var bands = preset.nodes[idx].eqBands ?? []
        body(&bands)
        preset.nodes[idx].eqBands = bands
    }

    private static func setBand(_ bands: inout [EQBandConfig], id: Int, type: EQBandConfig.BandType, freq: Float,
                                q: Float, gainDB: Float) {
        if let idx = bands.firstIndex(where: { $0.id == id }) {
            bands[idx].type = type; bands[idx].frequencyHz = freq; bands[idx].q = q; bands[idx].gainDB = gainDB
        } else {
            bands.append(EQBandConfig(id: id, type: type, frequencyHz: freq, gainDB: gainDB, q: q))
        }
    }

    // MARK: - Measurement

    /// One `Bool` per sample: true while the chain's own voice activity detector reports
    /// speech (probability > 0.5, the same threshold `GateNode`/`LevelerNode` use), fed in
    /// 480-sample (10 ms) hops like the live chain. A fresh detector per call, independent of
    /// any chain's.
    private static func speechMask(for samples: [Float], sampleRate: Float) -> [Bool] {
        guard let vad = VoiceActivityDetector() else { return [Bool](repeating: true, count: samples.count) }
        var mask = [Bool](repeating: false, count: samples.count)
        let hop = 480
        var offset = 0
        samples.withUnsafeBufferPointer { buf in
            while offset < samples.count {
                let n = min(hop, samples.count - offset)
                let probability = vad.process(buf.baseAddress! + offset, frames: n)
                let speaking = probability > 0.5
                for i in offset..<(offset + n) { mask[i] = speaking }
                offset += n
            }
        }
        return mask
    }

    private static func rmsDBFS(_ samples: [Float], where predicate: (Int) -> Bool) -> Float {
        var sum: Double = 0
        var count = 0
        for i in 0..<samples.count where predicate(i) {
            sum += Double(samples[i] * samples[i])
            count += 1
        }
        guard count > 0 else { return -80 }
        return fxLinearToDB(Float(sqrt(sum / Double(count))))
    }

    private static func peakDBFS(_ samples: [Float]) -> Float {
        var peak: Float = 0
        for s in samples { peak = max(peak, abs(s)) }
        return fxLinearToDB(peak)
    }

    /// Ungated BS.1770 integrated loudness (`-0.691 + 10*log10(meanSquare)`) over the samples
    /// where `predicate` holds, K-weighted continuously across the whole recording so the
    /// filters' own history stays correct. Doubles the squared term to match `LevelerNode`'s own
    /// per-sample mono convention (it sums both "channels'" squared K-weighted energy and only
    /// divides by 1 for mono content, since its `right` is a duplicate of `left` rather than an
    /// independent channel) -- so a `target` here means the same thing it does to the leveler
    /// actually levelling this mono recording, not a plain single-channel BS.1770 reading.
    private static func kWeightedIntegratedLUFS(_ samples: [Float], where predicate: (Int) -> Bool,
                                                sampleRate: Float) -> Float {
        var shelf = FXBiquadState()
        var hp = FXBiquadState()
        var sumSquares: Double = 0
        var count = 0
        for i in 0..<samples.count {
            var k = Float(shelf.process(Double(samples[i]), kShelf))
            k = Float(hp.process(Double(k), kHighpass))
            if predicate(i) {
                sumSquares += 2 * Double(k * k)
                count += 1
            }
        }
        guard count > 0 else { return -80 }
        let meanSquare = sumSquares / Double(count)
        return Float(-0.691 + 10 * log10(max(meanSquare, 1e-12)))
    }

    /// 5-9 kHz energy vs. 200 Hz-4 kHz energy, in dB, over the samples where `predicate` holds.
    private static func sibilanceDB(_ samples: [Float], where predicate: (Int) -> Bool, sampleRate: Float) -> Float {
        let lowBand = bandEnergyDB(samples, where: predicate, lowHz: 200, highHz: 4000, sampleRate: sampleRate)
        let highBand = bandEnergyDB(samples, where: predicate, lowHz: 5000, highHz: 9000, sampleRate: sampleRate)
        return highBand - lowBand
    }

    /// dB/octave slope between a ~300 Hz-800 Hz band and a ~4 kHz-8 kHz band, over the samples
    /// where `predicate` holds.
    private static func spectralTiltDB(_ samples: [Float], where predicate: (Int) -> Bool, sampleRate: Float) -> Float {
        let low = bandEnergyDB(samples, where: predicate, lowHz: 300, highHz: 800, sampleRate: sampleRate)
        let high = bandEnergyDB(samples, where: predicate, lowHz: 4000, highHz: 8000, sampleRate: sampleRate)
        let octaves = log2(Float(6000) / Float(550)) // band centers
        return (high - low) / octaves
    }

    /// RMS energy (dB) of `samples` band-limited to `lowHz...highHz` (a highpass then a
    /// cascaded lowpass, 2nd order each), measured only where `predicate` holds.
    private static func bandEnergyDB(_ samples: [Float], where predicate: (Int) -> Bool, lowHz: Float, highHz: Float,
                                     sampleRate: Float) -> Float {
        let hpCoeffs = FXBiquadCoeffs.make(type: .highpass, frequency: Double(lowHz), q: 0.7071, gainDB: 0,
                                           sampleRate: Double(sampleRate))
        let lpCoeffs = FXBiquadCoeffs.make(type: .lowpass, frequency: Double(highHz), q: 0.7071, gainDB: 0,
                                           sampleRate: Double(sampleRate))
        var hp = FXBiquadState()
        var lp = FXBiquadState()
        var sum: Double = 0
        var count = 0
        for i in 0..<samples.count {
            var x = Float(hp.process(Double(samples[i]), hpCoeffs))
            x = Float(lp.process(Double(x), lpCoeffs))
            if predicate(i) {
                sum += Double(x * x)
                count += 1
            }
        }
        guard count > 0 else { return -80 }
        return fxLinearToDB(Float(sqrt(sum / Double(count))))
    }
}
