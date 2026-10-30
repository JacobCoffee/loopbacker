import Foundation

/// Main-actor mic state: mute, push-to-talk/push-to-mute hold state, and mode. The audio side
/// is `MicGate.shared`, published lock-free so the IO thread never touches `UserDefaults` or
/// Combine. Drives and is driven by `GlobalHotkeyManager` when a hotkey is configured, and by
/// the menu bar's mute toggle, the Settings › Hotkeys recorder, Shortcuts, and the URL scheme.
@MainActor
final class MicControl: ObservableObject {
    private static let isMutedKey = "MicControl.isMuted"

    @Published private(set) var isMuted: Bool
    /// True only while a push-to-talk/push-to-mute key is physically held — distinct from
    /// `isMuted` so the overlay can show "PTT" vs. a plain mute state.
    @Published private(set) var pushToTalkHeld = false
    /// True unless `refreshHotkeyRegistration()` has determined the hotkey is disabled or has
    /// no chord configured. Defaults true (not yet determined == assume a hotkey may own mute,
    /// matching every call site's actual lifecycle: `refreshHotkeyRegistration()` always runs
    /// at launch before a real hotkey press could ever reach `hotkeyPressed()`). While false,
    /// `toggleMute()` works even in a held mode so manual control (menu bar, Shortcuts, URL
    /// scheme) isn't permanently locked out.
    @Published private(set) var isHotkeyActive = true
    @Published var mode: MicMode {
        didSet {
            guard mode != oldValue else { return }
            MicHotkeySettings.mode = mode
            applyModeChange()
        }
    }

    private var releaseTailTimer: Timer?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let mode = MicHotkeySettings.mode
        self.mode = mode
        switch mode {
        case .open:
            isMuted = defaults.object(forKey: Self.isMutedKey) as? Bool ?? false
        case .pushToTalk:
            isMuted = true // idle: not held
        case .pushToMute:
            isMuted = false // idle: not held
        }
        MicGate.shared.setTarget(muted: isMuted)
    }

    // MARK: - Manual control (menu bar, Shortcuts, URL scheme)

    /// Toggles mute. In `.open` mode, or whenever no hotkey is actively registered (so no
    /// physical key can drive mute), this is the primary control; while a hotkey is active in
    /// a held mode it's a no-op (the hotkey's physical state owns mute while held).
    func toggleMute() {
        guard mode == .open || !isHotkeyActive else { return }
        setMuted(!isMuted)
    }

    func setMuted(_ muted: Bool) {
        guard isMuted != muted else { return }
        isMuted = muted
        MicGate.shared.setTarget(muted: muted)
        if mode == .open { defaults.set(muted, forKey: Self.isMutedKey) }
    }

    // MARK: - Hotkey edges (from `GlobalHotkeyManager`)

    /// Key went down.
    func hotkeyPressed() {
        switch mode {
        case .open:
            toggleMute()
        case .pushToTalk, .pushToMute:
            releaseTailTimer?.invalidate()
            pushToTalkHeld = true
            setMuted(mode == .pushToMute)
        }
    }

    /// Key came back up: after `releaseTailMs` (so a brief gap between words doesn't clip),
    /// reverts to the mode's idle state.
    func hotkeyReleased() {
        guard mode == .pushToTalk || mode == .pushToMute else { return }
        pushToTalkHeld = false
        let tailSeconds = MicHotkeySettings.releaseTailMs / 1000
        releaseTailTimer?.invalidate()
        let targetMode = mode
        releaseTailTimer = Timer.scheduledTimer(withTimeInterval: tailSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.mode == targetMode, !self.pushToTalkHeld else { return }
                self.setMuted(targetMode == .pushToTalk)
            }
        }
    }

    private func applyModeChange() {
        releaseTailTimer?.invalidate()
        pushToTalkHeld = false
        switch mode {
        case .open:
            setMuted(defaults.object(forKey: Self.isMutedKey) as? Bool ?? false)
        case .pushToTalk:
            setMuted(true)
        case .pushToMute:
            setMuted(false)
        }
    }

    // MARK: - Hotkey registration

    /// Wires `GlobalHotkeyManager`'s press/release callbacks to this instance and applies the
    /// persisted chord. Call once at launch and again whenever Settings › Hotkeys changes the
    /// chord, the enabled toggle, or the mode. Replacing or dropping the chord always resets
    /// held/tail state: an old chord's eventual release can no longer reach `hotkeyReleased()`,
    /// so leaving it set could hold PTT "transmitting" (or PTM muted) indefinitely.
    func refreshHotkeyRegistration() {
        GlobalHotkeyManager.shared.onPressed = { [weak self] in self?.hotkeyPressed() }
        GlobalHotkeyManager.shared.onReleased = { [weak self] in self?.hotkeyReleased() }

        releaseTailTimer?.invalidate()
        releaseTailTimer = nil
        pushToTalkHeld = false

        if MicHotkeySettings.isEnabled, let chord = MicHotkeySettings.chord {
            GlobalHotkeyManager.shared.register(chord)
            isHotkeyActive = true
            if mode == .pushToTalk || mode == .pushToMute {
                setMuted(mode == .pushToTalk) // idle state for the (re)registered chord
            }
        } else {
            GlobalHotkeyManager.shared.unregister()
            isHotkeyActive = false
            if mode == .pushToTalk || mode == .pushToMute {
                // No physical key can drive mute anymore: restore effective open-mode manual
                // control instead of leaving the idle mic muted with the menu bar button inert.
                setMuted(false)
            }
        }
    }
}
