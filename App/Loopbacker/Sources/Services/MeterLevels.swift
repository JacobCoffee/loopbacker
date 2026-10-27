import Observation

/// Live meter levels (0...1, normalized dBFS) published by `AudioRouter` at ~30 Hz.
///
/// Kept apart from `RoutingState` on purpose: only views that read a level re-render when
/// meters move, instead of every view observing the routing graph.
@MainActor
@Observable
final class MeterLevels {
    /// Route key (source `deviceUID`, "app:<bundle>", or "output:<virtual device UID>") →
    /// 1-based channel → level.
    private(set) var sources: [String: [Int: Float]] = [:]
    /// Virtual mic channel (1-based) → post-mix level.
    private(set) var outputs: [Int: Float] = [:]

    nonisolated init() {}

    func level(source key: String, channel: Int) -> Float {
        sources[key]?[channel] ?? 0
    }

    func peak(source key: String) -> Float {
        sources[key]?.values.max() ?? 0
    }

    func output(channel: Int) -> Float {
        outputs[channel] ?? 0
    }

    func publish(sources: [String: [Int: Float]], outputs: [Int: Float]) {
        // Assigning always notifies observers; skip the frame when nothing moved.
        if sources != self.sources { self.sources = sources }
        if outputs != self.outputs { self.outputs = outputs }
    }
}
