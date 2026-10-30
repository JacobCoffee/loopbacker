import Observation

/// One channel's live level, observed independently of every other channel and route.
///
/// `@Observable` tracks access per stored property of the object that's actually read, so a
/// view that reads one box's `level` only re-renders when that box's own `level` is written —
/// not when any other channel, route, or output moves.
@MainActor
@Observable
final class ChannelLevelBox {
    private(set) var level: Float = 0

    /// Levels are quantized to ~0.4% (1/256) steps before the write-if-changed check, so the
    /// continuous exponential decay between a route's blocks doesn't invalidate observers on
    /// every tick for a change no meter pixel or cable glow could show.
    fileprivate func set(_ newValue: Float) {
        let quantized = (newValue * 256).rounded() / 256
        if level != quantized { level = quantized }
    }
}

/// One route's (source or output) channel levels plus its precomputed peak, so `SourcePeakMeter`
/// and `CableView` — which only ever want the loudest channel — don't force every per-channel
/// consumer to recompute a max on every read.
@MainActor
@Observable
final class SourceLevelStore {
    private var boxes: [Int: ChannelLevelBox] = [:]
    private(set) var peak: Float = 0

    /// Called once per meter tick with this route's freshly drained channel levels.
    fileprivate func update(_ channels: [Int: Float]) {
        var newPeak: Float = 0
        for (channel, level) in channels {
            box(forChannel: channel).set(level)
            newPeak = max(newPeak, level)
        }
        let quantizedPeak = (newPeak * 256).rounded() / 256
        if peak != quantizedPeak { peak = quantizedPeak }
    }

    fileprivate func level(channel: Int) -> Float {
        boxes[channel]?.level ?? 0
    }

    /// Looks up or lazily creates the box for a channel. Only writes `boxes` (and so only
    /// invalidates observers of the store's channel set, not of any individual channel) the
    /// first time a channel is seen; every later tick just mutates the existing box in place.
    private func box(forChannel channel: Int) -> ChannelLevelBox {
        if let existing = boxes[channel] { return existing }
        let box = ChannelLevelBox()
        boxes[channel] = box
        return box
    }
}

/// Live meter levels (0...1, normalized dBFS) published by `AudioRouter` at ~30 Hz.
///
/// Kept apart from `RoutingState` on purpose: only views that read a level re-render when
/// meters move, instead of every view observing the routing graph. Storage is split per route
/// (`SourceLevelStore`) and per channel (`ChannelLevelBox`) so one route's level change doesn't
/// invalidate every other route's meters and cables: `sourceStores`/`outputStores` are themselves
/// `@Observable`-tracked, but they're only written (and so only broadcast a change) when a route
/// or channel first appears, never on the per-tick level update — that writes the leaf box's own
/// `level`, which only the views reading that exact box observe.
///
/// Output levels are post-mix and per target device (the virtual mic and, when enabled, Stream
/// Mix): each target gets its own `SourceLevelStore` keyed by its device UID, so the two
/// targets' meters never bleed into each other even though their channel numbering overlaps
/// (both start at channel 1).
@MainActor
@Observable
final class MeterLevels {
    private var sourceStores: [String: SourceLevelStore] = [:]
    private var outputStores: [String: SourceLevelStore] = [:]

    nonisolated init() {}

    func level(source key: String, channel: Int) -> Float {
        sourceStores[key]?.level(channel: channel) ?? 0
    }

    func peak(source key: String) -> Float {
        sourceStores[key]?.peak ?? 0
    }

    /// Post-mix level for `channel` (1-based) on the given target device.
    func output(target: String, channel: Int) -> Float {
        outputStores[target]?.level(channel: channel) ?? 0
    }

    /// Pushes one route's freshly drained channel levels. Lazily creates the route's store the
    /// first time its key is seen.
    func updateSource(_ key: String, channels: [Int: Float]) {
        let store = sourceStores[key] ?? {
            let store = SourceLevelStore()
            sourceStores[key] = store
            return store
        }()
        store.update(channels)
    }

    /// Sets a target device's post-mix output levels (the router already took the max across
    /// every route feeding that target).
    func updateOutputs(target: String, _ channels: [Int: Float]) {
        let store = outputStores[target] ?? {
            let store = SourceLevelStore()
            outputStores[target] = store
            return store
        }()
        store.update(channels)
    }

    /// Number of route stores currently held, so the router can skip the `Set` allocation in
    /// `retainSources` on every tick where no route started or stopped.
    var sourceCount: Int { sourceStores.count }

    /// Drops stores for routes no longer present. Called only when `sourceCount` disagrees with
    /// the router's active-route count, so routing changes (rare) pay for this, not every tick.
    func retainSources(_ keys: Set<String>) {
        for key in sourceStores.keys where !keys.contains(key) {
            sourceStores.removeValue(forKey: key)
        }
    }

    /// Drops output channel state for one target. Called once when its last route stops, so a
    /// stale post-mix peak doesn't linger forever on a channel nothing writes anymore.
    func clearOutputs(target: String) {
        guard outputStores[target] != nil else { return }
        outputStores.removeValue(forKey: target)
    }
}
