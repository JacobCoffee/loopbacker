import AppKit
import CYSFX
import Foundation
import Synchronization

enum JSFXError: Error, CustomStringConvertible {
    case notFound(String)
    case loadFailed(String)
    case compileFailed(String)

    var description: String {
        switch self {
        case .notFound(let path): "JSFX file not found: \(path)"
        case .loadFailed(let path): "ysfx failed to load: \(path)"
        case .compileFailed(let path): "ysfx failed to compile: \(path)"
        }
    }
}

/// Hosts one REAPER JSFX effect, compiled and run by the vendored ysfx/EEL2 JIT (see
/// `CYSFX/README.md`). Every `ysfx_t*` call in `process` is either a plain variable read/write
/// or the per-sample EEL interpreter loop ysfx itself runs — no allocation on this class's part.
final class JSFXNode: FXHostedNode, @unchecked Sendable {
    let kind: FXNodeKind = .jsfx
    let specs: [FXParamSpec]
    let params: FXParamStore
    let meters = FXMeters()
    /// Fixed at `load()`: JSFX's `pdc_delay` is set once in `@init`/`@slider` by convention and
    /// is not re-read per block (matches the `FXNode.latencySamples` "fixed for the stage's
    /// lifetime" contract).
    let latencySamples: Int
    let ref: FXPluginRef

    /// `ysfx_t*`. Owns the compiled script, its EEL memory, and (if present) its `@gfx` state.
    private let fx: OpaquePointer
    /// `ysfx_config_t*`, kept alive for `fx`'s lifetime (ysfx takes its own ref in `ysfx_new`,
    /// but we still own the ref we created).
    private let config: OpaquePointer
    /// `specs[i]` corresponds to ysfx slider index `sliderIndices[i]`.
    private let sliderIndices: [UInt32]
    private let lastGeneration = ManagedAtomicBox(UInt32.max)
    /// Guards the EEL VM against concurrent `ysfx_process_float` (IO thread, `process`) and
    /// `ysfx_save_state` (main actor, `captureState`) access (LB-JSFX-002: see
    /// `CYSFX/README.md`'s "a real EEL host mutex" note — the EEL2-internal mutex that patch
    /// adds protects allocator/compiler-adjacent state, not a whole-VM-execution exclusion,
    /// which is what `process`/`captureState` need against each other). A plain atomic CAS,
    /// not a system lock: `process` only ever tries it once and never waits.
    private let vmLock = Atomic<Bool>(false)
    /// Preallocated 2-element pointer arrays for `ysfx_process_float`'s `ins`/`outs` args — no
    /// per-block allocation, just pointer stores (in-place: `outs[ch] === ins[ch] === block`).
    private let inPtrs: UnsafeMutablePointer<UnsafePointer<Float>?>
    private let outPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>

    let hasGfx: Bool
    let gfxWidth: Int
    let gfxHeight: Int

    private init(
        fx: OpaquePointer, config: OpaquePointer, ref: FXPluginRef, specs: [FXParamSpec],
        sliderIndices: [UInt32], latencySamples: Int, hasGfx: Bool, gfxWidth: Int, gfxHeight: Int
    ) {
        self.fx = fx
        self.config = config
        self.ref = ref
        self.specs = specs
        self.params = FXParamStore(specs: specs)
        self.sliderIndices = sliderIndices
        self.latencySamples = latencySamples
        self.hasGfx = hasGfx
        self.gfxWidth = gfxWidth
        self.gfxHeight = gfxHeight
        inPtrs = .allocate(capacity: 2)
        inPtrs.initialize(repeating: nil, count: 2)
        outPtrs = .allocate(capacity: 2)
        outPtrs.initialize(repeating: nil, count: 2)
    }

    deinit {
        inPtrs.deallocate()
        outPtrs.deallocate()
        ysfx_free(fx)
        ysfx_config_free(config)
    }

    // MARK: - Loading

    /// Compiles `ref.identifier` off the caller's thread. Never call from the IO thread: EEL
    /// compilation allocates freely and can take milliseconds for a large script.
    static func load(ref: FXPluginRef, state: Data?, sampleRate: Double) async throws -> JSFXNode {
        try await Task.detached(priority: .userInitiated) {
            try loadSynchronously(ref: ref, state: state, sampleRate: sampleRate)
        }.value
    }

