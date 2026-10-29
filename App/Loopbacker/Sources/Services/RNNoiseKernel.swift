import Accelerate
import CRNNoise
import Foundation

/// Xiph's RNNoise (BSD-3-Clause), vendored under `CRNNoise/` at v0.2 with its default model.
/// Takes 480-sample frames scaled to int16 range, so `process` rescales from ±1 and back.
///
/// Real-time safe: `rnnoise_process_frame` and `rnnoise_init(_, nil)` never allocate (the only
/// mallocs in the vendored code are in `rnnoise_create` and the model loaders, unused here),
/// checked with an interposed malloc over 2000 frames and 6 resets. `rnnoise_init` with a nil
/// model just clears the state and points it at the compiled-in weights, so it doubles as reset.
///
/// Delay: 960 samples (two hops), measured with an impulse. Analysis covers the current and
/// previous frame, and a frame's overlap-add completes only with the next call. ~0.19 ms per
/// 10 ms hop on an M4 Max.
///
/// The compiled-in weights stay in the binary's read-only data, unwired: mlock refuses those
/// pages (EPERM), and every hop reads all of them, as it does the callback's own code.
final class RNNoiseKernel: DenoiseKernel, @unchecked Sendable {
    let hop = 480
    let delay = 960

    /// One wired (mlock'd) anonymous mapping holds the `DenoiseState` (opaque; sized by
    /// `rnnoise_get_size()`) and the scratch buffers at RNNoise's scale.
    private let arena: UnsafeMutableRawPointer
    private let arenaSize: Int
    private let state: OpaquePointer
    private let scaledIn: UnsafeMutablePointer<Float>
    private let scaledOut: UnsafeMutablePointer<Float>

    private init(arena: UnsafeMutableRawPointer, arenaSize: Int, stateSize: Int) {
        self.arena = arena
        self.arenaSize = arenaSize
        state = OpaquePointer(arena)
        let floats = (arena + (stateSize + 63) / 64 * 64).bindMemory(to: Float.self, capacity: 960)
        scaledIn = floats
        scaledOut = floats + 480
    }

    deinit {
        munmap(arena, arenaSize)
    }

    /// An RNNoise kernel using the compiled-in default model, or nil (logged) if the vendored
    /// library disagrees with this file's frame size. Cheap: a mapping and a `memset`-sized init.
    static func make() -> RNNoiseKernel? {
        let frameSize = Int(rnnoise_get_frame_size())
        guard frameSize == 480 else {
            nsLogger.error("RNNoise frame size changed: expected 480, got \(frameSize)")
            return nil
        }
        let stateSize = Int(rnnoise_get_size())
        let page = Int(getpagesize())
        let total = ((stateSize + 63) / 64 * 64 + 960 * MemoryLayout<Float>.size + page - 1) / page * page
        guard let mapping = mmap(nil, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
              mapping != MAP_FAILED else {
            nsLogger.error("RNNoise buffers could not be mapped")
            return nil
        }
        if mlock(mapping, total) != 0 {
            nsLogger.error("Could not wire RNNoise buffers: errno \(errno)")
        }
        guard rnnoise_init(OpaquePointer(mapping), nil) == 0 else {
            munmap(mapping, total)
            nsLogger.error("rnnoise_init failed")
            return nil
        }
        return RNNoiseKernel(arena: mapping, arenaSize: total, stateSize: stateSize)
    }

    func reset() {
        rnnoise_init(state, nil)
    }

    func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>) -> Bool {
        var scale: Float = 32768
        vDSP_vsmul(input, 1, &scale, scaledIn, 1, vDSP_Length(hop))
        _ = rnnoise_process_frame(state, scaledOut, scaledIn)
        var invScale: Float = 1 / 32768
        vDSP_vsmul(scaledOut, 1, &invScale, output, 1, vDSP_Length(hop))
        return true
    }
}
