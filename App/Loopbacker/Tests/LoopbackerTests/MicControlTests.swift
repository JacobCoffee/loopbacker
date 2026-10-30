import Foundation
import Testing
@testable import Loopbacker

/// `MicControl` persists `.open` mode's mute state and the global `MicHotkeySettings` to
/// `UserDefaults.standard`; tests save and restore it so they don't leak into each other or a
/// real run of the app.
@MainActor
@Suite("MicControl", .serialized)
struct MicControlTests {
    private let testDefaults = UserDefaults(suiteName: "com.jacobcoffee.loopbacker.tests.miccontrol")!
    private func withClean(_ body: () async throws -> Void) async rethrows {
        let originalMode = MicHotkeySettings.mode
        let originalTail = MicHotkeySettings.releaseTailMs
        MicHotkeySettings.mode = .open
        defer {
            MicHotkeySettings.mode = originalMode
            MicHotkeySettings.releaseTailMs = originalTail
        }
        try await body()
    }

    @Test("Open mode: toggleMute flips isMuted")
    func openModeToggle() async {
        await withClean {
            let control = MicControl(defaults: testDefaults)
            #expect(control.mode == .open)
            let initial = control.isMuted
            control.toggleMute()
            #expect(control.isMuted == !initial)
            control.toggleMute()
            #expect(control.isMuted == initial)
        }
    }

    @Test("Push-to-talk: pressing the hotkey immediately unmutes and marks held")
    func pushToTalkPress() async {
        await withClean {
            let control = MicControl(defaults: testDefaults)
            control.mode = .pushToTalk
            #expect(control.isMuted == true) // idle: muted
            control.hotkeyPressed()
            #expect(control.isMuted == false)
            #expect(control.pushToTalkHeld == true)
        }
    }

    @Test("Push-to-talk: toggleMute is a no-op while held (hotkey owns mute state)")
    func pushToTalkIgnoresManualToggle() async {
        await withClean {
            let control = MicControl(defaults: testDefaults)
            control.mode = .pushToTalk
            control.hotkeyPressed()
            #expect(control.isMuted == false)
            control.toggleMute()
            #expect(control.isMuted == false) // unchanged
        }
    }

    @Test("Push-to-talk: releasing clears held immediately but mute is deferred by the release tail")
    func pushToTalkReleaseDeferred() async throws {
        try await withClean {
            MicHotkeySettings.releaseTailMs = 40
            let control = MicControl(defaults: testDefaults)
            control.mode = .pushToTalk
            control.hotkeyPressed()
            #expect(control.isMuted == false)

            control.hotkeyReleased()
            #expect(control.pushToTalkHeld == false) // held clears immediately
            #expect(control.isMuted == false) // but still live right after release

            try await Task.sleep(nanoseconds: 150_000_000) // > 40 ms tail
            #expect(control.isMuted == true) // now muted
        }
    }

    @Test("Push-to-talk: a re-press within the release tail cancels the pending mute")
    func pushToTalkRepressCancelsTail() async throws {
        try await withClean {
            MicHotkeySettings.releaseTailMs = 60
            let control = MicControl(defaults: testDefaults)
            control.mode = .pushToTalk
            control.hotkeyPressed()
            control.hotkeyReleased()

            try await Task.sleep(nanoseconds: 20_000_000) // well inside the 60 ms tail
            control.hotkeyPressed() // re-press before the tail fires
            #expect(control.isMuted == false)

            try await Task.sleep(nanoseconds: 100_000_000) // past the original tail's deadline
            #expect(control.isMuted == false) // still live: the stale timer didn't fire
        }
    }

    @Test("Push-to-mute: held = muted, released = live after the tail")
    func pushToMute() async throws {
        try await withClean {
            MicHotkeySettings.releaseTailMs = 40
            let control = MicControl(defaults: testDefaults)
            control.mode = .pushToMute
            #expect(control.isMuted == false) // idle: live

            control.hotkeyPressed()
            #expect(control.isMuted == true)

            control.hotkeyReleased()
            #expect(control.isMuted == true) // still muted right after release

            try await Task.sleep(nanoseconds: 150_000_000)
            #expect(control.isMuted == false) // live again
        }
    }

    @Test("Switching mode resets hold state and applies the new mode's idle mute state")
    func modeSwitchResets() async {
        await withClean {
            let control = MicControl(defaults: testDefaults)
            control.mode = .pushToTalk
            control.hotkeyPressed()
            #expect(control.pushToTalkHeld == true)

            control.mode = .open
            #expect(control.pushToTalkHeld == false)
        }
    }
}
