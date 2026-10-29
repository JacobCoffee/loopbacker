import Accelerate
import CryptoKit
import Foundation
import Synchronization
import os.log

private let nsLogger = Logger(subsystem: "com.jacobcoffee.loopbacker", category: "NoiseSuppressor")

/// Neural noise suppression for a mic's voice pair, using CEVA's DPDFNet2 48 kHz model
/// (Apache-2.0), bundled as `DPDFNet2_48k.mlmodelc` and reproducible with
/// `scripts/convert-dpdfnet.py`.
///
/// The model runs through BNNS Graph, which executes a compiled graph with caller-provided
/// workspace and buffers: no allocation, no locks, no thread hops. So it runs inline on the
/// capture device's IO thread, ~0.75 ms per 10 ms hop on an M4 Max.
///
/// One instance serves every voice route capturing the same device (mic → virtual mic and
/// mic → monitor). Those routes' input callbacks run back to back on the device's IO thread
/// with the same HAL sample time and the same channel mix, so the first route to see a block
/// computes it and the others copy the result.
///
/// Latency: 60 ms, constant. The model's output lags its input by four hops (40 ms), and a hop
/// can only be emitted once the second half of its 20 ms analysis window has arrived (up to
/// 20 ms). Switching on passes the dry signal until real output arrives, then crossfades over
/// 10 ms; switching off crossfades back. Neither clicks.
///
/// Thread contract:
/// - `process` runs on the capture devices' IO threads, one call at a time (a busy flag
///   enforces this; a contended call leaves its block dry).
/// - `setEnabled`/`setMaxReduction` may be called from any thread.
final class NoiseSuppressor: @unchecked Sendable {
    static let sampleRate: Float64 = 48_000

    private static let windowLength = 960
    private static let hop = 480
    private static let bins = windowLength / 2 + 1
    /// The model's output lags its input by four hops (two conv + two deep-filter lookahead frames).
    private static let modelDelay = 4 * hop
    /// Output queued ahead at session start so a hop is always ready: a hop is emitted only
    /// after two have arrived, so output trails input by at most `2 * hop - 1` samples.
    private static let lead = 2 * hop - 1
    /// Output samples before the enhanced signal is real (zeros and model warm-up before that).
    private static let primeSamples = lead + modelDelay
    /// Dry history: must reach back `modelDelay` behind the newest analysis window.
    private static let historySize = 4096
    /// Enhanced-sample FIFO; holds at most `lead + hop`.
    private static let fifoSize = 2048
    /// Largest block cached for routes sharing this instance; larger blocks aren't shared.
    private static let maxBlock = 4096
    /// Wet/dry crossfade step per sample (10 ms at 48 kHz).
    private static let fadeStep: Float = 1.0 / 480.0

    // MARK: Shared state

    private let enabled = Atomic<Bool>(false)
    /// Linear gain of the dry signal blended under the enhanced one (`10^(maxReduction/20)`).
    private let dryMixBits = Atomic<UInt32>(Float(0.001).bitPattern)
    private let busy = Atomic<Bool>(false)

    // MARK: Model

    private let graph: CompiledGraph
    private let context: bnns_graph_context_t
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

    // MARK: Stream state (IO thread)

    private var inSession = false
    private var failed = false
    private var wetGain: Float = 0
    /// Output samples produced this session, including the `lead`.
    private var sessionOut = 0
    /// Input hops consumed this session.
    private var hopsIn = 0
    private var hopFill = 0
    private var fifoRead = 0
    private var fifoWrite = 0
    /// Last block processed, for the other routes on the same device.
    private var cachedStart: Float64 = -1
    private var cachedFrames = 0
    private var cachedActive = false

    private let forwardDFT: vDSP_DFT_Setup
    private let inverseDFT: vDSP_DFT_Setup
    private let window: UnsafeMutablePointer<Float>
    private let analysis: UnsafeMutablePointer<Float>
    private let realIn: UnsafeMutablePointer<Float>
    private let imagIn: UnsafeMutablePointer<Float>
    private let realOut: UnsafeMutablePointer<Float>
    private let imagOut: UnsafeMutablePointer<Float>
    private let overlap: UnsafeMutablePointer<Float>
    private let history: UnsafeMutablePointer<Float>
    private let fifo: UnsafeMutablePointer<Float>
    private let cachedBlock: UnsafeMutablePointer<Float>

    /// Loads (compiling on first use) the bundled model, or returns nil (and logs why) when the
    /// route can't be suppressed. Blocks for the compile (~1.5 s) the first time after an app
    /// or OS update; later launches map the cached compiled graph.
    static func make(sampleRate: Float64) -> NoiseSuppressor? {
        guard sampleRate == Self.sampleRate else {
            nsLogger.error("Noise suppression needs 48 kHz; route runs at \(sampleRate) Hz")
            return nil
        }
        guard let graph = CompiledGraph.shared() else { return nil }
        return NoiseSuppressor(graph: graph)
    }

