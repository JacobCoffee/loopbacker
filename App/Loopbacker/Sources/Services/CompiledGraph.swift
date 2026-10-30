import Accelerate
import CryptoKit
import Foundation

/// A noise suppression model compiled for BNNS Graph, generic over the model's bundle name and
/// its four argument names (one spectral input, one spectral output, one flat recurrent state
/// in, one flat recurrent state out -- the shape every engine here uses). Compiling takes
/// roughly a second, so the result is cached in Caches, keyed by the model's contents and the
/// OS build. The graph lives in wired memory until `release`: a file mapping could be evicted
/// and then page-fault from disk on the IO thread.
struct CompiledGraph: @unchecked Sendable {
    let graph: bnns_graph_t
    /// True when `graph.data` is our own mapping (read from the cache); false when BNNS
    /// allocated it while compiling, which must be `free`d.
    let isMapped: Bool
    let stateSize: Int
    /// STFT geometry for kernels that frame their own analysis/synthesis in Swift (DPDFNet and
    /// FastEnhancer): read from metadata rather than assumed, since FastEnhancer ships several
    /// hop sizes. FFT size equals `windowLength` for every model here (none pads a shorter
    /// window into a longer FFT), so there's no separate `nFFT` field.
    let windowLength: Int
    let hopLength: Int
    /// Initial recurrent state: a model-specific non-zero prefix (e.g. DPDFNet's norm state),
    /// then zeros.
    let stateInit: [Float]
    let argumentCount: Int
    let inputPosition: Int
    let stateInPosition: Int
    let outputPosition: Int
    let stateOutPosition: Int

    /// Loads and compiles `model` (an `.mlmodelc`), or reads it from the per-OS-build cache.
    ///
    /// - Parameters:
    ///   - cacheName: prefix for the cached compiled graph's filename and log messages (e.g.
    ///     "DPDFNet2_48k"); also used to find and remove stale cache entries for this model.
    ///   - inputArgument/stateInArgument/outputArgument/stateOutArgument: the traced model's
    ///     argument names, as given to `coremltools.TensorType(name:)` by the conversion script.
    static func load(
        model: URL,
        cacheName: String,
        inputArgument: String,
        stateInArgument: String,
        outputArgument: String,
        stateOutArgument: String
    ) -> CompiledGraph? {
        guard let data = try? Data(contentsOf: model.appending(path: "metadata.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let meta = json.first?["userDefinedMetadata"] as? [String: String],
              let stateSize = meta["state_size"].flatMap(Int.init),
              let windowLength = meta["window_length"].flatMap(Int.init),
              let hopLength = meta["hop_length"].flatMap(Int.init) else {
            nsLogger.error("\(cacheName, privacy: .public) metadata lacks state_size/window_length/hop_length")
            return nil
        }
        let prefix = (meta["state_init"] ?? "").split(separator: ",").compactMap { Float($0) }
        guard prefix.count <= stateSize else {
            nsLogger.error("\(cacheName, privacy: .public) metadata state_init longer than state_size")
            return nil
        }
        let stateInit = prefix + [Float](repeating: 0, count: stateSize - prefix.count)

        let cacheFile = cacheURL(for: model, name: cacheName)
        if let cacheFile, let graph = readWired(cacheFile) {
            if let compiled = CompiledGraph(graph: graph, isMapped: true, stateSize: stateSize,
                                             windowLength: windowLength, hopLength: hopLength, stateInit: stateInit,
                                             inputArgument: inputArgument, stateInArgument: stateInArgument,
                                             outputArgument: outputArgument, stateOutArgument: stateOutArgument) {
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
            nsLogger.error("BNNSGraphCompileFromFile failed for \(cacheName, privacy: .public)")
            return nil
        }
        nsLogger.info("Compiled \(cacheName, privacy: .public) graph in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        mlock(data, graph.size)
        if let cacheFile {
            // .atomic writes a temporary file and renames it, so a crash never leaves a torn graph.
            try? Data(bytesNoCopy: data, count: graph.size, deallocator: .none).write(to: cacheFile, options: .atomic)
        }
        guard let compiled = CompiledGraph(graph: graph, isMapped: false, stateSize: stateSize,
                                           windowLength: windowLength, hopLength: hopLength, stateInit: stateInit,
                                           inputArgument: inputArgument, stateInArgument: stateInArgument,
                                           outputArgument: outputArgument, stateOutArgument: stateOutArgument) else {
            munlock(data, graph.size)
            free(data)
            return nil
        }
        return compiled
    }

    private init?(
        graph: bnns_graph_t, isMapped: Bool, stateSize: Int, windowLength: Int, hopLength: Int,
        stateInit: [Float], inputArgument: String, stateInArgument: String, outputArgument: String,
        stateOutArgument: String
    ) {
        func position(_ name: String) -> Int? {
            let p = BNNSGraphGetArgumentPosition(graph, nil, name)
            return p >= 0 ? p : nil
        }
        guard let input = position(inputArgument), let stateIn = position(stateInArgument),
              let output = position(outputArgument), let stateOut = position(stateOutArgument) else {
            nsLogger.error("Noise suppression graph lacks the expected arguments")
            return nil
        }
        self.graph = graph
        self.isMapped = isMapped
        self.stateSize = stateSize
        self.windowLength = windowLength
        self.hopLength = hopLength
        self.stateInit = stateInit
        argumentCount = BNNSGraphGetInputCount(graph, nil) + BNNSGraphGetOutputCount(graph, nil)
        inputPosition = input
        stateInPosition = stateIn
        outputPosition = output
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

    /// `Caches/<bundle id>/<name>-<model hash>-<OS build>.bnnsgraph`; older entries for `name`
    /// are removed.
    private static func cacheURL(for model: URL, name: String) -> URL? {
        var hasher = SHA256()
        for file in ["model.mil", "weights/weight.bin", "metadata.json"] {
            guard let data = try? Data(contentsOf: model.appending(path: file), options: .mappedIfSafe) else { return nil }
            hasher.update(data: data)
        }
        let modelHash = hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
        let os = ProcessInfo.processInfo.operatingSystemVersionString.filter { $0.isLetter || $0.isNumber || $0 == "." }
        let cacheName = "\(name)-\(modelHash)-\(os).bnnsgraph"

        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appending(path: Bundle.main.bundleIdentifier ?? "com.jacobcoffee.loopbacker")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for stale in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        where stale.hasPrefix("\(name)-") && stale != cacheName {
            try? fm.removeItem(at: dir.appending(path: stale))
        }
        return dir.appending(path: cacheName)
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
