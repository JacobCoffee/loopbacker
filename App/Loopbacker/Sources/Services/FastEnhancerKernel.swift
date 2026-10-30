import Accelerate
import Foundation

/// aask1357's FastEnhancer-M 48 kHz model (MIT), bundled as `FastEnhancer_M_48k.mlmodelc` and
/// reproducible with `scripts/convert-fastenhancer.py m` (that script also builds the S and L
/// checkpoints the app compared it against -- see `docs/architecture/ARCHITECTURE.md`). STFT
/// geometry (window, hop, bin count) comes from the model's own metadata
/// (`CompiledGraph.windowLength/hopLength`) rather than a hardcoded constant, so this kernel
/// works unmodified for any FastEnhancer checkpoint at this 1024-sample window.
///
/// Like `DPDFNetKernel`, this runs through BNNS Graph with caller-provided workspace and
/// buffers: no allocation, no locks, no thread hops, so it runs inline on the capture device's
/// IO thread -- see `docs/architecture/ARCHITECTURE.md` for the shipped variant's benchmark.
///
/// FastEnhancer is zero-lookahead: every layer except the per-frequency-bin GRUs is purely
/// per-frame (strided convs and self-attention across frequency bins, never across time), and
/// the GRUs only look backward. So unlike DPDFNet (which has four hops of model-inherent
/// lookahead), the only delay here is STFT analysis/synthesis framing.
///
/// Delay: `windowLength - hop` samples, measured with an impulse through the exact
/// analysis/synthesis path below (also reproduced in `scripts/convert-fastenhancer.py`'s
/// companion Python simulation): with a trailing analysis window (`[k*hop - windowLength,
/// (k+1)*hop)` for hop `k`) and `ceil(windowLength/hop)`-way overlapping synthesis, a sample is
/// only final once every overlapping frame has contributed, which takes exactly one window
/// minus one hop of lookback. Total latency (`delay + hop - 1`) is therefore `windowLength - 1`
/// samples regardless of hop size: every FastEnhancer checkpoint here shares the same ~21.3 ms
/// total latency (windowLength is 1024 for all of them), just split differently between
/// `delay` and the `hop - 1` fill wait.
final class FastEnhancerKernel: DenoiseKernel, @unchecked Sendable {
    let hop: Int
    let delay: Int

    private let windowLength: Int
    private let bins: Int
    /// `windowLength - hop`: both the analysis cache (samples carried into the next call's
    /// trailing window) and the synthesis cache (samples still waiting on future frames'
    /// overlap-add contributions) are exactly this size.
    private let cacheLen: Int

    /// Keeps the compiled graph alive while this context uses it.
    private let model: FastEnhancerModel
    private let context: bnns_graph_context_t
    private let stateSize: Int
    private let argumentCount: Int
    private let stateInPosition: Int
    private let stateOutPosition: Int
    /// One wired (mlock'd) anonymous mapping holds the workspace and every buffer the IO thread
    /// touches, so memory pressure can't page or compress them out from under the callback.
    private let arena: UnsafeMutableRawPointer
    private let arenaSize: Int
    private let workspace: UnsafeMutableRawPointer
    private let workspaceSize: Int
    private let arguments: UnsafeMutablePointer<bnns_graph_argument_t>
    private let specIn: UnsafeMutablePointer<Float>
    private let specOut: UnsafeMutablePointer<Float>
    /// Ping-pong: even hops read `stateA` and write `stateB`, odd hops the reverse.
    private let stateA: UnsafeMutablePointer<Float>
    private let stateB: UnsafeMutablePointer<Float>
    private let initialState: UnsafeMutablePointer<Float>
    private var pingPong = 0
    private var calls = 0

    private let forwardDFT: vDSP_DFT_Setup
    private let inverseDFT: vDSP_DFT_Setup
    /// Hann analysis window (periodic, matching `torch.hann_window(..., periodic=True)`).
    private let analysisWindow: UnsafeMutablePointer<Float>
    /// `window[i] / sum_m(window[i - m*hop]^2)` over every `m` keeping `i - m*hop` in bounds:
    /// the general synthesis-side COLA normalisation FastEnhancer's `ONNXSTFT.inverse` applies
    /// for any overlap factor, derived in `scripts/convert-fastenhancer.py`.
    private let synthesisWindow: UnsafeMutablePointer<Float>
    /// The trailing `cacheLen` samples of the last analysis frame (the dry input not yet fully
    /// consumed by the next call's window).
    private let analysisCache: UnsafeMutablePointer<Float>
    private let frame: UnsafeMutablePointer<Float>
    private let realIn: UnsafeMutablePointer<Float>
    private let imagIn: UnsafeMutablePointer<Float>
    private let realOut: UnsafeMutablePointer<Float>
    private let imagOut: UnsafeMutablePointer<Float>
    /// Synthesis overlap-add remainder: the last `cacheLen` samples of this call's windowed
    /// ifft output, still waiting on future calls' overlapping frames, carried into the start of
    /// the next call's output.
    private let synthesisCache: UnsafeMutablePointer<Float>

