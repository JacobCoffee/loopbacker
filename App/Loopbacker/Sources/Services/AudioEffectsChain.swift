import Foundation
import os.log

private let fxLogger = Logger(subsystem: "com.jacobcoffee.loopbacker", category: "AudioEffects")

/// Real-time safe audio effects chain for broadcast voice processing.
///
/// Signal flow: Gate → EQ → Compressor → De-Esser → Limiter
///
/// All processing operates in-place on interleaved Float32 buffers.
/// No allocations, no locks, no ObjC calls in the process path.
final class AudioEffectsChain {
    // MARK: - Configuration (written from main thread, read from RT thread)
    // Note: individual Float/Bool fields are naturally atomic on ARM64/x86_64.
    // The RT thread may briefly see a mix of old/new params during an update
    // (lasting at most one callback, ~5ms). This is standard practice for
    // real-time audio parameter updates and produces no audible artifacts.

    private(set) var enabled: Bool = false

    // Gate
    private(set) var gateEnabled: Bool = true
    private var gateThresholdLin: Float = 0.0
    private var gateReductionLin: Float = 0.0
    private var gateAttackCoeff: Float = 0.0
    private var gateReleaseCoeff: Float = 0.0

    // EQ
    private(set) var eqEnabled: Bool = true
    private let bandCount = 5
    // Biquad coefficients per band: b0, b1, b2, a1, a2
    private var eqB0: [Float]
    private var eqB1: [Float]
    private var eqB2: [Float]
    private var eqA1: [Float]
    private var eqA2: [Float]

    // Compressor
    private(set) var compressorEnabled: Bool = true
    private var compThresholdLin: Float = 0.0
    private var compRatio: Float = 3.0
    private var compAttackCoeff: Float = 0.0
    private var compReleaseCoeff: Float = 0.0
    private var compMakeupLin: Float = 1.0

    // De-Esser
    private(set) var deEsserEnabled: Bool = true
    private var deEsserReductionLin: Float = 0.0
    private var deEsserRatio: Float = 3.0
    private var deEsserThresholdLin: Float = 0.0
    // Bandpass biquad for sidechain
    private var deBpB0: Float = 0
    private var deBpB1: Float = 0
    private var deBpB2: Float = 0
    private var deBpA1: Float = 0
    private var deBpA2: Float = 0

    // Limiter
    private(set) var limiterEnabled: Bool = true
    private var limiterCeilingLin: Float = 0.0
    private var limiterReleaseCoeff: Float = 0.0

    // MARK: - Per-channel DSP state (max 2 channels)

    private let maxCh = 2

    // Gate envelope per channel
    private var gateEnv: [Float]

    // EQ biquad state: z1[band * maxCh + ch], z2[band * maxCh + ch]
    private var eqZ1: [Float]
    private var eqZ2: [Float]

    // Compressor envelope per channel
    private var compEnv: [Float]

    // De-esser bandpass state per channel
    private var deBpZ1: [Float]
    private var deBpZ2: [Float]
    // De-esser envelope per channel
    private var deEnv: [Float]

    // Limiter state per channel
    private var limiterEnv: [Float]

    // MARK: - Sample rate

    let sampleRate: Float

    // MARK: - Init

    init(sampleRate: Float) {
        self.sampleRate = sampleRate

        // Allocate coefficient arrays
        eqB0 = [Float](repeating: 1.0, count: bandCount)
        eqB1 = [Float](repeating: 0.0, count: bandCount)
        eqB2 = [Float](repeating: 0.0, count: bandCount)
        eqA1 = [Float](repeating: 0.0, count: bandCount)
        eqA2 = [Float](repeating: 0.0, count: bandCount)

        // Allocate state arrays
        let statePerBand = bandCount * maxCh
        gateEnv = [Float](repeating: 0, count: maxCh)
        eqZ1 = [Float](repeating: 0, count: statePerBand)
        eqZ2 = [Float](repeating: 0, count: statePerBand)
        compEnv = [Float](repeating: 0, count: maxCh)
        deBpZ1 = [Float](repeating: 0, count: maxCh)
        deBpZ2 = [Float](repeating: 0, count: maxCh)
        deEnv = [Float](repeating: 0, count: maxCh)
        limiterEnv = [Float](repeating: 0, count: maxCh)

        // Apply defaults
        updatePreset(EffectsPreset())
    }

    // MARK: - Settings update (called from main thread)

