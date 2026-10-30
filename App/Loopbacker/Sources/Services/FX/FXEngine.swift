import Foundation

/// Per-frame voice-chain meter values, isolated into their own `ObservableObject` so the 15 Hz
/// poll that updates them invalidates only the small views observing `FXEngine.meters` --
/// never the whole Effects page (`FXEngine` itself, including `InteractiveEQView`'s
/// pixel-by-pixel curve work) the way folding this into `FXEngine`'s own `@Published` state did.
@MainActor
final class FXEngineMeters: ObservableObject {
    @Published var voiceProbability: Float = 0
}

/// Main-actor facade over the voice chains running inside `AudioRouter`, owned by the app
/// alongside `RoutingSync`/`AudioRouter`. Every voice-input device (mic → virtual mic, mic →
/// monitor) runs its own `FXChain`, but they all run the same preset, so this surfaces the
/// first active one for UI purposes (meters, latency, plugin errors) and fans writes
/// (A/B bypass) out to all of them.
@MainActor
final class FXEngine: ObservableObject {
    @Published private(set) var totalLatencyMs: Double = 0
    @Published private(set) var nodeLoadErrors: [UUID: String] = [:]
    @Published private(set) var availablePlugins: [FXPluginInfo] = []
    @Published private(set) var abBypassed = false
    /// Per-frame speech-probability meter, moved out of this object's own `@Published` state
    /// (see `FXEngineMeters`). Not `@Published` here: reading it doesn't trigger a SwiftUI
    /// update on its own -- observe `meters` directly for that.
    var voiceProbability: Float { meters.voiceProbability }
    let meters = FXEngineMeters()

    private weak var audioRouter: AudioRouter?
    private var pollTimer: Timer?

    init(audioRouter: AudioRouter) {
        self.audioRouter = audioRouter
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.poll() }
        }
    }

    isolated deinit {
        pollTimer?.invalidate()
    }

    /// Publishes slow-changing chain status only on change (so a steady-state chain doesn't
    /// invalidate `EffectsView` 15 times a second for values that never moved), and routes the
    /// genuinely per-frame value (`voiceProbability`) through `meters` instead of `self`.
    private func poll() {
        guard let chain = audioRouter?.firstVoiceFXChain() else {
            if totalLatencyMs != 0 { totalLatencyMs = 0 }
            if !nodeLoadErrors.isEmpty { nodeLoadErrors = [:] }
            if meters.voiceProbability != 0 { meters.voiceProbability = 0 }
            return
        }
        let latencyMs = chain.sampleRate > 0 ? Double(chain.totalLatencySamples) / Double(chain.sampleRate) * 1000 : 0
        if totalLatencyMs != latencyMs { totalLatencyMs = latencyMs }
        let errors = chain.nodeLoadErrors()
        if nodeLoadErrors != errors { nodeLoadErrors = errors }
        let bypassed = chain.isABBypassed
        if abBypassed != bypassed { abBypassed = bypassed }
        meters.voiceProbability = chain.voiceProbability
    }

    /// The live node instance for `id` on the first active voice device, or nil if no voice
    /// route is running or the preset doesn't contain that node.
    func liveNode(id: UUID) -> (any FXNode)? {
        audioRouter?.firstVoiceFXChain()?.liveNode(id: id)
    }

    /// Bypasses (or restores) every running voice chain with loudness-matched A/B comparison.
    func setABBypass(_ bypassed: Bool) {
        for chain in audioRouter?.allVoiceFXChains() ?? [] { chain.setABBypass(bypassed) }
        abBypassed = bypassed
    }

    /// Every hosted node's current state from the representative voice chain
    /// (`firstVoiceFXChain()`, the same instance `liveNode` surfaces and the plugin editor
    /// edits), to persist into the preset. Other devices run independent instances of the same
    /// node ids but are never the one being edited, so their state is intentionally left out:
    /// capturing from every chain and merging by id let whichever instance happened to be
    /// visited last in `allVoiceFXChains()`'s unspecified dictionary order silently overwrite
    /// the edited instance's state. Live-synchronizing other devices' hosted-plugin instances
    /// would need a runtime `restoreState` on `FXHostedNode` (today state is only consumed at
    /// construction, from `FXNodeConfig.pluginState`); out of scope here.
    func captureHostedStates() async -> [UUID: Data] {
        guard let chain = audioRouter?.firstVoiceFXChain() else { return [:] }
        return await chain.captureHostedStates()
    }

    /// Scans the three hosted-effect catalogs concurrently and caches the result for the
    /// effect browser.
    func refreshPlugins() async {
        async let au = AUCatalog.scan()
        async let jsfx = JSFXCatalog.scan()
        async let airwindows = AirwindowsCatalog.scan()
        availablePlugins = await au + jsfx + airwindows
    }

    /// Records `seconds` of raw (pre-noise-suppression) and processed audio from the first
    /// active voice device. An empty recording when no voice route is running.
    func record(seconds: Double) async -> FXRecording {
        guard let chain = audioRouter?.firstVoiceFXChain() else {
            return FXRecording(raw: [], processed: [], sampleRate: Double(NoiseSuppressor.sampleRate))
        }
        return await chain.record(seconds: seconds)
    }
}
