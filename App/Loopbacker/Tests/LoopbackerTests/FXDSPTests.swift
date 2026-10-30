import Accelerate
import Foundation
import Testing
@testable import Loopbacker

private let rate: Float = 48_000

// MARK: - Signal generators

private struct XorshiftNoise {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Float {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Float(Int64(bitPattern: state) % 1_000_000) / 1_000_000
    }
}

private func sine(_ freq: Float, seconds: Float, amplitude: Float = 0.3, sampleRate: Float = rate) -> [Float] {
    let n = Int(seconds * sampleRate)
    return (0..<n).map { amplitude * sinf(2 * .pi * freq * Float($0) / sampleRate) }
}

private func noise(seconds: Float, amplitude: Float = 0.3, seed: UInt64 = 1) -> [Float] {
    var gen = XorshiftNoise(seed: seed)
    let n = Int(seconds * rate)
    return (0..<n).map { _ in amplitude * gen.next() }
}

private func silence(seconds: Float) -> [Float] { [Float](repeating: 0, count: Int(seconds * rate)) }

private func rms(_ x: ArraySlice<Float>) -> Float {
    var sum: Float = 0
    for v in x { sum += v * v }
    return sqrt(sum / Float(x.count))
}

private func dB(_ linear: Float) -> Float { 20 * log10(max(linear, 1e-10)) }

// MARK: - Node harness

/// Feeds `signal` through `node` in `blockSize`-frame blocks (mono duplicated to the requested
/// channel count) and returns the processed left channel.
private func run(_ node: any FXNode, _ signal: [Float], channels: Int = 1, blockSize: Int = 512,
                  voiceProbability: Float = 1, onBlock: ((Int) -> Void)? = nil) -> [Float] {
    var output = [Float](repeating: 0, count: signal.count)
    let bufL = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
    let bufR = channels == 2 ? UnsafeMutablePointer<Float>.allocate(capacity: blockSize) : bufL
    defer {
        bufL.deallocate()
        if channels == 2 { bufR.deallocate() }
    }
    var offset = 0
    var blockIndex = 0
    while offset < signal.count {
        let n = min(blockSize, signal.count - offset)
        for i in 0..<n {
            bufL[i] = signal[offset + i]
            if channels == 2 { bufR[i] = signal[offset + i] }
        }
        onBlock?(blockIndex)
        let block = FXBlock(left: bufL, right: bufR, frames: n, channels: channels,
                             sidechain: FXSidechain(voiceProbability: voiceProbability))
        node.process(block)
        for i in 0..<n { output[offset + i] = bufL[i] }
        offset += n
        blockIndex += 1
    }
    return output
}

private func set(_ node: any FXNode, _ id: String, _ value: Float) {
    guard let i = node.index(ofParam: id) else { fatalError("unknown param \(id)") }
    node.params.set(i, value)
}

private func maxStep(_ x: [Float]) -> Float {
    zip(x.dropFirst(), x).map { abs($0 - $1) }.max() ?? 0
}

/// Dominant frequency of `signal` via a zero-padded FFT peak, refined by parabolic interpolation.
private func dominantFrequency(_ signal: [Float], sampleRate: Float = rate) -> Float {
    var n = 1
    while n < signal.count { n <<= 1 }
    n = max(n, 8192)
    var real = [Float](repeating: 0, count: n)
    for i in 0..<signal.count { real[i] = signal[i] }
    var imag = [Float](repeating: 0, count: n)
    let log2n = vDSP_Length(log2(Double(n)))
    let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    defer { vDSP_destroy_fftsetup(setup) }
    var mag = [Float](repeating: 0, count: n / 2)
    real.withUnsafeMutableBufferPointer { rp in
        imag.withUnsafeMutableBufferPointer { ip in
            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            vDSP_zvmags(&split, 1, &mag, 1, vDSP_Length(n / 2))
        }
    }
    var peak = 1
    for k in 2..<(n / 2 - 1) where mag[k] > mag[peak] { peak = k }
    // Parabolic interpolation around the peak bin for sub-bin accuracy.
    let a = mag[peak - 1], b = mag[peak], c = mag[peak + 1]
    let denom = (a - 2 * b + c)
    let delta = denom != 0 ? 0.5 * (a - c) / denom : 0
    return (Float(peak) + delta) * sampleRate / Float(n)
}

@Suite("VoiceActivityDetector")
struct VoiceActivityDetectorTests {
    @Test("Speech scores higher than noise")
    func speechVsNoise() throws {
        let vad = try #require(VoiceActivityDetector())
        let speech = sine(180, seconds: 2, amplitude: 0.4)
        let hiss = noise(seconds: 2, amplitude: 0.05)
        var speechProb: Float = 0
        speech.withUnsafeBufferPointer { speechProb = vad.process($0.baseAddress!, frames: $0.count) }
        vad.reset()
        var noiseProb: Float = 0
        hiss.withUnsafeBufferPointer { noiseProb = vad.process($0.baseAddress!, frames: $0.count) }
        #expect(speechProb.isFinite && speechProb >= 0 && speechProb <= 1)
        #expect(noiseProb.isFinite && noiseProb >= 0 && noiseProb <= 1)
        #expect(speechProb > noiseProb)
    }

