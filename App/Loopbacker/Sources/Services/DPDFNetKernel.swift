import Accelerate
import CryptoKit
import Foundation

/// CEVA's DPDFNet2 48 kHz model (Apache-2.0), bundled as `DPDFNet2_48k.mlmodelc` and
/// reproducible with `scripts/convert-dpdfnet.py`.
///
/// The model runs through BNNS Graph, which executes a compiled graph with caller-provided
/// workspace and buffers: no allocation, no locks, no thread hops. So it runs inline on the
/// capture device's IO thread, ~0.75 ms per 10 ms hop on an M4 Max.
///
/// Delay: 2400 samples. The model's output lags its input by four hops (40 ms), and a frame
/// is analysed only once the hop after it has arrived (one more hop).
final class DPDFNetKernel: DenoiseKernel, @unchecked Sendable {
    private static let windowLength = 960
    private static let bins = windowLength / 2 + 1

    let hop = 480
    let delay = 5 * 480

    /// Keeps the compiled graph alive while this context uses it.
    private let model: NoiseSuppressionModel
    private let context: bnns_graph_context_t
    // The graph's scalars, copied: reading them through `model.graph` on the IO thread would
    // copy the struct and retain its `stateInit` array.
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
    /// Ping-pong: even hops read `stateA` and write `stateB`, odd hops the reverse. Plain
    /// pointers rather than an array, so the IO thread touches no reference-counted storage.
    private let stateA: UnsafeMutablePointer<Float>
    private let stateB: UnsafeMutablePointer<Float>
    private let initialState: UnsafeMutablePointer<Float>
    private var pingPong = 0
    private var calls = 0

    private let forwardDFT: vDSP_DFT_Setup
    private let inverseDFT: vDSP_DFT_Setup
    private let window: UnsafeMutablePointer<Float>
    private let analysis: UnsafeMutablePointer<Float>
    private let realIn: UnsafeMutablePointer<Float>
    private let imagIn: UnsafeMutablePointer<Float>
    private let realOut: UnsafeMutablePointer<Float>
    private let imagOut: UnsafeMutablePointer<Float>
    private let overlap: UnsafeMutablePointer<Float>