    /// EEL2's compiler caches function lookups (e.g. `pow`'s `x^const`/`const^x` rewrite) in a
    /// function-local `static` initialized from a lookup against a single process-wide function
    /// table (`nseel_getFunctionByName(NULL, ...)`), with no synchronization of its own —
    /// confirmed by the compiler hitting `WDL_ASSERT`s in `optimizeOpcodes` when two scripts
    /// compiled concurrently from different threads raced on it. `ysfx_compile`/`ysfx_init`
    /// (which also runs `@init`, itself able to call compiler-adjacent EEL paths) are
    /// serialized process-wide as the fix; this only affects loading several JSFX effects at
    /// once, never `process()`, so it has no IO-thread or steady-state latency cost.
    private static let compileLock = NSLock()

    /// Resolves `ref.identifier` to an on-disk path and the catalog root it belongs to,
    /// requiring it to canonicalize (after symlink resolution) under one of `JSFXCatalog`'s
    /// two roots (LB-PRESET-001): REAPER's own `Effects` folder and Loopbacker's `JSFX`
    /// folder. `ref.identifier` comes from an attacker-reachable source (an imported preset, a
    /// hand-edited persisted config), so this never trusts it as a bare filesystem path:
    /// `"<root>:<relative path>"` is resolved against the matching root; a bare path (configs
    /// persisted before this scheme existed) is still required to resolve under one of the
    /// same two roots. Also requires a regular file no larger than `maxJSFXFileSize`, closing
    /// off a FIFO/huge-file candidate blocking or exhausting a cooperative-pool thread.
    private static let maxJSFXFileSize = 1 * 1024 * 1024 // 1 MB

    private static func catalogRoots() -> [String: URL] { JSFXCatalogRoots.all() }

