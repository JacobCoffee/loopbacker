import Foundation
import Combine

@MainActor
final class DriverInstaller: ObservableObject {
    @Published var isInstalled: Bool = false
    @Published var isProcessing: Bool = false
    @Published var statusMessage: String = ""
    /// True when the driver bundled in this app is newer than the one installed in
    /// `/Library/Audio/Plug-Ins/HAL`. Reinstalling needs admin and restarts coreaudiod (drops
    /// audio briefly), so this is only ever offered, never applied automatically.
    @Published var updateAvailable: Bool = false

    static let driverPath = "/Library/Audio/Plug-Ins/HAL/Loopbacker.driver"

    init() {
        checkInstallation()
        checkForDriverUpdate()
    }

    func checkInstallation() {
        isInstalled = FileManager.default.fileExists(atPath: Self.driverPath)
        statusMessage = isInstalled ? "Driver installed" : "Driver not installed"
    }

    /// Compares the bundled driver's version against the installed one. Call again after
    /// install/uninstall, since both change which versions are being compared.
    func checkForDriverUpdate() {
        guard isInstalled,
              let bundledPath = findDriverBundle(),
              let bundledVersion = Self.driverVersion(atBundlePath: bundledPath),
              let installedVersion = Self.driverVersion(atBundlePath: Self.driverPath)
        else {
            updateAvailable = false
            return
        }
        updateAvailable = Self.isVersion(bundledVersion, newerThan: installedVersion)
    }

    private static func driverVersion(atBundlePath path: String) -> String? {
        let plistPath = (path as NSString).appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOfFile: plistPath) else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    /// Dotted-numeric comparison (e.g. "0.2.0" > "0.1.0"); missing components count as 0.
    /// Internal (not private) so `LoopbackerTests` can exercise it directly.
    nonisolated static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let lhsParts = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let rhsParts = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhsParts.count, rhsParts.count) {
            let l = index < lhsParts.count ? lhsParts[index] : 0
            let r = index < rhsParts.count ? rhsParts[index] : 0
            if l != r { return l > r }
        }
        return false
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
                checkForDriverUpdate()
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
                checkForDriverUpdate()
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
