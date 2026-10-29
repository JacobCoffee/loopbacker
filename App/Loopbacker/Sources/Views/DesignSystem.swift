import SwiftUI
import AppKit

// Loopbacker's visual system for macOS 26 Liquid Glass.
//
// Text and surfaces use semantic styles (.primary/.secondary, system materials, glass) so light,
// dark, and increased-contrast appearances adapt on their own. Loopbacker green is the single
// accent; it tints interactive glass, live signal, and active cables.

// MARK: - Color

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension Color {
    /// Loopbacker green. Brighter on dark glass, deeper on light glass to hold contrast.
    static let loopbacker = Color(nsColor: NSColor(name: "LoopbackerGreen") { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.10, green: 0.86, blue: 0.68, alpha: 1)
            : NSColor(srgbRed: 0.00, green: 0.55, blue: 0.42, alpha: 1)
    })

    /// Meter zone colors. Green up to -18 dBFS, amber to -6 dBFS, red above.
    static let signalWarm = Color(nsColor: .systemOrange)
    static let signalHot = Color(nsColor: .systemRed)
}

extension ShapeStyle where Self == Color {
    /// Lets `.foregroundStyle(.loopbacker)` and `.fill(.loopbacker)` read like system styles.
    static var loopbacker: Color { Color.loopbacker }
}

// MARK: - Metrics

enum Metrics {
    /// Corner radius of glass panels on the canvas (concentric with the macOS 26 window corner).
    static let panelRadius: CGFloat = 22
    /// Corner radius of rows and controls nested inside a panel.
    static let innerRadius: CGFloat = 12
    /// Padding inside a glass panel.
    static let panelPadding: CGFloat = 14
    /// Space between sibling panels.
    static let panelSpacing: CGFloat = 14
    /// Outer margin of a detail canvas.
    static let canvasMargin: CGFloat = 24
}

// MARK: - Appearance override

/// System / Light / Dark override, persisted under the `appearanceOverride` defaults key.
/// Applied app-wide through `NSApp.appearance` so every window, the menu bar panel, and
/// dynamic colors resolve against the same appearance.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearanceOverride"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    static func applyStored() {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? AppearanceMode.system.rawValue
        (AppearanceMode(rawValue: raw) ?? .system).apply()
    }
}

// MARK: - Glass panel

extension View {
    /// A Liquid Glass panel for content that floats on a canvas. Put sibling panels inside one
    /// `GlassEffectContainer` so their glass blends and morphs together.
    func glassPanel(cornerRadius: CGFloat = Metrics.panelRadius, tint: Color? = nil, interactive: Bool = false) -> some View {
        glassEffect(Glass.regular.tint(tint).interactive(interactive), in: .rect(cornerRadius: cornerRadius))
    }
}

// MARK: - Signal meter

/// Level meter shared by every surface. `level` is the router's normalized value
/// (0 = -60 dBFS, 1 = 0 dBFS). Colors sit at fixed dB positions like a hardware meter:
/// the fill reveals green, then amber past -18 dBFS, then red past -6 dBFS.
struct SignalMeter: View {
    var level: Float
    var axis: Axis = .horizontal
    var thickness: CGFloat = 6

    private var clamped: CGFloat { CGFloat(min(max(level, 0), 1)) }

    private var gradient: Gradient {
        Gradient(stops: [
            .init(color: .loopbacker, location: 0),
            .init(color: .loopbacker, location: 0.68),
            .init(color: .signalWarm, location: 0.80),
            .init(color: .signalWarm, location: 0.88),
            .init(color: .signalHot, location: 0.95),
        ])
    }

    // A Canvas redraws without touching layout. The previous mask-and-frame meter re-laid out the
    // window on every level change, and its 80 ms level animation kept that going at the display
    // rate. Meter ballistics (decay) already happen in the router.
    var body: some View {
        let horizontal = axis == .horizontal
        Canvas { context, size in
            context.fill(Capsule().path(in: CGRect(origin: .zero, size: size)), with: .style(.quaternary))
            let length = horizontal ? size.width : size.height
            let filled = max(clamped * length, clamped > 0 ? thickness : 0)
            guard filled > 0 else { return }
            let fill = horizontal
                ? CGRect(x: 0, y: 0, width: filled, height: size.height)
                : CGRect(x: 0, y: size.height - filled, width: size.width, height: filled)
            context.fill(Capsule().path(in: fill),
                         with: .linearGradient(gradient,
                                               startPoint: horizontal ? .zero : CGPoint(x: 0, y: size.height),
                                               endPoint: horizontal ? CGPoint(x: size.width, y: 0) : .zero))
        }
        .frame(width: horizontal ? nil : thickness, height: horizontal ? thickness : nil)
        .accessibilityElement()
        .accessibilityLabel("Level")
        .accessibilityValue(Self.dbString(level))
    }

