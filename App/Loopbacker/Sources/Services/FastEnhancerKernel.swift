import Accelerate
import Foundation

/// aask1357's FastEnhancer-S 48 kHz model (MIT), bundled as `FastEnhancer_S_48k.mlmodelc` and
/// reproducible with `scripts/convert-fastenhancer.py`.
///
/// Like `DPDFNetKernel`, this runs through BNNS Graph with caller-provided workspace and
/// buffers: no allocation, no locks, no thread hops, so it runs inline on the capture device's
/// IO thread. FastEnhancer-S is tiny (212K parameters) next to DPDFNet, and measures
/// ~0.2 ms per 10.67 ms hop on an M4 Max (~2% of a core) -- see
/// `docs/architecture/ARCHITECTURE.md` for the full benchmark.
///
/// FastEnhancer is zero-lookahead: every layer except the per-frequency-bin GRUs is purely
/// per-frame (strided convs and self-attention across frequency bins, never across time), and
/// the GRUs only look backward. So unlike DPDFNet (which has four hops of model-inherent
/// lookahead), the only delay here is STFT analysis/synthesis framing.
///
/// Delay: 512 samples (one hop), measured with an impulse through the exact analysis/synthesis
/// path below (see `scripts/convert-fastenhancer.py`'s derivation notes): with a 1024-sample
/// window and 512-sample hop, the analysis window for hop `k` spans samples
/// `[k*hop - 512, (k+1)*hop)` (trailing, no future samples), and the synthesis overlap-add
/// completes a hop's output only once the next hop's frame has contributed its earlier half.
/// That one hop of synthesis latency is exactly offset by the window's one hop of analysis
/// lookback, leaving delay = hop = 512 samples (10.67 ms) -- matching the model's reported zero
/// lookahead and ~10.7 ms algorithmic latency.
final class FastEnhancerKernel: DenoiseKernel, @unchecked Sendable {
    private static let windowLength = 1024
    private static let bins = windowLength / 2 + 1