    private init?(graph: CompiledGraph) {
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
        self.graph = graph
        self.context = context
        forwardDFT = forward
        inverseDFT = inverse
        workspaceSize = size

        // Carve the arena: the workspace first (BNNS requires it page-aligned), then the
        // arguments and float buffers on cache-line boundaries.
        let n = Self.windowLength
        let page = Int(getpagesize())
        func rounded(_ bytes: Int, to alignment: Int) -> Int { (bytes + alignment - 1) / alignment * alignment }
        let floatCounts = [2 * Self.bins, 2 * Self.bins, graph.stateSize, graph.stateSize, graph.stateSize,
                           n, n, n, n, n, n, n, Self.historySize, Self.fifoSize, Self.maxBlock]
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
        history = floats(Self.historySize)
        fifo = floats(Self.fifoSize)
        cachedBlock = floats(Self.maxBlock)

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

    func setEnabled(_ on: Bool) {
        enabled.store(on, ordering: .relaxed)
    }

    /// - Parameter dB: how far noise may be pulled down, as a negative level (e.g. -60).
    func setMaxReduction(dB: Float) {
        dryMixBits.store(powf(10, min(0, dB) / 20).bitPattern, ordering: .relaxed)
    }

    // MARK: - IO thread

    /// Replaces the first `min(stride, 2)` channels of interleaved `buffer` with the enhanced
    /// voice. Leaves the buffer untouched while disabled.
    ///
    /// - Parameter sampleTime: the block's HAL input sample time. A block already processed
    ///   for another route (same start and length) is copied instead of processed again.
    func process(_ buffer: UnsafeMutablePointer<Float>, frames: Int, stride: Int, sampleTime: Float64?) {
        let channels = min(stride, 2)
        guard channels > 0, frames > 0 else { return }
        guard busy.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged else { return }
        defer { busy.store(false, ordering: .releasing) }

        if let sampleTime, sampleTime == cachedStart, frames == cachedFrames {
            if cachedActive { write(cachedBlock, into: buffer, frames: frames, stride: stride, channels: channels) }
            return
        }

        let shareable = sampleTime != nil && frames <= Self.maxBlock
        cachedStart = shareable ? sampleTime! : -1
        cachedFrames = shareable ? frames : 0
        cachedActive = false
        var offset = 0
        while offset < frames {
            let n = min(frames - offset, Self.maxBlock)
            let block = buffer.advanced(by: offset * stride)
            if processChunk(block, frames: n, stride: stride, channels: channels) {
                if shareable { cachedActive = true }
                write(cachedBlock, into: block, frames: n, stride: stride, channels: channels)
            }
            offset += n
        }
    }

    private func write(_ mono: UnsafePointer<Float>, into buffer: UnsafeMutablePointer<Float>,
                       frames: Int, stride: Int, channels: Int) {
        for i in 0..<frames {
            buffer[i * stride] = mono[i]
            if channels == 2 { buffer[i * stride + 1] = mono[i] }
        }
    }

    /// Runs one chunk through the model into `cachedBlock`. Returns false (and leaves the
    /// chunk alone) while fully dry outside a session, so the stereo image survives.
    private func processChunk(_ buf: UnsafeMutablePointer<Float>, frames n: Int, stride: Int, channels: Int) -> Bool {
        let want = enabled.load(ordering: .relaxed)
        if !inSession {
            guard want else { return false }
            startSession()
        } else if !want && wetGain == 0 {
            inSession = false
            return false
        }

        let h = Self.hop, mask = Self.fifoSize - 1
        let tail = analysis.advanced(by: Self.windowLength - h)
        var g = wetGain
        for i in 0..<n {
            let base = i * stride
            let dry = channels == 1 ? buf[base] : 0.5 * (buf[base] + buf[base + 1])
            tail[hopFill] = dry
            hopFill += 1
            if hopFill == h {
                if !failed { failed = !processHop() }
                hopFill = 0
            }
            let wet = fifo[fifoRead & mask]
            fifoRead += 1
            sessionOut += 1

            let target: Float = want && !failed && sessionOut > Self.primeSamples ? 1 : 0
            g = target > g ? min(target, g + Self.fadeStep) : max(target, g - Self.fadeStep)
            cachedBlock[i] = g * wet + (1 - g) * dry
        }
        wetGain = g
        if !want && g == 0 { inSession = false }
        return true
    }

    private func startSession() {
        inSession = true
        failed = false
        wetGain = 0
        sessionOut = 0
        hopsIn = 0
        hopFill = 0
        pingPong = 0
        let n = Self.windowLength
        analysis.update(repeating: 0, count: n)
        overlap.update(repeating: 0, count: n)
        history.update(repeating: 0, count: Self.historySize)
        fifo.update(repeating: 0, count: Self.lead)
        fifoRead = 0
        fifoWrite = Self.lead
        stateA.update(from: initialState, count: graph.stateSize)
    }

    /// Consumes the hop sitting at the end of `analysis` and, once the window is full, emits one
    /// enhanced hop into the FIFO. Returns false if inference failed.
    private func processHop() -> Bool {
        let n = Self.windowLength, h = Self.hop
        let base = hopsIn * h
        for i in 0..<h {
            history[(base + i) & (Self.historySize - 1)] = analysis[n - h + i]
        }
        hopsIn += 1
        defer { analysis.update(from: analysis.advanced(by: h), count: n - h) }
        guard hopsIn >= 2 else { return true }

        // Analysis STFT frame (unnormalised, like numpy.fft.rfft).
        vDSP_vmul(analysis, 1, window, 1, realIn, 1, vDSP_Length(n))
        imagIn.update(repeating: 0, count: n)
        vDSP_DFT_Execute(forwardDFT, realIn, imagIn, realOut, imagOut)
        for k in 0..<Self.bins {
            specIn[2 * k] = realOut[k]
            specIn[2 * k + 1] = imagOut[k]
        }

        arguments[graph.stateInPosition].data_ptr = UnsafeMutableRawPointer(pingPong == 0 ? stateA : stateB)
        arguments[graph.stateOutPosition].data_ptr = UnsafeMutableRawPointer(pingPong == 0 ? stateB : stateA)
        let status = BNNSGraphContextExecute(context, nil, graph.argumentCount, arguments, workspaceSize,
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

        // Output sample j holds input sample j - modelDelay; blend that dry sample back in to
        // cap the reduction. Frame k = hopsIn - 2 starts at input sample k * hop.
        let dryMix = Float(bitPattern: dryMixBits.load(ordering: .relaxed))
        let wetMix = 1 - dryMix
        let outStart = (hopsIn - 2) * h - Self.modelDelay
        let mask = Self.fifoSize - 1
        for i in 0..<h {
            let j = outStart + i
            let dry = j >= 0 ? history[j & (Self.historySize - 1)] : 0
            fifo[fifoWrite & mask] = wetMix * overlap[i] + dryMix * dry
            fifoWrite += 1
        }
        overlap.update(from: overlap.advanced(by: h), count: n - h)
        overlap.advanced(by: n - h).update(repeating: 0, count: h)
        return true
    }
}

/// The bundled model compiled for BNNS Graph, shared by every suppressor (each has its own
/// context). Compiling takes ~1.5 s, so the result is cached in Caches, keyed by the model's
/// contents and the OS build. The graph lives in wired memory for the life of the process:
/// a file mapping could be evicted and then page-fault from disk on the IO thread.
private struct CompiledGraph: @unchecked Sendable {
    let graph: bnns_graph_t
    let stateSize: Int
    /// Initial recurrent state: the model's norm-state prefix, then zeros.
    let stateInit: [Float]
    let argumentCount: Int
    let specPosition: Int
    let stateInPosition: Int
    let specOutPosition: Int
    let stateOutPosition: Int

    private static let loaded = Mutex<CompiledGraph?>(nil)

    static func shared() -> CompiledGraph? {
        loaded.withLock { cached in
            if let cached { return cached }
            cached = load()
            return cached
        }
    }

    private static func load() -> CompiledGraph? {
        guard let model = Bundle.main.url(forResource: "DPDFNet2_48k", withExtension: "mlmodelc") else {
            nsLogger.error("DPDFNet2_48k.mlmodelc missing from the app bundle")
            return nil
        }
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
            if let compiled = CompiledGraph(graph: graph, stateSize: stateSize, stateInit: stateInit) {
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
        return CompiledGraph(graph: graph, stateSize: stateSize, stateInit: stateInit)
    }

    private init?(graph: bnns_graph_t, stateSize: Int, stateInit: [Float]) {
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
        self.stateSize = stateSize
        self.stateInit = stateInit
        argumentCount = BNNSGraphGetInputCount(graph, nil) + BNNSGraphGetOutputCount(graph, nil)
        specPosition = spec
        stateInPosition = stateIn
        specOutPosition = specOut
        stateOutPosition = stateOut
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

    /// Reads a cached compiled graph into wired anonymous memory, kept for the process lifetime.
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