    /// Cheap once `model` is loaded: one context, buffers, and a warm-up hop.
    init?(model: NoiseSuppressionModel) {
        let graph = model.graph
        let context = BNNSGraphContextMake(graph.graph)
        guard context.data != nil else {
            nsLogger.error("BNNSGraphContextMake failed")
            return nil
        }
        BNNSGraphContextSetArgumentType(context, BNNSGraphArgumentTypePointer)
        let size = BNNSGraphContextGetWorkspaceSize(context, nil)
        // size_t failure sentinels (SIZE_T_MAX) arrive in Swift as -1.
        guard size >= 0,
              let forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.windowLength), .FORWARD),
              let inverse = vDSP_DFT_zop_CreateSetup(forward, vDSP_Length(Self.windowLength), .INVERSE) else {
            BNNSGraphContextDestroy(context)
            nsLogger.error("Noise suppression setup failed")
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

        // Carve the arena: the workspace first (BNNS requires it page-aligned), then the
        // arguments and float buffers on cache-line boundaries.
        let n = Self.windowLength
        let page = Int(getpagesize())
        func rounded(_ bytes: Int, to alignment: Int) -> Int { (bytes + alignment - 1) / alignment * alignment }
        let floatCounts = [2 * Self.bins, 2 * Self.bins, graph.stateSize, graph.stateSize, graph.stateSize,
                           n, n, n, n, n, n, n]
        let argumentBytes = rounded(graph.argumentCount * MemoryLayout<bnns_graph_argument_t>.stride, to: 64)
        let total = rounded(rounded(max(size, 1), to: page) + argumentBytes
            + floatCounts.reduce(0) { $0 + rounded($1 * MemoryLayout<Float>.size, to: 64) }, to: page)
        guard let mapping = mmap(nil, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
              mapping != MAP_FAILED else {
            BNNSGraphContextDestroy(context)
            vDSP_DFT_DestroySetup(forward)
            vDSP_DFT_DestroySetup(inverse)
            nsLogger.error("Noise suppression buffers could not be mapped")
            return nil
        }
        if mlock(mapping, total) != 0 {
            nsLogger.error("Could not wire noise suppression buffers: errno \(errno)")
        }
        arena = mapping
        arenaSize = total
        workspace = mapping
        var offset = rounded(max(size, 1), to: page)
        let args = (mapping + offset).bindMemory(to: bnns_graph_argument_t.self, capacity: graph.argumentCount)
        args.initialize(repeating: bnns_graph_argument_t(), count: graph.argumentCount)
        arguments = args
        offset += argumentBytes
        // Anonymous mappings start zeroed.
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
        window = floats(n)
        analysis = floats(n)
        realIn = floats(n)
        imagIn = floats(n)
        realOut = floats(n)
        imagOut = floats(n)
        overlap = floats(n)

        arguments[graph.specPosition].data_ptr = UnsafeMutableRawPointer(specIn)
        arguments[graph.specPosition].data_ptr_size = 2 * Self.bins * MemoryLayout<Float>.size
        arguments[graph.specOutPosition].data_ptr = UnsafeMutableRawPointer(specOut)
        arguments[graph.specOutPosition].data_ptr_size = 2 * Self.bins * MemoryLayout<Float>.size
        arguments[graph.stateInPosition].data_ptr_size = graph.stateSize * MemoryLayout<Float>.size
        arguments[graph.stateOutPosition].data_ptr_size = graph.stateSize * MemoryLayout<Float>.size

        // Vorbis window: power-complementary at 50% overlap, as DPDFNet was trained with.
        for i in 0..<n {
            let s = sin(0.5 * Double.pi * (Double(i) + 0.5) / Double(n / 2))
            window[i] = Float(sin(0.5 * Double.pi * s * s))
        }

        // Warm-up hop here, off the IO thread: the first execution touches context memory
        // BNNS allocates lazily.
        stateA.update(from: initialState, count: graph.stateSize)
        arguments[graph.stateInPosition].data_ptr = UnsafeMutableRawPointer(stateA)
        arguments[graph.stateOutPosition].data_ptr = UnsafeMutableRawPointer(stateB)
        if BNNSGraphContextExecute(context, nil, graph.argumentCount, arguments, size,
                                   workspace.assumingMemoryBound(to: CChar.self)) != 0 {
            nsLogger.error("Noise suppression warm-up execution failed")
        }
    }

    deinit {
        BNNSGraphContextDestroy(context)
        vDSP_DFT_DestroySetup(forwardDFT)
        vDSP_DFT_DestroySetup(inverseDFT)
        munmap(arena, arenaSize)
    }

    func reset() {
        let n = Self.windowLength
        calls = 0
        pingPong = 0
        analysis.update(repeating: 0, count: n)
        overlap.update(repeating: 0, count: n)
        stateA.update(from: initialState, count: stateSize)
    }

    /// Appends `input` to the analysis window and, once the window holds two hops, runs one
    /// frame through the model and emits its first (now complete) overlap-added hop.
    func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>) -> Bool {
        let n = Self.windowLength
        analysis.advanced(by: n - hop).update(from: input, count: hop)
        calls += 1
        defer { analysis.update(from: analysis.advanced(by: hop), count: n - hop) }
        guard calls >= 2 else {
            output.update(repeating: 0, count: hop)
            return true
        }

        // Analysis STFT frame (unnormalised, like numpy.fft.rfft).
        vDSP_vmul(analysis, 1, window, 1, realIn, 1, vDSP_Length(n))
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

        // Synthesis window + overlap-add; the first hop is complete.
        var scale = 1 / Float(n)
        vDSP_vsmul(realOut, 1, &scale, realOut, 1, vDSP_Length(n))
        vDSP_vma(realOut, 1, window, 1, overlap, 1, overlap, 1, vDSP_Length(n))
        output.update(from: overlap, count: hop)
        overlap.update(from: overlap.advanced(by: hop), count: n - hop)
        overlap.advanced(by: n - hop).update(repeating: 0, count: hop)
        return true
    }
}

/// The DPDFNet model compiled for BNNS Graph. One instance serves every kernel made from it
/// (each gets its own context); its wired memory is freed once the last one is gone.
final class NoiseSuppressionModel: Sendable {
    fileprivate let graph: CompiledGraph

    private init(graph: CompiledGraph) {
        self.graph = graph
    }

    deinit {
        graph.release()
        nsLogger.info("DPDFNet model freed")
    }

    /// Loads the compiled model at `url` (an `.mlmodelc`). Slow: ~1.5 s to compile the first
    /// time per model and OS build, ~30 ms from the cache after that. Never call it on the
    /// audio thread or the routing queue.
    static func load(from url: URL) -> NoiseSuppressionModel? {
        CompiledGraph.load(model: url).map(NoiseSuppressionModel.init)
    }

    /// The model shipped in the app bundle. Same cost as `load(from:)`.
    static func loadBundled() -> NoiseSuppressionModel? {
        guard let url = Bundle.main.url(forResource: "DPDFNet2_48k", withExtension: "mlmodelc") else {
            nsLogger.error("DPDFNet2_48k.mlmodelc missing from the app bundle")
            return nil
        }
        return load(from: url)
    }
}

/// A model compiled for BNNS Graph. Compiling takes ~1.5 s, so the result is cached in Caches,
/// keyed by the model's contents and the OS build. The graph lives in wired memory until
/// `release`: a file mapping could be evicted and then page-fault from disk on the IO thread.
private struct CompiledGraph: @unchecked Sendable {
    let graph: bnns_graph_t
    /// True when `graph.data` is our own mapping (read from the cache); false when BNNS
    /// allocated it while compiling, which must be `free`d.
    let isMapped: Bool
    let stateSize: Int
    /// Initial recurrent state: the model's norm-state prefix, then zeros.
    let stateInit: [Float]
    let argumentCount: Int
    let specPosition: Int
    let stateInPosition: Int
    let specOutPosition: Int
    let stateOutPosition: Int

