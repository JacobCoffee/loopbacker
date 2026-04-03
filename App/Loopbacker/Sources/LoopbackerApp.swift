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
            let activeCount = routingState.routes.count
            let sourceCount = routingState.sources.filter(\.isEnabled).count

            Label(
                driverInstaller.isInstalled ? "Virtual device active" : "Driver not installed",
                systemImage: driverInstaller.isInstalled ? "checkmark.circle.fill" : "xmark.circle"
            )

            Text("\(sourceCount) source\(sourceCount == 1 ? "" : "s"), \(activeCount) route\(activeCount == 1 ? "" : "s")")

            Divider()

            Button("Show Window") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                for window in NSApplication.shared.windows {
                    if window.canBecomeMain {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
            }
            .keyboardShortcut("l", modifiers: .command)

            Button("Quit Loopbacker") {
                AppDelegate.forceQuit()
            }
        } label: {
            Image(systemName: "waveform.path")
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private static var shouldReallyQuit = false

    /// Call this to actually terminate (from menu bar or toolbar Quit button)
    static func forceQuit() {
        shouldReallyQuit = true
        NSApplication.shared.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.shouldReallyQuit {
            return .terminateNow
        }
        // Cmd+Q / red X: hide windows, keep routing in background
        for window in NSApplication.shared.windows {
            window.close()
        }
        return .terminateCancel
    }
}
