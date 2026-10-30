import Foundation
import os.log

private let urlCommandLogger = Logger(subsystem: "com.jacobcoffee.loopbacker", category: "URLCommand")

/// A parsed `loopbacker://` URL command. Parsing is pure (no AppKit/environment) so it's
/// testable without the app running; `URLCommandRouter` dispatches the result through
/// `ControlCenter`.
enum LoopbackerURLCommand: Equatable {
    case mute
    case unmute
    case toggleMute
    case preset(id: String)
    case scene(name: String)
    case effects(on: Bool)

    /// Parses `loopbacker://mute`, `unmute`, `toggle-mute`, `preset?id=…`, `scene?name=…`,
    /// `effects?on=1`. The host carries the command name; everything else is invalid and
    /// returns `nil` so the caller can log-and-ignore per the contract (unknown → log + ignore).
    static func parse(_ url: URL) -> LoopbackerURLCommand? {
        guard url.scheme?.lowercased() == "loopbacker" else { return nil }
        // `loopbacker://mute` parses "mute" as the host; `loopbacker:mute` (no slashes) parses
        // it as the path instead. Accept either shape.
        let command = (url.host ?? "").isEmpty
            ? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : (url.host ?? "")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            query.first { $0.name == name }?.value?.removingPercentEncoding
        }

        switch command.lowercased() {
        case "mute": return .mute
        case "unmute": return .unmute
        case "toggle-mute", "togglemute": return .toggleMute
        case "preset":
            guard let id = value("id"), !id.isEmpty else { return nil }
            return .preset(id: id)
        case "scene":
            guard let name = value("name"), !name.isEmpty else { return nil }
            return .scene(name: name)
        case "effects":
            guard let raw = value("on") else { return nil }
            switch raw.lowercased() {
            case "1", "true", "yes", "on": return .effects(on: true)
            case "0", "false", "no", "off": return .effects(on: false)
            default: return nil
            }
        default:
            return nil
        }
    }
}

/// Dispatches parsed URL commands through `ControlCenter`. Separate from parsing so the pure
/// parser stays trivially testable while this side carries the (untestable-without-the-app)
/// dispatch logic.
@MainActor
enum URLCommandRouter {

    /// Handles every URL the system hands the app via `application(_:open:)`. Unknown or
    /// malformed URLs are logged and ignored, never crash or surface UI.
    static func handle(_ urls: [URL]) {
        for url in urls { handle(url) }
    }

    static func handle(_ url: URL) {
        guard let command = LoopbackerURLCommand.parse(url) else {
            urlCommandLogger.log("Ignoring unrecognized URL: \(url.absoluteString, privacy: .public)")
            return
        }
        switch command {
        case .mute: ControlCenter.shared.setMuted(true)
        case .unmute: ControlCenter.shared.setMuted(false)
        case .toggleMute: ControlCenter.shared.toggleMute()
        case .preset(let id):
            if !ControlCenter.shared.applyPreset(id: id) {
                urlCommandLogger.log("Ignoring URL preset command for unknown preset id '\(id, privacy: .public)'")
            }
        case .scene(let name):
            if !ControlCenter.shared.loadScene(name: name) {
                urlCommandLogger.log("Ignoring URL scene command for unknown scene '\(name, privacy: .public)'")
            }
        case .effects(let on):
            ControlCenter.shared.setEffectsEnabled(on)
        }
    }
}
