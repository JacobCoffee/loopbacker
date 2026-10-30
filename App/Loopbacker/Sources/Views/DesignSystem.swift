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

// MARK: - Snapshot rendering (offscreen test/preview support)

private struct SnapshotRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True only inside offscreen render tests/previews. `.glassEffect`/`GlassEffectContainer`
    /// render blank without a live window-server compositor (confirmed empirically: an
    /// `ImageRenderer` or windowless `NSHostingView` snapshot of any Liquid Glass view is a
    /// blank rect), so every call through `glassPanel`/`glassMaterial` swaps the real material
    /// for a flat, opaque approximation of it while this is true. Layout (corner radius,
    /// padding, the tint opacity a real tint would carry) never changes — only the material.
    var snapshotRendering: Bool {
        get { self[SnapshotRenderingKey.self] }
        set { self[SnapshotRenderingKey.self] = newValue }
    }
}

// MARK: - Glass panel

private struct GlassMaterialModifier<S: Shape>: ViewModifier {
    @Environment(\.snapshotRendering) private var snapshotRendering
    @Environment(\.colorScheme) private var colorScheme
    let shape: S
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        if snapshotRendering {
            // `Color(nsColor: .windowBackgroundColor)` is a dynamic `NSColor` provider that
            // resolves against the "current drawing appearance" — a real window's `drawRect`
            // sets that automatically, but an offscreen `ImageRenderer`/`CGContext` draw never
            // does, so it always renders its light variant regardless of `.preferredColorScheme`
            // (confirmed empirically). `colorScheme` itself, read from the environment like any
            // other SwiftUI value, isn't affected by that and reliably tracks the render target,
            // so the flat-fill base is driven from it directly instead of going through AppKit.
            let base = colorScheme == .dark ? Color(white: 0.16) : Color(white: 0.95)
            content.background {
                ZStack {
                    shape.fill(base)
                    shape.fill(.quaternary)
                    if let tint { shape.fill(tint) }
                }
            }
        } else {
            content.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        }
    }
}

