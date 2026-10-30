import AppIntents

/// Shortcuts-visible wrapper over a saved scene name (`PresetManager`, as used by `ScenesView`).
struct SceneEntity: AppEntity {
    let id: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Scene"
    static let defaultQuery = SceneEntityQuery()

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}

struct SceneEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [SceneEntity] {
        let known = Set(ControlCenter.shared.availableScenes())
        return identifiers.filter { known.contains($0) }.map { SceneEntity(id: $0) }
    }

    @MainActor
    func suggestedEntities() async throws -> [SceneEntity] {
        ControlCenter.shared.availableScenes().map { SceneEntity(id: $0) }
    }
}

struct LoadSceneIntent: AppIntent {
    static let title: LocalizedStringResource = "Load Scene"
    static let description = IntentDescription("Loads a saved Loopbacker routing scene.")

    @Parameter(title: "Scene")
    var scene: SceneEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Load scene \(\.$scene)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard ControlCenter.shared.loadScene(name: scene.id) else { throw ControlIntentError.unknownScene }
        return .result(dialog: "Loaded \(scene.id)")
    }
}
