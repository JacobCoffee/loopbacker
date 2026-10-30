import Foundation
import Testing
@testable import Loopbacker

/// `AppAudioFX.trigger` and `CallDuckSettings` were both added by this feature; every field
/// must decode tolerantly from JSON saved before they existed (or hand-edited with fields
/// missing), falling back to defaults that preserve old behavior rather than failing to decode
/// the whole object.
@Suite("Call-duck settings tolerant decode")
struct CallDuckSettingsDecodeTests {
    @Test("AppAudioFX with no trigger key decodes to .myVoice (old, only, behavior)")
    func appAudioFXMissingTriggerDefaultsToMyVoice() throws {
        let json = """
        {"duckingEnabled": true, "duckAmountDB": -9, "duckAttackMs": 30, "duckReleaseMs": 500,
         "levelerEnabled": false, "levelerTarget": -18}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppAudioFX.self, from: json)
        #expect(decoded.trigger == .myVoice)
        #expect(decoded.duckingEnabled == true)
        #expect(decoded.duckAmountDB == -9)
    }

    @Test("A full EffectsPreset v2 export with no appAudio.trigger key still decodes, ducking unaffected")
    func effectsPresetMissingTriggerDecodes() throws {
        let json = """
        {"version": 2, "isEnabled": true, "nodes": [],
         "appAudio": {"duckingEnabled": true, "duckAmountDB": -15, "duckAttackMs": 40,
                      "duckReleaseMs": 600, "levelerEnabled": false, "levelerTarget": -20}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(EffectsPreset.self, from: json)
        #expect(decoded.appAudio.trigger == .myVoice)
        #expect(decoded.appAudio.duckAmountDB == -15)
    }

    @Test("A completely empty appAudio JSON object decodes to all defaults")
    func appAudioFXEmptyObjectDecodesToDefaults() throws {
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppAudioFX.self, from: json)
        #expect(decoded == AppAudioFX())
    }

    @Test("AppAudioFX with an explicit trigger round-trips")
    func appAudioFXTriggerRoundTrips() throws {
        var fx = AppAudioFX()
        fx.trigger = .both
        let data = try JSONEncoder().encode(fx)
        let decoded = try JSONDecoder().decode(AppAudioFX.self, from: data)
        #expect(decoded.trigger == .both)
    }

    @Test("CallDuckSettings.load() with no saved file returns suggested defaults, disabled")
    @MainActor
    func loadWithNoFileReturnsDefaults() {
        // `CallDuckSettings.load()` reads from `AppDataDirectory.url`, already routed to a
        // temp directory for this test process (see `AppDataDirectory`'s own doc comment) --
        // no real app data is touched.
        let settings = CallDuckSettings.load()
        #expect(settings.listenDuckEnabled == false)
        #expect(settings.listenDuckTrigger == .callVoices)
        #expect(settings.extraCallAppBundleIDs.isEmpty)
    }

    @Test("CallDuckSettings round-trips a full save/load cycle")
    @MainActor
    func saveLoadRoundTrips() async throws {
        let settings = CallDuckSettings()
        settings.listenDuckEnabled = true
        settings.listenDuckBundleIDs = ["com.spotify.client"]
        settings.listenDuckAmountDB = -14
        settings.listenDuckTrigger = .both
        settings.extraCallAppBundleIDs = ["com.google.Chrome"]
        settings.save()

        // `save()` writes asynchronously on a serial queue; give it a moment, matching
        // `PresetAutoSwitchStatePersistenceTests`'s own approach to the same pattern.
        try await Task.sleep(for: .milliseconds(200))

        let reloaded = CallDuckSettings.load()
        #expect(reloaded.listenDuckEnabled == true)
        #expect(reloaded.listenDuckBundleIDs == ["com.spotify.client"])
        #expect(reloaded.listenDuckAmountDB == -14)
        #expect(reloaded.listenDuckTrigger == .both)
        #expect(reloaded.extraCallAppBundleIDs == ["com.google.Chrome"])
    }
}
