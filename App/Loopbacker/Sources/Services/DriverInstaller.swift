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

    /// Compares the bundled driver's code against the installed one by content, not version --
    /// `Driver/CMakeLists.txt`'s `PROJECT_VERSION` is a hardcoded placeholder, not bumped per
    /// release, so `CFBundleShortVersionString` can't tell two builds apart. Call again after
    /// install/uninstall, since both change which installed copy is being compared.
    func checkForDriverUpdate() {
        guard isInstalled, let bundledPath = findDriverBundle() else {
            updateAvailable = false
            return
        }
        let installedPath = Self.driverPath
        Task {
            updateAvailable = await Self.driverContentDiffers(bundledPath: bundledPath, installedPath: installedPath)
        }
    }

    /// Hashes every section's content (except `__LINKEDIT`) of each driver's executable off the
    /// main thread and compares them. A content hash of all sections -- not the whole file, not
    /// just `__TEXT,__text`, and not codesign's CDHash -- is required here: `install()` re-signs
    /// the installed copy ad-hoc, which can change the embedded codesign CDHash and definitely
    /// changes the file bytes, even when the underlying code and data (strings, constant tables,
    /// etc) are identical.
    private nonisolated static func driverContentDiffers(bundledPath: String, installedPath: String) async -> Bool {
        await Task.detached(priority: .utility) {
            let bundledExecutable = (bundledPath as NSString).appendingPathComponent("Contents/MacOS/Loopbacker")
            let installedExecutable = (installedPath as NSString).appendingPathComponent("Contents/MacOS/Loopbacker")
            guard let bundledDigest = MachOTextHasher.contentDigest(ofExecutableAt: bundledExecutable),
                  let installedDigest = MachOTextHasher.contentDigest(ofExecutableAt: installedExecutable)
            else { return false }
            return bundledDigest != installedDigest
        }.value
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
