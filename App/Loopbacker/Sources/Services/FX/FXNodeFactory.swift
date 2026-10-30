import Foundation

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

    private static func makeHosted(_ config: FXNodeConfig, sampleRate: Float) async -> (node: any FXNode, loadError: String?) {
        guard let ref = config.pluginRef else {
            return (PassthroughNode(kind: config.kind), "No plugin selected")
        }
        do {
            switch config.kind {
            case .audioUnit:
                return (try await AUHostNode.load(ref: ref, state: config.pluginState, sampleRate: Double(sampleRate)), nil)
            case .jsfx:
                return (try await JSFXNode.load(ref: ref, state: config.pluginState, sampleRate: Double(sampleRate)), nil)
            case .airwindows:
                return (try await AirwindowsNode.load(ref: ref, state: config.pluginState, sampleRate: Double(sampleRate)), nil)
            default:
                return (PassthroughNode(kind: config.kind), "Not a hosted kind")
            }
        } catch {
            return (PassthroughNode(kind: config.kind), error.localizedDescription)
        }
    }
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
