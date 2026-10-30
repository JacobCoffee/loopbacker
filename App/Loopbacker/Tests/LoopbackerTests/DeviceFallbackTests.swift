import Foundation
import Testing
@testable import Loopbacker

@Suite("DeviceFallback")
struct DeviceFallbackTests {
    @Test("No preferences means no opinion")
    func noPreferences() {
        #expect(DeviceFallback.resolve(preferences: [], presentUIDs: ["a"]) == nil)
    }

    @Test("Resolves to the most-preferred present device")
    func mostPreferredWins() {
        let prefs = [
            DeviceFallbackEntry(uid: "motu", name: "MOTU M2"),
            DeviceFallbackEntry(uid: "airpods", name: "AirPods"),
            DeviceFallbackEntry(uid: "built-in", name: "MacBook Mic")
        ]

        #expect(DeviceFallback.resolve(preferences: prefs, presentUIDs: ["motu", "airpods", "built-in"]) == "motu")
        #expect(DeviceFallback.resolve(preferences: prefs, presentUIDs: ["airpods", "built-in"]) == "airpods")
        #expect(DeviceFallback.resolve(preferences: prefs, presentUIDs: ["built-in"]) == "built-in")
        #expect(DeviceFallback.resolve(preferences: prefs, presentUIDs: []) == nil)
    }
}

@Suite("RoutingState device fallback")
@MainActor
struct RoutingStateFallbackTests {
    private func device(uid: String, name: String, isInput: Bool = true) -> SystemAudioDevice {
        SystemAudioDevice(id: 0, uid: uid, name: name, inputChannelCount: 2, outputChannelCount: 0,
                           isInput: isInput, isOutput: false)
    }

    /// `RoutingState.save()` writes to disk on a background queue; tests must never touch the
    /// real Application Support config shared with the installed app, so every state in this
    /// suite persists to its own throwaway temp directory instead.
    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return url
    }

    @Test("A source with a configured fallback list rebinds to the next present preference")
    func rebindsToNextPresent() {
        var mic = AudioSource(name: "Interface", channels: [AudioChannel(id: 1, label: "1")], deviceUID: "motu")
        mic.fallbackDevices = [
            DeviceFallbackEntry(uid: "motu", name: "MOTU M2"),
            DeviceFallbackEntry(uid: "airpods", name: "AirPods")
        ]
        let state = RoutingState(sources: [mic], persistenceDirectory: tempDirectory())

        let changes = state.rebindMissingDeviceSources(to: [device(uid: "airpods", name: "AirPods")])

        #expect(changes.count == 1)
        #expect(changes[0].old == "motu")
        #expect(changes[0].newUID == "airpods")
        #expect(state.sources[0].deviceUID == "airpods")
    }

    @Test("A source switches back to a higher-preference device once it reappears")
    func switchesBackWhenPreferredReturns() {
        var mic = AudioSource(name: "Interface", channels: [AudioChannel(id: 1, label: "1")], deviceUID: "airpods")
        mic.fallbackDevices = [
            DeviceFallbackEntry(uid: "motu", name: "MOTU M2"),
            DeviceFallbackEntry(uid: "airpods", name: "AirPods")
        ]
        let state = RoutingState(sources: [mic], persistenceDirectory: tempDirectory())

        let changes = state.rebindMissingDeviceSources(to: [
            device(uid: "motu", name: "MOTU M2"), device(uid: "airpods", name: "AirPods")
        ])

        #expect(changes.count == 1)
        #expect(changes[0].old == "airpods")
        #expect(changes[0].newUID == "motu")
        #expect(state.sources[0].deviceUID == "motu")
    }

    @Test("No changes when the bound device is already the most preferred present one")
    func noChangeWhenAlreadyPreferred() {
        var mic = AudioSource(name: "Interface", channels: [AudioChannel(id: 1, label: "1")], deviceUID: "motu")
        mic.fallbackDevices = [
            DeviceFallbackEntry(uid: "motu", name: "MOTU M2"),
            DeviceFallbackEntry(uid: "airpods", name: "AirPods")
        ]
        let state = RoutingState(sources: [mic], persistenceDirectory: tempDirectory())

        let changes = state.rebindMissingDeviceSources(to: [
            device(uid: "motu", name: "MOTU M2"), device(uid: "airpods", name: "AirPods")
        ])

        #expect(changes.isEmpty)
        #expect(state.sources[0].deviceUID == "motu")
    }

    @Test("A source with no fallback list keeps the legacy single-name-match behavior")
    func legacyNameMatchUnaffected() {
        let mic = AudioSource(name: "USB Mic", channels: [AudioChannel(id: 1, label: "1")], deviceUID: "old-uid")
        let state = RoutingState(sources: [mic], persistenceDirectory: tempDirectory())

        let changes = state.rebindMissingDeviceSources(to: [device(uid: "new-uid", name: "USB Mic")])

        #expect(changes.count == 1)
        #expect(changes[0].old == "old-uid")
        #expect(changes[0].newUID == "new-uid")
    }
}