    func updatePreset(_ p: EffectsPreset) {
        enabled = p.isEnabled

        // Gate
        gateEnabled = p.gateEnabled
        gateThresholdLin = dBToLinear(p.gateThresholdDB)
        gateReductionLin = dBToLinear(p.gateReductionDB)
        gateAttackCoeff = expCoeff(timeMs: p.gateAttackMs, sr: sampleRate)
        gateReleaseCoeff = expCoeff(timeMs: p.gateReleaseMs, sr: sampleRate)

        // EQ
        eqEnabled = p.eqEnabled
        for (i, band) in p.eqBands.prefix(bandCount).enumerated() {
            let c = computeBiquad(type: band.type, freq: band.frequencyHz, gain: band.gainDB, q: band.q, sr: sampleRate)
            eqB0[i] = c.b0; eqB1[i] = c.b1; eqB2[i] = c.b2
            eqA1[i] = c.a1; eqA2[i] = c.a2
        }

        // Compressor
        compressorEnabled = p.compressorEnabled
        compThresholdLin = dBToLinear(p.compressorThresholdDB)
        compRatio = p.compressorRatio
        compAttackCoeff = expCoeff(timeMs: p.compressorAttackMs, sr: sampleRate)
        compReleaseCoeff = expCoeff(timeMs: p.compressorReleaseMs, sr: sampleRate)
        compMakeupLin = dBToLinear(p.compressorMakeupDB)

        // De-Esser — bandpass centered at target frequency, Q=2 for ~2 octave width
        deEsserEnabled = p.deEsserEnabled
        deEsserReductionLin = dBToLinear(p.deEsserReductionDB)
        deEsserRatio = p.deEsserRatio
        deEsserThresholdLin = dBToLinear(-22.0)  // matches gist: -22dB threshold
        let bpCoeffs = computeBandpass(freq: p.deEsserFrequencyHz, q: 2.0, sr: sampleRate)
        deBpB0 = bpCoeffs.b0; deBpB1 = bpCoeffs.b1; deBpB2 = bpCoeffs.b2
        deBpA1 = bpCoeffs.a1; deBpA2 = bpCoeffs.a2

        // Limiter
        limiterEnabled = p.limiterEnabled
        limiterCeilingLin = dBToLinear(p.limiterCeilingDB)
        limiterReleaseCoeff = expCoeff(timeMs: p.limiterReleaseMs, sr: sampleRate)
    }

    // MARK: - Real-time process (called from audio callback)

    /// Process interleaved Float32 audio in-place.
    func process(_ buffer: UnsafeMutablePointer<Float>, frames: UInt32, channels: UInt32) {
        guard enabled else { return }
        let n = Int(frames)
        let ch = min(Int(channels), maxCh)
        guard n > 0 && ch > 0 else { return }

        if gateEnabled { processGate(buffer, frames: n, channels: ch) }
        if eqEnabled { processEQ(buffer, frames: n, channels: ch) }
        if compressorEnabled { processCompressor(buffer, frames: n, channels: ch) }
        if deEsserEnabled { processDeEsser(buffer, frames: n, channels: ch) }
        if limiterEnabled { processLimiter(buffer, frames: n, channels: ch) }
    }

    // MARK: - Noise Gate

    private func processGate(_ buf: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        let thresh = gateThresholdLin
        let reduction = gateReductionLin
        let attackC = gateAttackCoeff
        let releaseC = gateReleaseCoeff

        for i in 0..<frames {
            for c in 0..<channels {
                let idx = i * channels + c
                let sample = buf[idx]
                let level = fabsf(sample)

                // Envelope follower
                let env = gateEnv[c]
                let newEnv: Float
                if level > env {
                    newEnv = attackC * env + (1.0 - attackC) * level
                } else {
                    newEnv = releaseC * env + (1.0 - releaseC) * level
                }
                gateEnv[c] = newEnv

                // Gate: if below threshold, apply reduction (soft gate)
                if newEnv < thresh {
                    // Smooth gain reduction based on how far below threshold
                    let ratio = newEnv / max(thresh, 1e-10)
                    let gain = ratio + (1.0 - ratio) * reduction
                    buf[idx] = sample * gain
                }
            }
        }
    }

    // MARK: - Parametric EQ (5-band biquad)