    /// Cheap once `model` is loaded: one context, buffers, and a warm-up hop.
    init?(model: FastEnhancerModel) {
        let graph = model.graph
        let context = BNNSGraphContextMake(graph.graph)
        guard context.data != nil else {
            nsLogger.error("BNNSGraphContextMake failed")
            return nil
        }
        BNNSGraphContextSetArgumentType(context, BNNSGraphArgumentTypePointer)
        let size = BNNSGraphContextGetWorkspaceSize(context, nil)
        let n = graph.windowLength
        let hop = graph.hopLength
        guard size >= 0, hop > 0, n > hop,
              let forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .FORWARD),
              let inverse = vDSP_DFT_zop_CreateSetup(forward, vDSP_Length(n), .INVERSE) else {
            BNNSGraphContextDestroy(context)
            nsLogger.error("FastEnhancer setup failed")
            return nil
        }
        self.model = model
        self.context = context
        self.hop = hop
        self.delay = n - hop
        windowLength = n
        bins = n / 2 + 1
        cacheLen = n - hop
        stateSize = graph.stateSize
        argumentCount = graph.argumentCount
        stateInPosition = graph.stateInPosition
        stateOutPosition = graph.stateOutPosition
        forwardDFT = forward
        inverseDFT = inverse
        workspaceSize = size

        let page = Int(getpagesize())
        func rounded(_ bytes: Int, to alignment: Int) -> Int { (bytes + alignment - 1) / alignment * alignment }
        let floatCounts = [2 * bins, 2 * bins, graph.stateSize, graph.stateSize, graph.stateSize,
                           n, n, cacheLen, n, n, n, n, n, cacheLen]
        let argumentBytes = rounded(graph.argumentCount * MemoryLayout<bnns_graph_argument_t>.stride, to: 64)
        let total = rounded(rounded(max(size, 1), to: page) + argumentBytes
            + floatCounts.reduce(0) { $0 + rounded($1 * MemoryLayout<Float>.size, to: 64) }, to: page)
        guard let mapping = mmap(nil, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
              mapping != MAP_FAILED else {
            BNNSGraphContextDestroy(context)
            vDSP_DFT_DestroySetup(forward)
            vDSP_DFT_DestroySetup(inverse)
            nsLogger.error("FastEnhancer buffers could not be mapped")
            return nil
        }
        if mlock(mapping, total) != 0 {
            nsLogger.error("Could not wire FastEnhancer buffers: errno \(errno)")
        }
        arena = mapping
        arenaSize = total
        workspace = mapping
        var offset = rounded(max(size, 1), to: page)
        let args = (mapping + offset).bindMemory(to: bnns_graph_argument_t.self, capacity: graph.argumentCount)
        args.initialize(repeating: bnns_graph_argument_t(), count: graph.argumentCount)
        arguments = args
        offset += argumentBytes
        func floats(_ count: Int) -> UnsafeMutablePointer<Float> {
            let p = (mapping + offset).bindMemory(to: Float.self, capacity: count)
            offset += rounded(count * MemoryLayout<Float>.size, to: 64)
            return p
        }
        specIn = floats(2 * bins)
        specOut = floats(2 * bins)
        stateA = floats(graph.stateSize)
        stateB = floats(graph.stateSize)
        let initial = floats(graph.stateSize)
        graph.stateInit.withUnsafeBufferPointer { initial.update(from: $0.baseAddress!, count: $0.count) }
        initialState = initial
        analysisWindow = floats(n)
        synthesisWindow = floats(n)
        analysisCache = floats(cacheLen)
        frame = floats(n)
        realIn = floats(n)
        imagIn = floats(n)
        realOut = floats(n)
        imagOut = floats(n)
        synthesisCache = floats(cacheLen)

        arguments[graph.inputPosition].data_ptr = UnsafeMutableRawPointer(specIn)
        arguments[graph.inputPosition].data_ptr_size = 2 * bins * MemoryLayout<Float>.size
        arguments[graph.outputPosition].data_ptr = UnsafeMutableRawPointer(specOut)
        arguments[graph.outputPosition].data_ptr_size = 2 * bins * MemoryLayout<Float>.size
        arguments[graph.stateInPosition].data_ptr_size = graph.stateSize * MemoryLayout<Float>.size
        arguments[graph.stateOutPosition].data_ptr_size = graph.stateSize * MemoryLayout<Float>.size

        for i in 0..<n {
            analysisWindow[i] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n)))
        }
        // General COLA synthesis normalisation for any overlap factor: sum every overlapping
        // frame's squared window contribution at sample i (frames shifted by whole hops, never
        // wrapping), not just the K=2 neighbour `(i+hop)%n` special case a 2x-overlap hop allows.
        let overlap = (n + hop - 1) / hop
        for i in 0..<n {
            var sumSquares: Float = 0
            var m = -overlap
            while m <= overlap {
                let idx = i - m * hop
                if idx >= 0 && idx < n { sumSquares += analysisWindow[idx] * analysisWindow[idx] }
                m += 1
            }
            synthesisWindow[i] = analysisWindow[i] / (sumSquares == 0 ? 1 : sumSquares)
        }

        // Warm-up hop here, off the IO thread: the first execution touches context memory
        // BNNS allocates lazily.
        stateA.update(from: initialState, count: graph.stateSize)
        arguments[graph.stateInPosition].data_ptr = UnsafeMutableRawPointer(stateA)
        arguments[graph.stateOutPosition].data_ptr = UnsafeMutableRawPointer(stateB)
        if BNNSGraphContextExecute(context, nil, graph.argumentCount, arguments, size,
                                   workspace.assumingMemoryBound(to: CChar.self)) != 0 {
            nsLogger.error("FastEnhancer warm-up execution failed")
        }
    }

    deinit {
        BNNSGraphContextDestroy(context)
        vDSP_DFT_DestroySetup(forwardDFT)
        vDSP_DFT_DestroySetup(inverseDFT)
        munmap(arena, arenaSize)
    }

    func reset() {
        calls = 0
        pingPong = 0
        analysisCache.update(repeating: 0, count: cacheLen)
        synthesisCache.update(repeating: 0, count: cacheLen)
        stateA.update(from: initialState, count: stateSize)
    }

    /// Frames `analysisCache ++ input` (the trailing `windowLength`-sample analysis window),
    /// runs one STFT frame through the model, and emits the overlap-added hop that completes
    /// this call: `synthesisCache` (every not-yet-finalised sample from past calls) plus this
    /// call's own windowed contribution, added into the first `cacheLen` samples before the
    /// first `hop` of those are read out and the rest become the next call's `synthesisCache`.
    func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>) -> Bool {
        let n = windowLength
        frame.update(from: analysisCache, count: cacheLen)
        frame.advanced(by: cacheLen).update(from: input, count: hop)
        calls += 1

        // Analysis STFT frame (unnormalised, like numpy.fft.rfft).
        vDSP_vmul(frame, 1, analysisWindow, 1, realIn, 1, vDSP_Length(n))
        imagIn.update(repeating: 0, count: n)
        vDSP_DFT_Execute(forwardDFT, realIn, imagIn, realOut, imagOut)
        for k in 0..<bins {
            specIn[2 * k] = realOut[k]
            specIn[2 * k + 1] = imagOut[k]
        }

        arguments[stateInPosition].data_ptr = UnsafeMutableRawPointer(pingPong == 0 ? stateA : stateB)
        arguments[stateOutPosition].data_ptr = UnsafeMutableRawPointer(pingPong == 0 ? stateB : stateA)
        let status = BNNSGraphContextExecute(context, nil, argumentCount, arguments, workspaceSize,
                                             workspace.assumingMemoryBound(to: CChar.self))
        guard status == 0 else { return false }
        pingPong = 1 - pingPong

        // Rebuild the Hermitian spectrum and inverse-transform.
        for k in 0..<bins {
            realIn[k] = specOut[2 * k]
            imagIn[k] = specOut[2 * k + 1]
        }
        for k in bins..<n {
            realIn[k] = realIn[n - k]
            imagIn[k] = -imagIn[n - k]
        }
        vDSP_DFT_Execute(inverseDFT, realIn, imagIn, realOut, imagOut)

        // Synthesis window, then add in every past call's carried overlap-add remainder: the
        // first `cacheLen` samples of `realOut` are now final.
        var scale = 1 / Float(n)
        vDSP_vsmul(realOut, 1, &scale, realOut, 1, vDSP_Length(n))
        vDSP_vmul(realOut, 1, synthesisWindow, 1, realOut, 1, vDSP_Length(n))
        vDSP_vadd(realOut, 1, synthesisCache, 1, realOut, 1, vDSP_Length(cacheLen))
        output.update(from: realOut, count: hop)
        synthesisCache.update(from: realOut.advanced(by: hop), count: cacheLen)

        analysisCache.update(from: frame.advanced(by: hop), count: cacheLen)
        return true
    }
}

