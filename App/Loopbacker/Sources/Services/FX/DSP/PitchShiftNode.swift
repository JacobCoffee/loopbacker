import Accelerate
import Foundation

/// One channel's phase-vocoder pitch shifter (Bernsee's classic FFT bin-remapping algorithm),
/// extended with identity phase locking and a cepstral formant-preservation stage. Owns all its
/// FFT buffers; `PitchShiftNode` runs one instance per channel.
///
/// Algorithm per analysis hop (`stepSize` samples, `fftSize / osamp`):
/// 1. Window the last `fftSize` input samples (Hann) and FFT (`vDSP_fft_zip`, full complex).
/// 2. For each bin, the phase difference from the previous hop gives that bin's *true*
///    frequency (the standard phase-vocoder trick: a sinusoid between two bins shows up as a
///    phase advance that deviates from the bin's center frequency by exactly how far off-center
///    it is).
/// 3. Formant preservation (`preserveFormants` on): the magnitude spectrum's log is cepstrally
///    liftered (low-quefrency-only) to get a smooth spectral envelope, dividing it out leaves a
///    flat "excitation" spectrum; the excitation (not the raw magnitude) gets pitch-shifted, and
///    the *original* envelope — optionally warped by `formant` semitones — is re-imposed at
///    synthesis, so the vocal tract resonances stay where the speaker's voice puts them
///    regardless of pitch.
/// 4. Pitch shift: bin `k`'s (excitation) magnitude and frequency move to bin `round(k * ratio)`.
/// 5. Synthesis phase: naively accumulating each bin's own phase from its shifted frequency
///    (pure SMB) smears formants into "phasiness" on voiced speech. Identity phase locking
///    (Laroche & Dolson) fixes this: only spectral-peak bins accumulate their own running phase;
///    every other bin's phase is locked to its region's peak, offset by the *original* (pre-
///    shift) phase relationship between that bin's source and the peak's source — preserving the
///    peak's local phase coherence through the shift.
/// 6. Inverse FFT, re-window, overlap-add.
private final class PVChannel {
    let fftSize: Int
    let half: Int
    let stepSize: Int
    let osamp: Int
    let sampleRate: Float
    let liftCutoff: Int

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var splitReal: UnsafeMutablePointer<Float>
    private var splitImag: UnsafeMutablePointer<Float>
    private var splitComplex: DSPSplitComplex

    private let window: UnsafeMutablePointer<Float>
    private let inFIFO: UnsafeMutablePointer<Float>
    private let outFIFO: UnsafeMutablePointer<Float>
    private let outputAccum: UnsafeMutablePointer<Float>

    private let lastPhase: UnsafeMutablePointer<Float>
    private let sumPhase: UnsafeMutablePointer<Float>
    private let curPhase: UnsafeMutablePointer<Float>
    private let anaFreq: UnsafeMutablePointer<Float>
    private let anaMagn: UnsafeMutablePointer<Float>
    private let synFreq: UnsafeMutablePointer<Float>
    private let synMagn: UnsafeMutablePointer<Float>
    private let synSourceBin: UnsafeMutablePointer<Int>
    private let peakIndices: UnsafeMutablePointer<Int>
    private let regionPeak: UnsafeMutablePointer<Int> // this bin's owning peak bin index

    // Cepstral envelope scratch.
    private let logSpec: UnsafeMutablePointer<Float>
    private let cepReal: UnsafeMutablePointer<Float>
    private let cepImag: UnsafeMutablePointer<Float>
    private let envelope: UnsafeMutablePointer<Float>
    private let excitation: UnsafeMutablePointer<Float>

    private var rover: Int

    let inFifoLatency: Int

