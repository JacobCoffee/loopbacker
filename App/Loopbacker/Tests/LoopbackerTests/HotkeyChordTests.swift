import Foundation
import Testing
import Carbon.HIToolbox
@testable import Loopbacker

@Suite("HotkeyChord")
struct HotkeyChordTests {
    @Test("Round-trips through JSON")
    func codable() throws {
        let chord = HotkeyChord(keyCode: 49, modifiers: UInt32(cmdKey | shiftKey))
        let data = try JSONEncoder().encode(chord)
        let decoded = try JSONDecoder().decode(HotkeyChord.self, from: data)
        #expect(decoded == chord)
    }

    @Test("Display string orders modifiers Control-Option-Shift-Command and names Space")
    func displayStringOrder() {
        let chord = HotkeyChord(keyCode: 49, modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey))
        #expect(chord.displayString == "⌃⌥⇧⌘Space")
    }

    @Test("Display string falls back to \"Key N\" for an unnamed key code")
    func displayStringFallback() {
        let chord = HotkeyChord(keyCode: 200, modifiers: UInt32(cmdKey))
        #expect(chord.displayString == "⌘Key 200")
    }

    @Test("Display string names letters")
    func displayStringLetter() {
        let chord = HotkeyChord(keyCode: 0, modifiers: UInt32(cmdKey)) // 'A'
        #expect(chord.displayString == "⌘A")
    }

    @Test("A single modifier shows just that one glyph")
    func displayStringSingleModifier() {
        let chord = HotkeyChord(keyCode: 49, modifiers: UInt32(optionKey))
        #expect(chord.displayString == "⌥Space")
    }
}

@Suite("MicHotkeySettings", .serialized)
struct MicHotkeySettingsTests {
    @Test("releaseTailMs clamps to the documented range on write")
    func releaseTailClamps() {
        let original = MicHotkeySettings.releaseTailMs
        defer { MicHotkeySettings.releaseTailMs = original }

        MicHotkeySettings.releaseTailMs = 10_000
        #expect(MicHotkeySettings.releaseTailMs == MicHotkeySettings.releaseTailRange.upperBound)

        MicHotkeySettings.releaseTailMs = -50
        #expect(MicHotkeySettings.releaseTailMs == MicHotkeySettings.releaseTailRange.lowerBound)

        MicHotkeySettings.releaseTailMs = 150
        #expect(MicHotkeySettings.releaseTailMs == 150)
    }

    @Test("chord round-trips through UserDefaults")
    func chordRoundTrip() {
        let original = MicHotkeySettings.chord
        defer { MicHotkeySettings.chord = original }

        let chord = HotkeyChord(keyCode: 49, modifiers: UInt32(cmdKey))
        MicHotkeySettings.chord = chord
        #expect(MicHotkeySettings.chord == chord)

        MicHotkeySettings.chord = nil
        #expect(MicHotkeySettings.chord == nil)
    }
}
