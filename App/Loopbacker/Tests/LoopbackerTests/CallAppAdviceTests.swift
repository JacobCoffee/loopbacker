import Foundation
import Testing
@testable import Loopbacker

@Suite("CallAppAdviceCatalog")
struct CallAppAdviceTests {
    @Test("Only native call apps are catalogued, no browsers")
    func noBrowsers() {
        let browserIDs: Set<String> = ["com.google.Chrome", "company.thebrowser.Browser", "com.apple.Safari"]
        #expect(CallAppAdviceCatalog.all.allSatisfy { !browserIDs.contains($0.id) })
    }

    @Test("Every entry has a bundle id, name and non-empty advice")
    func wellFormed() {
        for entry in CallAppAdviceCatalog.all {
            #expect(!entry.id.isEmpty)
            #expect(!entry.appName.isEmpty)
            #expect(!entry.advice.isEmpty)
        }
    }
}

@Suite("EffectsPresetLibrary", .serialized)
@MainActor
struct EffectsPresetLibraryTests {
    private func makeState() -> RoutingState {
        RoutingState(sources: [], outputChannels: [], routes: [])
    }

    @Test("all() lists every factory preset first")
    func listsFactoryPresetsFirst() {
        let named = EffectsPresetLibrary.all()
        let factoryCount = FactoryPresets.all.count
        #expect(named.count >= factoryCount)
        #expect(Array(named.prefix(factoryCount)).allSatisfy { $0.isFactory })
        #expect(Set(named.prefix(factoryCount).map(\.id)) == Set(FactoryPresets.all.map(\.id)))
    }

    @Test("apply(id:) with a factory preset id sets the preset and noise suppression, keeping the user's echo cancellation")
    func appliesFactoryPreset() {
        let state = makeState()
        state.noiseSuppression.echoCancellation = true
        let factory = FactoryPresets.preset(id: "open-office")!
        #expect(factory.echoCancellation == nil)
        #expect(EffectsPresetLibrary.apply(id: "open-office", to: state))
        #expect(state.effectsPreset.isEnabled)
        #expect(state.effectsPreset.nodes.count == factory.preset.nodes.count)
        #expect(state.noiseSuppression.engine == factory.noiseSuppression?.engine)
        #expect(state.noiseSuppression.echoCancellation, "a preset without an echo setting must not switch it off")

        state.noiseSuppression.echoCancellation = false
        #expect(EffectsPresetLibrary.apply(id: "speakers-gaming", to: state))
        #expect(state.noiseSuppression.echoCancellation, "Speakers – Gaming turns echo cancellation on")
    }

    @Test("apply(id:) with an unknown id returns false and leaves state untouched")
    func unknownIDReturnsFalse() {
        let state = makeState()
        let before = state.effectsPreset
        #expect(!EffectsPresetLibrary.apply(id: "not-a-real-preset", to: state))
        #expect(state.effectsPreset == before)
    }
}
