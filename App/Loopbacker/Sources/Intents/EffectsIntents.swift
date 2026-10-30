import AppIntents

/// Shortcuts-visible wrapper over `NamedPreset` (from the Presets slice's `EffectsPresetLibrary`,
/// stood in by `_PendingControl.swift` until that slice merges).
struct NamedPresetEntity: AppEntity {
    let id: String
    let name: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Effects Preset"
    static let defaultQuery = NamedPresetEntityQuery()

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct NamedPresetEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [NamedPresetEntity] {
        let wanted = Set(identifiers)
        return ControlCenter.shared.availablePresets()
            .filter { wanted.contains($0.id) }
            .map { NamedPresetEntity(id: $0.id, name: $0.name) }
    }

    @MainActor
    func suggestedEntities() async throws -> [NamedPresetEntity] {
        ControlCenter.shared.availablePresets().map { NamedPresetEntity(id: $0.id, name: $0.name) }
    }
}

struct SetEffectsPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Effects Preset"
    static let description = IntentDescription("Applies a Loopbacker voice effects preset.")

    @Parameter(title: "Preset")
    var preset: NamedPresetEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Apply effects preset \(\.$preset)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard ControlCenter.shared.applyPreset(id: preset.id) else { throw ControlIntentError.unknownPreset }
        return .result(dialog: "Applied \(preset.name)")
    }
}

struct ToggleEffectsIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Voice Effects"
    static let description = IntentDescription("Turns the Loopbacker voice effects chain on or off.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard ControlCenter.shared.toggleEffects() else { throw ControlIntentError.notReady }
        return .result(dialog: ControlCenter.shared.isEffectsEnabled ? "Effects on" : "Effects off")
    }
}
