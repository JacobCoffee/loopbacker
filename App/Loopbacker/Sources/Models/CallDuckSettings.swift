import Foundation

/// Global (not per-preset) call-ducking settings: which extra apps count as "a call" for
/// far-end detection (`CallAudioMonitor`), and "Duck what I hear" (`ListenDucker`, Part B) --
/// lowering apps like Spotify or a browser on the user's own output while people in a call are
/// talking. Part A's per-trigger ducking amount/attack/release stays in `EffectsPreset.appAudio`
/// (`AppAudioFX`, scoped to a preset like the rest of the voice/app-audio chain); this is global
/// because "what I hear" has nothing to do with which voice preset is active.
///
/// Persisted the same way as `PresetAutoSwitchState`/`AutomationRulesState`: a JSON file under
/// `AppDataDirectory` (routed to a temp directory for tests/non-app processes), loaded once at
/// launch via `load()`, written on every mutation via `save()`.
@MainActor
final class CallDuckSettings: ObservableObject {
    /// Bundle IDs treated as "a call" beyond the fixed `CallAppAdviceCatalog` (Zoom, Discord,
    /// Teams, Slack). Empty by default -- a browser running a web call can't be told apart from
    /// any other tab, so it only becomes a far-end source once the user explicitly adds it here.
    @Published var extraCallAppBundleIDs: Set<String>

    /// "Duck what I hear" (Part B): on/off.
    @Published var listenDuckEnabled: Bool
    /// Bundle IDs of apps to duck on the user's own output. Never includes Loopbacker itself or
    /// a bundle ID currently also in `extraCallAppBundleIDs`/`CallAppAdviceCatalog` --
    /// `ListenDucker.sanitizedBundleIDs` enforces this at the point the tap is built, since the
    /// two lists can each change independently.
    @Published var listenDuckBundleIDs: [String]
    @Published var listenDuckAmountDB: Float
    /// Only `.callVoices` (default) or `.both` make sense here -- ducking your own output while
    /// only you are talking and nobody else is has no use case, so the UI never offers
    /// `.myVoice` alone, but the type is shared with `AppAudioFX.trigger` rather than adding a
    /// second, narrower enum.
    @Published var listenDuckTrigger: CallDuckTrigger

    nonisolated static let duckAmountRange: ClosedRange<Float> = -30...0

    /// Seeded default pick for first launch (not re-applied once the user edits the list, even
    /// to an empty one): the apps most likely to be music/background noise worth ducking.
    /// Bundle IDs only, not a `CaptureApp` lookup, since the picker already intersects this
    /// against whatever's actually running via `AppCaptureService.availableApps`.
    nonisolated static let suggestedBundleIDs = [
        "com.spotify.client", "com.apple.Music", "com.apple.Safari",
        "com.google.Chrome", "org.mozilla.firefox", "com.microsoft.edgemac"
    ]

    init(
        extraCallAppBundleIDs: Set<String> = [],
        listenDuckEnabled: Bool = false,
        listenDuckBundleIDs: [String] = CallDuckSettings.suggestedBundleIDs,
        listenDuckAmountDB: Float = -20,
        listenDuckTrigger: CallDuckTrigger = .callVoices
    ) {
        self.extraCallAppBundleIDs = extraCallAppBundleIDs
        self.listenDuckEnabled = listenDuckEnabled
        self.listenDuckBundleIDs = listenDuckBundleIDs
        self.listenDuckAmountDB = listenDuckAmountDB
        self.listenDuckTrigger = listenDuckTrigger
    }

    // MARK: - Persistence

    private static let fileURL: URL = AppDataDirectory.url.appendingPathComponent("call-duck-settings.json")

    private struct Persisted: Codable {
        var extraCallAppBundleIDs: Set<String>
        var listenDuckEnabled: Bool
        var listenDuckBundleIDs: [String]
        var listenDuckAmountDB: Float
        var listenDuckTrigger: CallDuckTrigger

        init(
            extraCallAppBundleIDs: Set<String>, listenDuckEnabled: Bool, listenDuckBundleIDs: [String],
            listenDuckAmountDB: Float, listenDuckTrigger: CallDuckTrigger
        ) {
            self.extraCallAppBundleIDs = extraCallAppBundleIDs
            self.listenDuckEnabled = listenDuckEnabled
            self.listenDuckBundleIDs = listenDuckBundleIDs
            self.listenDuckAmountDB = listenDuckAmountDB
            self.listenDuckTrigger = listenDuckTrigger
        }

        /// Tolerant decode: every field falls back independently to its default (via a fresh
        /// `CallDuckSettings()`), so a file saved by an earlier build of this feature (or
        /// hand-edited) with some fields missing still loads instead of discarding the whole
        /// file -- same pattern as `AppAudioFX.init(from:)`.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Literal defaults, not `CallDuckSettings()`: this nested `Persisted` type isn't
            // `@MainActor`-isolated, but `CallDuckSettings` is, so constructing one here would
            // need actor isolation this decode init doesn't have.
            extraCallAppBundleIDs = (try? c.decode(Set<String>.self, forKey: .extraCallAppBundleIDs)) ?? []
            listenDuckEnabled = (try? c.decode(Bool.self, forKey: .listenDuckEnabled)) ?? false
            listenDuckBundleIDs = (try? c.decode([String].self, forKey: .listenDuckBundleIDs)) ?? CallDuckSettings.suggestedBundleIDs
            listenDuckAmountDB = (try? c.decode(Float.self, forKey: .listenDuckAmountDB)) ?? -20
            listenDuckTrigger = (try? c.decode(CallDuckTrigger.self, forKey: .listenDuckTrigger)) ?? .callVoices
        }
    }

    /// Serial, matching `RoutingState.save()`/`PresetAutoSwitchState.save()`: consecutive saves
    /// must finish their atomic file replacements in submission order.
    private static let saveQueue = DispatchQueue(label: "com.jacobcoffee.loopbacker.callduck.save", qos: .utility)

    func save() {
        let snapshot = Persisted(
            extraCallAppBundleIDs: extraCallAppBundleIDs, listenDuckEnabled: listenDuckEnabled,
            listenDuckBundleIDs: listenDuckBundleIDs, listenDuckAmountDB: listenDuckAmountDB,
            listenDuckTrigger: listenDuckTrigger)
        let url = Self.fileURL
        Self.saveQueue.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                print("Loopbacker: failed to save call-duck settings: \(error)")
            }
        }
    }

    static func load() -> CallDuckSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let persisted = try? JSONDecoder().decode(Persisted.self, from: data) else {
            return CallDuckSettings()
        }
        return CallDuckSettings(
            extraCallAppBundleIDs: persisted.extraCallAppBundleIDs, listenDuckEnabled: persisted.listenDuckEnabled,
            listenDuckBundleIDs: persisted.listenDuckBundleIDs, listenDuckAmountDB: persisted.listenDuckAmountDB,
            listenDuckTrigger: persisted.listenDuckTrigger)
    }
}
