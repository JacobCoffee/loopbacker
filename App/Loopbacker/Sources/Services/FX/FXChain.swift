import Foundation
import Synchronization

/// The voice-chain processor for one capture device, shared by every voice route on that
/// device (virtual mic + monitor) exactly like `NoiseSuppressor`: the routes' input callbacks
/// run back to back on the device's IO thread with the same HAL sample time, so the first
/// route to see a block computes it and the others copy the cached result.
///
/// Each block is deinterleaved into planar scratch buffers, run through an ordered list of
/// `FXNode`s (processing mono when the voice pair is bitwise identical, as from a mono mic
/// fanned to L+R), then reinterleaved. Blocks larger than `FXBlock.maxFrames` are split.
///
/// Structural edits (add/remove/reorder/kind/plugin change) build a brand new, immutable
/// `ChainGraph` off the IO thread (reusing existing node instances by `FXNodeConfig.id` where
/// the kind and plugin didn't change, and loading hosted nodes before publishing), then publish
/// it with one atomic pointer swap. The swap itself is declicked: the IO thread fades the
/// outgoing graph's last block to silence, then fades the incoming graph in from silence over
/// its first block.
///
/// Param-only edits (values, `enabled`, EQ bands) skip the rebuild entirely and push straight
/// into the live instances' `FXParamStore` (and `EQNode.setBands`). Toggling a node's `enabled`
/// still crossfades smoothly against a dry tap delayed by that node's own latency, so the
/// overall chain latency never changes when a node is bypassed.
///
/// ## Graph ownership
/// `graphPtr` is a purely observational, non-owning `Unmanaged` pointer: the IO thread reads it
/// with `takeUnretainedValue()` and never retains or releases through it. The single strong
/// owner of every graph that hasn't been freed yet is `ownedGraphs`, guarded by `configLock` and
/// touched only off the IO thread. A superseded graph is dropped from `ownedGraphs` -- and so
/// deinited, off the IO thread, on a background utility queue/task -- only once the IO thread
/// has observed the swap and marked the old graph `retired` (polled, with no timeout: if the IO
/// proc stalls the poll simply keeps waiting) or once `ioStopped()` proves the IO proc can never
/// touch it again. `ioStopped()` must be called by the owning router once every audio unit
/// feeding this chain has actually stopped (not on a timer); `deinit` calls it too, so a chain
/// that's simply dropped always frees its graphs off the IO thread rather than leaking.
///
/// Thread contract: `process` runs on the capture device's IO thread, one call at a time (a
/// busy flag enforces this, matching `NoiseSuppressor`) and never retains a `ChainGraph`.
/// `updateConfigs` serializes through an internal actor, so concurrent calls (a slow hosted-plugin
/// load racing a fast param edit) can't publish out of order: only the latest requested configs
/// ever end up applied, and a build in flight when a newer request arrives is superseded rather
/// than published. `liveNode`, `nodeLoadErrors`, `totalLatencySamples`, `captureHostedStates`,
/// `setABBypass`, `ioStopped` and `record` may be called from any thread.
final class FXChain: @unchecked Sendable {
    let sampleRate: Float
    let captureDeviceUID: String

    /// 10 ms at 48 kHz, used for the per-node bypass crossfade, the A/B crossfade, and the
    /// NoiseSuppressor-style cache invalidation granularity.
    private static let crossfadeStep: Float = 1.0 / 480.0
    /// Capacity of the chain-level A/B dry delay ring: generous headroom (~340 ms) over any
    /// realistic sum of built-in + hosted stage latencies, plus one block. If a graph's total
    /// latency ever exceeded this, the A/B dry tap would wrap and read stale samples instead of
    /// crashing (bounded by the `&` mask below); it's never resized at runtime (RT-safety).
    private static let abDryCapacity = FXBlockIO.nextPowerOfTwo(atLeast: 16_384 + FXBlock.maxFrames)

    private let vad = VoiceActivityDetector()
    private let recorder: FXRecorder

    // MARK: Published state (any thread)

    private let graphPtr = Atomic<Unmanaged<ChainGraph>?>(nil)
    private let abBypassFlag = Atomic<Bool>(false)
    private let voiceProbabilityBits = Atomic<UInt32>(Float(0).bitPattern)

