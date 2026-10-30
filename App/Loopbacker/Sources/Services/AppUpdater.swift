import AppKit
import Combine
import Sparkle

/// A found update waiting on the user (or app quit) to decide what happens next. Sparkle keeps
/// its session open until `reply` is invoked with a choice. `AppUpdater` is the only caller and
/// always nils out its `availableUpdate` reference before invoking `install()`/`dismiss()`, so the
/// closure captured here is never called twice even if two call sites race (click + quit hook).
struct AvailableAppUpdate {
    let displayVersion: String
    let isUserInitiated: Bool
    let isAlreadyDownloaded: Bool
    private let reply: (SPUUserUpdateChoice) -> Void

    init(appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        displayVersion = appcastItem.displayVersionString
        isUserInitiated = state.userInitiated
        isAlreadyDownloaded = state.stage != .notDownloaded
        self.reply = reply
    }

    func install() { reply(.install) }
    func dismiss() { reply(.dismiss) }
}

/// Drives Sparkle without its own windows. Background checks stay silent: an available update
/// surfaces only as state the menu bar panel and app menu read. A check the user started from
/// "Check for Updates…" that finds one asks right away (Install and Relaunch / Later), so they
/// don't have to reopen the menu. Installing happens only when the user says so, or
/// automatically when the app quits with an update already downloaded and waiting.
@MainActor
final class AppUpdater: NSObject, ObservableObject {
    /// One instance for the app's lifetime; the `AppDelegate` installs a pending update on quit
    /// without needing SwiftUI environment injection, same as `DefaultDeviceRestorer.shared`.
    static let shared = AppUpdater()

    @Published private(set) var availableUpdate: AvailableAppUpdate?
    /// Set once `availableUpdate` has been consumed by `installAvailableUpdate()` or
    /// `installPendingUpdateOnQuit()`, until the session ends. The menu bar panel and app menu
    /// show this as a non-actionable "Installing…" row instead of the dismissed Install button.
    @Published private(set) var installingVersion: String?
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var lastCheckError: String?
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var didFindNoUpdate = false
    /// True once we've told Sparkle to install (`reply(.install)`), until the process exits.
    /// `AppDelegate.applicationShouldTerminate` honors Sparkle's own termination request
    /// unconditionally while this is set, instead of treating it like a user-initiated quit.
    private(set) var isTerminatingForUpdate = false

    private var pendingTerminationRetry: (() -> Void)?
    private var canCheckForUpdatesObservation: NSKeyValueObservation?

    private lazy var userDriver = GentleUserDriver(
        onUpdateFound: { [weak self] update in
            guard let self else { return }
            availableUpdate = update
            installingVersion = nil
            didFindNoUpdate = false
            if update.isUserInitiated {
                // Out of Sparkle's callback, so the modal alert doesn't run inside it.
                Task { @MainActor in self.promptToInstall(update.displayVersion) }
            }
        },
        onDownloadProgress: { [weak self] downloading, progress in
            self?.isDownloading = downloading
            self?.downloadProgress = progress
        },
        onNoUpdateFound: { [weak self] in
            self?.didFindNoUpdate = true
        },
        onError: { [weak self] message in
            self?.lastCheckError = message
        },
        onInstalling: { [weak self] applicationTerminated, retryTerminatingApplication in
            guard let self else { return }
            isDownloading = true
            downloadProgress = nil
            guard !applicationTerminated else {
                pendingTerminationRetry = nil
                return
            }
            pendingTerminationRetry = retryTerminatingApplication
            // We already agreed to quit (isTerminatingForUpdate, set before `install()` was
            // called); if Sparkle's termination request didn't go through yet, ask it to try
            // again instead of leaving the install stuck waiting on a quit that never happens.
            if isTerminatingForUpdate {
                retryTerminatingApplication()
            }
        },
        onSessionEnded: { [weak self] in
            self?.availableUpdate = nil
            self?.installingVersion = nil
            self?.isDownloading = false
            self?.downloadProgress = nil
            self?.pendingTerminationRetry = nil
        }
    )

    private lazy var updater = SPUUpdater(
        hostBundle: Bundle.main,
        applicationBundle: Bundle.main,
        userDriver: userDriver,
        delegate: nil
    )

