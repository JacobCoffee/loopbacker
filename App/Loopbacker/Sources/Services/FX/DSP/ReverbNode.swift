import Accelerate
import Foundation

/// 8-line feedback delay network reverb — the standard topology for a dense, smooth tail
/// without the metallic ringing of a small Schroeder reverb: eight mutually-incommensurate
/// delay lines are cross-fed through a normalized 8x8 Hadamard matrix (energy-preserving: it's
/// orthogonal, so the loop's total energy per round trip is controlled purely by the scalar
/// feedback gain, not by the mixing itself) before a shared `damping` low-pass darkens the tail
/// over time the way real rooms do. Each line's read position is modulated by a slow, line-own
/// LFO (small, sub-millisecond) so the lines' resonances drift apart instead of locking into
/// the comb-filter buzz a static FDN gets on sustained tones.
///
/// `size` scales both the delay line lengths (bigger room, longer loop) and the feedback gain
/// (longer decay); `damping` is the per-bounce low-pass's cutoff; `preDelay` is a separate FIFO
/// ahead of the network so early reflections don't start the instant the dry signal arrives.
///
/// All IO-thread state (line buffers, write heads, LFO phase, the Hadamard matrix) lives in
/// `UnsafeMutablePointer` buffers allocated once in `init`; `process` touches no Swift
/// `Array`/`Dictionary`.
final class ReverbNode: FXNode, @unchecked Sendable {
    private static let lineCount = 8
    /// Base lengths in samples at 48 kHz, chosen with no small common factors so their loop
    /// resonances don't line up. Scaled to the actual sample rate in `init`.
    private static let baseLengths48k: [Int] = [1687, 1801, 2053, 2251, 2437, 2633, 2857, 3109]
    private static let maxPreDelayMs: Float = 200
    /// Per-line LFO rates (Hz), deliberately irrational-ish relative to each other.
    private static let lfoRatesHz: [Float] = [0.13, 0.17, 0.19, 0.23, 0.29, 0.31, 0.37, 0.41]
    private static let lfoDepthSamples: Float = 2.5

    let kind: FXNodeKind = .reverb
    let specs = FXBuiltinSpecs.reverb
    let params: FXParamStore
    let meters = FXMeters()
    let latencySamples = 0

    private let sampleRate: Float
    private var lastGeneration: UInt32 = .max

    // `size`/`damping`/`preDelay` all drive either a delay-line read position or the loop's
    // feedback gain -- jumping any of them at a block boundary while input/an existing tail is
    // present would discontinuously relocate a read head or step the loop gain, clicking.
    // Smoothed per sample like `mixSmoother`; only `feedbackGain` (derived from the smoothed
    // `sizeFraction`, not the raw param) needs no smoother of its own.
    private var sizeSmoother: FXSmoother
    private var dampSmoother: FXSmoother
    private var preDelaySmoother: FXSmoother
    private var mixSmoother: FXSmoother

    /// Row-major `lineCount x lineCount`, normalized ±1/√8 — fixed for the node's lifetime.
    private let hadamard: UnsafeMutablePointer<Float>
    private let lineLengths: UnsafeMutablePointer<Int>
    private let bufferMasks: UnsafeMutablePointer<Int>
    private let lineBufferStarts: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let writeIndices: UnsafeMutablePointer<Int>
    private let dampStates: UnsafeMutablePointer<Float>
    private let lfoCos: UnsafeMutablePointer<Float>
    private let lfoSin: UnsafeMutablePointer<Float>
    private let lfoRotCos: UnsafeMutablePointer<Float>
    private let lfoRotSin: UnsafeMutablePointer<Float>
    /// Per-line scratch for the current sample's read/damped and matrix-mixed values.
    private let dampedOut: UnsafeMutablePointer<Float>
    private let feedbackVec: UnsafeMutablePointer<Float>

    private let preDelayFrames: Int
    private let preDelayMask: Int
    private let preDelayBuffer: UnsafeMutablePointer<Float>
    private var preDelayWrite = 0

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
        params = FXParamStore(specs: FXBuiltinSpecs.reverb)
        sizeSmoother = FXSmoother(initial: 0.5, timeMs: 30, sampleRate: sampleRate)
        dampSmoother = FXSmoother(initial: 0.3, timeMs: 30, sampleRate: sampleRate)
        preDelaySmoother = FXSmoother(initial: 10, timeMs: 30, sampleRate: sampleRate)
        mixSmoother = FXSmoother(initial: 0.15, timeMs: 30, sampleRate: sampleRate)