    // MARK: Graph ownership + config state (guarded by configLock; never touched on the IO thread)

    private let configLock = NSLock()
    private var currentConfigs: [FXNodeConfig] = []
    private var latestGraph: ChainGraph?
    private var ownedGraphs: [ObjectIdentifier: ChainGraph] = [:]
    private var releaseTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var isTornDown = false

    /// Serializes `updateConfigs`: only ever one build/publish in flight, and a build superseded
    /// by a newer request while it awaits (e.g. a hosted-plugin load) is simply never reached --
    /// `apply` runs again with the newest request once the stale one returns.
    private lazy var configWorker = ConfigCoalescer { [weak self] configs in
        await self?.applyConfigs(configs)
    }

    // MARK: IO-thread sharing (mirrors NoiseSuppressor)

    private let busy = Atomic<Bool>(false)
    /// Mirrors `isTornDown`, but as a plain atomic `process` can check with a single cheap load
    /// before touching any graph state. Set first (before the `configLock`-guarded teardown),
    /// so any `process` call chronologically after `ioStopped()` returns is guaranteed to see
    /// it and bail out before dereferencing `activeGraphRef`/`graphPtr`, even though genuinely
    /// concurrent calls (which the real contract forbids -- `ioStopped` is only called once no
    /// more `process` calls can happen) aren't ordered by this alone.
    private let tornDownFlag = Atomic<Bool>(false)
    private var cachedStart: Float64 = -1
    private var cachedFrames = 0
    private let cachedInterleaved: UnsafeMutablePointer<Float>

    // MARK: IO-thread scratch (preallocated, no per-block allocation)

    private let scratchLeft: UnsafeMutablePointer<Float>
    private let scratchRight: UnsafeMutablePointer<Float>
    private let dryLeftScratch: UnsafeMutablePointer<Float>
    private let dryRightScratch: UnsafeMutablePointer<Float>
    private let vadMono: UnsafeMutablePointer<Float>
    private let rawMonoScratch: UnsafeMutablePointer<Float>
    private let processedMonoScratch: UnsafeMutablePointer<Float>
    /// Chain-level dry delay ring feeding the A/B bypass: the unprocessed input, so bypassing
    /// can be compared against a copy delayed by the *current* graph's total latency instead of
    /// an undelayed one (which would otherwise shift A/B timing by the chain's own latency).
    private let abDryLeft: UnsafeMutablePointer<Float>
    private let abDryRight: UnsafeMutablePointer<Float>

    // MARK: IO-thread only state (never touched off the IO thread)

    /// Non-owning: the IO thread's view of which graph it's currently driving. Always either
    /// nil or a pointer into an object `ownedGraphs` is still holding strongly.
    private var activeGraphRef: Unmanaged<ChainGraph>?
    private var activeTotalLatency = 0
    private var pendingFadeIn = false
    private var abDryWrite = 0
    private var abCrossfade: Float = 1 // 1 = normal chain output, 0 = fully bypassed (dry)
    private var inputRMSEnergy: Float = 0
    private var outputRMSEnergy: Float = 0
    private var abRatioSmoothed: Float = 1
    private static let rmsDecay: Float = 0.999 // ~3 s one-pole window at typical block rates

    init(sampleRate: Float, captureDeviceUID: String) {
        self.sampleRate = sampleRate
        self.captureDeviceUID = captureDeviceUID
        recorder = FXRecorder(sampleRate: Double(sampleRate))

        let n = FXBlock.maxFrames
        cachedInterleaved = .allocate(capacity: n * 2)
        scratchLeft = .allocate(capacity: n)
        scratchRight = .allocate(capacity: n)
        dryLeftScratch = .allocate(capacity: n)
        dryRightScratch = .allocate(capacity: n)
        vadMono = .allocate(capacity: n)
        rawMonoScratch = .allocate(capacity: n)
        processedMonoScratch = .allocate(capacity: n)
        abDryLeft = .allocate(capacity: Self.abDryCapacity)
        abDryRight = .allocate(capacity: Self.abDryCapacity)
        cachedInterleaved.initialize(repeating: 0, count: n * 2)
        for p in [scratchLeft, scratchRight, dryLeftScratch, dryRightScratch, vadMono, rawMonoScratch, processedMonoScratch] {
            p.initialize(repeating: 0, count: n)
        }
        abDryLeft.initialize(repeating: 0, count: Self.abDryCapacity)
        abDryRight.initialize(repeating: 0, count: Self.abDryCapacity)
    }