    let hop = 512
    let delay = 512

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
    /// `window / (window[i]^2 + window[(i+hop)%n]^2)`: the synthesis-side COLA normalisation
    /// FastEnhancer's `ONNXSTFT.inverse` applies, derived in `scripts/convert-fastenhancer.py`.
    private let synthesisWindow: UnsafeMutablePointer<Float>
    /// The previous hop's raw input samples: with a 2x-overlap, hop-sized analysis cache, the
    /// cache after each call is always exactly the hop just consumed.
    private let previousHop: UnsafeMutablePointer<Float>
    private let frame: UnsafeMutablePointer<Float>
    private let realIn: UnsafeMutablePointer<Float>
    private let imagIn: UnsafeMutablePointer<Float>
    private let realOut: UnsafeMutablePointer<Float>
    private let imagOut: UnsafeMutablePointer<Float>
    /// The synthesis window's second half, carried to be added into next call's first half.
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
        guard size >= 0,
              let forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.windowLength), .FORWARD),
              let inverse = vDSP_DFT_zop_CreateSetup(forward, vDSP_Length(Self.windowLength), .INVERSE) else {
            BNNSGraphContextDestroy(context)
            nsLogger.error("FastEnhancer setup failed")
            return nil
        }
        self.model = model
        self.context = context
        stateSize = graph.stateSize
        argumentCount = graph.argumentCount
        stateInPosition = graph.stateInPosition
        stateOutPosition = graph.stateOutPosition
        forwardDFT = forward
        inverseDFT = inverse
        workspaceSize = size

        let n = Self.windowLength
        let page = Int(getpagesize())
        func rounded(_ bytes: Int, to alignment: Int) -> Int { (bytes + alignment - 1) / alignment * alignment }
        let floatCounts = [2 * Self.bins, 2 * Self.bins, graph.stateSize, graph.stateSize, graph.stateSize,
                           n, n, hop, n, n, n, n, n, hop]
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
        specIn = floats(2 * Self.bins)
        specOut = floats(2 * Self.bins)
        stateA = floats(graph.stateSize)
        stateB = floats(graph.stateSize)
        let initial = floats(graph.stateSize)
        graph.stateInit.withUnsafeBufferPointer { initial.update(from: $0.baseAddress!, count: $0.count) }
        initialState = initial
        analysisWindow = floats(n)
        synthesisWindow = floats(n)
        previousHop = floats(hop)
        frame = floats(n)
        realIn = floats(n)
        imagIn = floats(n)
        realOut = floats(n)
        imagOut = floats(n)
        synthesisCache = floats(hop)

        arguments[graph.inputPosition].data_ptr = UnsafeMutableRawPointer(specIn)
        arguments[graph.inputPosition].data_ptr_size = 2 * Self.bins * MemoryLayout<Float>.size
        arguments[graph.outputPosition].data_ptr = UnsafeMutableRawPointer(specOut)
        arguments[graph.outputPosition].data_ptr_size = 2 * Self.bins * MemoryLayout<Float>.size
        arguments[graph.stateInPosition].data_ptr_size = graph.stateSize * MemoryLayout<Float>.size
        arguments[graph.stateOutPosition].data_ptr_size = graph.stateSize * MemoryLayout<Float>.size

        for i in 0..<n {
            analysisWindow[i] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n)))
        }
        for i in 0..<n {
            let a = analysisWindow[i]
            let b = analysisWindow[(i + hop) % n]
            synthesisWindow[i] = a / (a * a + b * b)
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
        previousHop.update(repeating: 0, count: hop)
        synthesisCache.update(repeating: 0, count: hop)
        stateA.update(from: initialState, count: stateSize)
    }

    /// Frames `previousHop ++ input` (the trailing 1024-sample analysis window), runs one STFT
    /// frame through the model, and emits the overlap-added hop that completes this call
    /// (`synthesisCache` carried from the previous call plus this call's first half).
    func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>) -> Bool {
        let n = Self.windowLength
        frame.update(from: previousHop, count: hop)
        frame.advanced(by: hop).update(from: input, count: hop)
        calls += 1

        // Analysis STFT frame (unnormalised, like numpy.fft.rfft).
        vDSP_vmul(frame, 1, analysisWindow, 1, realIn, 1, vDSP_Length(n))
        imagIn.update(repeating: 0, count: n)
        vDSP_DFT_Execute(forwardDFT, realIn, imagIn, realOut, imagOut)
        for k in 0..<Self.bins {
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
        for k in 0..<Self.bins {
            realIn[k] = specOut[2 * k]
            imagIn[k] = specOut[2 * k + 1]
        }
        for k in Self.bins..<n {
            realIn[k] = realIn[n - k]
            imagIn[k] = -imagIn[n - k]
        }
        vDSP_DFT_Execute(inverseDFT, realIn, imagIn, realOut, imagOut)

        // Synthesis window, then overlap-add with the previous call's carried second half.
        var scale = 1 / Float(n)
        vDSP_vsmul(realOut, 1, &scale, realOut, 1, vDSP_Length(n))
        vDSP_vmul(realOut, 1, synthesisWindow, 1, realOut, 1, vDSP_Length(n))
        vDSP_vadd(realOut, 1, synthesisCache, 1, output, 1, vDSP_Length(hop))
        synthesisCache.update(from: realOut.advanced(by: hop), count: hop)

        previousHop.update(from: input, count: hop)
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
        CompiledGraph.load(model: url, cacheName: "FastEnhancer_S_48k", inputArgument: "spec",
                            stateInArgument: "state_in", outputArgument: "spec_e",
                            stateOutArgument: "state_out").map(FastEnhancerModel.init)
    }

    /// The model shipped in the app bundle. Same cost as `load(from:)`.
    static func loadBundled() -> FastEnhancerModel? {
        guard let url = Bundle.main.url(forResource: "FastEnhancer_S_48k", withExtension: "mlmodelc") else {
            nsLogger.error("FastEnhancer_S_48k.mlmodelc missing from the app bundle")
            return nil
        }
        return load(from: url)
    }
}
