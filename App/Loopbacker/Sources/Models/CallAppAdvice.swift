import AppKit
import Foundation

/// Advice for turning off a call app's own noise/echo/gain processing so it doesn't fight
/// Loopbacker's. Phrased as menu paths, not exact labels we can't verify app-version-to-app-
/// version -- apps move these settings around across releases.
struct CallAppAdvice: Identifiable, Sendable {
    let id: String // bundle id
    let appName: String
    let advice: String
}

/// Native call apps only: a browser running Meet/Webex/FaceTime in a tab can't be told apart
/// from any other page the user has open, so there's nothing reliable to detect or advise.
enum CallAppAdviceCatalog {
    static let all: [CallAppAdvice] = [
        CallAppAdvice(
            id: "us.zoom.xos", appName: "Zoom",
            advice: "In Zoom's audio settings, turn on \"Original sound for musicians\" and turn off its "
                + "background noise suppression -- Loopbacker's own noise suppression and effects chain "
                + "already clean up and level your voice, and Zoom's processing on top of that fights it."
        ),
        CallAppAdvice(
            id: "com.hnc.Discord", appName: "Discord",
            advice: "In Discord's Voice & Video settings, turn off Krisp noise suppression, echo "
                + "cancellation and automatic gain control -- Loopbacker already handles noise "
                + "suppression, echo cancellation and loudness leveling, and Discord's own copies of "
                + "those fight them."
        ),
        CallAppAdvice(
            id: "com.microsoft.teams2", appName: "Microsoft Teams",
            advice: "In Teams' audio device settings, set noise suppression to Off or Low -- "
                + "Loopbacker's own noise suppression already cleans up the signal, and Teams' default "
                + "(high) processing on top of that can sound over-compressed and unnatural."
        ),
        CallAppAdvice(
            id: "com.tinyspeck.slackmacgap", appName: "Slack",
            advice: "If a Slack huddle sounds over-processed, look for an automatic noise reduction or "
                + "gain control toggle in its audio & video settings and turn it off -- Loopbacker's "
                + "effects chain already handles cleanup and leveling."
        ),
    ]

    /// `all` filtered to apps currently running, in the order they're listed above.
    @MainActor
    static func running() -> [CallAppAdvice] {
        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return all.filter { runningIDs.contains($0.id) }
    }
}
