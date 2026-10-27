import Foundation
import Combine

@MainActor
final class DriverInstaller: ObservableObject {
    @Published var isInstalled: Bool = false
    @Published var isProcessing: Bool = false
    @Published var statusMessage: String = ""

    static let driverPath = "/Library/Audio/Plug-Ins/HAL/Loopbacker.driver"

    init() {
        checkInstallation()
    }

    func checkInstallation() {
        isInstalled = FileManager.default.fileExists(atPath: Self.driverPath)
        statusMessage = isInstalled ? "Driver installed" : "Driver not installed"
    }

    func install() {
        guard !isProcessing else { return }
        isProcessing = true
        statusMessage = "Installing driver..."

        // Find the driver build relative to the app bundle, or fall back to known build paths
        let driverSource = findDriverBundle()
        guard let driverSource else {
            isProcessing = false
            statusMessage = "Driver bundle not found. Run 'make driver' first."
            return
        }

        // Sanitize the driver source path to prevent shell injection.
        // Replace single quotes with the AppleScript-safe escaped form,
        // then wrap in single quotes for the shell command.
        let escapedSource = driverSource.replacingOccurrences(of: "'", with: "'\\''")

        let script = """
        do shell script "cp -R '\(escapedSource)' /Library/Audio/Plug-Ins/HAL/ && \
        codesign --force --sign - /Library/Audio/Plug-Ins/HAL/Loopbacker.driver && \
        killall -9 coreaudiod" with administrator privileges
        """

        Task {
            let success = await Self.runAppleScript(script)
            isProcessing = false
            if success {
                isInstalled = true
                statusMessage = "Driver installed successfully"
            } else {
                statusMessage = "Installation failed"
            }
        }
    }

    func uninstall() {
        guard !isProcessing else { return }
        isProcessing = true
        statusMessage = "Uninstalling driver..."

        let script = """
        do shell script "rm -rf /Library/Audio/Plug-Ins/HAL/Loopbacker.driver && \
        killall -9 coreaudiod" with administrator privileges
        """

        Task {
            let success = await Self.runAppleScript(script)
            isProcessing = false
            if success {
                isInstalled = false
                statusMessage = "Driver uninstalled"
            } else {
                statusMessage = "Uninstall failed"
            }
        }
    }

    private func findDriverBundle() -> String? {
        // 1. Embedded inside .app bundle (Contents/Resources/Loopbacker.driver)
        if let resourcePath = Bundle.main.resourcePath {
            let embedded = (resourcePath as NSString).appendingPathComponent("Loopbacker.driver")
            if FileManager.default.fileExists(atPath: embedded) {
                return embedded
            }
        }

        // 2. Relative to working directory (dev builds)
        let devPaths = [
            "Driver/build/Loopbacker.driver",
            "../../../Driver/build/Loopbacker.driver",
        ]
        for path in devPaths {
            if FileManager.default.fileExists(atPath: path) {
                // Resolve to absolute path
                return (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(path)
            }
        }

        return nil
    }

    /// Runs osascript off the main thread; the admin prompt blocks until the user answers.
    private nonisolated static func runAppleScript(_ source: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", source]
                process.standardError = Pipe()

                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }
}
