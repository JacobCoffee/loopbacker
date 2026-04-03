import SwiftUI

@main
struct LoopbackerApp: App {
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
    }
}
