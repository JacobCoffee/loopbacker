import AppKit
import SwiftUI
import Testing
@testable import Loopbacker

/// Offscreen renders of the Effects page, in light and dark, written to `/tmp` for visual
/// review. A review tool, not a correctness test: opt in with `LOOPBACKER_RENDER_SNAPSHOTS=1
/// swift test --filter EffectsRenderTests`. Offscreen only: never creates, shows, or activates
/// a window.
///
/// `.glassEffect`/`GlassEffectContainer` render blank in a pure offscreen `CGContext` (no live
/// window-server compositor) — confirmed with isolated repros before writing this harness. Every
/// `glassPanel`/`glassMaterial` call in the app checks `EnvironmentValues.snapshotRendering`
/// (set true below) and substitutes a flat, same-geometry fill instead, so layout, text,
/// controls, and now panel surfaces all render faithfully for review.
@MainActor
@Suite("Effects UI offscreen renders",
       .enabled(if: ProcessInfo.processInfo.environment["LOOPBACKER_RENDER_SNAPSHOTS"] == "1"))
struct EffectsRenderTests {
    private struct Context {
        let routingState: RoutingState
        let audioRouter: AudioRouter
        let fxEngine: FXEngine
        let hostedPluginStateCapture: HostedPluginStateCapture
        let tap: SystemAudioTap
        let audioDeviceManager: AudioDeviceManager
        let driverInstaller: DriverInstaller
    }

    // Shared across every test in this file: `AudioRouter`'s deinit tears down CoreAudio IO
    // procs on a background queue, which isn't safe to race across many short-lived instances
    // created back-to-back, so render tests reuse one engine (exactly how the real app runs —
    // one `AudioRouter`/`FXEngine` for the process) rather than one per render.
    // `AudioRouter`'s meter timer touches the `NSApp` global unconditionally; this test target
    // has no `NSApplicationMain` run, so `NSApp` is nil until something first touches
    // `NSApplication.shared` — do that before the timer's first tick instead of after.
    // Never activates or shows anything on screen: this process only ever renders offscreen.
    private static let appInitialized: Void = {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
    }()
    private static let sharedAudioRouter: AudioRouter = { _ = appInitialized; return AudioRouter() }()
    private static let sharedFXEngine = FXEngine(audioRouter: sharedAudioRouter)
    private static let sharedRoutingStateForCapture = RoutingState(effectsPreset: EffectsPreset())
    private static let sharedHostedPluginStateCapture = HostedPluginStateCapture(
        fxEngine: sharedFXEngine, routingState: sharedRoutingStateForCapture
    )
    private static let sharedTap = SystemAudioTap()
    private static let sharedAudioDeviceManager = AudioDeviceManager()
    private static let sharedDriverInstaller = DriverInstaller()
    /// A realistic 6-stage chain: gate, EQ, compressor, leveler, de-esser, and a hosted Audio
    /// Unit that failed to load (so the load-error recovery state is exercised too). The hosted
    /// node keeps a stable id across every call (not a fresh random one) so it matches
    /// `missingPluginNodeID` and every render's `previewLoadErrors` actually lands on it.
    private static let missingPluginNodeID = UUID()

    private static func realisticPreset() -> EffectsPreset {
        var nodes: [FXNodeConfig] = [
            FXNodeConfig(kind: .gate),
            FXNodeConfig(kind: .eq, eqBands: EQBandConfig.broadcast),
            FXNodeConfig(kind: .compressor),
            FXNodeConfig(kind: .leveler),
            FXNodeConfig(kind: .deEsser),
        ]
        nodes.append(FXNodeConfig(
            id: missingPluginNodeID, kind: .audioUnit,
            pluginRef: FXPluginRef(format: .audioUnit, identifier: "aufx dely appl", name: "Delay Designer", vendor: "Apple")
        ))
        return EffectsPreset(isEnabled: true, nodes: nodes)
    }

    /// Mid-level activity so meter-driven visuals don't render at rest.
    private static func midLevelMeters() -> FXMeters {
        let meters = FXMeters()
        meters.inputPeak = 0.35
        meters.outputPeak = 0.28
        meters.gainReductionDB = 6.5
        meters.activity = 0.6
        return meters
    }

    private func makeContext() -> Context {
        let routingState = RoutingState(effectsPreset: Self.realisticPreset(),
                                        noiseSuppression: NoiseSuppressionSettings(isEnabled: true))
        return Context(routingState: routingState, audioRouter: Self.sharedAudioRouter,
                       fxEngine: Self.sharedFXEngine, hostedPluginStateCapture: Self.sharedHostedPluginStateCapture,
                       tap: Self.sharedTap,
                       audioDeviceManager: Self.sharedAudioDeviceManager, driverInstaller: Self.sharedDriverInstaller)
    }

