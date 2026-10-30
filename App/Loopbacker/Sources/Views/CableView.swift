import SwiftUI
import AppKit

/// Draws bezier "cables" between connected channel ports, beneath the glass cards.
/// Live cables (source enabled, unmuted) glow in `Color.loopbacker` with intensity following
/// the source's current level; idle or disabled cables stay dim graphite.
///
/// Backed by Core Animation layers rather than a SwiftUI `Canvas`: structure (routes, which
/// sources are enabled/muted, connector positions, the pending connector) comes from SwiftUI and
/// only reshapes layers when it changes. Per-tick glow follows `MeterLevels` by observing it
/// directly inside the `NSView`, the same pattern `LiveSignalMeter` uses, so a 30 Hz meter tick
/// never re-runs SwiftUI or re-rasterizes a blurred `Canvas` on the main thread.
struct CableView: View {
    @EnvironmentObject var routingState: RoutingState
    @Environment(MeterLevels.self) private var meters
    let connectorPositions: [ConnectorEnd: CGRect]

    /// Glow levels per source are quantized to this many steps, so a layer update happens only
    /// when the visible step changes rather than on every meter tick.
    static let glowStepCount = 16

    var body: some View {
        CableLayerRepresentable(
            routes: routingState.routes,
            sources: routingState.sources,
            pending: routingState.pendingConnector,
            positions: connectorPositions,
            meters: meters
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // CRITICAL: hit testing must be off so clicks pass through to cards/buttons
        .allowsHitTesting(false)
    }
}

/// Bridges the cables' structural inputs into the backing `NSView`. `meters` is only stored,
/// never read here: reading `meters.peak(...)` in a SwiftUI body would make this view re-render
/// on every meter tick, exactly the cost this exists to avoid.
private struct CableLayerRepresentable: NSViewRepresentable {
    let routes: [AudioRoute]
    let sources: [AudioSource]
    let pending: ConnectorEnd?
    let positions: [ConnectorEnd: CGRect]
    let meters: MeterLevels

    func makeNSView(context: Context) -> CableLayerView { CableLayerView() }

    func updateNSView(_ view: CableLayerView, context: Context) {
        view.update(routes: routes, sources: sources, pending: pending, positions: positions, meters: meters)
    }
}

/// The cable layers themselves. `update` rebuilds/reshapes layers only when the structural
/// inputs change; glow intensity is driven separately, per live source, by observing
/// `MeterLevels` with `withObservationTracking` and quantizing to `CableView.glowStepCount` steps.
private final class CableLayerView: NSView {
    private struct Structure: Equatable {
        let routes: [AudioRoute]
        let sources: [AudioSource]
        let pending: ConnectorEnd?
        let positions: [ConnectorEnd: CGRect]
    }

    private struct CableGroup {
        let sourceId: UUID
        let idle: CAShapeLayer
        let glow: CAShapeLayer
        let shadow: CAShapeLayer
        let main: CAShapeLayer
        let core: CAShapeLayer
        let startDot: CAShapeLayer
        let endDot: CAShapeLayer
    }

    private struct BloomGroup {
        let sourceId: UUID
        let layer: CAGradientLayer
        let center: CGPoint
    }

    private let cablesContainer = CALayer()
    private let bloomContainer = CALayer()
    private let pendingContainer = CALayer()

    private var structure: Structure?
    private var cableGroups: [CableGroup] = []
    private var bloomGroups: [BloomGroup] = []
    private var pendingLayers: [(layer: CAShapeLayer, alpha: CGFloat)] = []

    /// Source ID → quantized glow step (0 = no signal, else 1...glowStepCount).
    private var glowSteps: [UUID: Int] = [:]
    private var generation = 0

