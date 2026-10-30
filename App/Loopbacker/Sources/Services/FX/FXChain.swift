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
/// its first block. The outgoing graph is freed off the IO thread, once the IO thread has
/// provably finished using it (`ChainGraph.retired`).
///
/// Param-only edits (values, `enabled`, EQ bands) skip the rebuild entirely and push straight
/// into the live instances' `FXParamStore` (and `EQNode.setBands`). Toggling a node's `enabled`
/// still crossfades smoothly against a dry tap delayed by that node's own latency, so the
/// overall chain latency never changes when a node is bypassed.
///
/// Thread contract: `process` runs on the capture device's IO thread, one call at a time (a
/// busy flag enforces this, matching `NoiseSuppressor`). `updateConfigs`, `liveNode`,
/// `nodeLoadErrors`, `totalLatencySamples`, `captureHostedStates`, `setABBypass` and `record`
/// may be called from any thread (the structural path hops to a background `Task`).
final class FXChain: @unchecked Sendable {
    let sampleRate: Float
    let captureDeviceUID: String

    /// 10 ms at 48 kHz, used for both the per-node bypass crossfade and the NoiseSuppressor-style
    /// cache invalidation granularity.
    private static let crossfadeStep: Float = 1.0 / 480.0

    private let vad = VoiceActivityDetector()
    private let recorder: FXRecorder

    // MARK: Published state (any thread)

    private let graphPtr = Atomic<Unmanaged<ChainGraph>?>(nil)
    private let abBypassFlag = Atomic<Bool>(false)
    private let voiceProbabilityBits = Atomic<UInt32>(Float(0).bitPattern)
    private let configLock = NSLock()
    private var currentConfigs: [FXNodeConfig] = []

    // MARK: IO-thread sharing (mirrors NoiseSuppressor)

    private let busy = Atomic<Bool>(false)
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

    // MARK: IO-thread only state (never touched off the IO thread)

    private var activeGraph: ChainGraph?
    private var pendingFadeIn = false
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
        for p in [cachedInterleaved] { p.initialize(repeating: 0, count: n * 2) }
        for p in [scratchLeft, scratchRight, dryLeftScratch, dryRightScratch, vadMono, rawMonoScratch, processedMonoScratch] {
            p.initialize(repeating: 0, count: n)
        }
    }

    deinit {
        if let current = graphPtr.load(ordering: .acquiring) { current.release() }
        cachedInterleaved.deallocate()
        scratchLeft.deallocate()
        scratchRight.deallocate()
        dryLeftScratch.deallocate()
        dryRightScratch.deallocate()
        vadMono.deallocate()
        rawMonoScratch.deallocate()
        processedMonoScratch.deallocate()
    }

    // MARK: - Configuration (off the IO thread)

    /// Applies `configs` (the preset's ordered `nodes`), deciding internally whether this is a
    /// param-only update (same ids, kinds and plugin refs, in the same order -- values, EQ
    /// bands and enabled flags pushed straight into the live instances) or a structural one (a
    /// new graph built and published). Call from any non-IO-thread context; structural builds
    /// hop to a background `Task` on their own.
    func updateConfigs(_ configs: [FXNodeConfig]) async {
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

    /// Synchronous wrappers so the lock is never taken directly inside `updateConfigs`'s async
    /// body (`NSLock` is unavailable from async contexts).
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

    /// Publishes `newGraph` with one atomic swap, then waits (off the IO thread) for the
    /// outgoing graph to be marked retired by the IO thread before releasing it. Bounded by a
    /// timeout so a route that never processes another block again (e.g. torn down right after
    /// a structural edit) can't leak it forever.
    private func publish(_ newGraph: ChainGraph) {
        let previous = graphPtr.exchange(.passRetained(newGraph), ordering: .acquiringAndReleasing)
        guard let previous else { return }
        Task.detached(priority: .utility) {
            let old = previous.takeUnretainedValue()
            let deadline = DispatchTime.now() + 3
            while !old.retired.load(ordering: .acquiring), DispatchTime.now() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            previous.release()
        }
    }

    /// Test-only: installs `graph` as both the published and currently-active graph, bypassing
    /// config diffing, node construction and the declick swap. Lets tests drive `process` with
    /// hand-built graphs of fake nodes. Call before the first `process`.
    func debugInstallGraph(_ graph: ChainGraph) {
        let old = graphPtr.exchange(.passRetained(graph), ordering: .acquiringAndReleasing)
        old?.release()
        activeGraph = graph
        pendingFadeIn = false
    }

    private var publishedGraph: ChainGraph? { graphPtr.load(ordering: .acquiring)?.takeUnretainedValue() }

    // MARK: - Introspection (main thread, via FXEngine)

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
        guard frames > 0, stride > 0 else { return }
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
        if abBypassFlag.load(ordering: .relaxed) {
            let targetRatio = inputRMSEnergy > 1e-6 ? outputRMSEnergy / inputRMSEnergy : 1
            abRatioSmoothed = 0.995 * abRatioSmoothed + 0.005 * targetRatio
            for i in 0..<frames {
                scratchLeft[i] = dryLeftScratch[i] * abRatioSmoothed
                scratchRight[i] = dryRightScratch[i] * abRatioSmoothed
            }
        }

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

    /// Declicks a structural swap: the outgoing graph finishes its last block faded to
    /// silence, the incoming one starts its first block faded in from silence.
    private func runGraph(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                          frames: Int, mono: Bool, sidechain: FXSidechain) {
        let latest = graphPtr.load(ordering: .acquiring)?.takeUnretainedValue()
        var processedThisBlock = false

        if let latest, latest !== activeGraph {
            if let old = activeGraph {
                processSlots(old, left: left, right: right, frames: frames, mono: mono, sidechain: sidechain)
                let n = Float(frames)
                for i in 0..<frames {
                    let g = 1 - Float(i) / n
                    left[i] *= g
                    right[i] *= g
                }
                old.retired.store(true, ordering: .releasing)
                processedThisBlock = true
                pendingFadeIn = true
            }
            activeGraph = latest
        }

        if !processedThisBlock, let graph = activeGraph {
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

/// An immutable, published chain configuration: an ordered list of live node instances plus
/// the per-node live state (`enabled`, bypass crossfade, dry delay ring) the IO thread mutates
/// while this graph is active. Built off the IO thread; the IO thread never allocates one.
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
    /// runs through this graph following a swap. The publisher polls this off the IO thread
    /// before freeing the graph.
    let retired = Atomic<Bool>(false)

    init(slots: [Slot]) {
        self.slots = slots
        totalLatency = slots.reduce(0) { $0 + $1.latency }
    }

}