    deinit {
        // Never let a graph (or the hosted-plugin nodes inside it) deinit as a side effect of
        // this object's own deinit running on whatever thread dropped the last reference --
        // route it through the same off-IO-thread, background-queue teardown path `ioStopped`
        // uses for a live chain.
        ioStopped()
        cachedInterleaved.deallocate()
        scratchLeft.deallocate()
        scratchRight.deallocate()
        dryLeftScratch.deallocate()
        dryRightScratch.deallocate()
        vadMono.deallocate()
        rawMonoScratch.deallocate()
        processedMonoScratch.deallocate()
        abDryLeft.deallocate()
        abDryRight.deallocate()
    }

    // MARK: - Teardown

    /// Call once every audio unit feeding this chain has actually stopped (`AudioOutputUnitStop`
    /// returned for every voice route sharing it) -- never on a timer. Proves the IO proc can't
    /// touch this chain's graphs again, so it's safe to free every graph it still owns right
    /// now instead of waiting for an acknowledgement that will never come. Idempotent; safe to
    /// call from any thread. `deinit` also calls this, so a chain that's simply dropped (no
    /// explicit teardown) still frees off the IO thread rather than leaking.
    func ioStopped() {
        // Set first: any `process` call chronologically after this point bails before touching
        // graph state at all, so it can never dereference what we're about to free below.
        tornDownFlag.store(true, ordering: .releasing)

        configLock.lock()
        guard !isTornDown else { configLock.unlock(); return }
        isTornDown = true
        let tasks = releaseTasks
        releaseTasks.removeAll()
        let graphs = Array(ownedGraphs.values)
        ownedGraphs.removeAll()
        latestGraph = nil
        configLock.unlock()

        // Clear the observational pointer too: the IO thread must never dereference a graph
        // after this point, even one it hasn't yet acknowledged swapping away from (`runGraph`
        // treats a nil `graphPtr` as "fade out and go idle", never touching the old graph
        // again once it does).
        graphPtr.store(nil, ordering: .releasing)

        for (_, task) in tasks { task.cancel() }
        // `graphs` may contain hosted (AU/JSFX) nodes whose deinit can block (ObjC teardown,
        // file I/O); never run that on the caller's thread (the router's queue, or whatever
        // thread drops the last reference to this chain) or the main thread.
        guard !graphs.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            withExtendedLifetime(graphs) {}
        }
    }

    // MARK: - Configuration (off the IO thread)

    /// Applies `configs` (the preset's ordered `nodes`). Serialized and coalesced by
    /// `configWorker`: if a build is already in flight when this is called, it just registers
    /// `configs` as the latest request and returns -- the in-flight build's result is discarded
    /// in favor of a fresh build from `configs` once it finishes.
    func updateConfigs(_ configs: [FXNodeConfig]) async {
        await configWorker.request(configs)
    }

    /// Runs on `configWorker`: never concurrent with itself. Decides param-only vs. structural
    /// and applies it.
    private func applyConfigs(_ configs: [FXNodeConfig]) async {
        let previous = snapshotConfigs()

        if Self.isParamOnly(old: previous, new: configs) {
            applyParamsOnly(configs)
        } else {
            let oldByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
            let newGraph = await buildGraph(configs, oldByID: oldByID, oldGraph: publishedGraph)
            publish(newGraph)
        }

        storeConfigs(configs)
    }

    /// Synchronous wrappers so the lock is never taken directly inside an async body (`NSLock`
    /// is unavailable from async contexts).
    private func snapshotConfigs() -> [FXNodeConfig] {
        configLock.lock()
        defer { configLock.unlock() }
        return currentConfigs
    }

    private func storeConfigs(_ configs: [FXNodeConfig]) {
        configLock.lock()
        defer { configLock.unlock() }
        currentConfigs = configs
    }

    private static func isParamOnly(old: [FXNodeConfig], new: [FXNodeConfig]) -> Bool {
        guard old.count == new.count, !old.isEmpty else { return false }
        for (a, b) in zip(old, new) where a.id != b.id || a.kind != b.kind || a.pluginRef != b.pluginRef {
            return false
        }
        return true
    }

    private func applyParamsOnly(_ configs: [FXNodeConfig]) {
        guard let slots = publishedGraph?.slots else { return }
        for (slot, config) in zip(slots, configs) {
            slot.node.apply(config.params)
            slot.enabled.store(config.enabled, ordering: .relaxed)
            if let eqNode = slot.node as? EQNode, let bands = config.eqBands {
                eqNode.setBands(bands)
            }
        }
    }

    private func buildGraph(_ configs: [FXNodeConfig], oldByID: [UUID: FXNodeConfig], oldGraph: ChainGraph?) async -> ChainGraph {
        var slots: [ChainGraph.Slot] = []
        slots.reserveCapacity(configs.count)
        for config in configs {
            if let oldConfig = oldByID[config.id], oldConfig.kind == config.kind, oldConfig.pluginRef == config.pluginRef,
               let oldSlot = oldGraph?.slots.first(where: { $0.id == config.id }) {
                oldSlot.node.apply(config.params)
                if let eqNode = oldSlot.node as? EQNode, let bands = config.eqBands { eqNode.setBands(bands) }
                slots.append(ChainGraph.Slot(id: config.id, node: oldSlot.node, enabled: config.enabled,
                                             latency: oldSlot.latency, loadError: oldSlot.loadError))
            } else {
                let built = await FXNodeFactory.make(config, sampleRate: sampleRate)
                slots.append(ChainGraph.Slot(id: config.id, node: built.node, enabled: config.enabled,
                                             latency: built.node.latencySamples, loadError: built.loadError))
            }
        }
        return ChainGraph(slots: slots)
    }

    /// Publishes `newGraph`: registers it as the sole strong owner in `ownedGraphs`, then
    /// stores a non-owning pointer the IO thread can observe. The previously-latest graph (if
    /// any) is handed to `scheduleRelease`, which waits for the IO thread's acknowledgement
    /// (`retired`) before dropping it -- never a timeout.
    private func publish(_ newGraph: ChainGraph) {
        configLock.lock()
        guard !isTornDown else {
            // The chain was torn down while this build was in flight; don't resurrect it.
            configLock.unlock()
            return
        }
        let previous = latestGraph
        latestGraph = newGraph
        ownedGraphs[ObjectIdentifier(newGraph)] = newGraph
        configLock.unlock()

        graphPtr.store(.passUnretained(newGraph), ordering: .releasing)

        if let previous { scheduleRelease(of: previous) }
    }

    /// Waits (polling, no timeout) for the IO thread to mark `graph` retired, then drops the
    /// chain's strong reference to it off the IO thread. If the chain is torn down
    /// (`ioStopped`) while waiting, the poll notices and returns without touching `graph` again
    /// -- `ioStopped` already force-freed it.
    private func scheduleRelease(of graph: ChainGraph) {
        let id = ObjectIdentifier(graph)
        let task = Task.detached(priority: .utility) { [weak self] in
            while !graph.retired.load(ordering: .acquiring) {
                guard let self, !self.checkTornDown() else { return }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            self?.dropOwnership(of: graph, id: id)
        }
        configLock.lock()
        if isTornDown {
            // Lost the race with `ioStopped` between the check in `publish` and here; it
            // already owns (or already freed) every graph. Cancel the no-op task we just made.
            configLock.unlock()
            task.cancel()
            return
        }
        releaseTasks[id] = task
        configLock.unlock()
    }

    /// Sync wrapper so `scheduleRelease`'s poll loop (running inside an async `Task`) never
    /// takes `configLock` directly (`NSLock` is unavailable from async contexts).
    private func checkTornDown() -> Bool {
        configLock.lock()
        defer { configLock.unlock() }
        return isTornDown
    }

    private func dropOwnership(of graph: ChainGraph, id: ObjectIdentifier) {
        configLock.lock()
        ownedGraphs.removeValue(forKey: id)
        releaseTasks.removeValue(forKey: id)
        configLock.unlock()
        // `graph` (this function's strong parameter) is the last reference once the dictionary
        // entry above is gone; it deinits when this function returns, on the background
        // `Task.detached(priority: .utility)` thread that called us -- never the IO thread.
    }

    /// Test-only: installs `graph` as both the published and currently-active graph, bypassing
    /// config diffing, node construction and the declick swap. Lets tests drive `process` with
    /// hand-built graphs of fake nodes. Call before the first `process`.
    func debugInstallGraph(_ graph: ChainGraph) {
        configLock.lock()
        ownedGraphs[ObjectIdentifier(graph)] = graph
        latestGraph = graph
        configLock.unlock()
        graphPtr.store(.passUnretained(graph), ordering: .releasing)
        activeGraphRef = .passUnretained(graph)
        activeTotalLatency = graph.totalLatency
        pendingFadeIn = false
    }

    /// Off the IO thread only: the strongly-held current graph (never races a concurrent
    /// release, unlike reading `graphPtr` directly, which is reserved for the IO thread).
    private var publishedGraph: ChainGraph? {
        configLock.lock()
        defer { configLock.unlock() }
        return latestGraph
    }

    // MARK: - Introspection (any thread, via FXEngine)

    /// The live instance for a node id, from whichever graph is currently published.
    func liveNode(id: UUID) -> (any FXNode)? {
        publishedGraph?.slots.first { $0.id == id }?.node
    }

    /// Sum of every node's `latencySamples`, independent of `enabled` (so toggling a node never
    /// moves the chain's overall delay).
    var totalLatencySamples: Int { publishedGraph?.totalLatency ?? 0 }

    func nodeLoadErrors() -> [UUID: String] {
        guard let slots = publishedGraph?.slots else { return [:] }
        var out: [UUID: String] = [:]
        for slot in slots { if let error = slot.loadError { out[slot.id] = error } }
        return out
    }

    /// Main thread: every hosted node's current state, for persisting into the preset so a
    /// second device running this chain (or a relaunch) restores it.
    @MainActor
    func captureHostedStates() async -> [UUID: Data] {
        guard let slots = publishedGraph?.slots else { return [:] }
        var out: [UUID: Data] = [:]
        for slot in slots {
            if let hosted = slot.node as? any FXHostedNode, let data = hosted.captureState() {
                out[slot.id] = data
            }
        }
        return out
    }

    var voiceProbability: Float { Float(bitPattern: voiceProbabilityBits.load(ordering: .relaxed)) }

    // MARK: - A/B bypass

    var isABBypassed: Bool { abBypassFlag.load(ordering: .relaxed) }
    func setABBypass(_ bypassed: Bool) { abBypassFlag.store(bypassed, ordering: .relaxed) }

    // MARK: - Recording

    /// Arms the recorder and waits (polling, off the IO thread) until it fills or `seconds`
    /// have been requested, then returns what was captured.
    func record(seconds: Double) async -> FXRecording {
        recorder.arm(seconds: seconds)
        while recorder.isCapturing {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return recorder.snapshot()
    }

    // MARK: - IO thread

    /// Runs one captured block through the chain in place. `buffer` is interleaved with
    /// `stride` channels; only the first `min(stride, 2)` (the voice pair) are processed.
    /// `sampleTime`, when present, lets routes sharing this device (virtual mic + monitor) get
    /// the cached result instead of recomputing. `rawPreNS`, when present, is the dry
    /// (pre-noise-suppression) interleaved mix fed to the recorder's "raw" stream.
    func process(_ buffer: UnsafeMutablePointer<Float>, frames: Int, stride: Int,
                sampleTime: Float64?, rawPreNS: UnsafePointer<Float>?) {
        guard frames > 0, stride > 0, !tornDownFlag.load(ordering: .acquiring) else { return }
        guard busy.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged else { return }
        defer { busy.store(false, ordering: .releasing) }

        if let sampleTime, sampleTime == cachedStart, frames == cachedFrames {
            for i in 0..<frames {
                buffer[i * stride] = cachedInterleaved[i * 2]
                if stride >= 2 { buffer[i * stride + 1] = cachedInterleaved[i * 2 + 1] }
            }
            return
        }

        let shareable = sampleTime != nil && frames <= FXBlock.maxFrames
        cachedStart = shareable ? sampleTime! : -1
        cachedFrames = shareable ? frames : 0

        var offset = 0
        while offset < frames {
            let n = min(frames - offset, FXBlock.maxFrames)
            let chunk = buffer.advanced(by: offset * stride)
            let chunkRaw = rawPreNS?.advanced(by: offset * stride)
            processChunk(chunk, frames: n, stride: stride, rawPreNS: chunkRaw)
            if shareable, offset == 0, n == frames {
                for i in 0..<frames {
                    cachedInterleaved[i * 2] = chunk[i * stride]
                    cachedInterleaved[i * 2 + 1] = stride >= 2 ? chunk[i * stride + 1] : chunk[i * stride]
                }
            }
            offset += n
        }
    }

    private func processChunk(_ buffer: UnsafeMutablePointer<Float>, frames: Int, stride: Int, rawPreNS: UnsafePointer<Float>?) {
        let mono = FXBlockIO.deinterleave(buffer, frames: frames, stride: stride, left: scratchLeft, right: scratchRight)
        memcpy(dryLeftScratch, scratchLeft, frames * MemoryLayout<Float>.size)
        memcpy(dryRightScratch, scratchRight, frames * MemoryLayout<Float>.size)

        // Feed the chain-level A/B dry ring with the unprocessed signal before any node runs.
        let abPushStart = abDryWrite
        for i in 0..<frames {
            let idx = (abPushStart + i) & (Self.abDryCapacity - 1)
            abDryLeft[idx] = scratchLeft[i]
            abDryRight[idx] = scratchRight[i]
        }
        abDryWrite = abPushStart + frames

        for i in 0..<frames { vadMono[i] = mono ? scratchLeft[i] : 0.5 * (scratchLeft[i] + scratchRight[i]) }
        let probability = vad?.process(vadMono, frames: frames) ?? 1
        VoiceBus.update(probability)
        voiceProbabilityBits.store(probability.bitPattern, ordering: .relaxed)
        let sidechain = FXSidechain(voiceProbability: probability)

        runGraph(left: scratchLeft, right: scratchRight, frames: frames, mono: mono, sidechain: sidechain)

        if probability > 0.5 {
            let inEnergy = FXBlockIO.rms(dryLeftScratch, frames: frames)
            let outEnergy = FXBlockIO.rms(scratchLeft, frames: frames)
            inputRMSEnergy = Self.rmsDecay * inputRMSEnergy + (1 - Self.rmsDecay) * inEnergy
            outputRMSEnergy = Self.rmsDecay * outputRMSEnergy + (1 - Self.rmsDecay) * outEnergy
        }

        applyABBypass(left: scratchLeft, right: scratchRight, frames: frames, abPushStart: abPushStart)

        FXBlockIO.reinterleave(buffer, frames: frames, stride: stride, channels: min(stride, 2),
                               left: scratchLeft, right: scratchRight, mono: mono)

        if let rawPreNS {
            for i in 0..<frames {
                rawMonoScratch[i] = stride >= 2 ? 0.5 * (rawPreNS[i * stride] + rawPreNS[i * stride + 1]) : rawPreNS[i * stride]
                processedMonoScratch[i] = mono ? scratchLeft[i] : 0.5 * (scratchLeft[i] + scratchRight[i])
            }
            recorder.capture(raw: rawMonoScratch, processed: processedMonoScratch, frames: frames)
        }
    }

    /// Crossfades the chain's processed output against a dry tap delayed by `activeTotalLatency`
    /// -- the current graph's own latency -- so switching A/B doesn't shift timing (an undelayed
    /// dry tap would compare samples that are `activeTotalLatency` apart in time) and doesn't
    /// click (the blend ramps over `crossfadeStep` per sample, same cadence as per-node bypass).
    /// The dry side is scaled by `abRatioSmoothed` so A/B compares tone, not loudness.
    private func applyABBypass(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                               frames: Int, abPushStart: Int) {
        let target: Float = abBypassFlag.load(ordering: .relaxed) ? 0 : 1
        guard target != 1 || abCrossfade != 1 else { return } // steady-state not bypassed: nothing to blend
        let latency = min(activeTotalLatency, Self.abDryCapacity - FXBlock.maxFrames)
        var fade = abCrossfade
        for i in 0..<frames {
            fade = target > fade ? min(target, fade + Self.crossfadeStep) : max(target, fade - Self.crossfadeStep)
            let readIndex = abPushStart + i - latency
            let dl: Float = readIndex >= 0 ? abDryLeft[readIndex & (Self.abDryCapacity - 1)] : 0
            let dr: Float = readIndex >= 0 ? abDryRight[readIndex & (Self.abDryCapacity - 1)] : 0
            left[i] = fade * left[i] + (1 - fade) * dl * abRatioSmoothed
            right[i] = fade * right[i] + (1 - fade) * dr * abRatioSmoothed
        }
        abCrossfade = fade
    }

    /// Declicks a structural swap: the outgoing graph finishes its last block faded to
    /// silence, the incoming one starts its first block faded in from silence. Never retains a
    /// `ChainGraph`: `activeGraphRef`/`latest` are non-owning `Unmanaged` views into whatever
    /// `ownedGraphs` (off the IO thread) is holding alive.
    private func runGraph(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                          frames: Int, mono: Bool, sidechain: FXSidechain) {
        let latestRef = graphPtr.load(ordering: .acquiring)
        var processedThisBlock = false

        // Any change -- a new graph published, OR the chain torn down (`graphPtr` cleared to
        // nil by `ioStopped`) -- is handled the same way: fade the outgoing graph (if any) to
        // silence, then adopt whatever's new (possibly nothing). `activeGraphRef` is only ever
        // read here, right after confirming it still matches what's actually current, so a
        // torn-down chain's stale pointer is never dereferenced again once this notices the
        // mismatch.
        if latestRef?.toOpaque() != activeGraphRef?.toOpaque() {
            if let oldRef = activeGraphRef {
                let old = oldRef.takeUnretainedValue()
                processSlots(old, left: left, right: right, frames: frames, mono: mono, sidechain: sidechain)
                let n = Float(frames)
                for i in 0..<frames {
                    let g = 1 - Float(i) / n
                    left[i] *= g
                    right[i] *= g
                }
                old.retired.store(true, ordering: .releasing)
                processedThisBlock = true
                pendingFadeIn = latestRef != nil
            }
            activeGraphRef = latestRef
            activeTotalLatency = latestRef?.takeUnretainedValue().totalLatency ?? 0
        }

        if !processedThisBlock, let ref = activeGraphRef {
            let graph = ref.takeUnretainedValue()
            processSlots(graph, left: left, right: right, frames: frames, mono: mono, sidechain: sidechain)
            if pendingFadeIn {
                let n = Float(frames)
                for i in 0..<frames {
                    let g = Float(i) / n
                    left[i] *= g
                    right[i] *= g
                }
                pendingFadeIn = false
            }
        }
        // Else: no active graph (a torn-down chain, or one that never got a first config) --
        // `left`/`right` stay exactly as the caller provided them (dry passthrough).
    }

    private func processSlots(_ graph: ChainGraph, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                              frames: Int, mono: Bool, sidechain: FXSidechain) {
        for slot in graph.slots {
            processSlot(slot, left: left, right: right, frames: frames, mono: mono, sidechain: sidechain)
        }
    }

    /// Runs one stage, crossfading its wet output against a dry tap delayed by the stage's own
    /// latency, so toggling `enabled` never jumps (the delayed dry signal lines up exactly with
    /// where the wet signal would be) and never changes the chain's overall timing.
    private func processSlot(_ slot: ChainGraph.Slot, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                             frames: Int, mono: Bool, sidechain: FXSidechain) {
        let latency = slot.latency
        let ringLen = slot.dryCapacity
        let pushStart = slot.dryWrite
        for i in 0..<frames {
            let idx = (pushStart + i) & (ringLen - 1)
            slot.dryLeft[idx] = left[i]
            slot.dryRight[idx] = right[i]
        }
        slot.dryWrite = pushStart + frames

        let block = FXBlock(left: left, right: mono ? left : right, frames: frames,
                            channels: mono ? 1 : 2, sidechain: sidechain)
        slot.node.process(block)
        if mono { for i in 0..<frames { right[i] = left[i] } }

        let target: Float = slot.enabled.load(ordering: .relaxed) ? 1 : 0
        var fade = slot.crossfade
        for i in 0..<frames {
            fade = target > fade ? min(target, fade + Self.crossfadeStep) : max(target, fade - Self.crossfadeStep)
            let readIndex = pushStart + i - latency
            let dl: Float = readIndex >= 0 ? slot.dryLeft[readIndex & (ringLen - 1)] : 0
            let dr: Float = readIndex >= 0 ? slot.dryRight[readIndex & (ringLen - 1)] : 0
            left[i] = fade * left[i] + (1 - fade) * dl
            right[i] = fade * right[i] + (1 - fade) * dr
        }
        slot.crossfade = fade
    }
}

/// Serializes and coalesces async requests to a single `apply` worker: concurrent `request`
/// calls never run `apply` concurrently with itself, and if a newer request arrives while one
/// is in flight (e.g. awaiting a slow hosted-plugin load), the in-flight one's result is simply
/// superseded -- `apply` runs again with the newest request once it returns, so only the latest
/// requested value is ever the one that "wins".
private actor ConfigCoalescer<Value: Sendable> {
    private var pending: Value?
    private var isRunning = false
    private let apply: @Sendable (Value) async -> Void

    init(apply: @escaping @Sendable (Value) async -> Void) {
        self.apply = apply
    }

    func request(_ value: Value) async {
        pending = value
        guard !isRunning else { return }
        isRunning = true
        while let next = pending {
            pending = nil
            await apply(next)
        }
        isRunning = false
    }
}

/// An immutable, published chain configuration: an ordered list of live node instances plus
/// the per-node live state (`enabled`, bypass crossfade, dry delay ring) the IO thread mutates
/// while this graph is active. Built off the IO thread; the IO thread never allocates one, and
/// never holds the strong reference that keeps it alive (see `FXChain`'s "Graph ownership" doc).
final class ChainGraph: @unchecked Sendable {
    /// One stage: a node instance plus the mutable IO-thread state around it. `enabled` is an
    /// atomic so a param-only update can flip it from any thread without touching the node
    /// itself; everything else here is IO-thread-only (mutated only while this graph is the
    /// one `FXChain.runGraph` is driving).
    final class Slot: @unchecked Sendable {
        let id: UUID
        let node: any FXNode
        let enabled: Atomic<Bool>
        let latency: Int
        let loadError: String?

        /// Dry tap sized to outlive the node's own latency within one block, so bypassing never
        /// reads uninitialized history.
        let dryLeft: UnsafeMutablePointer<Float>
        let dryRight: UnsafeMutablePointer<Float>
        let dryCapacity: Int
        var dryWrite = 0
        /// 0 = fully bypassed (dry), 1 = fully wet. Initialized already settled to the node's
        /// starting `enabled` state: only live toggles animate it, not graph (re)builds.
        var crossfade: Float

        init(id: UUID, node: any FXNode, enabled: Bool, latency: Int, loadError: String?) {
            self.id = id
            self.node = node
            self.enabled = Atomic(enabled)
            self.latency = latency
            self.loadError = loadError
            dryCapacity = FXBlockIO.nextPowerOfTwo(atLeast: max(1, latency) + FXBlock.maxFrames)
            dryLeft = .allocate(capacity: dryCapacity)
            dryRight = .allocate(capacity: dryCapacity)
            dryLeft.initialize(repeating: 0, count: dryCapacity)
            dryRight.initialize(repeating: 0, count: dryCapacity)
            crossfade = enabled ? 1 : 0
        }

        deinit {
            dryLeft.deallocate()
            dryRight.deallocate()
        }
    }

    var slots: [Slot]
    let totalLatency: Int
    /// Set exactly once by the IO thread, after it has finished the one final (fading) block it
    /// runs through this graph following a swap. `FXChain.scheduleRelease` polls this (off the
    /// IO thread, no timeout) before freeing the graph.
    let retired = Atomic<Bool>(false)

    init(slots: [Slot]) {
        self.slots = slots
        totalLatency = slots.reduce(0) { $0 + $1.latency }
    }
}