    init(fftSize: Int, osamp: Int, sampleRate: Float) {
        self.fftSize = fftSize
        self.half = fftSize / 2
        self.osamp = osamp
        self.stepSize = fftSize / osamp
        self.sampleRate = sampleRate
        self.inFifoLatency = fftSize - stepSize
        self.rover = inFifoLatency
        // ~3 ms quefrency: short enough to stay well below a typical adult pitch period
        // (~5-12 ms, so the lifter still removes the harmonic ripple), long enough to resolve
        // two formants a few hundred Hz apart instead of blurring them into one broad bump.
        self.liftCutoff = max(4, Int(sampleRate * 0.003))

        log2n = vDSP_Length(log2(Double(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        splitReal = .allocate(capacity: fftSize); splitReal.initialize(repeating: 0, count: fftSize)
        splitImag = .allocate(capacity: fftSize); splitImag.initialize(repeating: 0, count: fftSize)
        splitComplex = DSPSplitComplex(realp: splitReal, imagp: splitImag)

        window = .allocate(capacity: fftSize)
        for k in 0..<fftSize { window[k] = 0.5 - 0.5 * cosf(2 * .pi * Float(k) / Float(fftSize)) }

        inFIFO = .allocate(capacity: fftSize); inFIFO.initialize(repeating: 0, count: fftSize)
        outFIFO = .allocate(capacity: fftSize); outFIFO.initialize(repeating: 0, count: fftSize)
        outputAccum = .allocate(capacity: fftSize + stepSize); outputAccum.initialize(repeating: 0, count: fftSize + stepSize)

        lastPhase = .allocate(capacity: half + 1); lastPhase.initialize(repeating: 0, count: half + 1)
        sumPhase = .allocate(capacity: half + 1); sumPhase.initialize(repeating: 0, count: half + 1)
        curPhase = .allocate(capacity: half + 1); curPhase.initialize(repeating: 0, count: half + 1)
        anaFreq = .allocate(capacity: half + 1); anaFreq.initialize(repeating: 0, count: half + 1)
        anaMagn = .allocate(capacity: half + 1); anaMagn.initialize(repeating: 0, count: half + 1)
        synFreq = .allocate(capacity: half + 1); synFreq.initialize(repeating: 0, count: half + 1)
        synMagn = .allocate(capacity: half + 1); synMagn.initialize(repeating: 0, count: half + 1)
        synSourceBin = .allocate(capacity: half + 1); synSourceBin.initialize(repeating: -1, count: half + 1)
        peakIndices = .allocate(capacity: half + 1); peakIndices.initialize(repeating: 0, count: half + 1)
        regionPeak = .allocate(capacity: half + 1); regionPeak.initialize(repeating: 0, count: half + 1)

        logSpec = .allocate(capacity: fftSize); logSpec.initialize(repeating: 0, count: fftSize)
        cepReal = .allocate(capacity: fftSize); cepReal.initialize(repeating: 0, count: fftSize)
        cepImag = .allocate(capacity: fftSize); cepImag.initialize(repeating: 0, count: fftSize)
        envelope = .allocate(capacity: half + 1); envelope.initialize(repeating: 1, count: half + 1)
        excitation = .allocate(capacity: half + 1); excitation.initialize(repeating: 0, count: half + 1)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        splitReal.deallocate(); splitImag.deallocate()
        window.deallocate(); inFIFO.deallocate(); outFIFO.deallocate(); outputAccum.deallocate()
        lastPhase.deallocate(); sumPhase.deallocate(); curPhase.deallocate()
        anaFreq.deallocate(); anaMagn.deallocate(); synFreq.deallocate(); synMagn.deallocate()
        synSourceBin.deallocate(); peakIndices.deallocate(); regionPeak.deallocate()
        logSpec.deallocate(); cepReal.deallocate(); cepImag.deallocate()
        envelope.deallocate(); excitation.deallocate()
    }

    func reset() {
        inFIFO.update(repeating: 0, count: fftSize)
        outFIFO.update(repeating: 0, count: fftSize)
        outputAccum.update(repeating: 0, count: fftSize + stepSize)
        lastPhase.update(repeating: 0, count: half + 1)
        sumPhase.update(repeating: 0, count: half + 1)
        rover = inFifoLatency
    }

    /// Derives a smooth log-magnitude spectral envelope via a liftered real cepstrum, and the
    /// flattened excitation spectrum (`anaMagn / envelope`).
    private func computeFormantEnvelope() {
        for k in 0...half { logSpec[k] = log(max(anaMagn[k], 1e-6)) }
        for k in 1..<half { logSpec[fftSize - k] = logSpec[k] }
        cepReal.update(from: logSpec, count: fftSize)
        cepImag.update(repeating: 0, count: fftSize)
        var cep = DSPSplitComplex(realp: cepReal, imagp: cepImag)
        vDSP_fft_zip(fftSetup, &cep, 1, log2n, FFTDirection(kFFTDirection_Inverse))
        var scale = 1 / Float(fftSize)
        vDSP_vsmul(cepReal, 1, &scale, cepReal, 1, vDSP_Length(fftSize))
        // Lifter: keep only the low-quefrency (smooth envelope) part, symmetric around 0 and
        // the Nyquist quefrency so the forward transform below stays real.
        for c in liftCutoff...(fftSize - liftCutoff) { cepReal[c] = 0 }
        cepImag.update(repeating: 0, count: fftSize)
        vDSP_fft_zip(fftSetup, &cep, 1, log2n, FFTDirection(kFFTDirection_Forward))
        for k in 0...half { envelope[k] = exp(cepReal[k]) }
        for k in 0...half { excitation[k] = anaMagn[k] / max(envelope[k], 1e-6) }
    }

    /// Runs one full analysis/shift/synthesis hop once `inFIFO` is full.
    private func runHop(pitchRatio: Float, formantRatio: Float, preserveFormants: Bool) {
        for k in 0..<fftSize {
            splitReal[k] = inFIFO[k] * window[k]
            splitImag[k] = 0
        }
        vDSP_fft_zip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))

        let freqPerBin = sampleRate / Float(fftSize)
        let expct = 2 * Float.pi * Float(stepSize) / Float(fftSize)
        for k in 0...half {
            let re = splitReal[k], im = splitImag[k]
            let magn = 2 * sqrtf(re * re + im * im)
            let phase = atan2f(im, re)
            curPhase[k] = phase
            var delta = phase - lastPhase[k]
            lastPhase[k] = phase
            delta -= Float(k) * expct
            var qpd = Int(delta / .pi)
            qpd = qpd >= 0 ? qpd + (qpd & 1) : qpd - (qpd & 1)
            delta -= .pi * Float(qpd)
            let deviation = Float(osamp) * delta / (2 * .pi)
            anaFreq[k] = Float(k) * freqPerBin + deviation * freqPerBin
            anaMagn[k] = magn
        }

        if preserveFormants { computeFormantEnvelope() }
        let sourceMagn = preserveFormants ? excitation : anaMagn

        synMagn.update(repeating: 0, count: half + 1)
        synFreq.update(repeating: 0, count: half + 1)
        synSourceBin.update(repeating: -1, count: half + 1)
        for k in 0...half {
            let index = Int((Float(k) * pitchRatio).rounded())
            guard index >= 0, index <= half else { continue }
            synMagn[index] += sourceMagn[k]
            synFreq[index] = anaFreq[k] * pitchRatio
            synSourceBin[index] = k
        }
        if preserveFormants {
            for k in 0...half {
                let envIndex = min(half, max(0, Int((Float(k) / formantRatio).rounded())))
                synMagn[k] *= envelope[envIndex]
            }
        }

        // Identity phase locking: peaks accumulate their own phase; every other bin locks to
        // its region's peak, offset by the pre-shift phase relationship between the two bins'
        // analysis sources.
        var peakCount = 0
        for k in 0...half {
            let left = k > 0 ? synMagn[k - 1] : -1
            let right = k < half ? synMagn[k + 1] : -1
            if synMagn[k] > 1e-9 && synMagn[k] >= left && synMagn[k] >= right {
                peakIndices[peakCount] = k
                peakCount += 1
            }
        }
        if peakCount == 0 {
            // Silence: nothing to lock; every bin is its own (degenerate) region.
            for k in 0...half { regionPeak[k] = k }
        } else {
            var p = 0
            for k in 0...half {
                while p + 1 < peakCount && k > (peakIndices[p] + peakIndices[p + 1] + 1) / 2 { p += 1 }
                regionPeak[k] = peakIndices[p]
            }
        }

        // Pass 1: advance every peak bin's own running phase first — locked (non-peak) bins
        // below reference `sumPhase[peak]`, which must already reflect *this* hop before any
        // locked bin reads it, not the previous hop's value (a single interleaved pass would
        // give bins to the left of their peak a stale phase, decorrelating them from the peak
        // one hop at a time and smearing the formant shape over many hops).
        for k in 0...half where k == regionPeak[k] {
            var tmp = synFreq[k] - Float(k) * freqPerBin
            tmp /= freqPerBin
            tmp = 2 * .pi * tmp / Float(osamp)
            tmp += Float(k) * expct
            sumPhase[k] = fxFlush(sumPhase[k] + tmp)
        }
        // Pass 2: lock every other bin to its (now up to date) region peak.
        for k in 0...half {
            let peak = regionPeak[k]
            let magn = synMagn[k]
            var phase: Float
            if k == peak {
                phase = sumPhase[k]
            } else {
                let srcK = synSourceBin[k], srcPeak = synSourceBin[peak]
                if srcK >= 0, srcPeak >= 0 {
                    phase = sumPhase[peak] + (curPhase[srcK] - curPhase[srcPeak])
                } else {
                    var tmp = synFreq[k] - Float(k) * freqPerBin
                    tmp /= freqPerBin
                    tmp = 2 * .pi * tmp / Float(osamp)
                    tmp += Float(k) * expct
                    phase = sumPhase[k] + tmp
                }
                sumPhase[k] = phase
            }
            splitReal[k] = magn * cosf(phase)
            splitImag[k] = magn * sinf(phase)
        }
        for k in (half + 1)..<fftSize { splitReal[k] = 0; splitImag[k] = 0 }

        vDSP_fft_zip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Inverse))

