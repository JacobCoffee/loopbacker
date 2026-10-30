import Foundation

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
    @Published private(set) var voiceProbability: Float = 0

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

    private func poll() {
        guard let chain = audioRouter?.firstVoiceFXChain() else {
            if totalLatencyMs != 0 { totalLatencyMs = 0 }
            if !nodeLoadErrors.isEmpty { nodeLoadErrors = [:] }
            if voiceProbability != 0 { voiceProbability = 0 }
            return
        }
        totalLatencyMs = chain.sampleRate > 0 ? Double(chain.totalLatencySamples) / Double(chain.sampleRate) * 1000 : 0
        nodeLoadErrors = chain.nodeLoadErrors()
        voiceProbability = chain.voiceProbability
        abBypassed = chain.isABBypassed
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

    /// Every hosted node's current state across every running voice chain (devices sharing the
    /// same preset carry the same node ids), to persist into the preset.
    func captureHostedStates() async -> [UUID: Data] {
        var out: [UUID: Data] = [:]
        for chain in audioRouter?.allVoiceFXChains() ?? [] {
            for (id, data) in await chain.captureHostedStates() { out[id] = data }
        }
        return out
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