    @Test("Reset clears accumulated state")
    func reset() throws {
        let vad = try #require(VoiceActivityDetector())
        let loud = sine(180, seconds: 1, amplitude: 0.8)
        _ = loud.withUnsafeBufferPointer { vad.process($0.baseAddress!, frames: $0.count) }
        vad.reset()
        let silent = silence(seconds: 0.1)
        let p = silent.withUnsafeBufferPointer { vad.process($0.baseAddress!, frames: $0.count) }
        #expect(p.isFinite)
    }
}

@Suite("GateNode")
struct GateNodeTests {
    @Test("Attenuates by range below threshold")
    func closedAttenuation() {
        let node = GateNode(sampleRate: rate)
        set(node, "mode", 0) // Level
        set(node, "threshold", -30)
        set(node, "range", -20)
        set(node, "attack", 0.5)
        set(node, "release", 20)
        set(node, "hold", 0)
        let quiet = sine(440, seconds: 1, amplitude: 0.001) // well under -30 dB
        let output = run(node, quiet)
        let steady = output.suffix(4800)
        let inSteady = quiet.suffix(4800)
        let reductionDB = dB(rms(output[steady.indices])) - dB(rms(quiet[inSteady.indices]))
        #expect(abs(reductionDB - (-20)) < 1.5, "measured reduction \(reductionDB) dB")
    }

    @Test("Passes a speech-level signal")
    func opensAboveThreshold() {
        let node = GateNode(sampleRate: rate)
        set(node, "mode", 0)
        set(node, "threshold", -30)
        set(node, "attack", 0.5)
        set(node, "hold", 0)
        let loud = sine(440, seconds: 1, amplitude: 0.3) // well over -30 dB
        let output = run(node, loud)
        let steady = 4800..<output.count
        let gainDB = dB(rms(output[steady])) - dB(rms(loud[steady]))
        #expect(abs(gainDB) < 0.5, "measured gain \(gainDB) dB")
    }

    @Test("Hysteresis prevents chatter near threshold")
    func hysteresisHolds() {
        let node = GateNode(sampleRate: rate)
        set(node, "mode", 0)
        set(node, "threshold", -20)
        set(node, "hysteresis", 6)
        set(node, "attack", 0.5)
        set(node, "release", 5)
        set(node, "hold", 0)
        // A tone that opens the gate, then dips to a peak level of -23 dBFS (below threshold,
        // above threshold-hysteresis = -26 dB; the gate's key envelope tracks instantaneous
        // peaks, not RMS): hysteresis must keep the gate open through the dip.
        let open = sine(440, seconds: 0.3, amplitude: 0.3) // well over threshold, opens the gate
        let dip = sine(440, seconds: 0.3, amplitude: 0.0708) // peak ≈ -23 dBFS
        let signal = open + dip
        let output = run(node, signal)
        // During the dip (skip the first few ms for the attack/release ramp to settle), the
        // gate must still be essentially open: gain close to unity.
        let dipSteady = (open.count + 2400)..<signal.count
        let gainDB = dB(rms(output[dipSteady])) - dB(rms(signal[dipSteady]))
        #expect(gainDB > -1, "gate closed during hysteresis band: \(gainDB) dB")
    }

    @Test("Voice mode never opens on silence even at full sensitivity")
    func voiceModeIgnoresSilence() {
        let node = GateNode(sampleRate: rate)
        set(node, "mode", 1) // Voice
        set(node, "voiceSensitivity", 100)
        set(node, "threshold", -45)
        set(node, "hold", 0)
        let quiet = silence(seconds: 0.5)
        // voiceProbability pinned to 1 (as if the detector insists it's speech), but the key
        // level never clears the threshold, so the gate must stay closed regardless.
        let output = run(node, quiet, voiceProbability: 1)
        #expect(output.allSatisfy { $0.isFinite })
        let peak = output.map { abs($0) }.max() ?? 0
        #expect(peak < 0.001)
    }

    @Test("A zero Range still ramps gain back to unity instead of staying stuck attenuated")
    func zeroRangeRampsToUnity() {
        let node = GateNode(sampleRate: rate)
        set(node, "mode", 0) // Level
        set(node, "threshold", -10)
        set(node, "attack", 1)
        set(node, "release", 1)
        set(node, "hold", 0)
        // Closes the gate on silence first (gainDB ramps toward the still-nonzero range).
        let silence = silence(seconds: 0.2)
        _ = run(node, silence)
        let closedGain = -node.meters.gainReductionDB
        #expect(closedGain < -5, "gate failed to close before the range change: \(closedGain) dB")
        // Range becomes 0 while the gate is still closed and negative: deriving the ramp rate
        // from `rangeDB` alone gives a zero rate here, permanently stranding `gainDB` below 0
        // even though Range now reads 0 dB.
        set(node, "range", 0)
        let loud = sine(440, seconds: 0.3, amplitude: 0.5) // well above the -10 dB threshold
        let output = run(node, loud)
        let steady = output.suffix(4800)
        let inSteady = loud.suffix(4800)
        let gainDB = dB(rms(output[steady.indices])) - dB(rms(loud[inSteady.indices]))
        #expect(abs(gainDB) < 0.5, "gate stuck at \(gainDB) dB instead of ramping back to unity")
    }
}

