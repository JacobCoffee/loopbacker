import Foundation

/// A hosted node that can report whether it has completed its first successful render.
/// Implemented by `QuarantineWitnessNode` (`FXNodeFactory.swift`); kept as a separate protocol
/// so `HostedPluginQuarantine` doesn't need to know about hosted-node internals, and so the
/// sweep below can hold it `weak` (see `observe(nodeID:witness:)`).
protocol HostedRenderWitness: AnyObject {
    var hasRendered: Bool { get }
}

/// Crash isolation for hosted nodes (LB-HOST-002). v2 Audio Units load in-process
/// (`AUHostNode`, see `AUCatalog`'s trust-model comment) and JSFX scripts JIT-compile and run
/// EEL2 code in the same process (`JSFXNode`); a crash or hang in either one takes the whole
/// process down, including every live audio route. Without this, a deterministic crash in a
/// hosted node that's part of the persisted routing config repeats at *every* launch, because
/// `FXNodeFactory` rebuilds the same chain again.
///
/// Mechanism: `FXNodeFactory` writes a sentinel file naming a hosted node (id + plugin ref)
/// before instantiating it. Three independent paths clear it again, all off the IO thread:
/// 1. A single shared sweep (`observe`/`sweepOnce`, not a per-node poll) notices the node's
///    first successful render.
/// 2. That same sweep notices the node was deallocated without ever rendering -- a disabled
///    node, a chain torn down for a route change, or any other normal removal. Reaching that
///    point at all proves the process didn't crash (a crash ends the whole process, including
///    this sweep), so the node wasn't the cause and shouldn't block its own retry next launch.
/// 3. `clearSessionSentinels()`, called from a clean-termination path, sweeps up every
///    sentinel this process ever wrote, whether or not its node rendered or was torn down --
///    covering a node that's still loaded and live right up to quit (deinit may not run before
///    the process actually exits).
///
/// If the process dies before any of the three clears it, the sentinel is still present next
/// launch. `isQuarantined` reports that node as crashed; the caller gets a `PassthroughNode`
/// with a "crashed Loopbacker last time; click to retry" load error instead of loading it
/// again, and `retry`/`clearAll` (surfaced to the UI through this class) let the user opt back
/// in.
final class HostedPluginQuarantine: @unchecked Sendable {
    static let shared = HostedPluginQuarantine()

    /// A hosted node whose sentinel from a previous launch was never cleared.
    struct Entry: Sendable, Equatable {
        var nodeID: UUID
        var pluginName: String
        var pluginRef: FXPluginRef
    }

    private struct SentinelPayload: Codable {
        var pluginName: String
        var pluginRef: FXPluginRef
    }

    private struct Observation {
        weak var witness: (any HostedRenderWitness)?
    }

    private let directory: URL
    private let lock = NSLock()
    /// Snapshot of sentinels that were already present (i.e. not cleared) when this instance
    /// was created — one launch's worth of "did this node crash last time" state. Updated as
    /// nodes clear or are retried during this run.
    private var quarantined: [UUID: Entry] = [:]
    /// Node ids this process wrote a sentinel for this session, regardless of whether it was
    /// later cleared — the source list for `clearSessionSentinels()`.
    private var sessionSentinelIDs: Set<UUID> = []
    /// Nodes currently being watched by the shared sweep (`observe`), held weakly.
    private var observations: [UUID: Observation] = [:]
    private var sweepTask: Task<Void, Never>?

    private convenience init() {
        self.init(directory: AppDataDirectory.url.appendingPathComponent("crash-sentinels", isDirectory: true))
    }

