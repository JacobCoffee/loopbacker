import Foundation
import Testing
@testable import Loopbacker

private let rate: Float = 48_000
private let hop = EchoCanceller.hop

/// Deterministic noise (xorshift), uniform in -1...1.
private struct Noise {
    var state: UInt64
    mutating func next() -> Float {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Float(state >> 40) / Float(1 << 23) - 1
    }
}

/// Speech-like test signal: a gliding glottal pulse train through formant-ish resonances, gated
/// into syllables. `seed` picks independent far-end/near-end talkers.
private func voice(seconds: Float, seed: Float) -> [Float] {
    let count = Int(seconds * rate)
    var out = [Float](repeating: 0, count: count)
    var phase: Float = 0
    var formants: [(y1: Float, y2: Float)] = [(0, 0), (0, 0), (0, 0)]
    let centers: [Float] = [700 + seed, 1200 + 1.4 * seed, 2600 + 0.6 * seed]
    for i in 0..<count {
        let t = Float(i) / rate
        let f0 = 145 + seed + 35 * sinf(2 * .pi * 0.7 * t)
        phase += f0 / rate
        var excitation: Float = 0
        if phase >= 1 { phase -= 1; excitation = 1 }
        var y: Float = 0
        for k in 0..<3 {
            let r = expf(-.pi * 100 / rate)
            let a1 = 2 * r * cosf(2 * .pi * centers[k] / rate), a2 = -r * r
            let v = excitation + a1 * formants[k].y1 + a2 * formants[k].y2
            formants[k] = (v, formants[k].y1)
            y += v / Float(k + 1)
        }
        let syllable = max(0, sinf(2 * .pi * 2.3 * t + seed))
        out[i] = 0.025 * y * syllable
    }
    return out
}

private func addNoise(_ signal: [Float], level: Float, seed: UInt64) -> [Float] {
    var noise = Noise(state: seed)
    return signal.map { $0 + level * noise.next() }
}

/// A short synthetic room impulse response: a direct tap plus a handful of exponentially
/// decaying reflections, ~15 ms long.
private func roomImpulseResponse() -> [Float] {
    let n = Int(0.015 * rate)
    var ir = [Float](repeating: 0, count: n)
    ir[0] = 1.0
    var noise = Noise(state: 0xC0FF_EE12_3456_789A)
    for i in stride(from: 40, to: n, by: 37) {
        let decay = expf(-Float(i) / (0.004 * rate))
        ir[i] += 0.5 * decay * (0.5 + 0.5 * noise.next())
    }
    return ir
}

/// Direct (non-FFT) convolution — signal lengths in these tests are small enough it's fast.
private func convolve(_ signal: [Float], _ ir: [Float]) -> [Float] {
    var out = [Float](repeating: 0, count: signal.count)
    for i in 0..<signal.count {
        var acc: Float = 0
        let maxK = min(ir.count, i + 1)
        for k in 0..<maxK {
            acc += ir[k] * signal[i - k]
        }
        out[i] = acc
    }
    return out
}

private func rms(_ x: ArraySlice<Float>) -> Float {
    sqrtf(x.reduce(0) { $0 + $1 * $1 } / Float(x.count))
}

/// Builds a far-end/near-end/mic scenario: `far` is what the system plays (and what the tap
/// reports), `mic` is `far` run through a room impulse response, delayed `bulkDelaySamples`,
/// plus `near` layered on top.
private struct Scenario {
    let far: [Float]
    let mic: [Float]
    let near: [Float]
    let bulkDelaySamples: Int
}

private func makeScenario(seconds: Float, bulkDelayMs: Float, nearStartSeconds: Float, nonlinear: Bool = false) -> Scenario {
    let far = voice(seconds: seconds, seed: 0)
    // Real laptop/phone speakers compress and distort loud passages rather than reproducing
    // them linearly; `tanh(2x)` models that soft-clipping before the signal bounces around the
    // room, so MDF's (linear-only) model can't fully predict the echo shape the way it can for
    // a pure room-impulse-response convolution.
    let speakerOutput = nonlinear ? far.map { tanhf(2 * $0) / 2 } : far
    let ir = roomImpulseResponse()
    let echoUndelayed = convolve(speakerOutput, ir)
    let bulkDelaySamples = Int(bulkDelayMs / 1000 * rate)
    var echo = [Float](repeating: 0, count: far.count)
    for i in bulkDelaySamples..<far.count {
        echo[i] = echoUndelayed[i - bulkDelaySamples]
    }
    var near = [Float](repeating: 0, count: far.count)
    let nearStart = Int(nearStartSeconds * rate)
    if nearStart < far.count {
        let nearVoice = addNoise(voice(seconds: Float(far.count - nearStart) / rate, seed: 37), level: 0.01, seed: 0xBEEF)
        for i in 0..<nearVoice.count where nearStart + i < near.count {
            near[nearStart + i] = nearVoice[i]
        }
    }
    let mic = zip(echo, near).map { $0 + $1 }
    return Scenario(far: far, mic: mic, near: near, bulkDelaySamples: bulkDelaySamples)
}