extension View {
    /// The Liquid Glass material for an arbitrary shape (e.g. a capsule terminal tile), with the
    /// same offscreen-safe fallback as `glassPanel`. Every `.glassEffect` call in the Effects UI
    /// routes through this (or `glassPanel`) instead of calling it directly.
    func glassMaterial<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassMaterialModifier(shape: shape, tint: tint, interactive: interactive))
    }

    /// A Liquid Glass panel for content that floats on a canvas. Put sibling panels inside one
    /// `GlassEffectContainer` so their glass blends and morphs together.
    func glassPanel(cornerRadius: CGFloat = Metrics.panelRadius, tint: Color? = nil, interactive: Bool = false) -> some View {
        glassMaterial(RoundedRectangle(cornerRadius: cornerRadius), tint: tint, interactive: interactive)
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

    // Core Animation layers rather than SwiftUI drawing: a level change only resizes a mask
    // layer, which the render server composites. A SwiftUI Canvas or shape re-rasterized the
    // meter on the main thread on every 30 Hz tick, and a frame-based mask re-laid out the window.
    // Meter ballistics (decay) already happen in the router.
    var body: some View {
        let horizontal = axis == .horizontal
        MeterBar(level: clamped, horizontal: horizontal, minimumFill: thickness)
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

/// A meter that follows `MeterLevels` by itself. `read` returns the current level; the meter
/// observes whatever it reads and redraws its layers on change, so a 30 Hz meter tick never
/// touches SwiftUI: no body evaluation, no layout pass, no re-rasterization. Driving the meter
/// through SwiftUI cost ~16% of a core with the Routing page's meters moving.
struct LiveSignalMeter: View {
    var thickness: CGFloat = 6
    let read: @MainActor () -> Float

    var body: some View {
        MeterBar(level: 0, horizontal: true, minimumFill: thickness, read: read)
            .frame(height: thickness)
    }
}

/// The meter's layers: a quaternary capsule track and a full-length zone gradient, masked to the
/// filled length. Driven either by `level` or, when set, by observing `read`.
private struct MeterBar: NSViewRepresentable {
    var level: CGFloat
    var horizontal: Bool
    var minimumFill: CGFloat
    var read: (@MainActor () -> Float)? = nil

    func makeNSView(context: Context) -> MeterBarView { MeterBarView() }

    func updateNSView(_ view: MeterBarView, context: Context) {
        view.update(level: level, horizontal: horizontal, minimumFill: minimumFill)
        view.observe(read)
    }
}

private final class MeterBarView: NSView {
    private let track = CALayer()
    private let fill = CAGradientLayer()
    private let fillMask = CALayer()
    private var level: CGFloat = 0
    private var horizontal = true
    private var minimumFill: CGFloat = 0
    private var read: (@MainActor () -> Float)?
    private var generation = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        fill.locations = [0, 0.68, 0.80, 0.88, 0.95]
        fillMask.backgroundColor = CGColor(gray: 0, alpha: 1)
        fill.mask = fillMask
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .levelIndicator }
    override func accessibilityLabel() -> String? { "Level" }
    override func accessibilityValue() -> Any? { SignalMeter.dbString(Float(level)) }

    func update(level: CGFloat, horizontal: Bool, minimumFill: CGFloat) {
        let reshape = horizontal != self.horizontal || minimumFill != self.minimumFill
        self.horizontal = horizontal
        self.minimumFill = minimumFill
        if read == nil { setLevel(level) }
        if reshape { needsLayout = true }
    }

    /// Starts following `read` (or stops, for nil). Each call starts a new observation chain
    /// and retires the previous one, so repeated SwiftUI updates never stack up refreshes.
    func observe(_ read: (@MainActor () -> Float)?) {
        self.read = read
        generation &+= 1
        let current = generation
        // Not inline: this runs inside SwiftUI's update, which would also record the level
        // read and re-run the update on every change, the cost this view exists to avoid.
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.refresh(current) } }
    }

    private func refresh(_ chain: Int) {
        guard chain == generation, let read else { return }
        let value = withObservationTracking { read() } onChange: { [weak self] in
            // Called as the level is about to change; read it once the write has landed.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh(chain) } }
        }
        setLevel(CGFloat(min(max(value, 0), 1)))
    }

    private func setLevel(_ level: CGFloat) {
        guard level != self.level else { return }
        self.level = level
        applyLevel()
    }

    override func layout() {
        super.layout()
        withoutAnimation {
            let radius = min(bounds.width, bounds.height) / 2
            track.frame = bounds
            track.cornerRadius = radius
            fill.frame = bounds
            fillMask.cornerRadius = radius
            // Unflipped layer coordinates: a vertical meter fills from the bottom up.
            fill.startPoint = horizontal ? CGPoint(x: 0, y: 0.5) : CGPoint(x: 0.5, y: 0)
            fill.endPoint = horizontal ? CGPoint(x: 1, y: 0.5) : CGPoint(x: 0.5, y: 1)
        }
        applyLevel()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyLevel() {
        let length = horizontal ? bounds.width : bounds.height
        let filled = level > 0 ? min(max(level * length, minimumFill), length) : 0
        withoutAnimation {
            fillMask.frame = horizontal
                ? CGRect(x: 0, y: 0, width: filled, height: bounds.height)
                : CGRect(x: 0, y: 0, width: bounds.width, height: filled)
        }
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let green = NSColor(Color.loopbacker).cgColor
            let warm = NSColor(Color.signalWarm).cgColor
            let hot = NSColor(Color.signalHot).cgColor
            withoutAnimation {
                track.backgroundColor = NSColor.quaternaryLabelColor.cgColor
                fill.colors = [green, green, warm, warm, hot]
            }
        }
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

/// A source's loudest channel, read live from `MeterLevels`.
struct SourcePeakMeter: View {
    @Environment(MeterLevels.self) private var meters
    /// Route key (`AudioSource.deviceUID`, or "output:<virtual device UID>").
    let key: String
    let isLive: Bool
    var thickness: CGFloat = 4

    var body: some View {
        LiveSignalMeter(thickness: thickness) { [meters, key, isLive] in
            isLive ? meters.peak(source: key) : 0
        }
        .opacity(isLive ? 1 : 0.5)
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