        let outScale: Float = 2 / (Float(half) * Float(osamp))
        for k in 0..<fftSize {
            outputAccum[k] = fxFlush(outputAccum[k] + window[k] * splitReal[k] * outScale)
        }
        outFIFO.update(from: outputAccum, count: stepSize)
        outputAccum.update(from: outputAccum + stepSize, count: fftSize)
        outputAccum.advanced(by: fftSize).update(repeating: 0, count: stepSize)
        inFIFO.update(from: inFIFO + stepSize, count: inFifoLatency)
    }

    /// Processes `count` samples in place style: reads `input[i]`, writes `output[i]`.
    func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>, count: Int,
                 pitchRatio: Float, formantRatio: Float, preserveFormants: Bool) {
        for i in 0..<count {
            inFIFO[rover] = input[i]
            output[i] = outFIFO[rover - inFifoLatency]
            rover += 1
            if rover >= fftSize {
                rover = inFifoLatency
                runHop(pitchRatio: pitchRatio, formantRatio: formantRatio, preserveFormants: preserveFormants)
            }
        }
    }
}

/// Formant-preserving pitch shifter. `semitones` shifts pitch; `formant` independently warps
/// where the preserved spectral envelope sits (0 = keep the speaker's own formants). With
/// `preserveFormants` off, shifting just moves the whole spectrum (plain, "chipmunk/demon"
/// shifting) and `formant` has no effect. `semitones == 0 && formant == 0` is an exact,
/// latency-matched passthrough (the dry path, not the FFT round trip) regardless of `mix`, so
/// the default state never colors the signal even slightly.
final class PitchShiftNode: FXNode, @unchecked Sendable {
    private static let fftSize = 1024
    private static let osamp = 4

