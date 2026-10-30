import Accelerate
import CRNNoise
import Foundation

/// Speech probability from Xiph's RNNoise, independent of `RNNoiseKernel`'s own instance so the
/// gate's voice trigger works whether or not noise suppression is enabled on the route. Owns a
/// private `DenoiseState` and buffers input into RNNoise's fixed 480-sample (10 ms) hop
/// internally, so callers can feed any block size.
///
/// Real-time safe: all RNNoise calls used here (`rnnoise_init`, `rnnoise_process_frame`) never
/// allocate; the only buffers touched are the ones mapped in `init`.
final class VoiceActivityDetector: @unchecked Sendable {
    private static let hop = 480

    private let arena: UnsafeMutableRawPointer
    private let arenaSize: Int
    private let state: OpaquePointer
    /// Scaled scratch for RNNoise's int16-range API.
    private let scaledIn: UnsafeMutablePointer<Float>
    private let scaledOut: UnsafeMutablePointer<Float>
    /// Partial hop accumulated across `process` calls that don't land on a 480-sample boundary.
    private let hopBuffer: UnsafeMutablePointer<Float>
    private var hopFill = 0
    private var lastProbability: Float = 0

    init?() {
        let frameSize = Int(rnnoise_get_frame_size())
        guard frameSize == Self.hop else {
            nsLogger.error("RNNoise frame size changed: expected 480, got \(frameSize)")
            return nil
        }
        let stateSize = Int(rnnoise_get_size())
        func rounded(_ bytes: Int, to alignment: Int) -> Int { (bytes + alignment - 1) / alignment * alignment }
        let stateBytes = rounded(stateSize, to: 64)
        let scratchFloats = Self.hop * 3 // scaledIn, scaledOut, hopBuffer
        let total = rounded(stateBytes + scratchFloats * MemoryLayout<Float>.size, to: Int(getpagesize()))
        guard let mapping = mmap(nil, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
              mapping != MAP_FAILED else {
            nsLogger.error("VAD buffers could not be mapped")
            return nil
        }
        if mlock(mapping, total) != 0 {
            nsLogger.error("Could not wire VAD buffers: errno \(errno)")
        }
        guard rnnoise_init(OpaquePointer(mapping), nil) == 0 else {
            munmap(mapping, total)
            nsLogger.error("VAD rnnoise_init failed")
            return nil
        }
        arena = mapping
        arenaSize = total
        state = OpaquePointer(mapping)
        let floats = (mapping + stateBytes).bindMemory(to: Float.self, capacity: scratchFloats)
        scaledIn = floats
        scaledOut = floats + Self.hop
        hopBuffer = floats + 2 * Self.hop
    }

    deinit {
        munmap(arena, arenaSize)
    }

    /// Clears accumulated history and the partial hop buffer, for the start of a new stream.
    func reset() {
        rnnoise_init(state, nil)
        hopFill = 0
        lastProbability = 0
    }

    /// IO thread. Feeds `frames` mono samples (full scale ±1) and returns the most recent
    /// speech probability (0...1); a block shorter than one 10 ms hop since the last completed
    /// hop returns the previous value unchanged.
    func process(_ mono: UnsafePointer<Float>, frames: Int) -> Float {
        var offset = 0
        while offset < frames {
            let n = min(frames - offset, Self.hop - hopFill)
            (hopBuffer + hopFill).update(from: mono + offset, count: n)
            hopFill += n
            offset += n
            if hopFill == Self.hop {
                var scale: Float = 32768
                vDSP_vsmul(hopBuffer, 1, &scale, scaledIn, 1, vDSP_Length(Self.hop))
                lastProbability = rnnoise_process_frame(state, scaledOut, scaledIn)
                hopFill = 0
            }
        }
        return lastProbability
    }
}
