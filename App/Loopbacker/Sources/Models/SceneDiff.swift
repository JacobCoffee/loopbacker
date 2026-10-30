import Foundation

/// What `AudioRouter` should be doing for a given routing configuration, derived purely from
/// state (no CoreAudio calls). Mirrors the decisions `RoutingSync.syncAudioRouting` makes, as a
/// value type so scene loading can diff two configs without touching the engine, and so the
/// diff logic is unit-testable without a live router.
struct RoutingDesiredState: Equatable {
    /// One audio route that should be running, keyed the same way `AudioRouter` keys its
    /// internal `activeRoutes` dictionary (`deviceUID` for a device source, `"app:<bundleID>"`
    /// for an app capture source).
    struct ActiveRoute: Equatable {
        let key: String
        let isAppCapture: Bool
        let bundleID: String
        let deviceUID: String
        /// Source-channel -> output-channel pairs, in canonical order so equality isn't
        /// sensitive to the order routes were added in.
        let mix: [MixEntry]
    }

    struct MixEntry: Equatable, Hashable {
        let sourceChannel: Int
        let outputChannel: Int
    }

    /// Active routes keyed by `ActiveRoute.key`.
    var routes: [String: ActiveRoute] = [:]
    /// Device source UID -> monitor output device UID, for every enabled, unmuted device
    /// source with a monitor configured.
    var monitors: [String: String] = [:]
    /// Output destinations that should be routing, keyed by `virtualDeviceUID`.
    var outputs: [String: OutputDestination] = [:]
    /// Virtual device UID -> channel count the driver should expose (the mic plus every output
    /// destination device).
    var deviceChannelCounts: [String: Int] = [:]

    static func compute(from config: RoutingConfig) -> RoutingDesiredState {
        var state = RoutingDesiredState()

        for source in config.sources {
            let sourceRoutes = config.routes.filter { $0.sourceId == source.id }
            let shouldRoute = source.isEnabled && !source.isMuted && !sourceRoutes.isEmpty
                && (source.isAppCapture ? !source.appBundleID.isEmpty : !source.deviceUID.isEmpty)
            guard shouldRoute else { continue }

            let key = source.isAppCapture ? "app:\(source.appBundleID)" : source.deviceUID
            let mix = sourceRoutes
                .map { MixEntry(sourceChannel: $0.sourceChannelId, outputChannel: $0.outputChannelId) }
                .sorted { ($0.sourceChannel, $0.outputChannel) < ($1.sourceChannel, $1.outputChannel) }
            state.routes[key] = ActiveRoute(
                key: key, isAppCapture: source.isAppCapture, bundleID: source.appBundleID,
                deviceUID: source.deviceUID, mix: mix
            )

            if !source.isAppCapture && !source.monitorOutputUID.isEmpty {
                state.monitors[source.deviceUID] = source.monitorOutputUID
            }
        }

        for dest in config.outputDestinations where dest.isEnabled && !dest.physicalOutputUID.isEmpty {
            state.outputs[dest.virtualDeviceUID] = dest
            state.deviceChannelCounts[dest.virtualDeviceUID] = dest.channelCount
        }

        state.deviceChannelCounts[VirtualDeviceChannels.micUID] =
            VirtualDeviceChannels.deviceCount(forChannels: config.outputChannels.count)

        return state
    }
}

/// The minimal set of engine actions needed to move from one `RoutingDesiredState` to another:
/// routes present in both are left running untouched, routes whose mix changed are retargeted
/// in place (no stop/start), and only genuinely added/removed routes start or stop.
struct SceneDiff: Equatable {
    struct Retarget: Equatable {
        let key: String
        let mix: [RoutingDesiredState.MixEntry]
    }

    var routesToStart: [RoutingDesiredState.ActiveRoute] = []
    var routesToStop: [String] = []
    var routesToRetarget: [Retarget] = []
    var monitorsToStart: [(sourceDeviceUID: String, outputDeviceUID: String)] = []
    var monitorsToStop: [String] = []
    var outputsToStart: [OutputDestination] = []
    var outputsToStop: [String] = []
    var channelCountChanges: [String: Int] = [:]

    var isEmpty: Bool {
        routesToStart.isEmpty && routesToStop.isEmpty && routesToRetarget.isEmpty
            && monitorsToStart.isEmpty && monitorsToStop.isEmpty
            && outputsToStart.isEmpty && outputsToStop.isEmpty && channelCountChanges.isEmpty
    }

    static func == (lhs: SceneDiff, rhs: SceneDiff) -> Bool {
        lhs.routesToStart == rhs.routesToStart && lhs.routesToStop == rhs.routesToStop
            && lhs.routesToRetarget == rhs.routesToRetarget
            && lhs.monitorsToStart.map(\.sourceDeviceUID) == rhs.monitorsToStart.map(\.sourceDeviceUID)
            && lhs.monitorsToStart.map(\.outputDeviceUID) == rhs.monitorsToStart.map(\.outputDeviceUID)
            && lhs.monitorsToStop == rhs.monitorsToStop
            && lhs.outputsToStart == rhs.outputsToStart && lhs.outputsToStop == rhs.outputsToStop
            && lhs.channelCountChanges == rhs.channelCountChanges
    }

    static func diff(from old: RoutingDesiredState, to new: RoutingDesiredState) -> SceneDiff {
        var result = SceneDiff()

        for (key, route) in new.routes {
            guard let existing = old.routes[key] else {
                result.routesToStart.append(route)
                continue
            }
            if existing.mix != route.mix {
                result.routesToRetarget.append(Retarget(key: key, mix: route.mix))
            }
        }
        for key in old.routes.keys where new.routes[key] == nil {
            result.routesToStop.append(key)
        }

        for (deviceUID, outputUID) in new.monitors where old.monitors[deviceUID] != outputUID {
            result.monitorsToStart.append((sourceDeviceUID: deviceUID, outputDeviceUID: outputUID))
        }
        for deviceUID in old.monitors.keys where new.monitors[deviceUID] == nil {
            result.monitorsToStop.append(deviceUID)
        }

        for (uid, dest) in new.outputs {
            if let existing = old.outputs[uid],
               existing.physicalOutputUID == dest.physicalOutputUID, existing.monitorChannel == dest.monitorChannel {
                continue
            }
            result.outputsToStart.append(dest)
        }
        for uid in old.outputs.keys where new.outputs[uid] == nil {
            result.outputsToStop.append(uid)
        }

        for (uid, count) in new.deviceChannelCounts where old.deviceChannelCounts[uid] != count {
            result.channelCountChanges[uid] = count
        }

        return result
    }
}