    private var accentColor: CGColor = NSColor.black.cgColor
    private var idleColor: CGColor = NSColor.black.cgColor

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(cablesContainer)
        layer?.addSublayer(bloomContainer)
        layer?.addSublayer(pendingContainer)
        resolveColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Top-left origin, y increasing downward: matches the SwiftUI "routing" named coordinate
    // space that connector positions are reported in.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        withoutAnimation {
            cablesContainer.frame = bounds
            bloomContainer.frame = bounds
            pendingContainer.frame = bounds
            for group in cableGroups {
                for layer in [group.idle, group.glow, group.shadow, group.main, group.core, group.startDot, group.endDot] {
                    layer.frame = bounds
                }
            }
            for entry in pendingLayers {
                entry.layer.frame = bounds
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
        reapplyColors()
    }

    // MARK: - Structural update (SwiftUI-driven)

    func update(
        routes: [AudioRoute],
        sources: [AudioSource],
        pending: ConnectorEnd?,
        positions: [ConnectorEnd: CGRect],
        meters: MeterLevels
    ) {
        let newStructure = Structure(routes: routes, sources: sources, pending: pending, positions: positions)
        if newStructure != structure {
            structure = newStructure
            rebuild(routes: routes, sources: sources, pending: pending, positions: positions)
        }
        startObservingGlow(sources: sources, meters: meters)
    }

    private func rebuild(routes: [AudioRoute], sources: [AudioSource], pending: ConnectorEnd?, positions: [ConnectorEnd: CGRect]) {
        withoutAnimation {
            cablesContainer.sublayers = nil
            bloomContainer.sublayers = nil
            pendingContainer.sublayers = nil
            cableGroups = []
            bloomGroups = []
            pendingLayers = []

            let bounds = self.bounds

            for route in routes {
                let sourceEnd = ConnectorEnd.source(sourceId: route.sourceId, channelId: route.sourceChannelId)
                let outputEnd = ConnectorEnd.output(target: route.targetId, channelId: route.outputChannelId)
                guard let sourceRect = positions[sourceEnd], let outputRect = positions[outputEnd] else { continue }

                let start = CGPoint(x: sourceRect.midX, y: sourceRect.midY)
                let end = CGPoint(x: outputRect.midX, y: outputRect.midY)
                let group = makeCableGroup(sourceId: route.sourceId, start: start, end: end, bounds: bounds)
                cableGroups.append(group)
                cablesContainer.addSublayer(group.idle)
                cablesContainer.addSublayer(group.glow)
                cablesContainer.addSublayer(group.shadow)
                cablesContainer.addSublayer(group.main)
                cablesContainer.addSublayer(group.core)
                cablesContainer.addSublayer(group.startDot)
                cablesContainer.addSublayer(group.endDot)
            }

            // Soft bloom under each live source's connectors.
            for source in sources {
                for channel in source.channels {
                    guard let rect = positions[.source(sourceId: source.id, channelId: channel.id)] else { continue }
                    let center = CGPoint(x: rect.midX, y: rect.midY)
                    let bloom = makeBloomLayer(sourceId: source.id, center: center)
                    bloomGroups.append(bloom)
                    bloomContainer.addSublayer(bloom.layer)
                }
            }

            // Pending connection pulse indicator.
            if let pending, let pendingRect = positions[pending] {
                let point = CGPoint(x: pendingRect.midX, y: pendingRect.midY)
                let outer = circleLayer(center: point, radius: 12, fillAlpha: 0.2, bounds: bounds)
                let inner = circleLayer(center: point, radius: 6, fillAlpha: 0.5, bounds: bounds)
                pendingContainer.addSublayer(outer)
                pendingContainer.addSublayer(inner)
                pendingLayers = [(outer, 0.2), (inner, 0.5)]
            }

            // Drop glow state for sources that no longer exist, then re-apply what's left so a
            // structural rebuild (e.g. a window resize) doesn't reset mid-level cables to idle.
            let validSourceIds = Set(sources.map(\.id))
            glowSteps = glowSteps.filter { validSourceIds.contains($0.key) }

            for group in cableGroups {
                applyCableAppearance(group, step: glowSteps[group.sourceId] ?? 0)
            }
            for bloom in bloomGroups {
                applyBloomAppearance(bloom, step: glowSteps[bloom.sourceId] ?? 0)
            }
        }
    }

    // MARK: - Layer construction

