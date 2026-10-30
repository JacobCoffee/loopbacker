import AppKit
import Carbon.HIToolbox
import os.log

private let hotkeyLogger = Logger(subsystem: "com.jacobcoffee.loopbacker", category: "GlobalHotkey")

/// One global hotkey via Carbon's `RegisterEventHotKey`/`InstallEventHandler`: no Accessibility
/// permission needed (unlike an `NSEvent` global monitor or a CGEvent tap), and unlike an
/// `NSEvent` monitor it reports both press *and* release, which push-to-talk needs to know when
/// the key comes back up. Main-actor: registration touches shared HIToolbox state.
@MainActor
final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    /// 'LBMH' as a four-char code, this app's hotkey signature.
    private static let signature: OSType = 0x4C424D48
    private let hotKeyID = EventHotKeyID(signature: GlobalHotkeyManager.signature, id: 1)

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// Called on `kEventHotKeyPressed`.
    var onPressed: (() -> Void)?
    /// Called on `kEventHotKeyReleased`.
    var onReleased: (() -> Void)?

    private init() {}

    /// Registers `chord` as the live global hotkey, replacing any previous one.
    func register(_ chord: HotkeyChord) {
        unregister()
        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            chord.keyCode, chord.modifiers, hotKeyID,
            GetEventDispatcherTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            hotkeyLogger.error("RegisterEventHotKey failed: \(status)")
            return
        }
        hotKeyRef = ref
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetEventDispatcherTarget(), globalHotkeyEventHandler, eventTypes.count, &eventTypes, selfPtr, &eventHandler
        )
        if status != noErr {
            hotkeyLogger.error("InstallEventHandler failed: \(status)")
        }
    }

    /// Dispatches a received hotkey event kind to the matching callback, once the caller has
    /// confirmed `receivedID` is ours. Called from the top-level C handler.
    fileprivate func handle(receivedID: EventHotKeyID, kind: UInt32) {
        guard receivedID.id == hotKeyID.id, receivedID.signature == hotKeyID.signature else { return }
        if kind == UInt32(kEventHotKeyPressed) {
            onPressed?()
        } else if kind == UInt32(kEventHotKeyReleased) {
            onReleased?()
        }
    }

    isolated deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}

/// Carbon event handlers are C function pointers (`EventHandlerUPP`) and can't capture state,
/// so `self` travels through `inUserData` the way `AudioRouter`'s render callbacks do.
private func globalHotkeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return noErr }
    let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()

    var receivedID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &receivedID
    )
    guard status == noErr else { return status }

    let kind = GetEventKind(event)
    MainActor.assumeIsolated { manager.handle(receivedID: receivedID, kind: kind) }
    return noErr
}
