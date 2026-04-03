import SwiftUI

@main
struct LoopbackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var routingState = RoutingState.load()
    @StateObject private var audioDeviceManager = AudioDeviceManager()
    @StateObject private var driverInstaller = DriverInstaller()
    @StateObject private var audioRouter = AudioRouter()

    @Environment(\.openWindow) private var openWindow
    @State private var windowVisible = true

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(routingState)
                .environmentObject(audioDeviceManager)
                .environmentObject(driverInstaller)
                .environmentObject(audioRouter)
                .frame(minWidth: 800, minHeight: 600)
                .preferredColorScheme(.dark)
                .onAppear { windowVisible = true }
                .onDisappear { windowVisible = false }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1000, height: 700)

        // Menu bar extra -- stays alive when window is closed
        MenuBarExtra {
            MenuBarView(windowVisible: $windowVisible)
                .environmentObject(routingState)
                .environmentObject(audioRouter)
                .environmentObject(driverInstaller)
        } label: {
            Image(systemName: "cable.connector.horizontal")
        }
    }
}

// MARK: - App Delegate to prevent quit on window close

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // Keep running in menu bar
    }
}

// MARK: - Menu bar dropdown view

struct MenuBarView: View {
    @Binding var windowVisible: Bool
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var audioRouter: AudioRouter
    @EnvironmentObject var driverInstaller: DriverInstaller

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status
            if driverInstaller.isInstalled {
                Label("Virtual device active", systemImage: "checkmark.circle.fill")
            } else {
                Label("Driver not installed", systemImage: "xmark.circle")
            }

            Divider()

            // Active routes
            let activeCount = routingState.routes.count
            let sourceCount = routingState.sources.filter(\.isEnabled).count
            Text("\(sourceCount) source\(sourceCount == 1 ? "" : "s"), \(activeCount) route\(activeCount == 1 ? "" : "s")")

            Divider()

            // Show/hide window
            Button(windowVisible ? "Hide Window" : "Show Window") {
                if windowVisible {
                    NSApplication.shared.keyWindow?.close()
                } else {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    NSApp.sendAction(#selector(NSWindow.makeKeyAndOrderFront(_:)), to: nil, from: nil)
                    // Open a new window if none exist
                    if NSApplication.shared.windows.filter({ $0.isVisible }).isEmpty {
                        NSWorkspace.shared.open(URL(string: "loopbacker://show")!)
                    }
                }
            }
            .keyboardShortcut("l", modifiers: .command)

            Divider()

            Button("Quit Loopbacker") {
                audioRouter.stopAll()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
