import Foundation

/// A condition an automation rule watches for. Levels, not edges: `appLaunched` matches for as
/// long as the app is running, `appQuit` for as long as it isn't, so a rule stays applied while
/// its condition holds rather than firing once and reverting.
enum RuleTrigger: Codable, Equatable {
    case appLaunched(bundleID: String, appName: String)
    case appQuit(bundleID: String, appName: String)
    case appFrontmost(bundleID: String, appName: String)
    case deviceAdded(uid: String, name: String)
    case deviceRemoved(uid: String, name: String)

    var summary: String {
        switch self {
        case .appLaunched(_, let name): "\(name.isEmpty ? "App" : name) is running"
        case .appQuit(_, let name): "\(name.isEmpty ? "App" : name) is not running"
        case .appFrontmost(_, let name): "\(name.isEmpty ? "App" : name) is frontmost"
        case .deviceAdded(_, let name): "\(name.isEmpty ? "Device" : name) is connected"
        case .deviceRemoved(_, let name): "\(name.isEmpty ? "Device" : name) is not connected"
        }
    }
}

/// What a matching rule does. Scene-only today; adding a sibling case (e.g. an effects-preset
/// action for #20) extends this enum without restructuring `AutomationRule` or `RuleEngine`.
enum RuleAction: Codable, Equatable {
    case loadScene(name: String)

    var sceneName: String? {
        if case .loadScene(let name) = self { return name }
        return nil
    }
}

struct AutomationRule: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var trigger: RuleTrigger
    var action: RuleAction
    var isEnabled: Bool

    init(id: UUID = UUID(), name: String, trigger: RuleTrigger, action: RuleAction, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.trigger = trigger
        self.action = action
        self.isEnabled = isEnabled
    }
}

/// Persisted automation rules, the fallback scene, and manual-override pause state. Rules apply
/// in list order; the first enabled rule whose trigger currently holds wins (see `RuleEngine`).
class AutomationRulesState: ObservableObject {
    @Published var rules: [AutomationRule]
    @Published var fallbackSceneName: String?
    /// Paused while the user manually picks a scene, until the triggering condition changes.
    @Published var isPaused: Bool
    /// The signals in effect when the user paused rules, so the engine can tell when the
    /// triggering condition has changed and resume automatically.
    @Published var pausedSignals: RuleEngine.Signals?

    init(rules: [AutomationRule] = [], fallbackSceneName: String? = nil, isPaused: Bool = false,
         pausedSignals: RuleEngine.Signals? = nil) {
        self.rules = rules
        self.fallbackSceneName = fallbackSceneName
        self.isPaused = isPaused
        self.pausedSignals = pausedSignals
    }

    func addRule(_ rule: AutomationRule) {
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

    /// Called when the user manually loads a scene: pauses automation until the signals that
    /// were true at pause time change.
    func pauseForManualSelection(signals: RuleEngine.Signals) {
        isPaused = true
        pausedSignals = signals
        save()
    }

    func resume() {
        isPaused = false
        pausedSignals = nil
        save()
    }

    // MARK: - Persistence

    private static let configURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Loopbacker", isDirectory: true)
            .appendingPathComponent("automation.json")
    }()

    private static let saveQueue = DispatchQueue(label: "com.jacobcoffee.loopbacker.automation.save", qos: .utility)

    private struct PersistedState: Codable {
        var rules: [AutomationRule]
        var fallbackSceneName: String?
        var isPaused: Bool
        var pausedSignals: RuleEngine.Signals?
    }

    func save() {
        let snapshot = PersistedState(
            rules: rules, fallbackSceneName: fallbackSceneName, isPaused: isPaused, pausedSignals: pausedSignals
        )
        Self.saveQueue.async {
            do {
                try FileManager.default.createDirectory(
                    at: Self.configURL.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: Self.configURL, options: .atomic)
            } catch {
                print("Loopbacker: failed to save automation rules: \(error)")
            }
        }
    }

    static func load() -> AutomationRulesState {
        do {
            let data = try Data(contentsOf: configURL)
            let snapshot = try JSONDecoder().decode(PersistedState.self, from: data)
            return AutomationRulesState(
                rules: snapshot.rules, fallbackSceneName: snapshot.fallbackSceneName,
                isPaused: snapshot.isPaused, pausedSignals: snapshot.pausedSignals
            )
        } catch {
            return AutomationRulesState()
        }
    }
}
