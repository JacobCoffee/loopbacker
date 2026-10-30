import Foundation
import Combine
import Sparkle

/// A found update waiting on the user (or app quit) to decide what happens next. Sparkle keeps
/// its session open until `reply` is invoked with a choice.
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

/// Drives Sparkle without ever putting a window in front of the user. Update checks happen in the
/// background; an available update surfaces only as state the menu bar panel and app menu read.
/// Installing happens only when the user clicks Install, or automatically when the app quits with
/// an update already downloaded and waiting.
@MainActor
final class AppUpdater: NSObject, ObservableObject {
    /// One instance for the app's lifetime; the `AppDelegate` installs a pending update on quit
    /// without needing SwiftUI environment injection, same as `DefaultDeviceRestorer.shared`.
    static let shared = AppUpdater()

    @Published private(set) var availableUpdate: AvailableAppUpdate?
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var lastCheckError: String?
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var didFindNoUpdate = false

    private lazy var userDriver = GentleUserDriver(
        onUpdateFound: { [weak self] update in
            self?.availableUpdate = update
            self?.didFindNoUpdate = false
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
        onSessionEnded: { [weak self] in
            self?.availableUpdate = nil
            self?.isDownloading = false
            self?.downloadProgress = nil
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
    }

    /// User-initiated check from the app menu or menu bar panel.
    func checkForUpdates() {
        didFindNoUpdate = false
        lastCheckError = nil
        updater.checkForUpdates()
        canCheckForUpdates = updater.canCheckForUpdates
    }

    func installAvailableUpdate() {
        availableUpdate?.install()
    }

    func dismissAvailableUpdate() {
        availableUpdate?.dismiss()
    }

    /// Called from `applicationShouldTerminate`. If an update already finished downloading and is
    /// just waiting on the user, install it now so it's ready next launch; Sparkle's helper tool
    /// finishes the install after this process exits.
    func installPendingUpdateOnQuit() {
        guard let update = availableUpdate, update.isAlreadyDownloaded else { return }
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
    private let onSessionEnded: () -> Void

    private var expectedContentLength: UInt64 = 0
    private var receivedContentLength: UInt64 = 0

    init(
        onUpdateFound: @escaping (AvailableAppUpdate) -> Void,
        onDownloadProgress: @escaping (Bool, Double?) -> Void,
        onNoUpdateFound: @escaping () -> Void,
        onError: @escaping (String) -> Void,
        onSessionEnded: @escaping () -> Void
    ) {
        self.onUpdateFound = onUpdateFound
        self.onDownloadProgress = onDownloadProgress
        self.onNoUpdateFound = onNoUpdateFound
        self.onError = onError
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
        onDownloadProgress(true, nil)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        onSessionEnded()
    }
}
