import Foundation
import Testing
@testable import Loopbacker

/// The model shipped in `Resources`, loaded once (compiling it takes ~1.5 s the first time per
/// OS build; later runs read the cached graph).
private let model: NoiseSuppressionModel = {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Resources/DPDFNet2_48k.mlmodelc")
    guard let model = NoiseSuppressionModel.load(from: url) else {
        fatalError("could not load \(url.path)")
    }
    return model
}()

private let block = 512
private let rate: Float = 48_000

/// Input sample → output sample delay: the kernel's delay plus up to a hop waiting for a hop to
/// fill. DPDFNet: 40 ms of model lookahead plus a hop for the second half of the analysis
/// window. RNNoise: two hops of analysis and overlap-add.
private func delay(_ engine: NoiseSuppressionEngine) -> Int {
    switch engine {
    case .dpdfnet: 2879
    case .rnnoise: 1439
    }
}

private func makeSuppressor(_ engine: NoiseSuppressionEngine) throws -> NoiseSuppressor {
    let kernel: (any DenoiseKernel)? = switch engine {
    case .dpdfnet: DPDFNetKernel(model: model)
    case .rnnoise: RNNoiseKernel.make()
    }
    let unwrapped = try #require(kernel)
    return try #require(NoiseSuppressor.make(sampleRate: 48_000, engine: engine, kernel: unwrapped))
}

/// Deterministic noise (xorshift), uniform in -1...1.
private struct Noise {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    mutating func next() -> Float {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Float(state >> 40) / Float(1 << 23) - 1
    }
}

/// Speech-like test signal: a gliding 110–180 Hz glottal pulse train through three formant-ish
/// resonances, gated into ~4 syllables per second.
private func voice(seconds: Float) -> [Float] {
    let count = Int(seconds * rate)
    var out = [Float](repeating: 0, count: count)
    var phase: Float = 0
    var formants: [(y1: Float, y2: Float)] = [(0, 0), (0, 0), (0, 0)]
    let centers: [Float] = [700, 1200, 2600]
    for i in 0..<count {
        let t = Float(i) / rate
        let f0 = 145 + 35 * sinf(2 * .pi * 0.7 * t)
        phase += f0 / rate
        var excitation: Float = 0
        if phase >= 1 { phase -= 1; excitation = 1 }
        var y: Float = 0
        for k in 0..<3 {
            // Two-pole resonator at centers[k] with ~100 Hz bandwidth.
            let r = expf(-.pi * 100 / rate)
            let a1 = 2 * r * cosf(2 * .pi * centers[k] / rate), a2 = -r * r
            let v = excitation + a1 * formants[k].y1 + a2 * formants[k].y2
            formants[k] = (v, formants[k].y1)
            y += v / Float(k + 1)
        }
        let syllable = max(0, sinf(2 * .pi * 2 * t))
        out[i] = 0.02 * y * syllable
    }
    return out
}

private func mix(_ signal: [Float], noiseSNR snrDB: Float) -> [Float] {
    var noise = Noise()
    var brown: Float = 0
    let n = signal.map { _ -> Float in
        brown = 0.995 * brown + 0.05 * noise.next()
        return brown + 0.1 * noise.next()
    }
    let ps = signal.reduce(0) { $0 + $1 * $1 }, pn = n.reduce(0) { $0 + $1 * $1 }
    let k = sqrtf(ps / pn / powf(10, snrDB / 10))
    return zip(signal, n).map { $0 + k * $1 }
}

private func maxStep(_ x: [Float]) -> Float {
    zip(x.dropFirst(), x).map { abs($0 - $1) }.max() ?? 0
}

private func snr(reference: ArraySlice<Float>, _ x: ArraySlice<Float>) -> Float {
    var s: Float = 0, e: Float = 0
    for (a, b) in zip(reference, x) { s += a * a; e += (a - b) * (a - b) }
    return 10 * log10f(s / e)
}

