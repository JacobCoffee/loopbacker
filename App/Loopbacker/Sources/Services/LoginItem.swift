import AppKit
import ServiceManagement
import os.log

private let loginLogger = Logger(subsystem: "com.jacobcoffee.loopbacker", category: "LoginItem")

/// Open at Login, through `SMAppService.mainApp`. The system owns the state (the user can also
/// change it in System Settings › General › Login Items), so it's read back rather than stored.
@MainActor
final class LoginItem: ObservableObject {
    static let shared = LoginItem()

    @Published private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    /// The last register/unregister failure, for the UI.
    @Published private(set) var error: String?

    /// On, or on but waiting for the user to allow it in System Settings.
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    func setEnabled(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            loginLogger.error("Open at Login \(on ? "register" : "unregister") failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
        refresh()
    }

    /// Re-reads the system's state (it may have changed in System Settings).
    func refresh() {
        status = SMAppService.mainApp.status
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Whether this process was started as a login item. Only meaningful while the launch
    /// Apple event is being handled (`applicationWillFinishLaunching`/`DidFinishLaunching`).
    static func isLaunchingAtLogin() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
