import AppKit
import Carbon.HIToolbox

/// A global hotkey chord: a virtual key code plus Carbon modifier flags (`cmdKey`/`optionKey`/
/// `controlKey`/`shiftKey`), the shape `RegisterEventHotKey` wants. Stored as plain integers
/// (not `NSEvent.ModifierFlags`) so it round-trips through `UserDefaults`/JSON without carrying
/// AppKit baggage.
struct HotkeyChord: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// Built from a key-down `NSEvent`. `nil` if the event carries no modifier — a bare key
    /// would steal every keystroke from every other app, so recording requires at least one.
    init?(event: NSEvent) {
        var carbonMods: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.control) { carbonMods |= UInt32(controlKey) }
        if flags.contains(.option) { carbonMods |= UInt32(optionKey) }
        if flags.contains(.shift) { carbonMods |= UInt32(shiftKey) }
        if flags.contains(.command) { carbonMods |= UInt32(cmdKey) }
        guard carbonMods != 0 else { return nil }
        self.keyCode = UInt32(event.keyCode)
        self.modifiers = carbonMods
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// "⌃⌥Space"-style readout for Settings and the muted overlay's help text.
    var displayString: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(Self.keyName(keyCode))
        return parts.joined()
    }

    /// Named keys a recorder commonly sees; anything else falls back to "Key N" rather than
    /// guessing a layout-dependent character.
    private static let keyNames: [UInt32: String] = [
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Escape",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
        12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
        16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
        28: "8", 25: "9",
    ]

    private static func keyName(_ keyCode: UInt32) -> String {
        keyNames[keyCode] ?? "Key \(keyCode)"
    }
}

/// Mode a configured hotkey drives the mic in.
enum MicMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Toggle: the hotkey flips mute on/off, like a manual mute button.
    case open
    /// Held = live, released = muted after the release tail.
    case pushToTalk
    /// Held = muted, released = live after the release tail (the inverse of push-to-talk, for
    /// workflows that are open by default and want a quick "shut up" key).
    case pushToMute

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: "Toggle Mute"
        case .pushToTalk: "Push to Talk"
        case .pushToMute: "Push to Mute"
        }
    }

    var detail: String {
        switch self {
        case .open: "The hotkey mutes and unmutes the mic."
        case .pushToTalk: "Hold the hotkey to talk; release to mute."
        case .pushToMute: "The mic stays live; hold the hotkey to mute."
        }
    }
}

/// Persisted mic-hotkey configuration: `UserDefaults`-backed so it reads back before any
/// `ObservableObject` is constructed (the app wires the real hotkey at launch, in `init()`).
enum MicHotkeySettings {
    private static let chordKey = "MicHotkey.chord"
    private static let enabledKey = "MicHotkey.isEnabled"
    private static let modeKey = "MicHotkey.mode"
    private static let releaseTailKey = "MicHotkey.releaseTailMs"

    /// Off by default: a global hotkey is an opt-in surprise.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var chord: HotkeyChord? {
        get {
            guard let data = UserDefaults.standard.data(forKey: chordKey) else { return nil }
            return try? JSONDecoder().decode(HotkeyChord.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                UserDefaults.standard.removeObject(forKey: chordKey)
                return
            }
            UserDefaults.standard.set(data, forKey: chordKey)
        }
    }

    static var mode: MicMode {
        get { MicMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .open }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    static let releaseTailRange: ClosedRange<Double> = 0...500

    /// Hold-release grace period before push-to-talk/push-to-mute commits, so a brief gap
    /// between words doesn't clip. ~150 ms default.
    static var releaseTailMs: Double {
        get {
            let stored = UserDefaults.standard.object(forKey: releaseTailKey) as? Double ?? 150
            return min(max(stored, releaseTailRange.lowerBound), releaseTailRange.upperBound)
        }
        set { UserDefaults.standard.set(min(max(newValue, releaseTailRange.lowerBound), releaseTailRange.upperBound), forKey: releaseTailKey) }
    }
}
