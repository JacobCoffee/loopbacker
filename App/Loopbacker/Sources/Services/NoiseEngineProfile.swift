import Foundation
import os.log

/// What each noise suppression engine costs and does, for choosing between them.
struct NoiseEngineProfile {
    let engine: NoiseSuppressionEngine
    let name: String
    /// Added latency, fixed by the engine's design (see `NoiseSuppressor`).
    let latencyMs: Int
    let cleanup: String
    let tradeoff: String

    static func of(_ engine: NoiseSuppressionEngine) -> NoiseEngineProfile {
        switch engine {
        case .dpdfnet:
            NoiseEngineProfile(engine: engine, name: "DPDFNet", latencyMs: 60, cleanup: "Strongest",
                               tradeoff: "Removes fans, keyboards, traffic and chatter. The delay is noticeable when monitoring yourself.")
        case .fastenhancer:
            NoiseEngineProfile(engine: engine, name: "FastEnhancer", latencyMs: 21, cleanup: "Strong",
                               tradeoff: "Removes fans, hum and most chatter, close to DPDFNet's cleanup, at less than half DPDFNet's latency and a fraction of its CPU.")
        case .rnnoise:
            NoiseEngineProfile(engine: engine, name: "RNNoise", latencyMs: 30, cleanup: "Light",
                               tradeoff: "Removes steady hiss and hum. Clicks and keyboard taps get through.")
        }
    }
}

/// Measures each engine's processing cost on this Mac, so the UI can show real numbers and
/// recommend one. Runs once per launch, off the main thread, when first asked.
@MainActor
final class NoiseEngineBenchmark: ObservableObject {
    static let shared = NoiseEngineBenchmark()

    /// Fraction of one core each engine uses on a single stream (processing time per hop over
    /// the hop's 10 ms duration).
    @Published private(set) var coreLoad: [NoiseSuppressionEngine: Double] = [:]
    @Published private(set) var isMeasuring = false

    /// DPDFNet and FastEnhancer are recommended while they stay under this share of a core.
    /// Each 512-frame IO callback can run two hops, and the IO thread also carries the mix and
    /// effects, so this keeps the worst callback well inside its deadline. RNNoise has no limit:
    /// it's the fallback of last resort, already a fraction of a core by design.
    static let loadLimit: [NoiseSuppressionEngine: Double] = [.dpdfnet: 0.2, .fastenhancer: 0.2]
    /// Best cleanup first; `recommended` picks the first of these that measures under its
    /// `loadLimit`, falling back to RNNoise.
    static let qualityOrder: [NoiseSuppressionEngine] = [.dpdfnet, .fastenhancer, .rnnoise]

    /// The Mac's chip, e.g. "Apple M4 Max".
    let chipName: String = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "this Mac" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return "this Mac" }
        return String(decoding: bytes.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
    }()

    private var started = false

    /// The best-cleanup engine that stays under its CPU budget on this Mac, falling back to
    /// RNNoise. Unmeasured engines are assumed to qualify, so the UI doesn't flip recommendations
    /// while `measureIfNeeded` is still running.
    var recommended: NoiseSuppressionEngine {
        for engine in Self.qualityOrder.dropLast() {
            if let load = coreLoad[engine], load > Self.loadLimit[engine] ?? .infinity { continue }
            return engine
        }
        return Self.qualityOrder.last!
    }

    func measureIfNeeded() {
        guard !started else { return }
        started = true
        isMeasuring = true
        Task.detached(priority: .userInitiated) {
            var results: [NoiseSuppressionEngine: Double] = [:]
            for engine in NoiseSuppressionEngine.allCases {
                if let load = Self.measure(engine) { results[engine] = load }
            }
            await MainActor.run {
                self.coreLoad = results
                self.isMeasuring = false
            }
        }
    }

    /// Times 200 hops of noise after a 20-hop warm-up. Model-backed engines load their model
    /// just for this and free it after.
    nonisolated private static func measure(_ engine: NoiseSuppressionEngine) -> Double? {
        let kernel: (any DenoiseKernel)?
        switch engine {
        case .dpdfnet: kernel = NoiseSuppressionModel.loadBundled().flatMap { DPDFNetKernel(model: $0) }
        case .fastenhancer: kernel = FastEnhancerModel.loadBundled().flatMap { FastEnhancerKernel(model: $0) }
        case .rnnoise: kernel = RNNoiseKernel.make()
        }
        guard let kernel else { return nil }
        let hop = kernel.hop
        var seed: UInt32 = 0x9E37_79B9
        let input = (0..<hop).map { _ -> Float in
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            return Float(seed) / Float(UInt32.max) * 0.2 - 0.1
        }
        var output = [Float](repeating: 0, count: hop)
        let hops = 200
        var elapsed: UInt64 = 0
        input.withUnsafeBufferPointer { inp in
            output.withUnsafeMutableBufferPointer { out in
                for _ in 0..<20 { _ = kernel.process(inp.baseAddress!, out.baseAddress!) }
                let start = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<hops { _ = kernel.process(inp.baseAddress!, out.baseAddress!) }
                elapsed = DispatchTime.now().uptimeNanoseconds - start
            }
        }
        let perHop = Double(elapsed) / Double(hops) / 1e9
        let load = perHop / (Double(hop) / NoiseSuppressor.sampleRate)
        nsLogger.info("\(engine.rawValue, privacy: .public): \(perHop * 1e6, format: .fixed(precision: 0)) µs per hop, \(load * 100, format: .fixed(precision: 1))% of a core")
        return load
    }
}
