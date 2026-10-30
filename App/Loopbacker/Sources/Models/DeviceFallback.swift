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
