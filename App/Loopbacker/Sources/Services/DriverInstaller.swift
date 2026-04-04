import Foundation
import Combine

class DriverInstaller: ObservableObject {
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
            DispatchQueue.main.async {
                self.isProcessing = false
                self.statusMessage = "Driver bundle not found. Run 'make driver' first."
            }
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

        runAppleScript(script) { [weak self] success in
            DispatchQueue.main.async {
                self?.isProcessing = false
                if success {
                    self?.isInstalled = true
                    self?.statusMessage = "Driver installed successfully"
                } else {
                    self?.statusMessage = "Installation failed"
                }
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

        runAppleScript(script) { [weak self] success in
            DispatchQueue.main.async {
                self?.isProcessing = false
                if success {
                    self?.isInstalled = false
                    self?.statusMessage = "Driver uninstalled"
                } else {
                    self?.statusMessage = "Uninstall failed"
                }
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

    private func runAppleScript(_ source: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]

            let pipe = Pipe()
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                completion(process.terminationStatus == 0)
            } catch {
                completion(false)
            }
        }
    }
}