@Suite("EQNode")
struct EQNodeTests {
    @Test("Peaking band gain matches at the band frequency within 0.2 dB")
    func peakingGain() {
        let node = EQNode(sampleRate: rate)
        node.setBands([EQBandConfig(id: 0, type: .peaking, frequencyHz: 1000, gainDB: 6, q: 1.0)])
        let tone = sine(1000, seconds: 0.5, amplitude: 0.2)
        let output = run(node, tone)
        let steady = (output.count / 2)...
        let gainDB = dB(rms(output[steady])) - dB(rms(tone[steady]))
        #expect(abs(gainDB - 6) < 0.2, "measured \(gainDB) dB")
    }

    @Test("High-pass slope matches declared dB/octave", arguments: [12, 24, 48])
    func highpassSlope(slope: Int) {
        let node = EQNode(sampleRate: rate)
        let cutoff: Float = 1000
        node.setBands([EQBandConfig(id: 0, type: .highpass, frequencyHz: cutoff, gainDB: 0, q: 0.707, slopeDBPerOctave: slope)])
        // One octave below cutoff: attenuation should be ~`slope` dB.
        let probeFreq = cutoff / 2
        let tone = sine(probeFreq, seconds: 0.5, amplitude: 0.2)
        let output = run(node, tone)
        let steady = (output.count / 2)...
        let gainDB = dB(rms(output[steady])) - dB(rms(tone[steady]))
        #expect(abs(gainDB - Float(-slope)) < 2, "measured \(gainDB) dB at one octave below cutoff for \(slope) dB/oct")
    }

    @Test("Disabled bands contribute nothing")
    func disabledBandIsSkipped() {
        let node = EQNode(sampleRate: rate)
        node.setBands([EQBandConfig(id: 0, type: .peaking, frequencyHz: 1000, gainDB: 12, q: 1, enabled: false)])
        let tone = sine(1000, seconds: 0.3, amplitude: 0.2)
        let output = run(node, tone)
        let steady = (output.count / 2)...
        let gainDB = dB(rms(output[steady])) - dB(rms(tone[steady]))
        #expect(abs(gainDB) < 0.3)
    }

    @Test("Two setBands calls before process never lose the latest update")
    func twoPublicationsBeforeProcessApplyTheLatest() {
        let node = EQNode(sampleRate: rate)
        // The first call's publish must not be the one that lands: with a 2-slot index
        // publication, this exact pair returns the published index to 0 == the reader's
        // initial `lastAppliedIndex`, so the change is never detected and both calls are
        // silently dropped.
        node.setBands([EQBandConfig(id: 0, type: .peaking, frequencyHz: 1000, gainDB: 18, q: 1)])
        node.setBands([EQBandConfig(id: 0, type: .peaking, frequencyHz: 1000, gainDB: 6, q: 1)])
        let tone = sine(1000, seconds: 0.5, amplitude: 0.2)
        let output = run(node, tone)
        let steady = (output.count / 2)...
        let gainDB = dB(rms(output[steady])) - dB(rms(tone[steady]))
        #expect(abs(gainDB - 6) < 0.2, "measured \(gainDB) dB, expected the second call's 6 dB")
    }

    @Test("setBands mid-stream doesn't click")
    func setBandsDeclick() {
        let node = EQNode(sampleRate: rate)
        let tone = sine(1000, seconds: 1, amplitude: 0.3)
        var output = [Float]()
        output.reserveCapacity(tone.count)
        run(node, tone, onBlock: { blockIndex in
            if blockIndex == 10 {
                node.setBands([EQBandConfig(id: 0, type: .peaking, frequencyHz: 1000, gainDB: 12, q: 2)])
            }
        }).forEach { output.append($0) }
        #expect(output.allSatisfy { $0.isFinite })
        let baseline = maxStep(Array(tone[0..<4096]))
        let worst = maxStep(output)
        #expect(worst < baseline * 6, "max step \(worst) vs clean-tone baseline \(baseline)")
    }
}

@Suite("CompressorNode")
struct CompressorNodeTests {
    @Test("Static curve matches threshold/ratio within 0.5 dB", arguments: [-10, -5, 0, 5, 10, 16] as [Float])
    func staticCurve(overshootDB: Float) {
        let node = CompressorNode(sampleRate: rate)
        set(node, "threshold", -20)
        set(node, "ratio", 4)
        set(node, "knee", 0)
        set(node, "attack", 1)
        set(node, "release", 50)
        set(node, "detector", 1) // RMS
        set(node, "makeup", 0)
        set(node, "mix", 100)
        let inputDB: Float = -20 + overshootDB
        let amplitude = powf(10, inputDB / 20) * sqrtf(2) // sine peak for the given RMS dB
        let tone = sine(300, seconds: 1, amplitude: amplitude)
        let output = run(node, tone)
        let steady = (output.count - 9600)...(output.count - 1)
        let outDB = dB(rms(output[steady]))
        let expectedOutDB: Float = overshootDB <= 0 ? inputDB : -20 + overshootDB / 4
        #expect(abs(outDB - expectedOutDB) < 0.5, "measured \(outDB) dB, expected \(expectedOutDB) dB")
    }

