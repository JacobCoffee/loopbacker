import Accelerate
import Foundation

/// Stereo echo with feedback. A flat, preallocated circular buffer per channel is read with
/// 4-point Catmull-Rom interpolation at a fractional delay time; `time` changes are slewed
/// (`FXSmoother`) rather than jump-cut, so dragging the knob glides the echo instead of
/// retriggering a click or a pitch-bend artifact from the read head jumping. The feedback path
/// runs through a one-pole low-pass (`highCut`) so repeats darken over time like tape/analog
/// echoes, and a soft clipper (`fxSoftClip`) so feedback near 90% can't blow up into a runaway
/// DC/clipping buildup — it saturates smoothly instead.
final class DelayNode: FXNode, @unchecked Sendable {
    private static let maxDelayMs: Float = 1000

    let kind: FXNodeKind = .delay
    let specs = FXBuiltinSpecs.delay
    let params: FXParamStore
    let meters = FXMeters()
    let latencySamples = 0

    private let sampleRate: Float
    private var lastGeneration: UInt32 = .max

    private var timeSmoother: FXSmoother
    private var feedback: Float = 0.3
    private var mixSmoother: FXSmoother
    private var lpCoeff: Float = 0.3 // one-pole low-pass coefficient for the feedback high-cut.

    private var fbStateL: Float = 0
    private var fbStateR: Float = 0

    private let bufferFrames: Int
    private let bufferMask: Int
    private let bufL: UnsafeMutablePointer<Float>
    private let bufR: UnsafeMutablePointer<Float>
    private var writeIndex = 0

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
        params = FXParamStore(specs: FXBuiltinSpecs.delay)
        timeSmoother = FXSmoother(initial: 250, timeMs: 80, sampleRate: sampleRate)
        mixSmoother = FXSmoother(initial: 0.25, timeMs: 20, sampleRate: sampleRate)
        let needed = Int((Self.maxDelayMs / 1000 * sampleRate).rounded(.up)) + 8
        bufferFrames = 1 << (Int.bitWidth - (needed - 1).leadingZeroBitCount)
        bufferMask = bufferFrames - 1
        bufL = .allocate(capacity: bufferFrames)
        bufR = .allocate(capacity: bufferFrames)
        bufL.initialize(repeating: 0, count: bufferFrames)
        bufR.initialize(repeating: 0, count: bufferFrames)
    }

    deinit {
        bufL.deallocate()
        bufR.deallocate()
    }

    private func refreshParams() {
        let gen = params.generation
        guard gen != lastGeneration else { return }
        lastGeneration = gen
        timeSmoother.target = params.get(0)
        feedback = params.get(1) / 100
        let cutHz = params.get(2)
        lpCoeff = expf(-2 * Float.pi * max(cutHz, 1) / sampleRate)
        mixSmoother.target = params.get(3) / 100
    }

    func reset() {
        bufL.update(repeating: 0, count: bufferFrames)
        bufR.update(repeating: 0, count: bufferFrames)
        writeIndex = 0
        fbStateL = 0
        fbStateR = 0
        timeSmoother.snap()
        mixSmoother.snap()
    }

    @inline(__always) private func read(_ buf: UnsafeMutablePointer<Float>, delaySamples: Float) -> Float {
        let pos = Float(writeIndex) - delaySamples
        let i0 = Int(floor(pos))
        let frac = pos - Float(i0)
        let p0 = buf[(i0 - 1) & bufferMask]
        let p1 = buf[i0 & bufferMask]
        let p2 = buf[(i0 + 1) & bufferMask]
        let p3 = buf[(i0 + 2) & bufferMask]
        let a0 = -0.5 * p0 + 1.5 * p1 - 1.5 * p2 + 0.5 * p3
        let a1 = p0 - 2.5 * p1 + 2 * p2 - 0.5 * p3
        let a2 = -0.5 * p0 + 0.5 * p2
        let a3 = p1
        return ((a0 * frac + a1) * frac + a2) * frac + a3
    }

    func process(_ block: FXBlock) {
        refreshParams()
        meters.inputPeak = fxBlockPeak(block)

        for i in 0..<block.frames {
            let l = block.left[i]
            let r = block.channels == 2 ? block.right[i] : l

            let delaySamples = max(1, timeSmoother.next() / 1000 * sampleRate)
            let tapL = read(bufL, delaySamples: delaySamples)
            let tapR = block.channels == 2 ? read(bufR, delaySamples: delaySamples) : tapL

            fbStateL = fxFlush(tapL + lpCoeff * (fbStateL - tapL))
            fbStateR = fxFlush(tapR + lpCoeff * (fbStateR - tapR))
            let fbL = fxSoftClip(fbStateL * feedback)
            let fbR = fxSoftClip(fbStateR * feedback)

            bufL[writeIndex] = l + fbL
            bufR[writeIndex] = r + fbR
            writeIndex = (writeIndex + 1) & bufferMask

            let mix = mixSmoother.next()
            block.left[i] = l * (1 - mix) + tapL * mix
            if block.channels == 2 { block.right[i] = r * (1 - mix) + tapR * mix }
        }
        meters.outputPeak = fxBlockPeak(block)
        meters.activity = mixSmoother.value
    }
}