        let n = Self.lineCount
        let scale = sampleRate / 48_000
        lineLengths = .allocate(capacity: n)
        bufferMasks = .allocate(capacity: n)
        lineBufferStarts = .allocate(capacity: n)
        for k in 0..<n {
            let base = Int(Float(Self.baseLengths48k[k]) * scale)
            lineLengths[k] = base
            let needed = Int(Float(base) * 1.6) + 16
            let size = 1 << (Int.bitWidth - (needed - 1).leadingZeroBitCount)
            bufferMasks[k] = size - 1
            let p = UnsafeMutablePointer<Float>.allocate(capacity: size)
            p.initialize(repeating: 0, count: size)
            lineBufferStarts[k] = p
        }
        writeIndices = .allocate(capacity: n); writeIndices.initialize(repeating: 0, count: n)
        dampStates = .allocate(capacity: n); dampStates.initialize(repeating: 0, count: n)
        lfoCos = .allocate(capacity: n); lfoCos.initialize(repeating: 1, count: n)
        lfoSin = .allocate(capacity: n); lfoSin.initialize(repeating: 0, count: n)
        lfoRotCos = .allocate(capacity: n)
        lfoRotSin = .allocate(capacity: n)
        for k in 0..<n {
            let w = 2 * Float.pi * Self.lfoRatesHz[k] / sampleRate
            lfoRotCos[k] = cosf(w)
            lfoRotSin[k] = sinf(w)
        }
        dampedOut = .allocate(capacity: n); dampedOut.initialize(repeating: 0, count: n)
        feedbackVec = .allocate(capacity: n); feedbackVec.initialize(repeating: 0, count: n)

        // Normalized order-8 Hadamard matrix via Sylvester's recursive construction, built once
        // (not on the IO thread) into a flat row-major buffer.
        hadamard = .allocate(capacity: n * n)
        var scratch: [[Float]] = ReverbNode.hadamardMatrix(order: n)
        let norm: Float = 1 / sqrt(Float(n))
        for r in 0..<n {
            for c in 0..<n {
                hadamard[r * n + c] = scratch[r][c] * norm
            }
        }
        scratch = []

