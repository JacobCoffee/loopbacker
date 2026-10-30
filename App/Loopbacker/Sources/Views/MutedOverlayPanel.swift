import SwiftUI
import Combine
import AppKit

/// Persisted muted-overlay preferences, set from Settings › General.
enum MutedOverlaySettings {
    private static let enabledKey = "MutedOverlay.isEnabled"
    private static let cornerKey = "MutedOverlay.corner"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var corner: MutedOverlayCorner {
        get { MutedOverlayCorner(rawValue: UserDefaults.standard.string(forKey: cornerKey) ?? "") ?? .bottomTrailing }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: cornerKey) }
    }
}

/// A tiny non-activating `NSPanel` showing "Muted"/"PTT" above everything, including full-screen
/// apps, on every Space, click-through so it never steals a click meant for the app underneath.
/// Follows `MicControl`'s published mute/hold state; owned by the app for its lifetime so it
/// tracks mute state even while the main window is closed.
@MainActor
final class MutedOverlayController {
    static let shared = MutedOverlayController()

    private var panel: NSPanel?
    private var cancellables: Set<AnyCancellable> = []
    private weak var micControl: MicControl?
    private var noticeRevertWorkItem: DispatchWorkItem?

    private init() {}

    /// Starts following `micControl`. Call once at launch.
    func start(micControl: MicControl) {
        self.micControl = micControl
        micControl.$isMuted
            .combineLatest(micControl.$pushToTalkHeld)
            .sink { [weak self] isMuted, held in
                self?.refresh(isMuted: isMuted, pushToTalkHeld: held)
            }
            .store(in: &cancellables)
    }

    /// Re-applies the current state and settings (e.g. after Settings › General toggles the
    /// overlay or moves its corner).
    func refreshFromSettings(micControl: MicControl) {
        refresh(isMuted: micControl.isMuted, pushToTalkHeld: micControl.pushToTalkHeld)
    }

    /// Shows a brief transparency notice (e.g. "Mic unmuted by URL command") in place of the
    /// mute/PTT badge, then reverts to tracking live mute state after a few seconds
    /// (LB-URL-001). Shown regardless of `MutedOverlaySettings.isEnabled`: the persistent badge
    /// is opt-out, but this one-time notice about an action another app took on the user's
    /// behalf isn't the same feature. No-op if `start(micControl:)` hasn't run yet.
    func showNotice(_ message: String) {
        guard let micControl else { return }
        noticeRevertWorkItem?.cancel()
        show(state: .notice(message: message))
        let workItem = DispatchWorkItem { [weak self] in
            self?.refresh(isMuted: micControl.isMuted, pushToTalkHeld: micControl.pushToTalkHeld)
        }
        noticeRevertWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }

    private func refresh(isMuted: Bool, pushToTalkHeld: Bool) {
        guard MutedOverlaySettings.isEnabled else {
            panel?.orderOut(nil)
            return
        }
        let state: MutedOverlayView.State
        if pushToTalkHeld && !isMuted {
            state = .pushToTalkLive
        } else if isMuted {
            state = .muted
        } else {
            panel?.orderOut(nil)
            return
        }
        show(state: state)
    }

    private func show(state: MutedOverlayView.State) {
        let panel = panel ?? makePanel()
        self.panel = panel
        guard let hosting = panel.contentView as? NSHostingView<MutedOverlayView> else { return }
        hosting.rootView = MutedOverlayView(state: state)
        position(panel)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingView(rootView: MutedOverlayView(state: .muted))
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        // Above full-screen apps on every Space; .stationary keeps it put across Space switches
        // rather than following the active Space's window like a normal document window would.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.level = .statusBar
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let size = panel.contentView?.fittingSize ?? CGSize(width: 90, height: 32)
        let origin = MutedOverlaySettings.corner.origin(screenFrame: screen.visibleFrame, size: size)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }
}