    static func load(model: URL) -> CompiledGraph? {
        guard let data = try? Data(contentsOf: model.appending(path: "metadata.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let meta = json.first?["userDefinedMetadata"] as? [String: String],
              let stateSize = meta["state_size"].flatMap(Int.init),
              let prefix = meta["state_init"]?.split(separator: ",").compactMap({ Float($0) }),
              prefix.count <= stateSize else {
            nsLogger.error("Noise suppression model metadata lacks state_size/state_init")
            return nil
        }
        let stateInit = prefix + [Float](repeating: 0, count: stateSize - prefix.count)

        let cacheFile = cacheURL(for: model)
        if let cacheFile, let graph = readWired(cacheFile) {
            if let compiled = CompiledGraph(graph: graph, isMapped: true, stateSize: stateSize, stateInit: stateInit) {
                return compiled
            }
            munmap(graph.data, graph.size)
            try? FileManager.default.removeItem(at: cacheFile)
        }

        let start = Date()
        let options = BNNSGraphCompileOptionsMakeDefault()
        defer { BNNSGraphCompileOptionsDestroy(options) }
        // It runs inside the IO callback: no worker threads.
        BNNSGraphCompileOptionsSetTargetSingleThread(options, true)
        let graph = model.withUnsafeFileSystemRepresentation { BNNSGraphCompileFromFile($0!, nil, options) }
        guard let data = graph.data else {
            nsLogger.error("BNNSGraphCompileFromFile failed for the noise suppression model")
            return nil
        }
        nsLogger.info("Compiled noise suppression graph in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        mlock(data, graph.size)
        if let cacheFile {
            // .atomic writes a temporary file and renames it, so a crash never leaves a torn graph.
            try? Data(bytesNoCopy: data, count: graph.size, deallocator: .none).write(to: cacheFile, options: .atomic)
        }
        guard let compiled = CompiledGraph(graph: graph, isMapped: false, stateSize: stateSize, stateInit: stateInit) else {
            munlock(data, graph.size)
            free(data)
            return nil
        }
        return compiled
    }

    private init?(graph: bnns_graph_t, isMapped: Bool, stateSize: Int, stateInit: [Float]) {
        func position(_ name: String) -> Int? {
            let p = BNNSGraphGetArgumentPosition(graph, nil, name)
            return p >= 0 ? p : nil
        }
        guard let spec = position("spec"), let stateIn = position("state_in"),
              let specOut = position("spec_e"), let stateOut = position("state_out") else {
            nsLogger.error("Noise suppression graph lacks the expected arguments")
            return nil
        }
        self.graph = graph
        self.isMapped = isMapped
        self.stateSize = stateSize
        self.stateInit = stateInit
        argumentCount = BNNSGraphGetInputCount(graph, nil) + BNNSGraphGetOutputCount(graph, nil)
        specPosition = spec
        stateInPosition = stateIn
        specOutPosition = specOut
        stateOutPosition = stateOut
    }

    /// Frees the graph memory. Only once nothing can execute it.
    func release() {
        if isMapped {
            munmap(graph.data, graph.size)
        } else {
            munlock(graph.data, graph.size)
            free(graph.data)
        }
    }

    /// `Caches/<bundle id>/DPDFNet2_48k-<model hash>-<OS build>.bnnsgraph`; older entries are removed.
    private static func cacheURL(for model: URL) -> URL? {
        var hasher = SHA256()
        for file in ["model.mil", "weights/weight.bin", "metadata.json"] {
            guard let data = try? Data(contentsOf: model.appending(path: file), options: .mappedIfSafe) else { return nil }
            hasher.update(data: data)
        }
        let modelHash = hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
        let os = ProcessInfo.processInfo.operatingSystemVersionString.filter { $0.isLetter || $0.isNumber || $0 == "." }
        let name = "DPDFNet2_48k-\(modelHash)-\(os).bnnsgraph"

        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appending(path: Bundle.main.bundleIdentifier ?? "com.jacobcoffee.loopbacker")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for stale in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        where stale.hasPrefix("DPDFNet2_48k-") && stale != name {
            try? fm.removeItem(at: dir.appending(path: stale))
        }
        return dir.appending(path: name)
    }

    /// Reads a cached compiled graph into wired anonymous memory.
    private static func readWired(_ url: URL) -> bnns_graph_t? {
        let fd = url.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY) }
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0 else { return nil }
        let size = Int(info.st_size)
        guard let data = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
              data != MAP_FAILED else { return nil }
        var done = 0
        while done < size {
            let n = read(fd, data + done, size - done)
            guard n > 0 else {
                munmap(data, size)
                return nil
            }
            done += n
        }
        mlock(data, size)
        return bnns_graph_t(data: data, size: size)
    }
}