/// Feeds `scenario.far` into a `DriftCompensatedRing` as `SystemAudioTap` would, then runs
/// `scenario.mic` through an `EchoCanceller` in `blockSize`-frame chunks (or a cycling pattern,
/// if `blockSizes` is given instead) and returns the cancelled output.
///
/// The writer tracks its own elapsed-time budget (`position * (1 + driftPPM)`, `position` being
/// the reader's consumed output sample count as a wall-clock proxy) and writes however many
/// source samples that budget newly allows, independent of the ring's current fill level.
/// That mirrors how two independent Core Audio devices actually behave — each emits samples at
/// its own clock rate, not reactively topping up toward some target whenever the consumer's
/// backlog runs low. A reactive "write enough to stay N frames ahead" policy biases
/// `DriftCompensatedRing`'s fill estimate above target on every call (since it always refills
/// to or above the threshold, never below), which pins `read()`'s steering at its maximum
/// correction rate indefinitely and drifts the delay continuously even with zero injected
/// `driftPPM` — an artifact of the feeding pattern, not a real device clock.
private func run(_ scenario: Scenario, driftPPM: Double = 0, blockSize: Int? = 480,
                 blockSizes: [Int]? = nil) throws -> [Float] {
    let ring = DriftCompensatedRing(capacityFrames: 1 << 16, channels: 2, targetFill: 960, sampleRate: 48_000)
    let canceller = try #require(EchoCanceller.make(reference: ring))
    canceller.setEnabled(true)

    var writerPos = 0
    var writeBuffer = [Float](repeating: 0, count: (FXBlock.maxFrames + 16) * 2)
    func topUpWriter(past position: Int) {
        let owed = min(Int(Double(position) * (1 + driftPPM * 1e-6)), scenario.far.count)
        guard owed > writerPos else { return }
        let n = owed - writerPos
        for i in 0..<n {
            let sample = scenario.far[writerPos + i]
            writeBuffer[2 * i] = sample
            writeBuffer[2 * i + 1] = sample
        }
        writeBuffer.withUnsafeMutableBufferPointer { buf in
            ring.write(buf.baseAddress!, frames: UInt32(n))
        }
        writerPos = owed
    }

    var output = [Float](repeating: 0, count: scenario.mic.count)
    var position = 0
    var blockCycle = 0
    while position < scenario.mic.count {
        let n: Int
        if let blockSizes {
            n = min(blockSizes[blockCycle % blockSizes.count], scenario.mic.count - position)
            blockCycle += 1
        } else {
            n = min(blockSize ?? hop, scenario.mic.count - position)
        }
        guard n > 0 else { break }
        topUpWriter(past: position)
        var chunk = Array(scenario.mic[position..<(position + n)])
        chunk.withUnsafeMutableBufferPointer { buf in
            canceller.process(buf.baseAddress!, frames: n)
        }
        for i in 0..<n { output[position + i] = chunk[i] }
        position += n
    }
    return output
}

@Suite("EchoCanceller")
struct EchoCancellerTests {
    @Test("Attenuates far-end-only echo by at least 20 dB ERLE once converged",
          arguments: [40.0, 90.0, 150.0] as [Float])
    func erle(bulkDelayMs: Float) throws {
        // No near-end speech at all: pure far-end-only convergence.
        let scenario = makeScenario(seconds: 9, bulkDelayMs: bulkDelayMs, nearStartSeconds: 999)
        let output = try run(scenario, driftPPM: 50)
        #expect(output.allSatisfy { $0.isFinite })

        // Measure in the last two seconds, well after the filter has converged.
        let window = (scenario.mic.count - Int(2 * rate))..<scenario.mic.count
        let micPower = scenario.mic[window].reduce(Float(0)) { $0 + $1 * $1 }
        let outPower = output[window].reduce(Float(0)) { $0 + $1 * $1 }
        let erle = 10 * log10f(micPower / outPower)
        #expect(erle >= 20, "ERLE \(erle) dB at \(bulkDelayMs) ms bulk delay")
    }

