import SwiftUI

@main
struct LoopbackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var routingState = RoutingState.load()
    @StateObject private var audioDeviceManager = AudioDeviceManager()
    @StateObject private var driverInstaller = DriverInstaller()
    @StateObject private var audioRouter = AudioRouter()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(routingState)
                .environmentObject(audioDeviceManager)
                .environmentObject(driverInstaller)
                .environmentObject(audioRouter)
                .frame(minWidth: 800, minHeight: 600)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1000, height: 700)

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(routingState)
                .environmentObject(audioDeviceManager)
                .environmentObject(driverInstaller)
                .environmentObject(audioRouter)
                .preferredColorScheme(.dark)
        } label: {
            Image(systemName: "waveform.path")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Rich menu bar panel

struct MenuBarPanel: View {
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var audioDeviceManager: AudioDeviceManager
    @EnvironmentObject var driverInstaller: DriverInstaller
    @EnvironmentObject var audioRouter: AudioRouter

    private let bg = Color(red: 0.08, green: 0.08, blue: 0.14)
    private let card = Color(red: 0.14, green: 0.14, blue: 0.22)
    private let border = Color(white: 0.18)
    private let accent = Color(red: 0.0, green: 0.83, blue: 0.67)
    private let textDim = Color(white: 0.5)
    private let danger = Color(red: 0.95, green: 0.30, blue: 0.35)

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "cable.connector.horizontal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(accent)

                Text("Loopbacker")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)

                Spacer()

                // Status dot
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusColor.opacity(0.6), radius: 4)

                Text(statusLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(textDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().background(border)

            // Sources summary
            VStack(spacing: 6) {
                ForEach(routingState.sources) { source in
                    HStack(spacing: 8) {
                        Image(systemName: source.icon)
                            .font(.system(size: 10))
                            .foregroundColor(source.isEnabled && !source.isMuted ? accent : textDim)
                            .frame(width: 16)

                        Text(source.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)

                        Spacer()

                        // Mini meter bar
                        if source.isEnabled && !source.isMuted {
                            MiniMeter(level: sourceMeterLevel(source))
                        }

                        // Status badge
                        Text(source.isMuted ? "MUTE" : source.isEnabled ? "ON" : "OFF")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(source.isMuted ? .orange : source.isEnabled ? accent : textDim)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(
                                    (source.isMuted ? Color.orange : source.isEnabled ? accent : textDim).opacity(0.15)
                                )
                            )
                    }
                }

                if routingState.sources.isEmpty {
                    HStack {
                        Image(systemName: "speaker.slash")
                            .font(.system(size: 10))
                            .foregroundColor(textDim)
                        Text("No sources")
                            .font(.system(size: 11))
                            .foregroundColor(textDim)
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider().background(border)

            // Stats row
            HStack(spacing: 12) {
                statBadge(icon: "cable.connector.horizontal", value: "\(routingState.routes.count)", label: "routes")
                statBadge(icon: "waveform", value: "48k", label: "")
                statBadge(icon: "arrow.right.circle", value: "\(routingState.outputDestinations.count)", label: "outputs")
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider().background(border)

            // Quick actions
            HStack(spacing: 8) {
                panelButton("Reconnect", icon: "arrow.clockwise") {
                    audioRouter.restartAllRoutes()
                }

                panelButton("Test Tone", icon: "tuningfork") {
                    audioRouter.playTestTone(duration: 2.0)
                }

                Spacer()

                panelButton("Show Window", icon: "macwindow") {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    for w in NSApplication.shared.windows where w.canBecomeMain {
                        w.makeKeyAndOrderFront(nil)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider().background(border)

            // Quit
            HStack {
                Spacer()
                Button(action: { AppDelegate.forceQuit() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                            .font(.system(size: 10))
                        Text("Quit")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(danger.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 280)
        .background(bg)
    }

    // MARK: - Components

    private func statBadge(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundColor(textDim)
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 9))
                    .foregroundColor(textDim)
            }
        }
    }

    private func panelButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(accent.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(accent.opacity(0.2), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private func sourceMeterLevel(_ source: AudioSource) -> Float {
        let levels = audioRouter.sourceMeterLevels[source.deviceUID] ?? [:]
        let maxLevel = levels.values.max() ?? 0
        return maxLevel
    }

    private var statusColor: Color {
        if !driverInstaller.isInstalled { return danger }
        if !audioDeviceManager.loopbackerDevicePresent { return .orange }
        return routingState.routes.isEmpty ? textDim : accent
    }

    private var statusLabel: String {
        if !driverInstaller.isInstalled { return "No driver" }
        if !audioDeviceManager.loopbackerDevicePresent { return "No device" }
        return routingState.routes.isEmpty ? "Idle" : "Routing"
    }
}

// MARK: - Mini meter bar for menu bar panel

private struct MiniMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(white: 0.15))
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(red: 0.0, green: 0.83, blue: 0.67))
                    .frame(width: geo.size.width * CGFloat(level))
            }
        }
        .frame(width: 40, height: 4)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private static var shouldReallyQuit = false

    static func forceQuit() {
        shouldReallyQuit = true
        NSApplication.shared.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.shouldReallyQuit { return .terminateNow }
        for window in NSApplication.shared.windows { window.close() }
        return .terminateCancel
    }
}
