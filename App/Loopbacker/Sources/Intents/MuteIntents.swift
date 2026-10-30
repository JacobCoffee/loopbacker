import AppIntents

struct ToggleMuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Mic Mute"
    static let description = IntentDescription("Mutes or unmutes the Loopbacker virtual mic.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard ControlCenter.shared.toggleMute() else { throw ControlIntentError.notReady }
        let muted = ControlCenter.shared.isMuted
        return .result(dialog: muted ? "Muted" : "Unmuted")
    }
}

struct SetMuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Mic Mute"
    static let description = IntentDescription("Mutes or unmutes the Loopbacker virtual mic.")

    @Parameter(title: "Muted")
    var muted: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Set mic mute to \(\.$muted)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard ControlCenter.shared.setMuted(muted) else { throw ControlIntentError.notReady }
        return .result(dialog: muted ? "Muted" : "Unmuted")
    }
}