    private static func validate(_ candidate: URL, under root: URL) -> String? {
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        let rootResolved = root.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = rootResolved.path.hasSuffix("/") ? rootResolved.path : rootResolved.path + "/"
        guard resolved.path.hasPrefix(rootPath) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir), !isDir.boolValue
        else { return nil }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: resolved.path))?[.size] as? Int,
              size <= maxJSFXFileSize
        else { return nil }
        return resolved.path
    }

    private static func resolvedPath(for identifier: String) -> (path: String, root: URL)? {
        let roots = catalogRoots()
        if let colonIndex = identifier.firstIndex(of: ":"), let root = roots[String(identifier[..<colonIndex])] {
            let relative = String(identifier[identifier.index(after: colonIndex)...])
            guard let path = validate(root.appendingPathComponent(relative), under: root) else { return nil }
            return (path, root)
        }
        // Legacy absolute-path identifiers: still must resolve under a known catalog root.
        let candidate = URL(fileURLWithPath: identifier)
        for root in roots.values {
            if let path = validate(candidate, under: root) { return (path, root) }
        }
        return nil
    }

    private static func loadSynchronously(
        ref: FXPluginRef, state: Data?, sampleRate: Double
    ) throws -> JSFXNode {
        guard let resolved = resolvedPath(for: ref.identifier) else {
            throw JSFXError.notFound(ref.identifier)
        }

        let config = ysfx_config_new()!
        ysfx_guess_file_roots(config, resolved.path)
        // LB-PRESET-001: pin the data root explicitly to the catalog root this ref resolved
        // under, rather than relying solely on ysfx_guess_file_roots' directory-name
        // heuristic; ysfx_find_data_file (CYSFX/README.md) confines every relative file_open
        // candidate to this root.
        ysfx_set_data_root(config, resolved.root.path)
        ysfx_register_builtin_audio_formats(config)

        let fx = ysfx_new(config)!
        ysfx_set_sample_rate(fx, sampleRate)
        ysfx_set_block_size(fx, UInt32(FXBlock.maxFrames))

        guard ysfx_load_file(fx, resolved.path, 0) else {
            ysfx_free(fx)
            ysfx_config_free(config)
            throw JSFXError.loadFailed(ref.identifier)
        }
        compileLock.lock()
        let compiled = ysfx_compile(fx, 0)
        if compiled { ysfx_init(fx) }
        compileLock.unlock()
        guard compiled else {
            ysfx_free(fx)
            ysfx_config_free(config)
            throw JSFXError.compileFailed(ref.identifier)
        }
        // Mitigates the lazy-calloc EEL2 RAM block described in CYSFX/README.md for scripts
        // that touch low memory indices without declaring `options:prealloc` or pre-touching
        // their own buffers in `@init` (`options:prealloc=*` and self pre-touching are both
        // already handled: the former inside `ysfx_compile`, off this same background thread;
        // the latter by running `@init` here, also off the IO thread).
        var warm: ysfx_real = 0
        ysfx_read_vmem(fx, 0, &warm, 1)

        // ysfx only runs `@slider` lazily, on the first `ysfx_process_*` call after `@init`
        // sets `must_compute_slider`, so `pdc_delay` (and any other value `@slider` computes)
        // isn't live until then. Prime it with one silent frame, off the IO thread, before
        // reading `ysfx_get_pdc_delay` below -- real hosts implicitly do the same by calling
        // process() at least once before trusting reported latency.
        var warmSample: Float = 0
        withUnsafeMutablePointer(to: &warmSample) { samplePtr in
            var inPtr: UnsafePointer<Float>? = UnsafePointer(samplePtr)
            var outPtr: UnsafeMutablePointer<Float>? = samplePtr
            withUnsafeMutablePointer(to: &inPtr) { ins in
                withUnsafeMutablePointer(to: &outPtr) { outs in
                    ysfx_process_float(fx, ins, outs, 1, 1, 1)
                }
            }
        }

        var specs: [FXParamSpec] = []
        var sliderIndices: [UInt32] = []
        for index in 0..<UInt32(ysfx_max_sliders) {
            guard ysfx_slider_exists(fx, index), ysfx_slider_is_initially_visible(fx, index) else {
                continue
            }
            let name = ysfx_slider_get_name(fx, index).map { String(cString: $0) } ?? "Slider \(index)"
            var curve = ysfx_slider_curve_t()
            _ = ysfx_slider_get_curve(fx, index, &curve)

            var choices: [String]?
            if ysfx_slider_is_enum(fx, index) {
                let count = ysfx_slider_get_enum_names(fx, index, nil, 0)
                var names: [String] = []
                names.reserveCapacity(Int(count))
                for enumIndex in 0..<count {
                    let name = ysfx_slider_get_enum_name(fx, index, enumIndex)
                    names.append(name.map { String(cString: $0) } ?? "\(enumIndex)")
                }
                choices = names
            }

            specs.append(FXParamSpec(
                id: "slider\(index)",
                name: name,
                detail: choices == nil ? "JSFX slider" : "JSFX enum slider",
                unit: .none,
                min: Float(curve.min),
                max: choices == nil ? Float(curve.max) : Float(max(curve.max, 0)),
                defaultValue: Float(curve.def),
                scale: curve.shape == 1 && curve.min > 0 ? .log : .linear,
                choices: choices,
                hostAddress: UInt64(index)
            ))
            sliderIndices.append(index)
        }

        let latency = Int(ysfx_get_pdc_delay(fx).rounded())
        let hasGfx = ysfx_has_section(fx, ysfx_section_gfx.rawValue)
        var dims: [UInt32] = [0, 0]
        _ = dims.withUnsafeMutableBufferPointer { ysfx_get_gfx_dim(fx, $0.baseAddress) }
        // LB-RES-001: `@gfx w h` is unvalidated script data; `gfxWidth`/`gfxHeight` size both
        // the editor's initial NSView frame and its pixel buffer allocation
        // (JSFXEditorViewController.swift), so clamp to a sane window range rather than
        // trusting the script's declared (or default) dimensions directly.
        func clampedGfxDim(_ value: UInt32, default def: Int) -> Int {
            min(max(Int(value) > 0 ? Int(value) : def, 64), 4096)
        }

        let node = JSFXNode(
            fx: fx, config: config, ref: ref, specs: specs, sliderIndices: sliderIndices,
            latencySamples: max(0, latency), hasGfx: hasGfx,
            gfxWidth: clampedGfxDim(dims[0], default: 480),
            gfxHeight: clampedGfxDim(dims[1], default: 320)
        )

        if let state {
            node.restoreState(state)
            // ysfx_load_state only updates its own internal slider values; mirror them into
            // this node's FXParamStore so captured/restored state round-trips through `params`
            // the same way a live `process()` would have pushed it there.
            for (i, sliderIndex) in sliderIndices.enumerated() {
                node.params.set(i, Float(ysfx_slider_get_value(fx, sliderIndex)))
            }
        }
        return node
    }

    // MARK: - Processing (IO thread)

    func process(_ block: FXBlock) {
        // LB-JSFX-002: if a `captureState` is mid-`ysfx_save_state` on the main actor, skip
        // this block's JSFX processing entirely rather than wait for it — `block` still holds
        // the untouched input, so this passes it through dry for one block instead of blocking
        // the IO thread.
        guard tryLockVM() else { return }
        defer { unlockVM() }

        let generation = params.generation
        if generation != lastGeneration.load() {
            lastGeneration.store(generation)
            for (i, sliderIndex) in sliderIndices.enumerated() {
                ysfx_slider_set_value(fx, sliderIndex, ysfx_real(params.get(i)), true)
            }
        }

        var inPeak: Float = 0
        for i in 0..<block.frames {
            inPeak = max(inPeak, abs(block.left[i]))
            if block.channels == 2 { inPeak = max(inPeak, abs(block.right[i])) }
        }
        meters.inputPeak = inPeak

        inPtrs[0] = UnsafePointer(block.left)
        outPtrs[0] = block.left
        if block.channels == 2 {
            inPtrs[1] = UnsafePointer(block.right)
            outPtrs[1] = block.right
        } else {
            inPtrs[1] = nil
            outPtrs[1] = nil
        }

        ysfx_process_float(fx, inPtrs, outPtrs, UInt32(block.channels), UInt32(block.channels), UInt32(block.frames))

        var outPeak: Float = 0
        for i in 0..<block.frames {
            outPeak = max(outPeak, abs(block.left[i]))
            if block.channels == 2 { outPeak = max(outPeak, abs(block.right[i])) }
        }
        meters.outputPeak = outPeak
    }

    /// ysfx exposes no "clear delay lines" primitive beyond re-running `@init`, and `@init` is
    /// arbitrary EEL code that may touch unallocated RAM blocks (see CYSFX/README.md) — running
    /// it here would violate the IO-thread no-allocation contract. There is nothing else this
    /// host can safely clear generically; a script's own history lives entirely in EEL memory
    /// it manages itself.
    func reset() {}

    /// Non-blocking: a single compare-exchange attempt. The only caller allowed to fail and
    /// move on is `process` (IO thread); `captureState` loops this with short sleeps instead.
    private func tryLockVM() -> Bool {
        vmLock.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged
    }

    private func unlockVM() {
        vmLock.store(false, ordering: .releasing)
    }

    // MARK: - State (main thread)

    @MainActor func captureState() -> Data? {
        // LB-JSFX-002: `process` only ever tries this lock once per block and moves on, so the
        // longest this can be held against us is one block's `ysfx_process_float` call —
        // microseconds at any block size this host uses. Bounded anyway: give up rather than
        // risk hanging the main actor if that assumption is ever wrong.
        var attempts = 0
        while !tryLockVM() {
            attempts += 1
            guard attempts < 2000 else { return nil }
            Thread.sleep(forTimeInterval: 0.0001)
        }
        defer { unlockVM() }

        guard let raw = ysfx_save_state(fx) else { return nil }
        defer { ysfx_state_free(raw) }
        let state = raw.pointee

        var data = Data()
        var sliderCount = state.slider_count
        withUnsafeBytes(of: &sliderCount) { data.append(contentsOf: $0) }
        if let sliders = state.sliders {
            for i in 0..<Int(state.slider_count) {
                var index = sliders[i].index
                var value = sliders[i].value
                withUnsafeBytes(of: &index) { data.append(contentsOf: $0) }
                withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
            }
        }
        var dataSize = UInt64(state.data_size)
        withUnsafeBytes(of: &dataSize) { data.append(contentsOf: $0) }
        if state.data_size > 0, let bytes = state.data {
            data.append(bytes, count: state.data_size)
        }
        return data
    }

    /// Called only from `loadSynchronously`, before the node is handed to the IO thread.
    /// `data` is `FXNodeConfig.pluginState`, from an imported preset or a hand-edited
    /// persisted config: every conversion here must stay bounds-checked rather than trap
    /// (LB-JSFX-001). `FXNodeConfig`'s decoder already drops an oversized blob before it
    /// reaches here; everything below additionally re-validates each field against the actual
    /// remaining buffer, comparing 64-bit sizes before narrowing to `Int` instead of narrowing
    /// first and risking an overflow trap.
    private func restoreState(_ data: Data) {
        var offset = 0
        func read<T>(_ type: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard size <= data.count - offset else { return nil }
            let value = data.subdata(in: offset..<offset + size).withUnsafeBytes {
                $0.loadUnaligned(as: T.self)
            }
            offset += size
            return value
        }

        guard let sliderCount: UInt32 = read(UInt32.self), sliderCount <= UInt32(ysfx_max_sliders)
        else { return }
        var sliders: [ysfx_state_slider_t] = []
        sliders.reserveCapacity(Int(sliderCount))
        for _ in 0..<sliderCount {
            guard let index: UInt32 = read(UInt32.self), let value: ysfx_real = read(ysfx_real.self)
            else { return }
            sliders.append(ysfx_state_slider_t(index: index, value: value))
        }
        guard let dataSize: UInt64 = read(UInt64.self),
              dataSize <= UInt64(data.count - offset), // compare in UInt64 space before narrowing
              let payloadSize = Int(exactly: dataSize)
        else { return }
        let payload = data.subdata(in: offset..<offset + payloadSize)

        sliders.withUnsafeMutableBufferPointer { sliderBuf in
            payload.withUnsafeBytes { (payloadBuf: UnsafeRawBufferPointer) in
                var raw = ysfx_state_t(
                    sliders: sliderBuf.baseAddress,
                    slider_count: sliderCount,
                    data: UnsafeMutablePointer(mutating: payloadBuf.bindMemory(to: UInt8.self).baseAddress),
                    data_size: Int(dataSize)
                )
                _ = ysfx_load_state(fx, &raw)
            }
        }
    }

    // MARK: - Editor (main thread)

    @MainActor func makeEditor() async -> NSViewController? {
        hasGfx ? JSFXEditorViewController(node: self) : nil
    }

    /// Exposed to `JSFXEditorViewController`; all gfx calls happen on the main thread.
    var ysfxHandle: OpaquePointer { fx }
}