    /// "-12 dB" style readout for a normalized level; "Silent" at the floor.
    static func dbString(_ level: Float) -> String {
        guard level > 0.001 else { return "Silent" }
        return "\(Int((Double(level) * 60 - 60).rounded())) dB"
    }

    /// Map a linear peak (0…1 amplitude) to the meter's normalized dB scale.
    static func normalized(linearPeak: Float) -> Float {
        guard linearPeak > 0.001 else { return 0 }
        return min(max((20 * log10f(linearPeak) + 60) / 60, 0), 1)
    }
}

/// A source's loudest channel, read live from `MeterLevels`. Keep this a leaf: it is the only
/// view that re-renders at meter rate in a row.
struct SourcePeakMeter: View {
    @Environment(MeterLevels.self) private var meters
    /// Route key (`AudioSource.deviceUID`, or "output:<virtual device UID>").
    let key: String
    let isLive: Bool
    var thickness: CGFloat = 4

    var body: some View {
        let level = isLive ? meters.peak(source: key) : 0
        SignalMeter(level: level, thickness: thickness)
            .opacity(isLive ? 1 : 0.5)
            .accessibilityValue(isLive ? SignalMeter.dbString(level) : "Off")
    }
}

// MARK: - Status tag

/// Small capsule naming a state that needs attention: Muted, Unavailable, Not Running.
struct StatusTag: View {
    let title: String
    var tint: Color = .secondary
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(title)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.14), in: Capsule())
        .fixedSize()
    }
}

// MARK: - Live indicator

/// Status dot. When `isLive`, a soft halo breathes so "audio is flowing" reads at a glance.
struct LiveDot: View {
    var color: Color
    var isLive: Bool = false
    var size: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .background {
                if isLive {
                    if reduceMotion {
                        Circle().fill(color.opacity(0.35)).scaleEffect(1.4)
                    } else {
                        LoopingDot(color: color.opacity(0.35), diameter: size, loop: .breathe)
                    }
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Looping dot

/// A dot looped by Core Animation. A repeating SwiftUI animation re-runs the view graph and the
/// window's layout every display frame; a CAAnimation runs in the render server and leaves the
/// main thread idle, on screen or not.
struct LoopingDot: NSViewRepresentable {
    enum Loop {
        /// Centered; grows from 1.4× to 2.2× while fading out, every 1.6 s.
        case breathe
        /// Falls from the top edge to the bottom edge while fading out, every 0.6 s.
        case fall
    }

    var color: Color
    var diameter: CGFloat
    var loop: Loop

    func makeNSView(context: Context) -> LoopingDotView { LoopingDotView(loop: loop) }

    func updateNSView(_ view: LoopingDotView, context: Context) {
        view.color = color
        view.diameter = diameter
    }
}

final class LoopingDotView: NSView {
    private let dot = CALayer()
    private let loop: LoopingDot.Loop
    private var animatedSize: CGSize?

    var color: Color = .clear {
        didSet { if color != oldValue { applyColor() } }
    }
    var diameter: CGFloat = 4 {
        didSet { if diameter != oldValue { needsLayout = true } }
    }

    init(loop: LoopingDot.Loop) {
        self.loop = loop
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(dot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        dot.cornerRadius = diameter / 2
        dot.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
        // The fall's endpoints depend on the bounds; restarting on every layout would reset the phase.
        if bounds.size != animatedSize { restart() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restart()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    private func applyColor() {
        var resolved: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance { resolved = NSColor(color).cgColor }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.backgroundColor = resolved
        CATransaction.commit()
    }

    private func restart() {
        dot.removeAllAnimations()
        animatedSize = nil
        guard window != nil else { return }
        animatedSize = bounds.size

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        let move: CABasicAnimation
        let group = CAAnimationGroup()
        switch loop {
        case .breathe:
            move = CABasicAnimation(keyPath: "transform.scale")
            move.fromValue = 1.4
            move.toValue = 2.2
            group.duration = 1.6
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        case .fall:
            // Unflipped layer coordinates: maxY is the top edge.
            move = CABasicAnimation(keyPath: "position.y")
            move.fromValue = bounds.maxY
            move.toValue = bounds.minY
            group.duration = 0.6
            group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        }
        group.animations = [move, fade]
        group.repeatCount = .infinity
        dot.add(group, forKey: "loop")
    }
}

// MARK: - Empty state

/// Native-feeling empty state for a canvas or list.
struct EmptyStateView<Actions: View>: View {
    let title: String
    let message: String
    let symbol: String
    @ViewBuilder var actions: Actions

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            actions
        }
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(title: String, message: String, symbol: String) {
        self.init(title: title, message: message, symbol: symbol) { EmptyView() }
    }
}
