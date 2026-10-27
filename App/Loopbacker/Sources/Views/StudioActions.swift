import SwiftUI
import AppKit

/// Scene identifiers.
enum WindowID {
    static let main = "main"
}

/// Sections of the main window, listed in the sidebar and bound to ⌘1–⌘4.
enum StudioSection: String, CaseIterable, Identifiable {
    case routing, effects, soundboard, scenes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .routing: "Routing"
        case .effects: "Effects"
        case .soundboard: "Soundboard"
        case .scenes: "Scenes"
        }
    }

    var symbol: String {
        switch self {
        case .routing: "point.3.connected.trianglepath.dotted"
        case .effects: "slider.vertical.3"
        case .soundboard: "square.grid.3x3.square"
        case .scenes: "square.stack.3d.up"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .routing: "1"
        case .effects: "2"
        case .soundboard: "3"
        case .scenes: "4"
        }
    }
}

/// App-wide actions shared by the toolbar, the menu bar commands, and the menu bar panel.
@MainActor
struct StudioActions {
    let routingState: RoutingState
    let audioRouter: AudioRouter
    let audioDeviceManager: AudioDeviceManager
    let driverInstaller: DriverInstaller

    /// Tear down and rebuild every route. Fixes glitches after sleep or device changes.
    func reconnect() {
        audioRouter.restartAllRoutes()
    }

    /// Stop all audio and remove every route; sources stay.
    func stopAllRouting() {
        withAnimation {
            audioRouter.stopAll()
            routingState.disconnectAll()
        }
    }

    func rescanDevices() {
        audioDeviceManager.enumerateDevices()
    }

    func playTestTone() {
        audioRouter.playTestTone(duration: 2.0)
    }

    func toggleDriver() {
        driverInstaller.isInstalled ? driverInstaller.uninstall() : driverInstaller.install()
    }

    /// Route the first enabled stereo source to output channels 1 & 2, adding a source if needed.
    func autoRouteStereo() {
        while routingState.outputChannels.count < 2 { routingState.addOutputChannel() }

        if let source = routingState.sources.first(where: { $0.channels.count >= 2 && $0.isEnabled }) {
            withAnimation { addStereoRoutes(for: source) }
            return
        }
        let inputDevices = audioDeviceManager.systemDevices.filter {
            $0.isInput && !$0.name.contains("Loopbacker") && $0.inputChannelCount >= 2
        }
        guard let device = inputDevices.first else { return }
        let newSource = audioDeviceManager.createSource(from: device)
        withAnimation {
            routingState.sources.append(newSource)
            addStereoRoutes(for: newSource)
        }
    }

    private func addStereoRoutes(for source: AudioSource) {
        let outChannels = routingState.outputChannels.sorted(by: { $0.id < $1.id })
        guard outChannels.count >= 2, source.channels.count >= 2 else { return }
        routingState.addRoute(sourceId: source.id, sourceChannelId: source.channels[0].id, outputChannelId: outChannels[0].id)
        routingState.addRoute(sourceId: source.id, sourceChannelId: source.channels[1].id, outputChannelId: outChannels[1].id)
    }

    /// Copy a plain-text snapshot of driver, sources, routes, outputs, and devices for bug reports.
    func copyDebugSnapshot() {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        var l = ["=== Loopbacker \(v) (\(b)) ===", ""]

        l.append("Driver: \(driverInstaller.isInstalled ? "installed" : "missing"), Virtual: \(audioDeviceManager.loopbackerDevicePresent ? "active" : "not found")")
        l.append("")

        for s in routingState.sources {
            l.append("[\(s.isEnabled ? (s.isMuted ? "MUTED" : "ON") : "OFF")] \(s.name) (\(s.channels.count)ch) uid=\(s.deviceUID)")
        }
        l.append("")

        for r in routingState.routes {
            let n = routingState.sources.first { $0.id == r.sourceId }?.name ?? "?"
            l.append("\(n) ch\(r.sourceChannelId) → out\(r.outputChannelId)")
        }
        l.append("")

        for d in routingState.outputDestinations {
            l.append("[\(d.isEnabled ? "ON" : "OFF")] \(d.virtualDeviceName) → \(d.physicalOutputName)")
        }
        l.append("")

        for d in audioDeviceManager.systemDevices {
            let io = [d.isInput ? "in:\(d.inputChannelCount)" : nil, d.isOutput ? "out:\(d.outputChannelCount)" : nil].compactMap { $0 }.joined(separator: " ")
            l.append("\(d.name) [\(io)]")
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(l.joined(separator: "\n"), forType: .string)
    }
}

// MARK: - Engine status

/// One reading of "is Loopbacker working", shared by the sidebar footer and the menu bar panel.
enum EngineStatus {
    case installing
    case noDriver
    case noDevice
    case idle
    case live(routes: Int)

    @MainActor
    init(driverInstaller: DriverInstaller, audioDeviceManager: AudioDeviceManager, routingState: RoutingState) {
        if driverInstaller.isProcessing { self = .installing }
        else if !driverInstaller.isInstalled { self = .noDriver }
        else if !audioDeviceManager.loopbackerDevicePresent { self = .noDevice }
        else if routingState.routes.isEmpty { self = .idle }
        else { self = .live(routes: routingState.routes.count) }
    }

    var title: String {
        switch self {
        case .installing: "Working…"
        case .noDriver: "Driver not installed"
        case .noDevice: "Virtual device missing"
        case .idle: "Idle"
        case .live: "Live"
        }
    }

    var detail: String {
        switch self {
        case .installing: "Installing or removing the audio driver"
        case .noDriver: "Install the driver to create the Loopbacker device"
        case .noDevice: "Driver installed, but CoreAudio has no Loopbacker device. Try Reconnect."
        case .idle: "48 kHz · 32-bit float · no routes"
        case .live(let n): "48 kHz · 32-bit float · \(n) route\(n == 1 ? "" : "s")"
        }
    }

    var color: Color {
        switch self {
        case .installing, .noDevice: .signalWarm
        case .noDriver: .signalHot
        case .idle: .secondary
        case .live: .loopbacker
        }
    }

    var isLive: Bool {
        if case .live = self { return true }
        return false
    }
}

// MARK: - Focused section (menu commands ⌘1–⌘4)

extension FocusedValues {
    @Entry var studioSection: Binding<StudioSection>?
}