    private func previewMetersForAllNodes(_ context: Context) -> [UUID: FXMeters] {
        var out: [UUID: FXMeters] = [:]
        for node in context.routingState.effectsPreset.nodes {
            out[node.id] = Self.midLevelMeters()
        }
        return out
    }

    // Offscreen only, by hard rule: never create, show, or activate an on-screen window.
    // `ImageRenderer` renders into a private `CGContext`; `EnvironmentValues.snapshotRendering`
    // (see `DesignSystem.swift`) makes every glass panel in the tree draw a flat, same-geometry
    // fill instead of `.glassEffect`, so the capture reflects real layout/spacing/contrast.
    @discardableResult
    private func renderToPNG<V: View>(
        _ content: V, context: Context, name: String, colorScheme: ColorScheme,
        size: CGSize = CGSize(width: 900, height: 760),
        previewMeters: [UUID: FXMeters] = [:], previewLoadErrors: [UUID: String] = [:]
    ) throws -> Int {
        // `Color.loopbacker` and the flat-fill fallback both resolve through an `NSColor`
        // dynamic provider keyed to `NSAppearance.isDark`; without a real window, AppKit has no
        // other signal for which appearance is "current", so `.preferredColorScheme` alone
        // doesn't change what they draw. Setting `NSApp.appearance` directly (exactly what
        // `AppearanceMode.apply()` does for the real app) is a process-wide, no-UI state change
        // that every `NSColor`-backed color on the next draw picks up.
        NSApp.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        let wrapped = content
            .environmentObject(context.routingState)
            .environmentObject(context.fxEngine)
            .environmentObject(context.hostedPluginStateCapture)
            .environmentObject(context.tap)
            .environmentObject(context.audioRouter)
            .environmentObject(context.audioDeviceManager)
            .environmentObject(context.driverInstaller)
            .environmentObject(PresetAutoSwitchState())
            // GlobalToolbar reads it; its user driver never shows UI, so starting it here is
            // inert (the test bundle has no update feed).
            .environmentObject(AppUpdater.shared)
            .environment(context.audioRouter.meters)
            .environment(\.snapshotRendering, true)
            .environment(\.previewMeters, previewMeters)
            .environment(\.previewLoadErrors, previewLoadErrors)
            // `.preferredColorScheme` is a window-appearance *hint*; it doesn't propagate to
            // `@Environment(\.colorScheme)` reads without a real window (confirmed empirically:
            // a minimal probe view reads .light under `.preferredColorScheme(.dark)` here).
            // Setting the environment key directly is what every descendant actually reads.
            .environment(\.colorScheme, colorScheme)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(colorScheme == .dark ? Color.black : Color.white)

        let renderer = ImageRenderer(content: wrapped)
        renderer.scale = 2
        // `NSApp.appearance` alone doesn't make a dynamic `NSColor` resolve as dark/light during
        // an offscreen `CGContext` draw (that reads the thread-local "current drawing
        // appearance", which only a real view's `drawRect` sets automatically) — set it
        // explicitly around the render so `Color.loopbacker` and the flat-fill background both
        // pick the right variant.
        var nsImage: NSImage?
        NSApp.appearance!.performAsCurrentDrawingAppearance {
            nsImage = renderer.nsImage
        }
        guard let nsImage else {
            Issue.record("Failed to render \(name)")
            return 0
        }
        guard let tiff = nsImage.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            Issue.record("Failed to encode PNG for \(name)")
            return 0
        }
        let schemeName = colorScheme == .dark ? "dark" : "light"
        let url = URL(fileURLWithPath: "/tmp/loopbacker-effects-\(name)-\(schemeName).png")
        try png.write(to: url)
        return png.count
    }

    private func node(_ context: Context, kind: FXNodeKind) -> UUID {
        context.routingState.effectsPreset.nodes.first { $0.kind == kind }!.id
    }

    private func renderAdvanced(_ context: Context, selectedKind: FXNodeKind, name: String) throws {
        let selectedID = node(context, kind: selectedKind)
        let meters = previewMetersForAllNodes(context)
        let errors = [Self.missingPluginNodeID: "The \"Delay Designer\" Audio Unit is not installed on this Mac."]
        for scheme in [ColorScheme.light, .dark] {
            let size = try renderToPNG(NavigationStack { EffectsView(previewAdvanced: true, previewSelectedNodeID: selectedID) },
                                       context: context, name: name, colorScheme: scheme,
                                       previewMeters: meters, previewLoadErrors: errors)
            #expect(size > 2000)
        }
    }

    @Test("Simple mode renders in light and dark")
    func simpleMode() throws {
        for scheme in [ColorScheme.light, .dark] {
            let context = makeContext()
            let size = try renderToPNG(NavigationStack { EffectsView(previewAdvanced: false, previewSelectedNodeID: nil) },
                                       context: context, name: "simple", colorScheme: scheme,
                                       previewMeters: previewMetersForAllNodes(context))
            #expect(size > 2000)
        }
    }

    @Test("Advanced mode with Gate selected renders in light and dark")
    func advancedGate() throws { try renderAdvanced(makeContext(), selectedKind: .gate, name: "advanced-gate") }

    @Test("Advanced mode with Compressor selected renders in light and dark")
    func advancedCompressor() throws { try renderAdvanced(makeContext(), selectedKind: .compressor, name: "advanced-compressor") }

    @Test("Advanced mode with EQ selected renders in light and dark")
    func advancedEQ() throws { try renderAdvanced(makeContext(), selectedKind: .eq, name: "advanced-eq") }

    @Test("Advanced mode with Leveler selected renders in light and dark")
    func advancedLeveler() throws { try renderAdvanced(makeContext(), selectedKind: .leveler, name: "advanced-leveler") }

    @Test("Advanced mode with a load-error hosted stage selected renders in light and dark")
    func advancedLoadError() throws { try renderAdvanced(makeContext(), selectedKind: .audioUnit, name: "advanced-load-error") }

    @Test("Effect browser renders every tab, including the empty JSFX state, in light and dark")
    func effectBrowser() async throws {
        for (index, tabName) in ["builtin", "audio-units", "jsfx", "airwindows"].enumerated() {
            for scheme in [ColorScheme.light, .dark] {
                let context = makeContext()
                await context.fxEngine.refreshPlugins()
                let sheet = EffectBrowserSheet(previewTabIndex: index, onInsertBuiltin: { _ in }, onInsertHosted: { _ in })
                let size = try renderToPNG(sheet, context: context, name: "browser-\(tabName)", colorScheme: scheme,
                                           size: CGSize(width: 620, height: 520))
                #expect(size > 1000)
            }
        }
    }

    @Test("Mic check result renders in light and dark")
    func micCheckResult() throws {
        for scheme in [ColorScheme.light, .dark] {
            let context = makeContext()
            let samples = (0..<4800).map { Float(sin(Double($0) * 0.05)) * 0.6 }
            let recording = FXRecording(raw: samples, processed: samples.map { $0 * 0.8 }, sampleRate: 48000)
            let size = try renderToPNG(MicCheckView(previewResult: recording), context: context, name: "mic-check-result",
                                       colorScheme: scheme, size: CGSize(width: 480, height: 420))
            #expect(size > 1000)
        }
    }

    @Test("Auto Setup result renders in light and dark")
    func autoSetupResult() throws {
        for scheme in [ColorScheme.light, .dark] {
            let context = makeContext()
            var tunedPreset = context.routingState.effectsPreset
            if let idx = tunedPreset.nodes.firstIndex(where: { $0.kind == .compressor }) {
                tunedPreset.nodes[idx].params["ratio"] = 5
                tunedPreset.nodes[idx].params["makeup"] = 6
            }
            var tunedNoise = context.routingState.noiseSuppression
            tunedNoise.maxReductionDB = -48
            let result = AutoSetupResult(
                noiseFloorDBFS: -42, speechLUFS: -21, peakDBFS: -6, sibilanceDB: 4.2, tiltDB: -3.1,
                findings: [
                    "Moderate room noise detected; noise suppression is set to a medium depth.",
                    "Your speaking level is in a healthy range.",
                    "Sibilance ('s'/'sh' sounds) is forward; the de-esser was tightened.",
                ],
                preset: tunedPreset,
                noiseSuppression: tunedNoise
            )
            let size = try renderToPNG(AutoSetupView(previewResult: result), context: context, name: "auto-setup-result",
                                       colorScheme: scheme, size: CGSize(width: 520, height: 520))
            #expect(size > 1000)
        }
    }

    @Test("Call app advice banner renders in light and dark")
    func callAppAdviceBanner() throws {
        for scheme in [ColorScheme.light, .dark] {
            let context = makeContext()
            let advice = CallAppAdvice(id: "us.zoom.xos", appName: "Zoom",
                                       advice: "Zoom has its own noise suppression and auto-gain; turn those off in Zoom's audio settings so Loopbacker's chain isn't fighting a second processor.")
            let size = try renderToPNG(CallAppAdviceBanner(advice: advice, onDismiss: {}), context: context,
                                       name: "call-app-advice", colorScheme: scheme, size: CGSize(width: 820, height: 100))
            #expect(size > 1000)
        }
    }
}