    private func makeCableGroup(sourceId: UUID, start: CGPoint, end: CGPoint, bounds: CGRect) -> CableGroup {
        let dx = end.x - start.x
        let controlOffset = max(abs(dx) * 0.5, 60)
        let path = CGMutablePath()
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + controlOffset, y: start.y),
            control2: CGPoint(x: end.x - controlOffset, y: end.y)
        )

        func shapeLayer() -> CAShapeLayer {
            let layer = CAShapeLayer()
            layer.frame = bounds
            layer.path = path
            layer.fillColor = nil
            layer.lineCap = .round
            return layer
        }

        let idle = shapeLayer()
        idle.lineWidth = 1.5
        idle.strokeColor = idleColor.withAlpha(0.22)

        // Glow: a wide, low-opacity stroke plus a native layer shadow for softness, instead of a
        // Gaussian blur filter that would force the canvas to be rasterized on the main thread.
        let glow = shapeLayer()
        glow.shadowOffset = .zero
        glow.shadowColor = accentColor
        glow.shadowPath = path.copy(strokingWithWidth: 14, lineCap: .round, lineJoin: .round, miterLimit: 1)
        glow.isHidden = true

        let shadow = shapeLayer()
        shadow.lineWidth = 4
        shadow.strokeColor = accentColor.withAlpha(0.3)
        shadow.isHidden = true

        let main = shapeLayer()
        main.lineWidth = 2
        main.isHidden = true

        let core = shapeLayer()
        core.lineWidth = 1
        core.isHidden = true

        let startDot = dotLayer(at: start, bounds: bounds)
        let endDot = dotLayer(at: end, bounds: bounds)

