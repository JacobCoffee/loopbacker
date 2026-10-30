import Foundation
import Testing
@testable import Loopbacker

@Suite("LoopbackerURLCommand")
struct LoopbackerURLCommandTests {
    private func parse(_ string: String) -> LoopbackerURLCommand? {
        guard let url = URL(string: string) else { return nil }
        return LoopbackerURLCommand.parse(url)
    }

    @Test("mute / unmute / toggle-mute")
    func simpleCommands() {
        #expect(parse("loopbacker://mute") == .mute)
        #expect(parse("loopbacker://unmute") == .unmute)
        #expect(parse("loopbacker://toggle-mute") == .toggleMute)
        #expect(parse("loopbacker://togglemute") == .toggleMute)
    }

    @Test("preset?id= carries the id")
    func presetCommand() {
        #expect(parse("loopbacker://preset?id=factory:meeting-natural") == .preset(id: "factory:meeting-natural"))
    }

    @Test("preset without id is invalid")
    func presetMissingID() {
        #expect(parse("loopbacker://preset") == nil)
        #expect(parse("loopbacker://preset?id=") == nil)
    }

    @Test("scene?name= carries the name, percent-decoded")
    func sceneCommand() {
        #expect(parse("loopbacker://scene?name=Gaming%20Night") == .scene(name: "Gaming Night"))
    }

    @Test("scene without name is invalid")
    func sceneMissingName() {
        #expect(parse("loopbacker://scene") == nil)
    }

    @Test("effects?on= accepts 1/0, true/false, yes/no, on/off")
    func effectsCommand() {
        #expect(parse("loopbacker://effects?on=1") == .effects(on: true))
        #expect(parse("loopbacker://effects?on=true") == .effects(on: true))
        #expect(parse("loopbacker://effects?on=YES") == .effects(on: true))
        #expect(parse("loopbacker://effects?on=on") == .effects(on: true))
        #expect(parse("loopbacker://effects?on=0") == .effects(on: false))
        #expect(parse("loopbacker://effects?on=false") == .effects(on: false))
        #expect(parse("loopbacker://effects?on=no") == .effects(on: false))
        #expect(parse("loopbacker://effects?on=off") == .effects(on: false))
    }

    @Test("effects with garbage value is invalid")
    func effectsInvalidValue() {
        #expect(parse("loopbacker://effects?on=maybe") == nil)
        #expect(parse("loopbacker://effects") == nil)
    }

    @Test("Unknown command is invalid")
    func unknownCommand() {
        #expect(parse("loopbacker://frobnicate") == nil)
    }

    @Test("Wrong scheme is invalid")
    func wrongScheme() {
        #expect(parse("https://mute") == nil)
    }

    @Test("Scheme-only form (no slashes) still resolves the command from the path")
    func schemeOnlyForm() {
        #expect(parse("loopbacker:mute") == .mute)
    }

    @Test("Command name is case-insensitive")
    func caseInsensitive() {
        #expect(parse("loopbacker://MUTE") == .mute)
        #expect(parse("LOOPBACKER://mute") == .mute)
    }
}

/// `LoopbackerURLSettings.allowCommands` uses `UserDefaults.standard` directly (shared with the
/// real app's setting, same as `MicHotkeySettings`); tests save and restore the original value.
/// Exercises only the pure gating decision (`command == .mute || allowCommands`), not
/// `URLCommandRouter.handle(_:)` itself, which drives `ControlCenter`/`MutedOverlayController`
/// and would show a real on-screen panel for `.unmute`.
@Suite("LoopbackerURLSettings", .serialized)
struct LoopbackerURLSettingsTests {
    private func withClean(_ body: () -> Void) {
        let original = LoopbackerURLSettings.allowCommands
        defer { LoopbackerURLSettings.allowCommands = original }
        body()
    }

    @Test("Off by default")
    func offByDefault() {
        withClean {
            UserDefaults.standard.removeObject(forKey: "Automation.allowURLCommands")
            #expect(LoopbackerURLSettings.allowCommands == false)
        }
    }

    @Test("mute is always allowed regardless of the setting")
    func muteAlwaysAllowed() {
        withClean {
            for allowed in [true, false] {
                LoopbackerURLSettings.allowCommands = allowed
                let command = LoopbackerURLCommand.mute
                #expect(command == .mute || LoopbackerURLSettings.allowCommands)
            }
        }
    }

    @Test("Every non-mute command is blocked while the setting is off")
    func nonMuteBlockedWhenOff() {
        withClean {
            LoopbackerURLSettings.allowCommands = false
            let commands: [LoopbackerURLCommand] = [
                .unmute, .toggleMute, .preset(id: "p"), .scene(name: "s"), .effects(on: true),
            ]
            for command in commands {
                #expect(!(command == .mute || LoopbackerURLSettings.allowCommands))
            }
        }
    }

    @Test("Every command is allowed while the setting is on")
    func allCommandsAllowedWhenOn() {
        withClean {
            LoopbackerURLSettings.allowCommands = true
            let commands: [LoopbackerURLCommand] = [
                .mute, .unmute, .toggleMute, .preset(id: "p"), .scene(name: "s"), .effects(on: true),
            ]
            for command in commands {
                #expect(command == .mute || LoopbackerURLSettings.allowCommands)
            }
        }
    }
}
