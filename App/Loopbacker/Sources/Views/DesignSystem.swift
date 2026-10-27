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

    var body: some View {
        GeometryReader { geo in
            let horizontal = axis == .horizontal
            let length = horizontal ? geo.size.width : geo.size.height
            let filled = max(clamped * length, clamped > 0 ? thickness : 0)
            ZStack(alignment: horizontal ? .leading : .bottom) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(gradient: gradient,
                                         startPoint: horizontal ? .leading : .bottom,
                                         endPoint: horizontal ? .trailing : .top))
                    .mask(alignment: horizontal ? .leading : .bottom) {
                        Capsule().frame(width: horizontal ? filled : nil, height: horizontal ? nil : filled)
                    }
            }
        }
        .frame(width: axis == .vertical ? thickness : nil, height: axis == .horizontal ? thickness : nil)
        .animation(.linear(duration: 0.08), value: level)
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

    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .background {
                if isLive {
                    Circle()
                        .fill(color.opacity(0.35))
                        .scaleEffect(breathe && !reduceMotion ? 2.2 : 1.4)
                        .opacity(breathe && !reduceMotion ? 0 : 1)
                }
            }
            .onAppear { startBreathing() }
            .onChange(of: isLive) { _, _ in startBreathing() }
            .accessibilityHidden(true)
    }

    private func startBreathing() {
        breathe = false
        guard isLive, !reduceMotion else { return }
        withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { breathe = true }
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