    @Test("Attenuates nonlinear (soft-clipped speaker) echo too",
          arguments: [40.0, 90.0, 150.0] as [Float])
    func erleNonlinear(bulkDelayMs: Float) throws {
        let scenario = makeScenario(seconds: 9, bulkDelayMs: bulkDelayMs, nearStartSeconds: 999, nonlinear: true)
        let output = try run(scenario, driftPPM: 50)
        #expect(output.allSatisfy { $0.isFinite })

        let window = (scenario.mic.count - Int(2 * rate))..<scenario.mic.count
        let micPower = scenario.mic[window].reduce(Float(0)) { $0 + $1 * $1 }
        let outPower = output[window].reduce(Float(0)) { $0 + $1 * $1 }
        let erle = 10 * log10f(micPower / outPower)
        #expect(erle >= 10, "nonlinear ERLE \(erle) dB at \(bulkDelayMs) ms bulk delay")
    }

    @Test("Preserves near-end level within 3 dB during double talk")
    func doubleTalk() throws {
        let scenario = makeScenario(seconds: 8, bulkDelayMs: 80, nearStartSeconds: 4)
        let output = try run(scenario, driftPPM: 30)
        #expect(output.allSatisfy { $0.isFinite })

        // Double talk starts at 4 s; measure the last 2 s of it, after the echo path has had
        // 4 s to converge and the near-end voice has had time to get going.
        let window = Int(6 * rate)..<Int(8 * rate)
        let nearLevel = rms(scenario.near[window])
        let outLevel = rms(output[window])
        let deltaDB = 20 * log10f(outLevel / nearLevel)
        #expect(abs(deltaDB) <= 3, "near-end level moved \(deltaDB) dB during double talk")
    }

    @Test("Handles arbitrary block sizes from 1 to FXBlock.maxFrames without NaNs")
    func blockSizes() throws {
        let scenario = makeScenario(seconds: 2, bulkDelayMs: 60, nearStartSeconds: 1)
        let sizes = [1, 2, 3, 7, 37, 128, 480, 1000, 4096, FXBlock.maxFrames]
        let output = try run(scenario, blockSizes: sizes)
        #expect(output.allSatisfy { $0.isFinite })
        #expect(output.allSatisfy { !$0.isNaN })
    }

    @Test("Disabled, the signal passes through unchanged after the crossfade settles")
    func disabledPassthrough() throws {
        let ring = DriftCompensatedRing(capacityFrames: 1 << 16, channels: 2, targetFill: 4_800, sampleRate: 48_000)
        let canceller = try #require(EchoCanceller.make(reference: ring))
        // Never enabled: wetGain stays 0, so every sample should be the untouched dry input.
        var buffer = (0..<hop).map { Float($0) / Float(hop) - 0.5 }
        let original = buffer
        buffer.withUnsafeMutableBufferPointer { canceller.process($0.baseAddress!, frames: hop) }
        #expect(buffer == original)
    }

    @Test("Reset clears adaptation state without allocating or crashing")
    func reset() throws {
        let ring = DriftCompensatedRing(capacityFrames: 1 << 16, channels: 2, targetFill: 4_800, sampleRate: 48_000)
        let canceller = try #require(EchoCanceller.make(reference: ring))
        canceller.setEnabled(true)
        var buffer = [Float](repeating: 0.1, count: hop)
        buffer.withUnsafeMutableBufferPointer { canceller.process($0.baseAddress!, frames: hop) }
        canceller.reset()
        buffer = [Float](repeating: 0.1, count: hop)
        buffer.withUnsafeMutableBufferPointer { canceller.process($0.baseAddress!, frames: hop) }
        #expect(buffer.allSatisfy { $0.isFinite })
    }

    @Test("Only a 48 kHz reference gets an echo canceller")
    func otherRates() {
        let ring = DriftCompensatedRing(capacityFrames: 1 << 16, channels: 2, targetFill: 4_800, sampleRate: 44_100)
        #expect(EchoCanceller.make(reference: ring) == nil)
    }
}