/// Minimal atomic box so `JSFXNode` (a plain `final class`) doesn't need `Synchronization`'s
/// `Atomic<T>` ceremony for one `UInt32`. The IO thread is the only reader/writer.
final class ManagedAtomicBox: @unchecked Sendable {
    private var value: UInt32
    init(_ value: UInt32) { self.value = value }
    func load() -> UInt32 { value }
    func store(_ newValue: UInt32) { value = newValue }
}

/// The two JSFX catalog roots (LB-PRESET-001), shared by `JSFXNode.resolvedPath` (load-time
/// confinement) and `JSFXCatalog.scan` (listing). Keyed by the same `"reaper"`/`"loopbacker"`
/// names `FXPluginRef.identifier`'s `"<root>:<relative path>"` scheme uses.
enum JSFXCatalogRoots {
    /// Testing seam: when set, used as the sole `"loopbacker"` root directly (no `REAPER/
    /// Effects` root, and skipping Application Support entirely), so tests can exercise path
    /// confinement against fixtures committed in the test bundle without reading or writing
    /// the user's real catalog folders. Unset in normal operation.
    private static let testRootOverrideKey = "LOOPBACKER_JSFX_TEST_ROOT"

    static func all() -> [String: URL] {
        if let overridePath = ProcessInfo.processInfo.environment[testRootOverrideKey] {
            return ["loopbacker": URL(fileURLWithPath: overridePath, isDirectory: true)]
        }
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return [:] }
        return [
            "reaper": support.appendingPathComponent("REAPER/Effects", isDirectory: true),
            "loopbacker": support.appendingPathComponent("Loopbacker/JSFX", isDirectory: true)
        ]
    }
}
