import AppKit
import Observation

/// Whether any window that shows meters (main window, menu bar panel) is currently on screen.
///
/// The single source of truth for "is it worth doing live-level work right now": `AudioRouter`
/// gates publishing `MeterLevels` on it (closing the main window only hides it -- SwiftUI keeps
/// its view graph alive, and the router would otherwise keep draining and republishing levels
/// nobody sees), and any UI that polls a level directly (rather than observing `MeterLevels`)
/// should stop polling on the same signal instead of inventing its own. The menu bar icon's own
/// window always reports visible, so it's excluded.
@MainActor
@Observable
final class MeterWindowVisibility {
    static let shared = MeterWindowVisibility()

    private(set) var isVisible: Bool

    private init() {
        isVisible = Self.compute()
        // `.didChangeOcclusionState` fires for ordering, miniaturize/deminiaturize, Spaces/
        // Mission Control, and app hide/unhide -- every case that can make every window
        // invisible at once, which is the only thing `isVisible` needs to track.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isVisible = Self.compute() }
        }
    }

    static func compute() -> Bool {
        NSApp.windows.contains {
            $0.isVisible && $0.occlusionState.contains(.visible) && $0.className != "NSStatusBarWindow"
        }
    }
}