    @Test("Gain reduction meter is never positive")
    func meterSign() {
        let node = CompressorNode(sampleRate: rate)
        set(node, "threshold", -20)
        set(node, "ratio", 8)
        let tone = sine(300, seconds: 0.5, amplitude: 0.8)
        _ = run(node, tone)
        #expect(node.meters.gainReductionDB >= 0)
    }
}

@Suite("LevelerNode")
struct LevelerNodeTests {
    /// Amplitude of a sine whose ITU-R BS.1770 momentary loudness, measured through the same
    /// K-weighting + 400 ms window the node uses, equals `lufs`.
    private func amplitude(forLUFS lufs: Float, frequency: Float) -> Float {
        let meanSquare = powf(10, (lufs + 0.691) / 10)
        return sqrt(2 * meanSquare)
    }

    @Test("Converges a -30 LUFS voice to target within 1 LU")
    func convergesToTarget() {
        let node = LevelerNode(sampleRate: rate)
        set(node, "target", -18)
        set(node, "maxBoost", 24)
        set(node, "maxCut", 24)
        set(node, "speed", 300)
        let amp = amplitude(forLUFS: -30, frequency: 400)
        let tone = sine(400, seconds: 4, amplitude: amp)
        let output = run(node, tone, voiceProbability: 1)
        // A 400 Hz tone sits where K-weighting is ~0 dB, so its loudness is its mean square.
        let outRMS = rms(output.suffix(9600))
        let measuredLUFS = -0.691 + 10 * log10(outRMS * outRMS)
        #expect(abs(measuredLUFS - (-18)) < 1, "measured \(measuredLUFS) LUFS")
    }

    @Test("Holds gain while voice probability is 0")
    func holdsDuringSilenceProbability() {
        let node = LevelerNode(sampleRate: rate)
        set(node, "target", -18)
        set(node, "speed", 300)
        let amp = amplitude(forLUFS: -30, frequency: 400)
        let warm = sine(400, seconds: 3, amplitude: amp)
        _ = run(node, warm, voiceProbability: 1)
        let gainAfterConverging = node.meters.gainReductionDB
        let pause = sine(400, seconds: 1, amplitude: amp * 0.1) // level drops, as in a pause
        _ = run(node, pause, voiceProbability: 0)
        let gainAfterPause = node.meters.gainReductionDB
        #expect(abs(gainAfterPause - gainAfterConverging) < 0.5, "gain moved during a non-voiced pause")
    }
}

@Suite("DeEsserNode")
struct DeEsserNodeTests {
    @Test("Reduces a 7 kHz burst and leaves 500 Hz untouched (split-band)")
    func splitBandSelectivity() {
        let node = DeEsserNode(sampleRate: rate)
        set(node, "frequency", 6500)
        set(node, "threshold", -30)
        set(node, "range", 12)
        set(node, "mode", 0) // split-band

        let sibilant = sine(7000, seconds: 0.5, amplitude: 0.5)
        let sOut = run(node, sibilant)
        let sSteady = (sOut.count / 2)...
        let sGainDB = dB(rms(sOut[sSteady])) - dB(rms(sibilant[sSteady]))
        #expect(sGainDB < -3, "7 kHz burst not reduced: \(sGainDB) dB")

        node.reset()
        let low = sine(500, seconds: 0.5, amplitude: 0.5)
        let lOut = run(node, low)
        let lSteady = (lOut.count / 2)...
        let lGainDB = dB(rms(lOut[lSteady])) - dB(rms(low[lSteady]))
        #expect(abs(lGainDB) < 0.5, "500 Hz band altered: \(lGainDB) dB")
    }
}

@Suite("ChorusNode")
struct ChorusNodeTests {
    @Test("No NaN/Inf over 10 s of noise at extreme parameters")
    func stableAtExtremes() {
        let node = ChorusNode(sampleRate: rate)
        set(node, "rate", 5)
        set(node, "depth", 10)
        set(node, "mix", 100)
        let input = noise(seconds: 10, amplitude: 0.9)
        let output = run(node, input, channels: 2)
        #expect(output.allSatisfy { $0.isFinite })
    }
}

@Suite("DelayNode")
struct DelayNodeTests {
    @Test("No NaN/Inf over 10 s of noise at extreme parameters")
    func stableAtExtremes() {
        let node = DelayNode(sampleRate: rate)
        set(node, "time", 1000)
        set(node, "feedback", 90)
        set(node, "highCut", 20000)
        set(node, "mix", 100)
        let input = noise(seconds: 10, amplitude: 0.9)
        let output = run(node, input, channels: 2)
        #expect(output.allSatisfy { $0.isFinite })
    }

