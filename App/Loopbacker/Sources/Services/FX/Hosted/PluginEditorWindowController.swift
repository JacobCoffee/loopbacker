import AppKit

extension Notification.Name {
    /// Posted with `object` = the `any FXHostedNode` whose editor window just closed, so the
    /// engine can capture its state while it's still loaded.
    static let fxPluginEditorClosed = Notification.Name("FXPluginEditorClosed")
}

/// One utility window per hosted node showing that plugin's own editor (`FXHostedNode.makeEditor()`).
/// Generic across AU/JSFX/Airwindows: works for anything that can hand back an `NSViewController`.
@MainActor
enum PluginEditorWindowController {
    private final class Owner: NSObject, NSWindowDelegate {
        let node: any FXHostedNode
        init(node: any FXHostedNode) { self.node = node }

        func windowWillClose(_ notification: Notification) {
            let id = ObjectIdentifier(node)
            windows.removeValue(forKey: id)
            owners.removeValue(forKey: id)
            NotificationCenter.default.post(name: .fxPluginEditorClosed, object: node)
        }
    }

    private static var windows: [ObjectIdentifier: NSWindow] = [:]
    private static var owners: [ObjectIdentifier: Owner] = [:]

    /// Opens a node's editor, or brings its already-open window forward. No-op if the node has
    /// no editor view controller.
    static func show(for node: any FXHostedNode, title: String) async {
        let id = ObjectIdentifier(node)
        if let window = windows[id] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let viewController = await node.makeEditor() else { return }

        // A plugin that declares a `preferredContentSize` is asking for that exact canvas, so
        // the window isn't resizable; one that doesn't gets a window sized to fit and free to
        // grow.
        let declaresSize = viewController.preferredContentSize != .zero
        let contentSize = declaresSize ? viewController.preferredContentSize : viewController.view.fittingSize
        var styleMask: NSWindow.StyleMask = [.titled, .closable, .utilityWindow]
        if !declaresSize { styleMask.insert(.resizable) }

        let window = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentViewController = viewController
        window.setContentSize(contentSize)
        window.center()

        let owner = Owner(node: node)
        window.delegate = owner
        owners[id] = owner
        windows[id] = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closes a node's editor window, if open. Triggers the same `.fxPluginEditorClosed`
    /// notification as the user closing it themselves.
    static func close(for node: any FXHostedNode) {
        windows[ObjectIdentifier(node)]?.close()
    }
}