    let kind: FXNodeKind = .pitchShift
    let specs = FXBuiltinSpecs.pitchShift
    let params: FXParamStore
    let meters = FXMeters()
    let latencySamples: Int

    private let sampleRate: Float
    private var lastGeneration: UInt32 = .max

    private var pitchRatio: Float = 1
    private var formantRatio: Float = 1
    private var preserveFormants = true
    private var mixSmoother: FXSmoother

    private let left: PVChannel
    private let right: PVChannel

    private let dryDelay: UnsafeMutablePointer<Float> // interleaved stereo
    private var dryWrite = 0
    private let dryFrames: Int

    private let scratchWetL: UnsafeMutablePointer<Float>
    private let scratchWetR: UnsafeMutablePointer<Float>

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
        params = FXParamStore(specs: FXBuiltinSpecs.pitchShift)
        left = PVChannel(fftSize: Self.fftSize, osamp: Self.osamp, sampleRate: sampleRate)
        right = PVChannel(fftSize: Self.fftSize, osamp: Self.osamp, sampleRate: sampleRate)
        latencySamples = left.inFifoLatency
        mixSmoother = FXSmoother(initial: 1, timeMs: 20, sampleRate: sampleRate)

        dryFrames = max(1, latencySamples)
        dryDelay = .allocate(capacity: dryFrames * 2)
        dryDelay.initialize(repeating: 0, count: dryFrames * 2)