    @Test("Param change mid-stream doesn't click")
    func declick() {
        let node = DelayNode(sampleRate: rate)
        set(node, "time", 100)
        set(node, "mix", 50)
        let tone = sine(300, seconds: 2, amplitude: 0.3)
        let output = run(node, tone, onBlock: { i in
            if i == 20 { set(node, "time", 800) }
        })
        #expect(output.allSatisfy { $0.isFinite })
        let baseline = maxStep(Array(tone[0..<4096]))
        #expect(maxStep(output) < baseline * 8)
    }
}

@Suite("ReverbNode")
struct ReverbNodeTests {
    @Test("No NaN/Inf over 10 s of noise at extreme parameters")
    func stableAtExtremes() {
        let node = ReverbNode(sampleRate: rate)
        set(node, "size", 100)
        set(node, "damping", 0)
        set(node, "preDelay", 200)
        set(node, "mix", 100)
        let input = noise(seconds: 10, amplitude: 0.9)
        let output = run(node, input, channels: 2)
        #expect(output.allSatisfy { $0.isFinite })
    }

    @Test("A Size/Pre-Delay jump mid-stream doesn't click")
    func sizeAndPreDelayDeclick() {
        let node = ReverbNode(sampleRate: rate)
        set(node, "size", 20)
        set(node, "damping", 30)
        set(node, "preDelay", 5)
        set(node, "mix", 100)
        let tone = sine(300, seconds: 1, amplitude: 0.3)
        let output = run(node, tone, channels: 2, onBlock: { i in
            if i == 20 {
                // A full-scale jump of both params at once: the delay-line read positions
                // these drive (Size: ~506 -> ~2193 samples behind the write head; Pre-Delay:
                // 5 ms -> 200 ms) must crossfade, not relocate the read head instantly.
                set(node, "size", 100)
                set(node, "preDelay", 200)
            }
        })
        #expect(output.allSatisfy { $0.isFinite })
        let baseline = maxStep(Array(tone[0..<4096]))
        let worst = maxStep(output)
        #expect(worst < baseline * 8, "max step \(worst) vs clean-tone baseline \(baseline)")
    }
}

@Suite("LimiterNode")
struct LimiterNodeTests {
    private func truePeakBound(_ ceilingDB: Float, _ signal: [Float]) -> Bool {
        let node = LimiterNode(sampleRate: rate)
        set(node, "inputGain", 0)
        set(node, "ceiling", ceilingDB)
        set(node, "release", 60)
        let output = run(node, signal)
        // Independent true-peak check: 8x FFT-domain upsample (zero-pad spectrum, inverse FFT),
        // separate from the limiter's own oversampled detector.
        var n = 1
        while n < output.count { n <<= 1 }
        n = max(n, 4096)
        let factor = 8
        var real = [Float](repeating: 0, count: n)
        for i in 0..<output.count { real[i] = output[i] }
        var imag = [Float](repeating: 0, count: n)
        let log2n = vDSP_Length(log2(Double(n)))
        let setup = vDSP_create_fftsetup(vDSP_Length(log2(Double(n * factor))), FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        var upReal = [Float](repeating: 0, count: n * factor)
        var upImag = [Float](repeating: 0, count: n * factor)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                upReal.withUnsafeMutableBufferPointer { urp in
                    upImag.withUnsafeMutableBufferPointer { uip in
                        // Place the spectrum's positive and negative halves at the ends of the
                        // zero-padded (larger) buffer: zero-stuffing in the frequency domain is
                        // ideal (sinc) interpolation in time.
                        let half = n / 2
                        urp.baseAddress!.update(from: rp.baseAddress!, count: half)
                        uip.baseAddress!.update(from: ip.baseAddress!, count: half)
                        (urp.baseAddress! + n * factor - half).update(from: rp.baseAddress! + half, count: half)
                        (uip.baseAddress! + n * factor - half).update(from: ip.baseAddress! + half, count: half)
                        var upSplit = DSPSplitComplex(realp: urp.baseAddress!, imagp: uip.baseAddress!)
                        vDSP_fft_zip(setup, &upSplit, 1, vDSP_Length(log2(Double(n * factor))), FFTDirection(kFFTDirection_Inverse))
                    }
                }
            }
        }
        var scale: Float = 1 / Float(n)
        vDSP_vsmul(upReal, 1, &scale, &upReal, 1, vDSP_Length(n * factor))
        var truePeak: Float = 0
        // Skip the limiter's startup transient and the zero-padded tail's Gibbs ringing at the
        // FFT interpolation boundary: measure over the steady middle portion only.
        let measureStart = (output.count / 4) * factor
        let measureCount = (output.count / 2) * factor
        upReal.withUnsafeBufferPointer { buf in
            vDSP_maxmgv(buf.baseAddress! + measureStart, 1, &truePeak, vDSP_Length(measureCount))
        }
        let ceilingLinear = powf(10, ceilingDB / 20)
        let boundLinear = ceilingLinear * powf(10, 0.1 / 20)
        return truePeak <= boundLinear
    }

    @Test("True peak stays under ceiling + 0.1 dB for a sine near Nyquist/4")
    func sineNearQuarterNyquist() {
        let tone = sine(12_000, seconds: 0.2, amplitude: 1.5)
        #expect(truePeakBound(-1, tone))
    }

    @Test("True peak stays under ceiling + 0.1 dB for impulses")
    func impulses() {
        var signal = [Float](repeating: 0, count: 4800)
        for i in stride(from: 0, to: signal.count, by: 480) { signal[i] = 3 }
        #expect(truePeakBound(-1, signal))
    }

    @Test("True peak stays under ceiling + 0.1 dB for a square wave")
    func squareWave() {
        var signal = [Float](repeating: 0, count: 4800)
        for i in 0..<signal.count { signal[i] = (i / 24) % 2 == 0 ? 1.5 : -1.5 }
        #expect(truePeakBound(-1, signal))
    }

    @Test("Param change mid-stream doesn't click")
    func declick() {
        let node = LimiterNode(sampleRate: rate)
        set(node, "ceiling", -1)
        let tone = sine(300, seconds: 1, amplitude: 0.5)
        let output = run(node, tone, onBlock: { i in
            if i == 20 { set(node, "inputGain", 12) }
        })
        #expect(output.allSatisfy { $0.isFinite })
    }

    @Test("Lowering the ceiling mid-lookahead rescales an already-queued peak, not just new ones")
    func ceilingChangeRescalesQueuedPeak() {
        let node = LimiterNode(sampleRate: rate)
        set(node, "inputGain", 0)
        set(node, "ceiling", -1)
        set(node, "release", 60)
        // An isolated full-scale impulse: its main FIR peak is queued using the -1 dB ceiling.
        // `latencySamples` (~72 at 48 kHz) later, lowering the ceiling to -12 dB must still
        // bring that already-queued impulse's emitted gain under the *new* ceiling: storing
        // `ceilingLinear / peak` (baked in at push time) instead of the raw peak would leave
        // it emitted at the stale -1 dB requirement.
        var signal = [Float](repeating: 0, count: 300)
        signal[0] = 1
        let output = run(node, signal, blockSize: 1, onBlock: { i in
            if i == 60 { set(node, "ceiling", -12) }
        })
        let newCeilingLinear = powf(10, -12 / 20)
        let peakOut = output.map { abs($0) }.max() ?? 0
        #expect(peakOut <= newCeilingLinear * 1.05,
               "peak \(peakOut) exceeds the new -12 dB ceiling (\(newCeilingLinear)) -- emitted using the stale -1 dB gain")
    }
}

