import SwiftUI

/// Content of the floating muted/PTT overlay badge. Red (`signalHot`) reads as a fault/attention
/// state under the Fault Colors Are Reserved Rule -- DESIGN.md explicitly carves out "a
/// muted-source mute button" for `signalWarm`/`signalHot`, and a muted mic is exactly that state
/// surfaced outside the window, so this overlay keeps the same color rather than inventing a
/// second meaning for red. Held-and-live (push-to-talk engaged) uses Loopbacker green instead,
/// since "mic is live" is the one thing the accent is reserved for.
struct MutedOverlayView: View {
    enum State: Equatable {
        /// Mic is muted (open mode, or push-to-talk/push-to-mute idle).
        case muted
        /// A push-to-talk/push-to-mute key is held and the mic is live.
        case pushToTalkLive
    }

    let state: State

    private var symbol: String {
        switch state {
        case .muted: "mic.slash.fill"
        case .pushToTalkLive: "mic.fill"
        }
    }

    private var title: String {
        switch state {
        case .muted: "Muted"
        case .pushToTalkLive: "PTT"
        }
    }

    private var tint: Color {
        switch state {
        case .muted: .signalHot
        case .pushToTalkLive: .loopbacker
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.callout.weight(.semibold))
            Text(title)
                .font(.callout.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(tint.gradient, in: Capsule())
        .glassEffect(.regular.tint(tint).interactive(false), in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title == "PTT" ? "Push to talk, mic live" : "Mic muted")
        .fixedSize()
    }
}

/// Corner the overlay floats in, persisted in Settings › General.
enum MutedOverlayCorner: String, Codable, CaseIterable, Identifiable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeading: "Top Left"
        case .topTrailing: "Top Right"
        case .bottomLeading: "Bottom Left"
        case .bottomTrailing: "Bottom Right"
        }
    }

    /// The panel's origin for a screen `frame`, given the badge's rendered `size` and a margin
    /// from the screen edge.
    func origin(screenFrame: CGRect, size: CGSize, margin: CGFloat = 16) -> CGPoint {
        let x: CGFloat
        let y: CGFloat
        switch self {
        case .topLeading, .bottomLeading:
            x = screenFrame.minX + margin
        case .topTrailing, .bottomTrailing:
            x = screenFrame.maxX - size.width - margin
        }
        switch self {
        case .topLeading, .topTrailing:
            y = screenFrame.maxY - size.height - margin
        case .bottomLeading, .bottomTrailing:
            y = screenFrame.minY + margin
        }
        return CGPoint(x: x, y: y)
    }
}
