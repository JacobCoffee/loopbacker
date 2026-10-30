import AppKit
import Foundation
import Synchronization

/// Builds `FXNode` instances from an `FXNodeConfig`: built-ins directly, hosted effects via
/// their format's async loader. Off the IO thread only (hosted loads hit disk/other processes).
enum FXNodeFactory {
    /// Builds the node for `config` and applies its persisted parameters. A hosted effect that
    /// fails to load returns a `PassthroughNode` carrying the error instead of throwing, so a
    /// chain build never aborts over one bad slot.
    static func make(_ config: FXNodeConfig, sampleRate: Float) async -> (node: any FXNode, loadError: String?) {
        let node: any FXNode
        var loadError: String?
        switch config.kind {
        case .gate: node = GateNode(sampleRate: sampleRate)
        case .eq: node = EQNode(sampleRate: sampleRate)
        case .compressor: node = CompressorNode(sampleRate: sampleRate)
        case .leveler: node = LevelerNode(sampleRate: sampleRate)
        case .deEsser: node = DeEsserNode(sampleRate: sampleRate)
        case .chorus: node = ChorusNode(sampleRate: sampleRate)
        case .pitchShift: node = PitchShiftNode(sampleRate: sampleRate)
        case .reverb: node = ReverbNode(sampleRate: sampleRate)
        case .delay: node = DelayNode(sampleRate: sampleRate)
        case .limiter: node = LimiterNode(sampleRate: sampleRate)
        case .audioUnit, .jsfx, .airwindows:
            let built = await makeHosted(config, sampleRate: sampleRate)
            node = built.node
            loadError = built.loadError
        }

        node.apply(config.params)
        if let eqNode = node as? EQNode {
            eqNode.setBands(config.eqBands ?? EQBandConfig.broadcast)
        }
        return (node, loadError)
    }

    /// Loads a hosted effect, coordinating with `HostedPluginQuarantine` (LB-HOST-002): a node
    /// whose sentinel from a previous launch is still present (meaning that launch never
    /// reached a successful first render for it) loads as a quarantined `PassthroughNode`
    /// instead of being instantiated again. Otherwise the sentinel is written before `load()`
    /// runs and cleared either on a graceful (non-crashing) load failure or, for a node that
    /// did load, once `QuarantineWitnessNode` observes its first successful `process()` call.
    private static func makeHosted(_ config: FXNodeConfig, sampleRate: Float) async -> (node: any FXNode, loadError: String?) {
        guard let ref = config.pluginRef else {
            return (PassthroughNode(kind: config.kind), "No plugin selected")
        }
        let quarantine = HostedPluginQuarantine.shared
        if quarantine.isQuarantined(nodeID: config.id) {
            return (PassthroughNode(kind: config.kind), "crashed Loopbacker last time; click to retry")
        }
        quarantine.beginTracking(nodeID: config.id, ref: ref)
        do {
            let hosted: any FXHostedNode
            switch config.kind {
            case .audioUnit:
                hosted = try await AUHostNode.load(ref: ref, state: config.pluginState, sampleRate: Double(sampleRate))
            case .jsfx:
                hosted = try await JSFXNode.load(ref: ref, state: config.pluginState, sampleRate: Double(sampleRate))
            case .airwindows:
                hosted = try await AirwindowsNode.load(ref: ref, state: config.pluginState, sampleRate: Double(sampleRate))
            default:
                quarantine.clearTracking(nodeID: config.id)
                return (PassthroughNode(kind: config.kind), "Not a hosted kind")
            }
            return (QuarantineWitnessNode(wrapping: hosted, nodeID: config.id), nil)
        } catch {
            // A thrown Swift error is a graceful failure, not a crash: nothing to quarantine.
            quarantine.clearTracking(nodeID: config.id)
            return (PassthroughNode(kind: config.kind), error.localizedDescription)
        }
    }
}

/// Wraps a hosted node so `HostedPluginQuarantine` can observe its first successful render
/// without the render call itself doing any I/O (LB-HOST-002). Transparent pass-through
/// otherwise: every `FXHostedNode` requirement forwards to the wrapped node unchanged.
private final class QuarantineWitnessNode: FXHostedNode, HostedRenderWitness, @unchecked Sendable {
    private let wrapped: any FXHostedNode
    let kind: FXNodeKind
    var specs: [FXParamSpec] { wrapped.specs }
    var params: FXParamStore { wrapped.params }
    var meters: FXMeters { wrapped.meters }
    var latencySamples: Int { wrapped.latencySamples }
    var ref: FXPluginRef { wrapped.ref }

    /// Set once, on the IO thread, after the first `process()` call returns -- a plain atomic
    /// store, no I/O. `HostedPluginQuarantine`'s single shared sweep (not a per-node poll)
    /// reads this through `hasRendered` and, independently, notices if this instance is
    /// deallocated without ever rendering (held weakly) -- both clear the crash sentinel.
    private let rendered = Atomic<Bool>(false)
    var hasRendered: Bool { rendered.load(ordering: .acquiring) }

    init(wrapping node: any FXHostedNode, nodeID: UUID) {
        wrapped = node
        kind = node.kind
        HostedPluginQuarantine.shared.observe(nodeID: nodeID, witness: self)
    }

    func process(_ block: FXBlock) {
        wrapped.process(block)
        if !rendered.load(ordering: .relaxed) {
            rendered.store(true, ordering: .releasing)
        }
    }

    func reset() { wrapped.reset() }

    @MainActor func captureState() -> Data? { wrapped.captureState() }
    @MainActor func makeEditor() async -> NSViewController? { await wrapped.makeEditor() }
}

/// A stage that failed to load (or has no plugin selected yet): carries audio through
/// unchanged so the chain keeps running, while the id surfaces in `FXChain.nodeLoadErrors()`.
final class PassthroughNode: FXNode, @unchecked Sendable {
    let kind: FXNodeKind
    let specs: [FXParamSpec] = []
    let params = FXParamStore(specs: [])
    let meters = FXMeters()
    let latencySamples = 0

    init(kind: FXNodeKind) { self.kind = kind }
    func process(_ block: FXBlock) {}
    func reset() {}
}