/// Feeds mono `signal` (duplicated to stereo) through one suppressor in 512-frame blocks, as
/// `routes` callers sharing it (same sample times), and returns each caller's left channel.
private func run(_ engine: NoiseSuppressionEngine, _ signal: [Float], reductionDB: Float, routes: Int = 1,
                 toggleEveryBlocks: Int? = nil) throws -> [[Float]] {
    let suppressor = try makeSuppressor(engine)
    suppressor.setMaxReduction(dB: reductionDB)
    suppressor.setEnabled(true)
    var outputs = [[Float]](repeating: [Float](repeating: 0, count: signal.count), count: routes)
    var buffer = [Float](repeating: 0, count: block * 2)
    var on = true
    var position = 0
    while position + block <= signal.count {
        if let every = toggleEveryBlocks, position > 0, (position / block) % every == 0 {
            on.toggle()
            suppressor.setEnabled(on)
        }
        for route in 0..<routes {
            for i in 0..<block {
                buffer[2 * i] = signal[position + i]
                buffer[2 * i + 1] = signal[position + i]
            }
            buffer.withUnsafeMutableBufferPointer {
                suppressor.process($0.baseAddress!, frames: block, stride: 2, sampleTime: Float64(position))
            }
            for i in 0..<block {
                #expect(buffer[2 * i] == buffer[2 * i + 1])
                outputs[route][position + i] = buffer[2 * i]
            }
        }
        position += block
    }
    return outputs
}

@Suite("NoiseSuppressor")
struct NoiseSuppressorTests {
    @Test("Output is the input delayed by exactly the engine's latency",
          arguments: NoiseSuppressionEngine.allCases)
    func latency(engine: NoiseSuppressionEngine) throws {
        // At 0 dB max reduction the delayed dry signal fully replaces the enhanced one, so once
        // the wet path is primed the output must be a pure delay.
        let delay = delay(engine)
        let input = mix(voice(seconds: 2), noiseSNR: 5)
        let output = try run(engine, input, reductionDB: 0)[0]
        let steady = (delay + 4800)..<(input.count - block)
        let worst = steady.map { abs(output[$0] - input[$0 - delay]) }.max() ?? .infinity
        #expect(worst < 1e-6)
    }

    @Test("Removes noise from speech", arguments: NoiseSuppressionEngine.allCases)
    func reducesNoise(engine: NoiseSuppressionEngine) throws {
        let delay = delay(engine)
        let clean = voice(seconds: 4)
        let noisy = mix(clean, noiseSNR: 5)
        let output = try run(engine, noisy, reductionDB: -60)[0]
        let steady = (delay + 9600)..<(noisy.count - block)
        let reference = steady.map { clean[$0 - delay] }[...]
        let before = snr(reference: reference, steady.map { noisy[$0 - delay] }[...])
        let after = snr(reference: reference, steady.map { output[$0] }[...])
        #expect(after > before + 6, "SNR \(before) dB -> \(after) dB")
    }

    @Test("Routes sharing a suppressor get exactly the single-route result",
          arguments: NoiseSuppressionEngine.allCases)
    func sharing(engine: NoiseSuppressionEngine) throws {
        let input = mix(voice(seconds: 1.5), noiseSNR: 5)
        let single = try run(engine, input, reductionDB: -60)[0]
        let shared = try run(engine, input, reductionDB: -60, routes: 2)
        #expect(shared[0] == single)
        #expect(shared[1] == single)
    }

    @Test("Switching on and off mid-stream doesn't click", arguments: NoiseSuppressionEngine.allCases)
    func toggling(engine: NoiseSuppressionEngine) throws {
        let input = mix(voice(seconds: 4), noiseSNR: 5)
        let output = try run(engine, input, reductionDB: -60, toggleEveryBlocks: 30)[0]
        let finite = output.allSatisfy { $0.isFinite }
        #expect(finite)
        #expect(maxStep(output) <= maxStep(input) * 1.1)
    }

    @Test("Disabled, the buffer (stereo image included) is untouched", arguments: NoiseSuppressionEngine.allCases)
    func disabledPassthrough(engine: NoiseSuppressionEngine) throws {
        let suppressor = try makeSuppressor(engine)
        var buffer = (0..<(block * 2)).map { Float($0) / Float(block * 2) }
        let original = buffer
        buffer.withUnsafeMutableBufferPointer {
            suppressor.process($0.baseAddress!, frames: block, stride: 2, sampleTime: 0)
        }
        #expect(buffer == original)
    }

    @Test("Only 48 kHz routes get a suppressor")
    func otherRates() throws {
        let kernel = try #require(DPDFNetKernel(model: model))
        #expect(NoiseSuppressor.make(sampleRate: 44_100, engine: .dpdfnet, kernel: kernel) == nil)
    }
}