    /// Testing seam: an instance rooted at an arbitrary directory, so tests can exercise
    /// sentinel persistence and quarantine detection (including a simulated relaunch, by
    /// constructing a second instance over the same directory) without touching the real
    /// Application Support folder the live, installed app uses.
    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        loadExistingSentinels()
    }

    private func sentinelURL(_ nodeID: UUID) -> URL {
        directory.appendingPathComponent(nodeID.uuidString + ".json")
    }

    private func loadExistingSentinels() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for file in files {
            guard file.pathExtension == "json",
                  let nodeID = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: file),
                  let payload = try? JSONDecoder().decode(SentinelPayload.self, from: data)
            else { continue }
            quarantined[nodeID] = Entry(nodeID: nodeID, pluginName: payload.pluginName, pluginRef: payload.pluginRef)
        }
    }

    /// Call before instantiating a hosted node, off the IO thread (`FXNodeFactory.makeHosted`
    /// already runs off it — hosted loads hit disk/other processes). Writes a sentinel naming
    /// the node so a crash during `load()` or the node's first render is attributed to it at
    /// the next launch.
    func beginTracking(nodeID: UUID, ref: FXPluginRef) {
        let payload = SentinelPayload(pluginName: ref.name, pluginRef: ref)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: sentinelURL(nodeID), options: .atomic)
        lock.lock()
        sessionSentinelIDs.insert(nodeID)
        lock.unlock()
    }

    /// Registers `witness` for `nodeID` under the single shared sweep below (never a per-node
    /// poll). Held weakly on purpose: see the class doc's point 2.
    func observe(nodeID: UUID, witness: any HostedRenderWitness) {
        lock.lock()
        observations[nodeID] = Observation(witness: witness)
        lock.unlock()
        startSweepIfNeeded()
    }

    private func startSweepIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard sweepTask == nil else { return }
        sweepTask = Task.detached(priority: .utility) { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                self.sweepOnce()
            }
        }
    }

    private func sweepOnce() {
        lock.lock()
        let snapshot = observations
        lock.unlock()
        guard !snapshot.isEmpty else { return }

        var toClear: [UUID] = []
        for (nodeID, observation) in snapshot {
            if let witness = observation.witness {
                if witness.hasRendered { toClear.append(nodeID) }
            } else {
                // Deallocated without ever rendering: not a crash (see class doc, point 2).
                toClear.append(nodeID)
            }
        }
        guard !toClear.isEmpty else { return }

        lock.lock()
        for nodeID in toClear { observations.removeValue(forKey: nodeID) }
        lock.unlock()
        for nodeID in toClear { clearTracking(nodeID: nodeID) }
    }

    /// Call once a hosted node has either failed to load gracefully (a thrown Swift error, not
    /// a crash — nothing to quarantine) or has otherwise been confirmed not to have crashed
    /// (the shared sweep, or `clearSessionSentinels`). Always off the IO thread.
    func clearTracking(nodeID: UUID) {
        try? FileManager.default.removeItem(at: sentinelURL(nodeID))
        lock.lock()
        quarantined.removeValue(forKey: nodeID)
        sessionSentinelIDs.remove(nodeID)
        lock.unlock()
    }

    /// Call from a clean-termination path (e.g. `applicationWillTerminate`). Clears every
    /// sentinel this process wrote this session, whether or not its node ever rendered or was
    /// torn down: reaching a clean termination proves none of them crashed.
    func clearSessionSentinels() {
        lock.lock()
        let ids = sessionSentinelIDs
        lock.unlock()
        for id in ids { clearTracking(nodeID: id) }
    }

    /// True if `nodeID`'s sentinel from a previous launch is still present, meaning that launch
    /// never reached a successful first render for it.
    func isQuarantined(nodeID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return quarantined[nodeID] != nil
    }

    /// Every node currently quarantined, for a UI list/badge ("crashed Loopbacker last time").
    var quarantinedEntries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(quarantined.values)
    }

    /// User-initiated: stop treating `nodeID` as quarantined. Does not itself trigger a chain
    /// rebuild — the caller (effects UI) must do that afterward for the node to actually load
    /// again; the next load attempt rewrites the sentinel like any other node's.
    func retry(nodeID: UUID) {
        clearTracking(nodeID: nodeID)
    }

    /// User-initiated: dismiss every quarantine entry.
    func clearAll() {
        lock.lock()
        let ids = Array(quarantined.keys)
        lock.unlock()
        for id in ids { clearTracking(nodeID: id) }
    }
}
