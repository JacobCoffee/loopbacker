import AppIntents

/// Errors App Intents (and the URL scheme's ControlCenter calls) surface to Shortcuts.
enum ControlIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady
    case unknownPreset
    case unknownScene

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: "Loopbacker isn't ready yet. Open the app and try again."
        case .unknownPreset: "That effects preset couldn't be found."
        case .unknownScene: "That scene couldn't be found."
        }
    }
}
