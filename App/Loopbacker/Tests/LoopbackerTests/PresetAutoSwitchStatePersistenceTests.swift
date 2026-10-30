import Foundation
import Testing
@testable import Loopbacker

/// `PresetAutoSwitchState.save()` writes to the same file the real app uses (its path isn't
/// injectable); every test here captures the file's original bytes and restores them in `defer`
/// so a real run of the app never loses its automation rules because the test suite ran.
@MainActor
@Suite("PresetAutoSwitchState persistence", .serialized)
struct PresetAutoSwitchStatePersistenceTests {
    private var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Loopbacker", isDirectory: true)
            .appendingPathComponent("preset-auto-switch.json")
    }

    @Test("Rapid consecutive saves land in submission order, not completion-race order")
    func savesLandInSubmissionOrder() async throws {
        let original = try? Data(contentsOf: fileURL)
        defer {
            if let original {
                try? original.write(to: fileURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

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
        let original = try? Data(contentsOf: fileURL)
        defer {
            if let original {
                try? original.write(to: fileURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

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