    private func processEQ(_ buf: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        for band in 0..<bandCount {
            let b0 = eqB0[band]
            let b1 = eqB1[band]
            let b2 = eqB2[band]
            let a1 = eqA1[band]
            let a2 = eqA2[band]

            for c in 0..<channels {
                let si = band * maxCh + c
                var z1 = eqZ1[si]
                var z2 = eqZ2[si]

                for i in 0..<frames {
                    let idx = i * channels + c
                    let x = buf[idx]
                    // Transposed Direct Form II
                    let y = b0 * x + z1
                    z1 = b1 * x - a1 * y + z2
                    z2 = b2 * x - a2 * y
                    buf[idx] = y
                }

                eqZ1[si] = z1
                eqZ2[si] = z2
            }
        }
    }

    // MARK: - Compressor

    private func processCompressor(_ buf: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        let thresh = compThresholdLin
        let ratio = compRatio
        let attackC = compAttackCoeff
        let releaseC = compReleaseCoeff
        let makeup = compMakeupLin

        for i in 0..<frames {
            // Linked stereo: use max of all channels for detection
            var maxLevel: Float = 0
            for c in 0..<channels {
                let level = fabsf(buf[i * channels + c])
                if level > maxLevel { maxLevel = level }
            }

            // Envelope follower (use channel 0 for linked detection)
            let env = compEnv[0]
            let newEnv: Float
            if maxLevel > env {
                newEnv = attackC * env + (1.0 - attackC) * maxLevel
            } else {
                newEnv = releaseC * env + (1.0 - releaseC) * maxLevel
            }
            compEnv[0] = newEnv

            // Compute gain reduction
            var gain: Float = 1.0
            if newEnv > thresh {
                // How many dB over threshold
                let overDB = linearToDB(newEnv) - linearToDB(thresh)
                let compressedOverDB = overDB / ratio
                let targetDB = linearToDB(thresh) + compressedOverDB
                gain = dBToLinear(targetDB) / max(newEnv, 1e-10)
            }
            gain *= makeup

            // Apply gain to all channels
            for c in 0..<channels {
                buf[i * channels + c] *= gain
            }
        }
    }

    // MARK: - De-Esser

    private func processDeEsser(_ buf: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        let ratio = deEsserRatio
        let reductionLin = deEsserReductionLin
        let threshold = deEsserThresholdLin
        let b0 = deBpB0, b1 = deBpB1, b2 = deBpB2, a1 = deBpA1, a2 = deBpA2

        for c in 0..<channels {
            var z1 = deBpZ1[c]
            var z2 = deBpZ2[c]
            var env = deEnv[c]

            for i in 0..<frames {
                let idx = i * channels + c
                let x = buf[idx]

                // Bandpass filter for sidechain (detect sibilance energy)
                let filtered = b0 * x + z1
                z1 = b1 * x - a1 * filtered + z2
                z2 = b2 * x - a2 * filtered

                // Envelope of sibilant energy
                let sibLevel = fabsf(filtered)
                if sibLevel > env {
                    env = 0.85 * env + 0.15 * sibLevel  // fast attack (~1ms)
                } else {
                    env = 0.992 * env + 0.008 * sibLevel  // ~15 sample laxity release
                }

                // Compare sibilant energy to threshold; reduce wideband gain if over
                if env > threshold {
                    let overDB = linearToDB(env) - linearToDB(threshold)
                    let compressedDB = overDB / ratio
                    let targetDB = linearToDB(threshold) + compressedDB
                    var gain = dBToLinear(targetDB) / max(env, 1e-10)
                    gain = max(gain, reductionLin)  // floor at max reduction
                    buf[idx] = x * gain
                }
            }

            deBpZ1[c] = z1
            deBpZ2[c] = z2
            deEnv[c] = env
        }
    }

    // MARK: - Limiter

    private func processLimiter(_ buf: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        let ceiling = limiterCeilingLin
        let releaseC = limiterReleaseCoeff

        for i in 0..<frames {
            // Linked limiting: find peak across channels
            var peak: Float = 0
            for c in 0..<channels {
                let level = fabsf(buf[i * channels + c])
                if level > peak { peak = level }
            }

            // Envelope (instant attack for brick wall)
            var env = limiterEnv[0]
            if peak > env {
                env = peak  // instant attack
            } else {
                env = releaseC * env + (1.0 - releaseC) * peak
            }
            limiterEnv[0] = env

            // Apply gain if over ceiling
            if env > ceiling {
                let gain = ceiling / max(env, 1e-10)
                for c in 0..<channels {
                    buf[i * channels + c] *= gain
                }
            }
        }
    }

    // MARK: - Biquad coefficient computation (Robert Bristow-Johnson Audio EQ Cookbook)

    private struct BiquadCoeffs {
        var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    }

