import Foundation
import Testing
@testable import Loopbacker

/// `PresetAutoSwitchState` persists under `AppDataDirectory`, which in a test process is a
/// private temp folder, never the installed app's Application Support.
@MainActor
@Suite("PresetAutoSwitchState persistence", .serialized)
struct PresetAutoSwitchStatePersistenceTests {
    @Test("Tests never write the installed app's data folder")
    func testProcessDataIsPrivate() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        #expect(!AppDataDirectory.url.standardizedFileURL.path.hasPrefix(appSupport.standardizedFileURL.path))
        #expect(RoutingState.defaultConfigDirectoryURL == AppDataDirectory.url)
    }

    @Test("Rapid consecutive saves land in submission order, not completion-race order")
    func savesLandInSubmissionOrder() async throws {
        let state = PresetAutoSwitchState()
        for i in 0..<20 {
            state.fallbackPresetID = "preset-\(i)"
            state.save()
        }
        // Give the serial save queue time to drain every submitted write.
        try await Task.sleep(nanoseconds: 300_000_000)

        let loaded = PresetAutoSwitchState.load()
        #expect(loaded.fallbackPresetID == "preset-19")
    }

    @Test("Adding then immediately deleting a rule doesn't resurrect it on next launch")
    func addThenDeleteDoesNotResurrect() async throws {
        let state = PresetAutoSwitchState()
        let rule = PresetAutoSwitchRule(appBundleID: "com.example.app", appName: "Example", presetID: "p1", presetName: "P1")
        state.addRule(rule)
        state.removeRule(id: rule.id)
        // Give the serial save queue time to drain both writes.
        try await Task.sleep(nanoseconds: 300_000_000)

        let loaded = PresetAutoSwitchState.load()
        #expect(loaded.rules.isEmpty)
    }
}