@Suite("PitchShiftNode")
struct PitchShiftNodeTests {
    @Test("Shifts a sine's frequency by the ratio within 1%", arguments: [-12, -5, 5, 12] as [Float])
    func shiftsFrequency(semitones: Float) {
        let node = PitchShiftNode(sampleRate: rate)
        set(node, "semitones", semitones)
        set(node, "formant", 0)
        set(node, "preserveFormants", 0) // plain shifting: output frequency should match exactly.
        set(node, "mix", 100)
        let inputFreq: Float = 220
        let tone = sine(inputFreq, seconds: 2, amplitude: 0.5)
        let output = run(node, tone)
        // Skip the lookahead/analysis-window latency plus settling time.
        let steady = Array(output[4096...])
        let measured = dominantFrequency(steady)
        let expected = inputFreq * powf(2, semitones / 12)
        #expect(abs(measured - expected) / expected < 0.01, "measured \(measured) Hz, expected \(expected) Hz")
    }

    @Test("The non-bypassed wet path at ratio 1 is unity gain and aligned to the actual FFT latency")
    func wetPathUnityGainAndLatencyAligned() {
        let node = PitchShiftNode(sampleRate: rate)
        set(node, "semitones", 0)
        // `formant` has no effect with `preserveFormants` off, but a nonzero value avoids the
        // explicit `bypass` dry passthrough, forcing the signal through the real FFT
        // analysis/synthesis round trip -- unlike `transparentPassthrough` above.
        set(node, "formant", 1)
        set(node, "preserveFormants", 0)
        set(node, "mix", 100)
        let tone = sine(300, seconds: 1, amplitude: 0.4)
        let output = run(node, tone)
        // The declared latency must be the actual wet-path latency (`fftSize`), not the
        // shorter `inFifoLatency`: using that offset below is itself part of the regression,
        // since the too-short declared latency would misalign this comparison by one hop.
        let latency = node.latencySamples
        #expect(latency == 1024, "declared latency \(latency), expected the full FFT size")
        let steadyOut = output[(latency + 4096)...]
        let steadyIn = tone[(latency + 4096)...]
        let gainDB = dB(rms(steadyOut)) - dB(rms(steadyIn))
        #expect(abs(gainDB) < 0.3, "wet path gain \(gainDB) dB, expected ~0 dB (unity) for an unchanged spectrum")
    }

