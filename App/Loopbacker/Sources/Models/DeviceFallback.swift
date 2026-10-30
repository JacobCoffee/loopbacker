import Foundation

/// A device the user has pre-approved as a fallback for a source, remembered by UID and name so
/// it still reads correctly in the UI while the device is absent (sleep, unplug).
struct DeviceFallbackEntry: Identifiable, Codable, Equatable {
    var uid: String
    var name: String

    var id: String { uid }

    init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

/// Pure resolution logic for a source's ordered device preference list, decoupled from
/// CoreAudio enumeration so it's unit-testable.
enum DeviceFallback {
    /// Given a source's ordered device preferences (most-preferred first) and the set of
    /// currently present device UIDs, returns the UID the source should be bound to: the
    /// most-preferred present device. Returns `nil` when `preferences` is empty (the caller
    /// should fall back to its own legacy behavior) or when none of the preferred devices are
    /// present.
    static func resolve(preferences: [DeviceFallbackEntry], presentUIDs: Set<String>) -> String? {
        guard !preferences.isEmpty else { return nil }
        return preferences.first { presentUIDs.contains($0.uid) }?.uid
    }
}

/// One source's device UID changing underneath it, from `DeviceRebinder.rebind`.
struct RebindChange: Equatable {
    let sourceId: UUID
    let sourceName: String
    let old: String
    let newUID: String
    let newName: String
}

/// Pure device-rebinding logic, decoupled from `RoutingState` so both the live engine (via
/// `RoutingState.rebindMissingDeviceSources`) and scene loading (via `SceneLoader`, which must
/// normalize a saved scene's sources against the current device inventory *before* diffing it)
/// can reuse exactly the same rules without duplicating them.
enum DeviceRebinder {
    /// Re-binds device sources whose current device is unavailable.
    ///
    /// Sources with a configured `fallbackDevices` list use it: the most-preferred *present and
    /// unclaimed* device wins, so a source switches back to a higher-preference device (e.g.
    /// the primary interface) as soon as it reappears, not just when its current device
    /// disappears, and two sources can never end up bound to the same device UID (AudioRouter
    /// keys routing contexts by device UID, so that would silently stop/overwrite one of them).
    ///
    /// Sources with no configured list fall back to the legacy behavior: re-bind only while the
    /// current device is missing, by matching a single unclaimed input device with the same
    /// name (CoreAudio UIDs change when a different driver claims the hardware, e.g. MOTU's
    /// CoreUAC driver vs. AppleUSBAudioEngine).
    static func rebind(sources: [AudioSource], devices: [SystemAudioDevice]) -> (sources: [AudioSource], changes: [RebindChange]) {
        var sources = sources
        let presentUIDs = Set(devices.map(\.uid))
        var claimedUIDs = Set(sources.map(\.deviceUID))
        var changes: [RebindChange] = []

        for idx in sources.indices {
            let source = sources[idx]
            guard !source.isAppCapture, !source.deviceUID.isEmpty else { continue }

            if !source.fallbackDevices.isEmpty {
                // Only consider devices not currently claimed by some other source.
                let availableUIDs = presentUIDs.subtracting(claimedUIDs.subtracting([source.deviceUID]))
                guard let target = DeviceFallback.resolve(preferences: source.fallbackDevices, presentUIDs: availableUIDs),
                      target != source.deviceUID else { continue }
                let newName = source.fallbackDevices.first { $0.uid == target }?.name
                    ?? devices.first { $0.uid == target }?.name ?? ""
                changes.append(RebindChange(sourceId: source.id, sourceName: source.name,
                                             old: source.deviceUID, newUID: target, newName: newName))
                claimedUIDs.remove(source.deviceUID)
                claimedUIDs.insert(target)
                sources[idx].deviceUID = target
                continue
            }

            guard !presentUIDs.contains(source.deviceUID) else { continue }
            let candidates = devices.filter {
                $0.isInput && $0.name == source.name && !claimedUIDs.contains($0.uid)
            }
            guard candidates.count == 1, let match = candidates.first else { continue }
            claimedUIDs.insert(match.uid)
            changes.append(RebindChange(sourceId: source.id, sourceName: source.name,
                                         old: source.deviceUID, newUID: match.uid, newName: match.name))
            sources[idx].deviceUID = match.uid
        }

        return (sources, changes)
    }
}
