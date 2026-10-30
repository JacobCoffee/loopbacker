import AppKit
import CYSFX

/// Renders a JSFX effect's `@gfx` block into a bitmap, ~30 fps, with mouse/keyboard/scroll
/// forwarded to ysfx. All `ysfx_gfx_*` calls happen on the main thread, as required by ysfx
/// (`include/ysfx.h`: "all ysfx_gfx_* functions must be invoked from a dedicated UI thread").
final class JSFXEditorViewController: NSViewController {
    private let node: JSFXNode
    private var gfxView: JSFXGraphicsView { view as! JSFXGraphicsView }

    init(node: JSFXNode) {
        self.node = node
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unavailable") }

    override func loadView() {
        view = JSFXGraphicsView(node: node)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        gfxView.startRunning()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        gfxView.stopRunning()
    }
}

/// The actual gfx surface. Owns the pixel buffer ysfx paints into and a `CVDisplayLink`-free
/// `Timer` driving `ysfx_gfx_run` at the script's requested rate (clamped to ~30 fps, per the
/// host contract — JSFX UIs are not expected to run faster than that).
private final class JSFXGraphicsView: NSView {
    private let node: JSFXNode
    private var timer: Timer?
    private nonisolated(unsafe) var pixels: UnsafeMutablePointer<UInt8>?
    private var pixelCapacity = 0
    private var bufferWidth = 0
    private var bufferHeight = 0
    private var scaleFactor: CGFloat = 1

    /// Boxed so the C callback trampolines (which only get a raw `void*`) can reach back into
    /// this view without ARC games across the C boundary.
    private var selfBox: Unmanaged<JSFXGraphicsView>?

