import Foundation
@testable import Loopbacker

/// Runs `nodes` through a real `FXChain` (with its own VAD, same as production), feeding `input`
/// mono (fanned to identical L/R, like a mono mic) in 10 ms chunks so VAD hops and the chain's
/// crossfade cadence behave exactly as they would live. Returns the processed mono output,
/// sample-aligned to `input` (nodes delay by their own small `latencySamples`, a few ms at most).
func runFXChain(_ nodes: [FXNodeConfig], sampleRate: Float, input: [Float], chunkFrames: Int = 480) async -> [Float] {
    let chain = FXChain(sampleRate: sampleRate, captureDeviceUID: "preset-verify-\(UUID())")
    await chain.updateConfigs(nodes)

    var output = [Float](repeating: 0, count: input.count)
    var offset = 0
    while offset < input.count {
        let n = min(chunkFrames, input.count - offset)
        var buffer = [Float](repeating: 0, count: n * 2)
        for i in 0..<n {
            buffer[i * 2] = input[offset + i]
            buffer[i * 2 + 1] = input[offset + i]
        }
        buffer.withUnsafeMutableBufferPointer { ptr in
            chain.process(ptr.baseAddress!, frames: n, stride: 2, sampleTime: nil, rawPreNS: nil)
        }
        for i in 0..<n { output[offset + i] = buffer[i * 2] }
        offset += n
    }
    chain.ioStopped()
    return output
}

/// BS.1770-style K-weighted integrated loudness (`-0.691 + 10*log10(meanSquare)`), ungated,
/// computed only over `ranges` but with the K-weighting filters run continuously across all of
/// `samples` so their history stays correct across gaps. Doubles the squared term to match
/// `LevelerNode`'s own per-sample mono convention (see `AutoSetup.kWeightedIntegratedLUFS`), so
/// a leveler's `target` param means the same thing here as it does to the leveler itself.
func measuredLUFS(_ samples: [Float], ranges: [Range<Int>], sampleRate: Float) -> Float {
    let shelf = FXBiquadCoeffs.make(type: .highshelf, frequency: 1681.9744509555319, q: 0.7071752369554196,
                                    gainDB: 3.999843853973347, sampleRate: Double(sampleRate))
    let hp = FXBiquadCoeffs.make(type: .highpass, frequency: 38.13547087602444, q: 0.5003270373238773, gainDB: 0,
                                 sampleRate: Double(sampleRate))
    var shelfState = FXBiquadState()
    var hpState = FXBiquadState()
    var sumSquares: Double = 0
    var count = 0
    var rangeIdx = 0
    for i in 0..<samples.count {
        var k = Float(shelfState.process(Double(samples[i]), shelf))
        k = Float(hpState.process(Double(k), hp))
        while rangeIdx < ranges.count, i >= ranges[rangeIdx].upperBound { rangeIdx += 1 }
        if rangeIdx < ranges.count, ranges[rangeIdx].contains(i) {
            sumSquares += 2 * Double(k * k)
            count += 1
        }
    }
    guard count > 0 else { return -.infinity }
    return Float(-0.691 + 10 * log10(max(sumSquares / Double(count), 1e-12)))
}

/// 4x-oversampled true-peak estimate (a windowed-sinc interpolator, same idea as `LimiterNode`'s
/// own detector but lighter-weight: only refined near candidate sample peaks, not every sample,
/// since this only needs to confirm the limiter kept inter-sample peaks under its ceiling, not
/// drive gain reduction in real time).
func truePeakDBFS(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return -.infinity }
    var samplePeak: Float = 0
    for s in samples where s.isFinite { samplePeak = max(samplePeak, abs(s)) }
    guard samplePeak > 0 else { return -.infinity }

    let factor = 4
    let halfTaps = 8
    var maxAbs = samplePeak
    let threshold = samplePeak * 0.5
    for i in 0..<samples.count where abs(samples[i]) >= threshold {
        for sub in 1..<factor {
            let t = Float(i) + Float(sub) / Float(factor)
            var acc: Float = 0
            for k in -halfTaps...halfTaps {
                let idx = i + k
                guard idx >= 0, idx < samples.count else { continue }
                acc += samples[idx] * sincWindowed(t - Float(idx), halfTaps: halfTaps)
            }
            maxAbs = max(maxAbs, abs(acc))
        }
    }
    return fxLinearToDB(maxAbs)
}

private func sincWindowed(_ x: Float, halfTaps: Int) -> Float {
    guard abs(x) <= Float(halfTaps) else { return 0 }
    let sinc: Float = abs(x) < 1e-6 ? 1 : sinf(.pi * x) / (.pi * x)
    let window = 0.5 * (1 + cosf(.pi * x / Float(halfTaps)))
    return sinc * window
}

/// Peak amplitude (dB) of `samples` restricted to `ranges`.
func peakDBFS(_ samples: [Float], ranges: [Range<Int>]) -> Float {
    var peak: Float = 0
    for range in ranges {
        for i in range where i >= 0 && i < samples.count { peak = max(peak, abs(samples[i])) }
    }
    return peak > 0 ? fxLinearToDB(peak) : -.infinity
}