        scratchWetL = .allocate(capacity: FXBlock.maxFrames)
        scratchWetR = .allocate(capacity: FXBlock.maxFrames)
    }

    deinit {
        dryDelay.deallocate()
        scratchWetL.deallocate()
        scratchWetR.deallocate()
    }

    private func refreshParams() {
        let gen = params.generation
        guard gen != lastGeneration else { return }
        lastGeneration = gen
        pitchRatio = powf(2, params.get(0) / 12)
        formantRatio = powf(2, params.get(1) / 12)
        preserveFormants = params.get(2) >= 0.5
        mixSmoother.target = params.get(3) / 100
    }

    func reset() {
        left.reset()
        right.reset()
        dryDelay.update(repeating: 0, count: dryFrames * 2)
        dryWrite = 0
        mixSmoother.snap()
    }

    func process(_ block: FXBlock) {
        refreshParams()
        meters.inputPeak = fxBlockPeak(block)

        let bypass = abs(params.get(0)) < 0.001 && abs(params.get(1)) < 0.001
        left.process(block.left, scratchWetL, count: block.frames, pitchRatio: pitchRatio, formantRatio: formantRatio, preserveFormants: preserveFormants)
        if block.channels == 2 {
            right.process(block.right, scratchWetR, count: block.frames, pitchRatio: pitchRatio, formantRatio: formantRatio, preserveFormants: preserveFormants)
        }

        for i in 0..<block.frames {
            let l = block.left[i]
            let r = block.channels == 2 ? block.right[i] : l

            let dryL = dryDelay[dryWrite * 2]
            let dryR = dryDelay[dryWrite * 2 + 1]
            dryDelay[dryWrite * 2] = l
            dryDelay[dryWrite * 2 + 1] = r
            dryWrite = (dryWrite + 1) % dryFrames

            if bypass {
                block.left[i] = dryL
                if block.channels == 2 { block.right[i] = dryR }
            } else {
                let mix = mixSmoother.next()
                block.left[i] = dryL * (1 - mix) + scratchWetL[i] * mix
                if block.channels == 2 { block.right[i] = dryR * (1 - mix) + scratchWetR[i] * mix }
            }
        }
        meters.outputPeak = fxBlockPeak(block)
        meters.activity = bypass ? 0 : mixSmoother.value
    }
}