    init(node: JSFXNode) {
        self.node = node
        let size = NSSize(width: node.gfxWidth, height: node.gfxHeight)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        selfBox = Unmanaged.passUnretained(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unavailable") }

    deinit {
        pixels?.deallocate()
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    func startRunning() {
        stopRunning()
        window?.makeFirstResponder(self)
        let fps = max(1, min(30, Int(ysfx_get_requested_framerate(node.ysfxHandle))))
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / Double(fps), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stopRunning() {
        timer?.invalidate()
        timer = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    // MARK: - Rendering

    private func tick() {
        guard window != nil else { return }
        let backingScale = window?.backingScaleFactor ?? 1
        let wantsRetina = ysfx_gfx_wants_retina(node.ysfxHandle)
        let scale = wantsRetina ? backingScale : 1
        let width = max(1, Int(bounds.width * scale))
        let height = max(1, Int(bounds.height * scale))
        ensureBuffer(width: width, height: height, scale: scale)

        guard let pixels else { return }
        let stride = width * 4
        var config = ysfx_gfx_config_t()
        config.user_data = selfBox.map { UnsafeMutableRawPointer($0.toOpaque()) }
        config.pixel_width = UInt32(width)
        config.pixel_height = UInt32(height)
        config.pixel_stride = UInt32(stride)
        config.pixels = pixels
        config.scale_factor = ysfx_real(scale)
        config.show_menu = { userData, spec, x, y in JSFXGraphicsView.showMenu(userData, spec, x, y) }
        config.set_cursor = { userData, cursorID in JSFXGraphicsView.setCursor(userData, cursorID) }
        config.get_drop_file = { userData, index in JSFXGraphicsView.dropFile(userData, index) }

        ysfx_gfx_setup(node.ysfxHandle, &config)
        ysfx_gfx_set_window_state(node.ysfxHandle, window?.isKeyWindow ?? false, true, isMouseInside)
        let dirty = ysfx_gfx_run(node.ysfxHandle)
        if dirty { needsDisplay = true }
    }

    private func ensureBuffer(width: Int, height: Int, scale: CGFloat) {
        guard width != bufferWidth || height != bufferHeight else { return }
        let needed = width * height * 4
        if needed > pixelCapacity {
            pixels?.deallocate()
            pixels = .allocate(capacity: needed)
            pixelCapacity = needed
        }
        pixels?.update(repeating: 0, count: needed)
        bufferWidth = width
        bufferHeight = height
        scaleFactor = scale
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let pixels, bufferWidth > 0, bufferHeight > 0,
              let context = NSGraphicsContext.current?.cgContext
        else { return }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let dataProvider = CGDataProvider(
            dataInfo: nil, data: pixels, size: bufferWidth * bufferHeight * 4, releaseData: { _, _, _ in }
        ), let image = CGImage(
            width: bufferWidth, height: bufferHeight, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bufferWidth * 4, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: dataProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ) else { return }

        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(image, in: NSRect(origin: .zero, size: bounds.size))
        context.restoreGState()
    }

    // MARK: - Input forwarding

    private var isMouseInside = false

    private func ysfxPoint(for event: NSEvent) -> (x: Int32, y: Int32) {
        let local = convert(event.locationInWindow, from: nil)
        let scale = ysfx_gfx_wants_retina(node.ysfxHandle) ? (window?.backingScaleFactor ?? 1) : 1
        return (Int32(local.x * scale), Int32(local.y * scale))
    }

    private func ysfxModifiers(for event: NSEvent) -> UInt32 {
        var mods: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.shift) { mods |= UInt32(ysfx_mod_shift) }
        if flags.contains(.control) { mods |= UInt32(ysfx_mod_ctrl) }
        if flags.contains(.option) { mods |= UInt32(ysfx_mod_alt) }
        if flags.contains(.command) { mods |= UInt32(ysfx_mod_super) }
        return mods
    }

    private func sendMouse(_ event: NSEvent, buttons: UInt32, wheel: CGFloat = 0, hwheel: CGFloat = 0) {
        let (x, y) = ysfxPoint(for: event)
        ysfx_gfx_update_mouse(
            node.ysfxHandle, ysfxModifiers(for: event), x, y, buttons, ysfx_real(wheel), ysfx_real(hwheel)
        )
    }

    private var currentButtons: UInt32 = 0

    override func mouseDown(with event: NSEvent) {
        currentButtons |= UInt32(ysfx_button_left)
        sendMouse(event, buttons: currentButtons)
    }

    override func mouseUp(with event: NSEvent) {
        currentButtons &= ~UInt32(ysfx_button_left)
        sendMouse(event, buttons: currentButtons)
    }

    override func rightMouseDown(with event: NSEvent) {
        currentButtons |= UInt32(ysfx_button_right)
        sendMouse(event, buttons: currentButtons)
    }

    override func rightMouseUp(with event: NSEvent) {
        currentButtons &= ~UInt32(ysfx_button_right)
        sendMouse(event, buttons: currentButtons)
    }

    override func otherMouseDown(with event: NSEvent) {
        currentButtons |= UInt32(ysfx_button_middle)
        sendMouse(event, buttons: currentButtons)
    }

    override func otherMouseUp(with event: NSEvent) {
        currentButtons &= ~UInt32(ysfx_button_middle)
        sendMouse(event, buttons: currentButtons)
    }

    override func mouseDragged(with event: NSEvent) { sendMouse(event, buttons: currentButtons) }
    override func rightMouseDragged(with event: NSEvent) { sendMouse(event, buttons: currentButtons) }
    override func otherMouseDragged(with event: NSEvent) { sendMouse(event, buttons: currentButtons) }
    override func mouseMoved(with event: NSEvent) { sendMouse(event, buttons: currentButtons) }

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        sendMouse(event, buttons: currentButtons)
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        sendMouse(event, buttons: currentButtons)
    }

    override func scrollWheel(with event: NSEvent) {
        sendMouse(event, buttons: currentButtons, wheel: event.scrollingDeltaY, hwheel: event.scrollingDeltaX)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func keyDown(with event: NSEvent) {
        guard let key = translateKey(event) else { return }
        ysfx_gfx_add_key(node.ysfxHandle, ysfxModifiers(for: event), key, true)
    }

    override func keyUp(with event: NSEvent) {
        guard let key = translateKey(event) else { return }
        ysfx_gfx_add_key(node.ysfxHandle, ysfxModifiers(for: event), key, false)
    }

    /// Maps an `NSEvent`'s key to the pugl-style codes `ysfx_gfx_add_key` expects
    /// (`include/ysfx.h`'s "YSFX key map").
    private func translateKey(_ event: NSEvent) -> UInt32? {
        if let special = JSFXGraphicsView.specialKeys[event.keyCode] { return special }
        guard let chars = event.characters, let scalar = chars.unicodeScalars.first else { return nil }
        return scalar.value
    }

    private static let specialKeys: [UInt16: UInt32] = [
        51: UInt32(ysfx_key_backspace), 53: UInt32(ysfx_key_escape), 117: UInt32(ysfx_key_delete),
        122: UInt32(ysfx_key_f1), 120: UInt32(ysfx_key_f2), 99: UInt32(ysfx_key_f3),
        118: UInt32(ysfx_key_f4), 96: UInt32(ysfx_key_f5), 97: UInt32(ysfx_key_f6),
        98: UInt32(ysfx_key_f7), 100: UInt32(ysfx_key_f8), 101: UInt32(ysfx_key_f9),
        109: UInt32(ysfx_key_f10), 103: UInt32(ysfx_key_f11), 111: UInt32(ysfx_key_f12),
        123: UInt32(ysfx_key_left), 126: UInt32(ysfx_key_up), 124: UInt32(ysfx_key_right),
        125: UInt32(ysfx_key_down), 116: UInt32(ysfx_key_page_up), 121: UInt32(ysfx_key_page_down),
        115: UInt32(ysfx_key_home), 119: UInt32(ysfx_key_end)
    ]

    // MARK: - gfx callbacks (ysfx_gfx_config_t function pointers, main thread only)

    private static func showMenu(
        _ userData: UnsafeMutableRawPointer?, _ spec: UnsafePointer<CChar>?, _ x: Int32, _ y: Int32
    ) -> Int32 {
        guard let userData, let spec else { return 0 }
        let view = Unmanaged<JSFXGraphicsView>.fromOpaque(userData).takeUnretainedValue()
        return view.runPopupMenu(spec: String(cString: spec), x: Int(x), y: Int(y))
    }

    private static func setCursor(_ userData: UnsafeMutableRawPointer?, _ cursorID: Int32) {
        // JSFX's built-in cursor IDs don't map cleanly to AppKit cursors; the default arrow is
        // close enough for the effects this host targets, so this is a deliberate no-op.
    }

    private static func dropFile(
        _ userData: UnsafeMutableRawPointer?, _ index: Int32
    ) -> UnsafePointer<CChar>? {
        // Drag-and-drop file targets aren't wired into Loopbacker's generic hosted-editor
        // window, so there are never any dropped files to report.
        nil
    }

    /// `menu_spec` is `#`-separated `label` (or `label|` for a checked/disabled item encoded by
    /// JSFX's own gfx_showmenu convention: a leading `#` disables, leading `!` checks).
    private func runPopupMenu(spec: String, x: Int, y: Int) -> Int32 {
        let menu = NSMenu()
        var itemID: Int32 = 0
        for rawItem in spec.split(separator: "|", omittingEmptySubsequences: false) {
            itemID += 1
            var title = String(rawItem)
            if title.isEmpty { menu.addItem(.separator()); continue }
            var enabled = true
            var checked = false
            while let first = title.first, first == "#" || first == "!" || first == ">" || first == "<" {
                if first == "#" { enabled = false }
                if first == "!" { checked = true }
                title.removeFirst()
            }
            let item = NSMenuItem(title: title, action: #selector(menuItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            item.state = checked ? .on : .off
            item.tag = Int(itemID)
            menu.addItem(item)
        }
        selectedMenuItem = 0
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: y), in: self)
        return selectedMenuItem
    }

    private var selectedMenuItem: Int32 = 0

    @objc private func menuItemSelected(_ sender: NSMenuItem) {
        selectedMenuItem = Int32(sender.tag)
    }
}
