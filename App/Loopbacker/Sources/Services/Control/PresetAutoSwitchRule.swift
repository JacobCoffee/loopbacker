import Foundation

/// When a rule's app condition is considered to hold.
enum PresetAutoSwitchMatch: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The app is running anywhere (foreground or background).
    case launched
    /// The app is the frontmost (active) app.
    case frontmost

    var id: String { rawValue }

    var title: String {
        switch self {
        case .launched: "App Running"
        case .frontmost: "App Frontmost"
        }
    }
}

/// Switches the effects preset to `presetID` (a `NamedPreset.id`) while `appBundleID` matches
/// `matchOn`. Rules apply in list order — the first enabled match wins — mirroring how
/// `EffectsPresetLibrary.all()` already orders factory-before-saved presets.
struct PresetAutoSwitchRule: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var appBundleID: String
    var appName: String
    var presetID: String
    var presetName: String
    var matchOn: PresetAutoSwitchMatch
    var isEnabled: Bool
    /// When the triggering app quits (meaningful for `.launched`; ignored for `.frontmost`,
    /// since another app becoming frontmost already re-evaluates normally), revert to whatever
    /// preset was active just before this rule took over, instead of falling through to the
    /// next matching rule's preset or the automation fallback.
    var restorePreviousOnQuit: Bool

    init(id: UUID = UUID(), appBundleID: String, appName: String, presetID: String, presetName: String,
         matchOn: PresetAutoSwitchMatch = .launched, isEnabled: Bool = true, restorePreviousOnQuit: Bool = false) {
        self.id = id
        self.appBundleID = appBundleID
        self.appName = appName
        self.presetID = presetID
        self.presetName = presetName
        self.matchOn = matchOn
        self.isEnabled = isEnabled
        self.restorePreviousOnQuit = restorePreviousOnQuit
    }

    var summary: String {
        "\(appName) \(matchOn == .frontmost ? "is frontmost" : "is running") → \(presetName)"
    }
}

/// Persisted preset auto-switch rules and fallback, plus a suppression flag the Effects UI can
/// set while the user is mid-edit so a rule firing doesn't yank the chain out from under them.
@MainActor
final class PresetAutoSwitchState: ObservableObject {
    @Published var rules: [PresetAutoSwitchRule]
    @Published var fallbackPresetID: String?
    /// Set by the Effects page while the user has it open/is editing; the switcher skips
    /// evaluation entirely while this is true so an app launch mid-edit can't apply a rule out
    /// from under unsaved changes.
    @Published var isSuppressedByEditing = false

    init(rules: [PresetAutoSwitchRule] = [], fallbackPresetID: String? = nil) {
        self.rules = rules
        self.fallbackPresetID = fallbackPresetID
    }

    func addRule(_ rule: PresetAutoSwitchRule) {
        rules.append(rule)
        save()
    }

    func removeRule(id: UUID) {
        rules.removeAll { $0.id == id }
        save()
    }

    func moveRule(fromOffsets: IndexSet, toOffset: Int) {
        rules.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
    }

    func setRuleEnabled(id: UUID, isEnabled: Bool) {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[idx].isEnabled = isEnabled
        save()
    }

    // MARK: - Persistence

    private static let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Loopbacker", isDirectory: true)
            .appendingPathComponent("preset-auto-switch.json")
    }()

    private struct Persisted: Codable {
        var rules: [PresetAutoSwitchRule]
        var fallbackPresetID: String?
    }

    func save() {
        let snapshot = Persisted(rules: rules, fallbackPresetID: fallbackPresetID)
        let url = Self.fileURL
        DispatchQueue.global(qos: .utility).async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                print("Loopbacker: failed to save preset auto-switch rules: \(error)")
            }
        }
    }

    static func load() -> PresetAutoSwitchState {
        guard let data = try? Data(contentsOf: fileURL),
              let persisted = try? JSONDecoder().decode(Persisted.self, from: data) else {
            return PresetAutoSwitchState()
        }
        return PresetAutoSwitchState(rules: persisted.rules, fallbackPresetID: persisted.fallbackPresetID)
    }
}