        preDelayFrames = Int(Self.maxPreDelayMs / 1000 * sampleRate) + 4
        preDelayMask = (1 << (Int.bitWidth - (preDelayFrames - 1).leadingZeroBitCount)) - 1
        preDelayBuffer = .allocate(capacity: preDelayMask + 1)
        preDelayBuffer.initialize(repeating: 0, count: preDelayMask + 1)
    }

    /// Built once in `init` with ordinary `Array`s — never touched again, let alone from the IO
    /// thread.
    private static func hadamardMatrix(order: Int) -> [[Float]] {
        var h: [[Float]] = [[1]]
        while h.count < order {
            let m = h.count
            var next = [[Float]](repeating: [Float](repeating: 0, count: m * 2), count: m * 2)
            for r in 0..<m {
                for c in 0..<m {
                    next[r][c] = h[r][c]
                    next[r][c + m] = h[r][c]
                    next[r + m][c] = h[r][c]
                    next[r + m][c + m] = -h[r][c]
                }
            }
            h = next
        }
        return h
    }

    deinit {
        for k in 0..<Self.lineCount { lineBufferStarts[k].deallocate() }
        lineLengths.deallocate()
        bufferMasks.deallocate()
        lineBufferStarts.deallocate()
        writeIndices.deallocate()
        dampStates.deallocate()
        lfoCos.deallocate()
        lfoSin.deallocate()
        lfoRotCos.deallocate()
        lfoRotSin.deallocate()
        dampedOut.deallocate()
        feedbackVec.deallocate()
        hadamard.deallocate()
        preDelayBuffer.deallocate()
    }

    private func refreshParams() {
        let gen = params.generation
        guard gen != lastGeneration else { return }
        lastGeneration = gen
        sizeSmoother.target = params.get(0) / 100
        let dampingFraction = params.get(1) / 100
        // Higher damping -> lower cutoff -> more one-pole smoothing per bounce.
        let cutoffHz = 20_000 * powf(0.02, dampingFraction)
        dampSmoother.target = expf(-2 * Float.pi * cutoffHz / sampleRate)
        preDelaySmoother.target = params.get(2) / 1000 * sampleRate
        mixSmoother.target = params.get(3) / 100
    }

    func reset() {
        for k in 0..<Self.lineCount {
            lineBufferStarts[k].update(repeating: 0, count: bufferMasks[k] + 1)
            writeIndices[k] = 0
            dampStates[k] = 0
            lfoCos[k] = 1
            lfoSin[k] = 0
        }
        preDelayBuffer.update(repeating: 0, count: preDelayMask + 1)
        preDelayWrite = 0
        sizeSmoother.snap()
        dampSmoother.snap()
        preDelaySmoother.snap()
        mixSmoother.snap()
    }

    @inline(__always) private func readLine(_ index: Int, delaySamples: Float) -> Float {
        let buf = lineBufferStarts[index]
        let mask = bufferMasks[index]
        let pos = Float(writeIndices[index]) - delaySamples
        let i0 = Int(floor(pos))
        let frac = pos - Float(i0)
        let a = buf[i0 & mask]
        let b = buf[(i0 + 1) & mask]
        return a + (b - a) * frac
    }

    func process(_ block: FXBlock) {
        refreshParams()
        meters.inputPeak = fxBlockPeak(block)
        let n = Self.lineCount

        for i in 0..<block.frames {
            let dryL = block.left[i]
            let dryR = block.channels == 2 ? block.right[i] : dryL
            let monoIn = 0.5 * (dryL + dryR)

            // 30%...130% of the base length as the room grows from empty to `size` = 100,
            // smoothed per sample (not jumped at the block boundary) so a Size/Pre-Delay/
            // Damping drag crossfades the delay-line read positions and feedback gain instead
            // of relocating a read head or stepping the loop gain discontinuously.
            let sizeNow = sizeSmoother.next()
            let sizeScale = 0.3 + sizeNow
            let dampCoeffNow = dampSmoother.next()
            let preDelayNow = preDelaySmoother.next()
            let feedbackGainNow = 0.6 + 0.37 * sizeNow

            preDelayBuffer[preDelayWrite] = monoIn
            let readPos = Float(preDelayWrite) - max(0, preDelayNow)
            let i0 = Int(floor(readPos))
            let frac = readPos - Float(i0)
            let a = preDelayBuffer[i0 & preDelayMask]
            let b = preDelayBuffer[(i0 + 1) & preDelayMask]
            let prefed = a + (b - a) * frac
            preDelayWrite = (preDelayWrite + 1) & preDelayMask

            for k in 0..<n {
                let modulatedLength = Float(lineLengths[k]) * sizeScale + lfoSin[k] * Self.lfoDepthSamples
                let raw = readLine(k, delaySamples: max(4, modulatedLength))
                dampStates[k] = fxFlush(raw + dampCoeffNow * (dampStates[k] - raw))
                dampedOut[k] = dampStates[k]

                let rc = lfoRotCos[k], rs = lfoRotSin[k]
                var nc = lfoCos[k] * rc - lfoSin[k] * rs
                var ns = lfoCos[k] * rs + lfoSin[k] * rc
                // The rotation recurrence is exact only in infinite precision; in `Float` it
                // drifts the (cos, sin) vector away from unit magnitude over a long-running
                // session, growing the delay-line modulation depth past the capacity sized
                // from `maxDepthMs` until masked reads wrap into unrelated audio.
                fxRenormalizeLFO(&nc, &ns)
                lfoCos[k] = nc
                lfoSin[k] = fxFlush(ns)
            }

            for k in 0..<n {
                var acc: Float = 0
                let rowBase = k * n
                for j in 0..<n { acc += hadamard[rowBase + j] * dampedOut[j] }
                feedbackVec[k] = acc * feedbackGainNow
            }

            for k in 0..<n {
                let buf = lineBufferStarts[k]
                buf[writeIndices[k]] = prefed * 0.35 + feedbackVec[k]
                writeIndices[k] = (writeIndices[k] + 1) & bufferMasks[k]
            }

            // Alternate +/- taps across lines decorrelate L and R without extra delay lines.
            var outL: Float = 0, outR: Float = 0
            for k in 0..<n {
                if k % 2 == 0 { outL += dampedOut[k] } else { outR += dampedOut[k] }
            }
            outL *= 0.5
            outR *= 0.5

            let mix = mixSmoother.next()
            block.left[i] = dryL * (1 - mix) + outL * mix
            if block.channels == 2 { block.right[i] = dryR * (1 - mix) + outR * mix }
        }
        meters.outputPeak = fxBlockPeak(block)
        meters.activity = mixSmoother.value
    }
}