    @Test("Zero semitones and zero formant is an exact, latency-aligned passthrough")
    func transparentPassthrough() {
        let node = PitchShiftNode(sampleRate: rate)
        // Defaults are already 0/0; also exercise a non-100 mix to prove bypass ignores it.
        set(node, "mix", 30)
        let tone = sine(300, seconds: 0.5, amplitude: 0.4)
        let output = run(node, tone)
        let latency = node.latencySamples
        let worst = zip(output.dropFirst(latency), tone).map { abs($0 - $1) }.max() ?? .infinity
        #expect(worst < 1e-5, "max deviation \(worst)")
    }

    @Test("Formant-preserving mode keeps the spectral envelope roughly in place")
    func preservesFormants() {
        // A two-formant "vowel": a 110 Hz source through fixed resonances at 700 Hz and 1200 Hz,
        // approximated as the sum of two bands of harmonics shaped by those resonances.
        func vowel(seconds: Float) -> [Float] {
            let n = Int(seconds * rate)
            var out = [Float](repeating: 0, count: n)
            let f0: Float = 110
            for h in 1...20 {
                let freq = f0 * Float(h)
                guard freq < rate / 2 else { break }
                let w1 = exp(-pow((freq - 700) / 150, 2))
                let w2 = exp(-pow((freq - 1200) / 150, 2))
                let amp = 0.02 * (w1 + 0.6 * w2 + 0.02)
                for i in 0..<n { out[i] += amp * sinf(2 * .pi * freq * Float(i) / rate) }
            }
            return out
        }
        let node = PitchShiftNode(sampleRate: rate)
        set(node, "semitones", 7)
        set(node, "formant", 0)
        set(node, "preserveFormants", 1)
        set(node, "mix", 100)
        let input = vowel(seconds: 2)
        let output = run(node, input)
        let steadyOut = Array(output[8192...])
        // Band energy around the lower formant (700 Hz, where it must stay) vs. where a *plain*
        // (non-formant-preserving) shift would have moved it to — `700 * 2^(7/12)` ≈ 1048 Hz.
        // With formants preserved, energy should still favor 700 Hz; a plain shift would favor
        // ~1048 Hz instead (the whole spectrum, this formant included, scales with pitch).
        func bandEnergy(_ x: [Float], low: Float, high: Float) -> Float {
            var n = 1
            while n < x.count { n <<= 1 }
            n = max(n, 16384)
            var real = [Float](repeating: 0, count: n)
            for i in 0..<x.count { real[i] = x[i] }
            var imag = [Float](repeating: 0, count: n)
            let log2n = vDSP_Length(log2(Double(n)))
            let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
            defer { vDSP_destroy_fftsetup(setup) }
            var mag = [Float](repeating: 0, count: n / 2)
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                    vDSP_zvmags(&split, 1, &mag, 1, vDSP_Length(n / 2))
                }
            }
            let loBin = Int(low / rate * Float(n)), hiBin = Int(high / rate * Float(n))
            return mag[loBin...hiBin].reduce(0, +)
        }
        let atOriginalFormant = bandEnergy(steadyOut, low: 625, high: 775)
        let atShiftedLocation = bandEnergy(steadyOut, low: 975, high: 1125)
        #expect(atOriginalFormant > atShiftedLocation,
                "formant followed pitch instead of staying put: at 700 Hz \(atOriginalFormant), at shifted ~1048 Hz \(atShiftedLocation)")
    }
}

@Suite("FX stage declicking")
struct FXDeclickTests {
    @Test("Compressor threshold change mid-stream doesn't click")
    func compressorDeclick() {
        let node = CompressorNode(sampleRate: rate)
        set(node, "threshold", -20)
        set(node, "ratio", 4)
        let tone = sine(300, seconds: 1, amplitude: 0.5)
        let output = run(node, tone, onBlock: { i in
            if i == 20 { set(node, "threshold", -40) }
        })
        #expect(output.allSatisfy { $0.isFinite })
        let baseline = maxStep(Array(tone[0..<4096]))
        #expect(maxStep(output) < baseline * 10)
    }

    @Test("Gate parameter change mid-stream doesn't click")
    func gateDeclick() {
        let node = GateNode(sampleRate: rate)
        set(node, "mode", 0)
        set(node, "threshold", -40)
        let tone = sine(300, seconds: 1, amplitude: 0.3)
        let output = run(node, tone, onBlock: { i in
            if i == 20 { set(node, "range", -40) }
        })
        #expect(output.allSatisfy { $0.isFinite })
        let baseline = maxStep(Array(tone[0..<4096]))
        #expect(maxStep(output) < baseline * 10)
    }
}