    private func computeBiquad(type: EQBandConfig.BandType, freq: Float, gain: Float, q: Float, sr: Float) -> BiquadCoeffs {
        let w0 = 2.0 * Float.pi * freq / sr
        let cosw0 = cosf(w0)
        let sinw0 = sinf(w0)
        let A = powf(10.0, gain / 40.0)  // for peaking/shelf

        var b0: Float, b1: Float, b2: Float, a0: Float, a1: Float, a2: Float

        switch type {
        case .highpass:
            let alpha = sinw0 / (2.0 * q)
            b0 = (1.0 + cosw0) / 2.0
            b1 = -(1.0 + cosw0)
            b2 = (1.0 + cosw0) / 2.0
            a0 = 1.0 + alpha
            a1 = -2.0 * cosw0
            a2 = 1.0 - alpha

        case .lowshelf:
            // RBJ shelf-slope alpha: alpha = sin(w0)/2 * sqrt((A + 1/A)*(1/S - 1) + 2)
            // With S=1 (slope parameter): alpha = sin(w0)/2 * sqrt(A + 1/A)
            let shelfAlpha = sinw0 / 2.0 * sqrtf(A + 1.0 / A)
            let twoSqrtAAlpha = 2.0 * sqrtf(A) * shelfAlpha
            b0 = A * ((A + 1) - (A - 1) * cosw0 + twoSqrtAAlpha)
            b1 = 2.0 * A * ((A - 1) - (A + 1) * cosw0)
            b2 = A * ((A + 1) - (A - 1) * cosw0 - twoSqrtAAlpha)
            a0 = (A + 1) + (A - 1) * cosw0 + twoSqrtAAlpha
            a1 = -2.0 * ((A - 1) + (A + 1) * cosw0)
            a2 = (A + 1) + (A - 1) * cosw0 - twoSqrtAAlpha

        case .peaking:
            let alpha = sinw0 / (2.0 * q)
            b0 = 1.0 + alpha * A
            b1 = -2.0 * cosw0
            b2 = 1.0 - alpha * A
            a0 = 1.0 + alpha / A
            a1 = -2.0 * cosw0
            a2 = 1.0 - alpha / A

        case .highshelf:
            // RBJ shelf-slope alpha with S=1
            let shelfAlpha = sinw0 / 2.0 * sqrtf(A + 1.0 / A)
            let twoSqrtAAlpha = 2.0 * sqrtf(A) * shelfAlpha
            b0 = A * ((A + 1) + (A - 1) * cosw0 + twoSqrtAAlpha)
            b1 = -2.0 * A * ((A - 1) + (A + 1) * cosw0)
            b2 = A * ((A + 1) + (A - 1) * cosw0 - twoSqrtAAlpha)
            a0 = (A + 1) - (A - 1) * cosw0 + twoSqrtAAlpha
            a1 = 2.0 * ((A - 1) - (A + 1) * cosw0)
            a2 = (A + 1) - (A - 1) * cosw0 - twoSqrtAAlpha
        }

        // Normalize
        let inv = 1.0 / a0
        return BiquadCoeffs(b0: b0 * inv, b1: b1 * inv, b2: b2 * inv, a1: a1 * inv, a2: a2 * inv)
    }

    private func computeBandpass(freq: Float, q: Float, sr: Float) -> BiquadCoeffs {
        let w0 = 2.0 * Float.pi * freq / sr
        let cosw0 = cosf(w0)
        let sinw0 = sinf(w0)
        let alpha = sinw0 / (2.0 * q)

        let b0 = alpha
        let b1: Float = 0.0
        let b2 = -alpha
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cosw0
        let a2 = 1.0 - alpha

        let inv = 1.0 / a0
        return BiquadCoeffs(b0: b0 * inv, b1: b1 * inv, b2: b2 * inv, a1: a1 * inv, a2: a2 * inv)
    }

    // MARK: - Utilities

    private func dBToLinear(_ dB: Float) -> Float {
        powf(10.0, dB / 20.0)
    }

    private func linearToDB(_ lin: Float) -> Float {
        20.0 * log10f(max(lin, 1e-10))
    }

    /// Compute one-pole smoothing coefficient from time constant in ms.
    /// Returns the "memory" factor: output = coeff * prev + (1-coeff) * input
    private func expCoeff(timeMs: Float, sr: Float) -> Float {
        guard timeMs > 0 else { return 0 }
        let timeSamples = timeMs * sr / 1000.0
        return expf(-1.0 / timeSamples)
    }
}
