import AppKit
import SwiftUI
import Testing
@testable import Loopbacker

/// Offscreen renders of the redesigned Effects page, in light and dark, written to `/tmp` for
/// manual inspection (per `local://fx-contract-wave2.md`'s "Verifying UI without launching the
/// app"). These assert only that rendering succeeds and produces a nontrivial image — a real
/// pixel-level visual review happens by reading the PNGs, not by asserting on them here, so this
/// stays deterministic across machines/appearances.
@MainActor
@Suite("Effects UI offscreen renders")
struct EffectsRenderTests {
    private struct Context {
        let routingState: RoutingState
        let audioRouter: AudioRouter
        let fxEngine: FXEngine
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
    private static let sharedTap = SystemAudioTap()
    private static let sharedAudioDeviceManager = AudioDeviceManager()
    private static let sharedDriverInstaller = DriverInstaller()

    private func makeContext() -> Context {
        let routingState = RoutingState(effectsPreset: .broadcastVoice,
                                        noiseSuppression: NoiseSuppressionSettings(isEnabled: true))
        return Context(routingState: routingState, audioRouter: Self.sharedAudioRouter,
                       fxEngine: Self.sharedFXEngine, tap: Self.sharedTap,
                       audioDeviceManager: Self.sharedAudioDeviceManager, driverInstaller: Self.sharedDriverInstaller)
    }

    // Offscreen only, by hard rule: never create, show, or activate an on-screen window.
    // `ImageRenderer` renders into a private `CGContext`, so it's used exclusively here. It
    // faithfully renders ordinary SwiftUI content (text, controls, shapes, sliders) but, being a
    // pure offscreen context with no live window-server compositor, can't show Liquid Glass
    // blur/backdrop materials (`.glassEffect`/`GlassEffectContainer`) — those panels render
    // without their blur/tint. That's a platform limitation of offscreen rendering in general,
    // not specific to this page; it affects every `.glassPanel()` in the app the same way and
    // isn't fixable from view code. Layout, spacing, text, and every non-glass control still
    // render correctly and are what gets visually reviewed from these PNGs.
    @discardableResult
    private func renderToPNG<V: View>(
        _ content: V, context: Context, name: String, colorScheme: ColorScheme,
        size: CGSize = CGSize(width: 1180, height: 820)
    ) throws -> Int {
        let wrapped = content
            .environmentObject(context.routingState)
            .environmentObject(context.fxEngine)
            .environmentObject(context.tap)
            .environmentObject(context.audioRouter)
            .environmentObject(context.audioDeviceManager)
            .environmentObject(context.driverInstaller)
            .environment(context.audioRouter.meters)
            .preferredColorScheme(colorScheme)
            .frame(width: size.width, height: size.height)
            .background(colorScheme == .dark ? Color.black : Color.white)

        let renderer = ImageRenderer(content: wrapped)
        renderer.scale = 2
        guard let nsImage = renderer.nsImage else {
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

    @Test("Simple mode renders in light and dark")
    func simpleMode() throws {
        for scheme in [ColorScheme.light, .dark] {
            let context = makeContext()
            let size = try renderToPNG(EffectsView(previewAdvanced: false, previewSelectedNodeID: nil),
                                       context: context, name: "simple", colorScheme: scheme)
            #expect(size > 2000)
        }
    }

    @Test("Advanced mode with Gate selected renders in light and dark")
    func advancedGate() throws {
        for scheme in [ColorScheme.light, .dark] {
            let context = makeContext()
            let gateID = node(context, kind: .gate)
            let size = try renderToPNG(EffectsView(previewAdvanced: true, previewSelectedNodeID: gateID),
                                       context: context, name: "advanced-gate", colorScheme: scheme)
            #expect(size > 2000)
        }
    }

    @Test("Advanced mode with Compressor selected renders in light and dark")
    func advancedCompressor() throws {
        for scheme in [ColorScheme.light, .dark] {
            let context = makeContext()
            let compressorID = node(context, kind: .compressor)
            let size = try renderToPNG(EffectsView(previewAdvanced: true, previewSelectedNodeID: compressorID),
                                       context: context, name: "advanced-compressor", colorScheme: scheme)
            #expect(size > 2000)
        }
    }

    @Test("Advanced mode with EQ selected renders in light and dark")
    func advancedEQ() throws {
        for scheme in [ColorScheme.light, .dark] {
            let context = makeContext()
            let eqID = node(context, kind: .eq)
            let size = try renderToPNG(EffectsView(previewAdvanced: true, previewSelectedNodeID: eqID),
                                       context: context, name: "advanced-eq", colorScheme: scheme)
            #expect(size > 2000)
        }
    }

    @Test("Effect browser renders every tab in light and dark")
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
            let result = AutoSetupResult(
                noiseFloorDBFS: -42, speechLUFS: -21, peakDBFS: -6, sibilanceDB: 4.2, tiltDB: -3.1,
                findings: [
                    "Moderate room noise detected; noise suppression is set to a medium depth.",
                    "Your speaking level is in a healthy range.",
                    "Sibilance ('s'/'sh' sounds) is forward; the de-esser was tightened.",
                ],
                preset: context.routingState.effectsPreset,
                noiseSuppression: context.routingState.noiseSuppression
            )
            let size = try renderToPNG(AutoSetupView(previewResult: result), context: context, name: "auto-setup-result",
                                       colorScheme: scheme, size: CGSize(width: 520, height: 520))
            #expect(size > 1000)
        }
    }
}
