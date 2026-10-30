import Foundation

/// Shared buffer utilities for the FX chain and app-audio processor. `FXNode`s process planar
/// `FXBlock`s; routes carry interleaved audio, so every stage of IO-thread processing
/// deinterleaves the voice pair into preallocated scratch buffers, runs the nodes, then
/// reinterleaves. All functions here are IO-thread safe: no allocation, every buffer is passed
/// in already sized to at least the caller's frame count.
enum FXBlockIO {
    /// Copies the first one or two interleaved channels of `buffer` into `left`/`right`.
    /// Returns true when the two channels are bitwise identical for the whole block (e.g. a
    /// mono mic fanned to L+R): callers should then process `left` alone and fan it back out,
    /// rather than run a true stereo signal through twice.
    @inline(__always)
    static func deinterleave(_ buffer: UnsafePointer<Float>, frames: Int, stride: Int,
                             left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) -> Bool {
        guard stride >= 2 else {
            for i in 0..<frames { left[i] = buffer[i * stride] }
            return true
        }
        var identical = true
        for i in 0..<frames {
            let l = buffer[i * stride]
            let r = buffer[i * stride + 1]
            left[i] = l
            right[i] = r
            if l != r { identical = false }
        }
        return identical
    }

    /// Writes `left`/`right` back into the first `channels` interleaved slots of `buffer`,
    /// leaving any further channels (wider mic devices) untouched. When `mono`, `right` is
    /// ignored and `left` is fanned to both slots.
    @inline(__always)
    static func reinterleave(_ buffer: UnsafeMutablePointer<Float>, frames: Int, stride: Int, channels: Int,
                             left: UnsafePointer<Float>, right: UnsafePointer<Float>, mono: Bool) {
        guard stride >= 2 else {
            for i in 0..<frames { buffer[i] = left[i] }
            return
        }
        for i in 0..<frames {
            buffer[i * stride] = left[i]
            if channels >= 2 { buffer[i * stride + 1] = mono ? left[i] : right[i] }
        }
    }

    /// Linear RMS of a planar run.
    @inline(__always)
    static func rms(_ buf: UnsafePointer<Float>, frames: Int) -> Float {
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<frames { sum += buf[i] * buf[i] }
        return sqrtf(sum / Float(frames))
    }

    /// Smallest power of two that is at least `n` (minimum 1).
    static func nextPowerOfTwo(atLeast n: Int) -> Int {
        guard n > 1 else { return 1 }
        return 1 << (Int.bitWidth - (n - 1).leadingZeroBitCount)
    }
}