/// The FastEnhancer model compiled for BNNS Graph. One instance serves every kernel made from
/// it (each gets its own context); its wired memory is freed once the last one is gone.
final class FastEnhancerModel: Sendable {
    fileprivate let graph: CompiledGraph

    private init(graph: CompiledGraph) {
        self.graph = graph
    }

    deinit {
        graph.release()
        nsLogger.info("FastEnhancer model freed")
    }

    /// Loads the compiled model at `url` (an `.mlmodelc`). Slow: ~1.5 s to compile the first
    /// time per model and OS build, ~30 ms from the cache after that. Never call it on the
    /// audio thread or the routing queue.
    static func load(from url: URL) -> FastEnhancerModel? {
        CompiledGraph.load(model: url, cacheName: "FastEnhancer_M_48k", inputArgument: "spec",
                            stateInArgument: "state_in", outputArgument: "spec_e",
                            stateOutArgument: "state_out").map(FastEnhancerModel.init)
    }

    /// The model shipped in the app bundle. Same cost as `load(from:)`.
    static func loadBundled() -> FastEnhancerModel? {
        guard let url = Bundle.main.url(forResource: "FastEnhancer_M_48k", withExtension: "mlmodelc") else {
            nsLogger.error("FastEnhancer_M_48k.mlmodelc missing from the app bundle")
            return nil
        }
        return load(from: url)
    }

}
