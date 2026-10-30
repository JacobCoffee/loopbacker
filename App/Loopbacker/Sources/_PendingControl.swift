import Foundation

// Stand-ins for the Presets slice's wave-2 interfaces (`local://fx-contract-wave2.md`), not yet
// merged into this worktree. Exact signatures from the contract:
//
//   struct NamedPreset: Identifiable, Hashable, Sendable { let id: String; let name: String; let isFactory: Bool }
//   enum EffectsPresetLibrary {
//       static func all() -> [NamedPreset]
//       @MainActor static func apply(id: String, to state: RoutingState) -> Bool
//   }
//
// The integration owner deletes this file once the Presets slice (`FactoryPreset`/
// `EffectsPresetLibrary`) lands and replaces `EffectsPreset.factoryPresets`/
// `EffectsPresetManager` with it. Until then this wraps what wave 1 actually shipped:
// `EffectsPreset.factoryPresets` (name/preset tuples) for factory presets and
// `EffectsPresetManager` (file-based) for saved ones.

struct NamedPreset: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isFactory: Bool
}

enum EffectsPresetLibrary {
    private static let factoryPrefix = "factory:"
    private static let savedPrefix = "saved:"

    /// Factory presets first (stable id = their name, since wave 1's tuples have no slug),
    /// then saved presets from `EffectsPresetManager`.
    static func all() -> [NamedPreset] {
        let factory = EffectsPreset.factoryPresets.map {
            NamedPreset(id: factoryPrefix + $0.name, name: $0.name, isFactory: true)
        }
        let saved = EffectsPresetManager.list().map {
            NamedPreset(id: savedPrefix + $0, name: $0, isFactory: false)
        }
        return factory + saved
    }

    /// Applies the preset named by `id` (as returned by `all()`) to `state.effectsPreset` and
    /// saves. Returns `false` if `id` doesn't resolve to a known preset.
    @MainActor
    static func apply(id: String, to state: RoutingState) -> Bool {
        if id.hasPrefix(factoryPrefix) {
            let name = String(id.dropFirst(factoryPrefix.count))
            guard let entry = EffectsPreset.factoryPresets.first(where: { $0.name == name }) else { return false }
            state.effectsPreset = entry.preset
            state.save()
            return true
        }
        if id.hasPrefix(savedPrefix) {
            let name = String(id.dropFirst(savedPrefix.count))
            guard let preset = EffectsPresetManager.load(name: name) else { return false }
            state.effectsPreset = preset
            state.save()
            return true
        }
        return false
    }
}