@Suite("FXDSPCommon")
struct FXDSPCommonTests {
    @Test("fxRenormalizeLFO keeps a rotated unit vector at magnitude 1 over a long-running session")
    func lfoRotationStaysNormalized() {
        // The same per-sample rotation increment ChorusNode's default rate and ReverbNode's
        // lines use (0.8 Hz / 48 kHz): small enough that `cosf(w)` rounds to exactly 1, so
        // `sinf(w)` alone nudges the vector's magnitude every sample. Run far more samples than
        // a single audio buffer to accumulate the drift a long session would show.
        let w = 2 * Float.pi * 0.8 / 48_000
        let rc = cosf(w), rs = sinf(w)
        var c: Float = 1, s: Float = 0
        for _ in 0..<2_000_000 {
            let nc = c * rc - s * rs
            let ns = c * rs + s * rc
            c = nc; s = ns
            fxRenormalizeLFO(&c, &s)
        }
        let mag = sqrtf(c * c + s * s)
        #expect(abs(mag - 1) < 1e-4, "magnitude drifted to \(mag) even with renormalization")
    }

    @Test("Without renormalization, the same rotation measurably drifts off unit magnitude")
    func lfoRotationDriftsWithoutRenormalization() {
        let w = 2 * Float.pi * 0.8 / 48_000
        let rc = cosf(w), rs = sinf(w)
        var c: Float = 1, s: Float = 0
        for _ in 0..<2_000_000 {
            let nc = c * rc - s * rs
            let ns = c * rs + s * rc
            c = nc; s = ns
        }
        let mag = sqrtf(c * c + s * s)
        #expect(abs(mag - 1) > 1e-4,
               "expected measurable drift without renormalization (baseline for the fix above); got \(mag)")
    }

    @Test("pvWrapPhase keeps a phase within -pi...pi while preserving its sin/cos")
    func wrapsPitchShiftPhase() {
        #expect(abs(pvWrapPhase(5 * Float.pi)) <= Float.pi + 1e-5)
        #expect(abs(pvWrapPhase(-100.3)) <= Float.pi + 1e-5)
        // A phase that has run many times around the circle (as an unwrapped `sumPhase` would
        // without the periodic wrap the fix adds) must wrap to something trigonometrically
        // equivalent. Kept to a magnitude where the *input* itself still has full Float
        // precision (a huge raw phase value has already lost precision representing itself,
        // independent of `pvWrapPhase` -- exactly the failure mode wrapping every hop avoids by
        // never letting `sumPhase` reach that magnitude in the first place).
        let x: Float = 1.7
        let farOut = x + 100 * 2 * Float.pi
        let wrapped = pvWrapPhase(farOut)
        #expect(abs(wrapped) <= Float.pi + 1e-3)
        #expect(abs(sinf(wrapped) - sinf(x)) < 1e-3, "sin mismatch after wrapping \(farOut) -> \(wrapped)")
        #expect(abs(cosf(wrapped) - cosf(x)) < 1e-3, "cos mismatch after wrapping \(farOut) -> \(wrapped)")
    }
}

@Suite("FXKWeighting")
struct FXKWeightingTests {
    @Test("Reproduces the ITU-R BS.1770-5 Annex 1 Table 1 (shelf) coefficients at 48 kHz")
    func matchesPublishedShelfCoefficients() {
        let coeffs = FXKWeighting.coefficients(sampleRate: 48_000)
        #expect(abs(coeffs.shelf.b0 - 1.53512485958697) < 1e-9)
        #expect(abs(coeffs.shelf.b1 - (-2.69169618940638)) < 1e-9)
        #expect(abs(coeffs.shelf.b2 - 1.19839281085285) < 1e-9)
        #expect(abs(coeffs.shelf.a1 - (-1.69065929318241)) < 1e-9)
        #expect(abs(coeffs.shelf.a2 - 0.73248077421585) < 1e-9)
    }

    @Test("Reproduces the ITU-R BS.1770-5 Annex 1 Table 2 (RLB high-pass) coefficients at 48 kHz")
    func matchesPublishedHighpassCoefficients() {
        let coeffs = FXKWeighting.coefficients(sampleRate: 48_000)
        #expect(coeffs.highpass.b0 == 1)
        #expect(coeffs.highpass.b1 == -2)
        #expect(coeffs.highpass.b2 == 1)
        #expect(abs(coeffs.highpass.a1 - (-1.99004745483398)) < 1e-9)
        #expect(abs(coeffs.highpass.a2 - 0.99007225036621) < 1e-9)
    }

    @Test("Differs from FXBiquadCoeffs.make's generic RBJ shelf/high-pass at 48 kHz")
    func differsFromGenericRBJDesign() {
        // The regression this guards: passing the quoted frequency/Q straight into the RBJ
        // cookbook formulas does *not* reproduce the published coefficients above.
        let coeffs = FXKWeighting.coefficients(sampleRate: 48_000)
        let genericShelf = FXBiquadCoeffs.make(type: .highshelf, frequency: 1681.9744509555319,
                                               q: 0.7071752369554196, gainDB: 3.999843853973347, sampleRate: 48_000)
        let genericHighpass = FXBiquadCoeffs.make(type: .highpass, frequency: 38.13547087602444,
                                                   q: 0.5003270373238773, gainDB: 0, sampleRate: 48_000)
        #expect(abs(coeffs.shelf.b0 - genericShelf.b0) > 1e-6)
        #expect(abs(coeffs.highpass.b1 - genericHighpass.b1) > 1e-6)
    }
}
