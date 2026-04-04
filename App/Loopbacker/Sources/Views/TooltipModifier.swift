import SwiftUI
import AppKit

struct Tooltip: ViewModifier {
    let text: String
    @State private var hoverTask: Task<Void, Never>?
    @State private var tipWindow: NSWindow?

    func body(content: Content) -> some View {
        content
            .onHover { over in
                if over {
                    hoverTask?.cancel()
                    hoverTask = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        await MainActor.run { show() }
                    }
                } else {
                    hoverTask?.cancel()
                    hoverTask = nil
                    hide()
                }
            }
            .onDisappear { hide() }
    }

    private func show() {
        guard tipWindow == nil, !text.isEmpty else { return }

        let view = NSHostingView(rootView:
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: NSColor(red: 0.14, green: 0.14, blue: 0.22, alpha: 0.95))))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                .fixedSize()
        )
        view.setFrameSize(view.fittingSize)
        let size = view.fittingSize

        let mouse = NSEvent.mouseLocation
        // Center horizontally on cursor, place above cursor
        var x = mouse.x - size.width / 2
        var y = mouse.y + 18

        // Keep on screen
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })?.visibleFrame {
            x = max(screen.minX + 2, min(x, screen.maxX - size.width - 2))
            y = max(screen.minY + 2, min(y, screen.maxY - size.height - 2))
        }

        let w = NSWindow(contentRect: NSRect(x: x, y: y, width: size.width, height: size.height),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .statusBar
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.contentView = view
        w.alphaValue = 0
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.1; w.animator().alphaValue = 1 }
        tipWindow = w
    }

    private func hide() {
        guard let w = tipWindow else { return }
        tipWindow = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.06; w.animator().alphaValue = 0 }) { w.orderOut(nil) }
    }
}

extension View {
    func tooltip(_ text: String) -> some View { modifier(Tooltip(text: text)) }
}