    override init() {
        super.init()
        do {
            try updater.start()
        } catch {
            lastCheckError = "Updater didn't start: \(error.localizedDescription)"
        }
        canCheckForUpdates = updater.canCheckForUpdates
        // Sparkle flips `canCheckForUpdates` false synchronously when a check starts and true
        // again asynchronously once the session ends; observe it instead of snapshotting once.
        canCheckForUpdatesObservation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            guard let newValue = change.newValue else { return }
            Task { @MainActor in
                self?.canCheckForUpdates = newValue
            }
        }
    }

    /// User-initiated check from the app menu or menu bar panel.
    func checkForUpdates() {
        didFindNoUpdate = false
        lastCheckError = nil
        updater.checkForUpdates()
    }

    func installAvailableUpdate() {
        guard let update = availableUpdate else { return }
        availableUpdate = nil
        installingVersion = update.displayVersion
        isTerminatingForUpdate = true
        update.install()
    }

    func dismissAvailableUpdate() {
        guard let update = availableUpdate else { return }
        availableUpdate = nil
        update.dismiss()
    }

    /// Asks once after a user-started check finds an update. "Later" leaves it pending, so the
    /// menu still offers Install and quitting still installs it.
    private func promptToInstall(_ version: String) {
        guard availableUpdate?.displayVersion == version else { return }
        let alert = NSAlert()
        alert.messageText = "Loopbacker \(version) is available"
        alert.informativeText = "Installing quits and relaunches Loopbacker. Your audio routes stop for a few seconds."
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        installAvailableUpdate()
    }

    /// Called from `applicationShouldTerminate`. If an update already finished downloading and is
    /// just waiting on the user, install it now so it's ready next launch; Sparkle's helper tool
    /// finishes the install after this process exits. No-ops if nothing is pending, or if it was
    /// already consumed by a racing `installAvailableUpdate()` call.
    func installPendingUpdateOnQuit() {
        guard let update = availableUpdate, update.isAlreadyDownloaded else { return }
        availableUpdate = nil
        installingVersion = update.displayVersion
        isTerminatingForUpdate = true
        update.install()
    }
}

/// `SPUUserDriver` implementation with no UI of its own. It reports everything through closures so
/// `AppUpdater` can publish state for SwiftUI to read; it never shows an alert, sheet, or window.
@MainActor
private final class GentleUserDriver: NSObject, SPUUserDriver {
    private let onUpdateFound: (AvailableAppUpdate) -> Void
    private let onDownloadProgress: (Bool, Double?) -> Void
    private let onNoUpdateFound: () -> Void
    private let onError: (String) -> Void
    private let onInstalling: (Bool, @escaping () -> Void) -> Void
    private let onSessionEnded: () -> Void

    private var expectedContentLength: UInt64 = 0
    private var receivedContentLength: UInt64 = 0

    init(
        onUpdateFound: @escaping (AvailableAppUpdate) -> Void,
        onDownloadProgress: @escaping (Bool, Double?) -> Void,
        onNoUpdateFound: @escaping () -> Void,
        onError: @escaping (String) -> Void,
        onInstalling: @escaping (Bool, @escaping () -> Void) -> Void,
        onSessionEnded: @escaping () -> Void
    ) {
        self.onUpdateFound = onUpdateFound
        self.onDownloadProgress = onDownloadProgress
        self.onNoUpdateFound = onNoUpdateFound
        self.onError = onError
        self.onInstalling = onInstalling
        self.onSessionEnded = onSessionEnded
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // SUEnableAutomaticChecks in Info.plist normally skips this entirely; answer silently if
        // it's ever reached so nothing is ever shown to the user.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        // No progress window; the menu bar panel reflects state once something changes.
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        onUpdateFound(AvailableAppUpdate(appcastItem: appcastItem, state: state, reply: reply))
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        onNoUpdateFound()
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        onError(error.localizedDescription)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedContentLength = 0
        receivedContentLength = 0
        onDownloadProgress(true, nil)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        self.expectedContentLength = expectedContentLength
        onDownloadProgress(true, 0)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedContentLength += length
        guard expectedContentLength > 0 else { return }
        onDownloadProgress(true, Double(receivedContentLength) / Double(expectedContentLength))
    }

    func showDownloadDidStartExtractingUpdate() {
        onDownloadProgress(true, nil)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        onDownloadProgress(true, progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Reached after the user already chose Install from `showUpdateFound`. Proceed right away
        // -- the user already made their decision; no second prompt.
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        onInstalling(applicationTerminated, retryTerminatingApplication)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        onSessionEnded()
    }
}
