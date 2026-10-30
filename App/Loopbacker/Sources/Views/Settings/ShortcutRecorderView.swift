import SwiftUI
import AppKit

/// Click to record, then press a key chord (any key plus at least one modifier) to capture a
/// Carbon-shaped `HotkeyChord`. Escape cancels; a bare key (no modifier) beeps and keeps waiting
/// -- it would otherwise steal every keystroke from every other app.
struct ShortcutRecorderView: View {
    @Binding var chord: HotkeyChord?

    var body: some View {
        HStack(spacing: 6) {
            RecorderField(chord: $chord)
                .frame(width: 150, height: 22)
            if chord != nil {
                Button {
                    chord = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear the hotkey")
                .accessibilityLabel("Clear hotkey")
            }
        }
    }
}

private struct RecorderField: NSViewRepresentable {
    @Binding var chord: HotkeyChord?

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
        view.onCapture = { chord = $0 }
        return view
    }

    func updateNSView(_ view: RecorderNSView, context: Context) {
        view.displayChord = chord
    }
}

private final class RecorderNSView: NSView {
    var onCapture: ((HotkeyChord) -> Void)?
    var displayChord: HotkeyChord? {
        didSet { if displayChord != oldValue { needsDisplay = true } }
    }
    private var isRecording = false {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return }
        if event.keyCode == 53 { // Escape cancels without changing the chord
            isRecording = false
            return
        }
        guard let chord = HotkeyChord(event: event) else {
            NSSound.beep()
            return
        }
        isRecording = false
        onCapture?(chord)
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()

        let text = isRecording ? "Type shortcut…" : (displayChord?.displayString ?? "Click to Record")
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: isRecording ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .font: NSFont.systemFont(ofSize: 12),
        ]
        let size = text.size(withAttributes: attrs)
        let point = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        text.draw(at: point, withAttributes: attrs)
    }
}