        return CableGroup(sourceId: sourceId, idle: idle, glow: glow, shadow: shadow, main: main, core: core, startDot: startDot, endDot: endDot)
    }

    private func dotLayer(at point: CGPoint, bounds: CGRect) -> CAShapeLayer {
        let radius: CGFloat = 3
        let layer = CAShapeLayer()
        layer.frame = bounds
        layer.path = CGPath(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2), transform: nil)
        layer.fillColor = idleColor.withAlpha(0.35)
        return layer
    }

    private func makeBloomLayer(sourceId: UUID, center: CGPoint) -> BloomGroup {
        let layer = CAGradientLayer()
        layer.type = .radial
        layer.locations = [0, 1]
        layer.startPoint = CGPoint(x: 0.5, y: 0.5)
        layer.endPoint = CGPoint(x: 1, y: 0.5)
        layer.isHidden = true
        let base: CGFloat = 36
        layer.frame = CGRect(x: center.x - base, y: center.y - base, width: base * 2, height: base * 2)
        return BloomGroup(sourceId: sourceId, layer: layer, center: center)
    }

    private func circleLayer(center: CGPoint, radius: CGFloat, fillAlpha: CGFloat, bounds: CGRect) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.frame = bounds
        layer.path = CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), transform: nil)
        layer.fillColor = accentColor.withAlpha(fillAlpha)
        return layer
    }

    // MARK: - Glow observation (MeterLevels-driven, outside SwiftUI)

    /// Starts following each live source's level (or stops, for sources that are no longer live).
    /// Each call starts a new observation chain and retires the previous one, so repeated
    /// structural updates never stack up refreshes.
    private func startObservingGlow(sources: [AudioSource], meters: MeterLevels) {
        generation &+= 1
        let gen = generation

        let liveSources = sources.filter { $0.isEnabled && !$0.isMuted }
        let liveIds = Set(liveSources.map(\.id))

        for sourceId in glowSteps.keys where !liveIds.contains(sourceId) {
            glowSteps.removeValue(forKey: sourceId)
            applyGlow(sourceId: sourceId, step: 0)
        }

        for source in liveSources {
            let sourceId = source.id
            let deviceUID = source.deviceUID
            // Not inline: this runs inside SwiftUI's update, which would also record the level
            // read and re-run the update on every change, the cost this view exists to avoid.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.refreshGlow(sourceId: sourceId, deviceUID: deviceUID, meters: meters, generation: gen) }
            }
        }
    }

    private func refreshGlow(sourceId: UUID, deviceUID: String, meters: MeterLevels, generation: Int) {
        guard generation == self.generation else { return }
        let level = withObservationTracking {
            meters.peak(source: deviceUID)
        } onChange: { [weak self] in
            // Called as the level is about to change; read it once the write has landed.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshGlow(sourceId: sourceId, deviceUID: deviceUID, meters: meters, generation: generation) } }
        }
        setGlowStep(sourceId: sourceId, level: level)
    }

    private func setGlowStep(sourceId: UUID, level: Float) {
        let step = level > 0 ? max(1, Int((min(level, 1) * Float(CableView.glowStepCount)).rounded())) : 0
        let current = glowSteps[sourceId] ?? 0
        guard current != step else { return }
        if step == 0 {
            glowSteps.removeValue(forKey: sourceId)
        } else {
            glowSteps[sourceId] = step
        }
        applyGlow(sourceId: sourceId, step: step)
    }

    private func applyGlow(sourceId: UUID, step: Int) {
        withoutAnimation {
            for group in cableGroups where group.sourceId == sourceId {
                applyCableAppearance(group, step: step)
            }
            for bloom in bloomGroups where bloom.sourceId == sourceId {
                applyBloomAppearance(bloom, step: step)
            }
        }
    }

    // MARK: - Appearance (color/opacity only; never reshapes a path)

    private func applyCableAppearance(_ group: CableGroup, step: Int) {
        let isLive = step > 0
        let rawLevel = CGFloat(step) / CGFloat(CableView.glowStepCount)
        let intensity = isLive ? min(max(rawLevel, 0.12), 1) : 0

        group.idle.isHidden = isLive
        group.glow.isHidden = !isLive
        group.shadow.isHidden = !isLive
        group.main.isHidden = !isLive
        group.core.isHidden = !isLive

        if isLive {
            group.glow.strokeColor = accentColor.withAlpha(0.12 + 0.18 * intensity)
            group.glow.lineWidth = 6 + 8 * intensity
            group.glow.shadowOpacity = Float(0.35 + 0.45 * intensity)
            group.glow.shadowRadius = 4 + 6 * intensity

            group.main.strokeColor = accentColor.withAlpha(0.55 + 0.3 * intensity)
            group.core.strokeColor = accentColor.withAlpha(0.5 + 0.3 * intensity)
        }

        group.startDot.fillColor = isLive ? accentColor.withAlpha(0.9) : idleColor.withAlpha(0.35)
        group.endDot.fillColor = isLive ? accentColor.withAlpha(0.9) : idleColor.withAlpha(0.35)
    }

    private func applyBloomAppearance(_ bloom: BloomGroup, step: Int) {
        let isLive = step > 0
        bloom.layer.isHidden = !isLive
        guard isLive else { return }
        let rawLevel = CGFloat(step) / CGFloat(CableView.glowStepCount)
        let radius: CGFloat = 36 + rawLevel * 48
        bloom.layer.frame = CGRect(x: bloom.center.x - radius, y: bloom.center.y - radius, width: radius * 2, height: radius * 2)
        bloom.layer.colors = [accentColor.withAlpha(0.10 * rawLevel), accentColor.withAlpha(0)]
    }

    private func resolveColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            accentColor = NSColor(Color.loopbacker).cgColor
            idleColor = NSColor.secondaryLabelColor.cgColor
        }
    }

    private func reapplyColors() {
        withoutAnimation {
            for group in cableGroups {
                group.idle.strokeColor = idleColor.withAlpha(0.22)
                group.shadow.strokeColor = accentColor.withAlpha(0.3)
                group.glow.shadowColor = accentColor
                applyCableAppearance(group, step: glowSteps[group.sourceId] ?? 0)
            }
            for bloom in bloomGroups {
                applyBloomAppearance(bloom, step: glowSteps[bloom.sourceId] ?? 0)
            }
            for entry in pendingLayers {
                entry.layer.fillColor = accentColor.withAlpha(entry.alpha)
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

private extension CGColor {
    func withAlpha(_ alpha: CGFloat) -> CGColor {
        copy(alpha: alpha) ?? self
    }
}
