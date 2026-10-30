import SwiftUI

/// Ducking and leveling for app-capture routes (game, music, browser), separate from the voice
/// chain. A live duck-gain meter shows how far app audio is currently pulled down. Also hosts
/// "Duck what I hear" (Part B): lowering apps like Spotify or a browser on the user's own
/// output while people in a call are talking.
struct AppAudioSection: View {
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var callDuckSettings: CallDuckSettings
    @EnvironmentObject var callAudioMonitor: CallAudioMonitor
    @EnvironmentObject var listenDucker: ListenDucker
    @EnvironmentObject var appCaptureService: AppCaptureService

    private var appAudio: AppAudioFX { routingState.effectsPreset.appAudio }

    private func binding<T>(_ keyPath: WritableKeyPath<AppAudioFX, T>) -> Binding<T> {
        Binding(
            get: { routingState.effectsPreset.appAudio[keyPath: keyPath] },
            set: { routingState.effectsPreset.appAudio[keyPath: keyPath] = $0; routingState.save() }
        )
    }

    /// Apps `callDuckSettings.extraCallAppBundleIDs`/`CallAppAdviceCatalog` currently count as
    /// "a call" -- excluded from the "duck what I hear" app picker (ducking a call app on the
    /// user's own output would duck the call itself) same as `ListenDucker.sanitizedBundleIDs`
    /// excludes them when actually building the tap.
    private var currentCallAppBundleIDs: Set<String> {
        Set(CallAppAdviceCatalog.all.map(\.id)).union(callDuckSettings.extraCallAppBundleIDs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.panelSpacing) {
            Text("App Audio").font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.to.line.compact")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(appAudio.duckingEnabled ? Color.loopbacker : Color.secondary)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Ducking").font(.headline)
                        Text("Pulls game/music/browser audio down while you're talking.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(isOn: binding(\.duckingEnabled)) {
                        Text(appAudio.duckingEnabled ? "On" : "Off").font(.caption.weight(.semibold))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(.loopbacker)
                }

                if appAudio.duckingEnabled {
                    triggerPicker
                    duckGainMeter
                    ParameterSliderRow(label: "Amount", description: "How far app audio is pulled down while the trigger is active",
                                       value: binding(\.duckAmountDB), range: AppAudioFX.duckAmountRange, unit: "dB")
                    ParameterSliderRow(label: "Attack", description: "How fast ducking kicks in",
                                       value: binding(\.duckAttackMs), range: 5...500, unit: "ms")
                    ParameterSliderRow(label: "Release", description: "How fast app audio returns after the trigger stops",
                                       value: binding(\.duckReleaseMs), range: 50...2000, unit: "ms")
                }
            }
            .padding(Metrics.panelPadding)
            .glassPanel(cornerRadius: Metrics.panelRadius, tint: appAudio.duckingEnabled ? Color.loopbacker.opacity(0.08) : nil)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "chart.bar.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(appAudio.levelerEnabled ? Color.loopbacker : Color.secondary)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("App Leveler").font(.headline)
                        Text("Holds app audio at a consistent loudness.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(isOn: binding(\.levelerEnabled)) {
                        Text(appAudio.levelerEnabled ? "On" : "Off").font(.caption.weight(.semibold))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(.loopbacker)
                }

                if appAudio.levelerEnabled {
                    ParameterSliderRow(label: "Target", description: "Loudness to hold app audio at",
                                       value: binding(\.levelerTarget), range: -30 ... -10, unit: "LUFS")
                }
            }
            .padding(Metrics.panelPadding)
            .glassPanel(cornerRadius: Metrics.panelRadius, tint: appAudio.levelerEnabled ? Color.loopbacker.opacity(0.08) : nil)

            listenDuckPanel
        }
    }

    /// What counts as "someone's talking" for Part A ducking: the user's own mic, far-end call
    /// voices, or both. Only shown while ducking is on.
    private var triggerPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Trigger").font(.caption).foregroundStyle(.secondary)
            Picker("Trigger", selection: binding(\.trigger)) {
                Text("My voice").tag(CallDuckTrigger.myVoice)
                Text("Call voices").tag(CallDuckTrigger.callVoices)
                Text("Both").tag(CallDuckTrigger.both)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if appAudio.trigger.dependsOnCallVoices {
                callMonitorStatusRow
            }
        }
    }

    /// Live duck-gain meter driven by `AppAudioDuckBus`, the actual gain `AppAudioProcessor`
    /// applied on its IO thread (not inferred from app-signal presence: silent app audio or a
    /// release still in progress both show the real current reduction).
    private var duckGainMeter: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { _ in
            let duckGainDB = min(0, fxLinearToDB(AppAudioDuckBus.gain()))
            let lowerBound = AppAudioFX.duckAmountRange.lowerBound
            let fraction = lowerBound == 0 ? 0 : min(max(duckGainDB / lowerBound, 0), 1)

            HStack(spacing: 10) {
                Text("Duck Gain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                GeometryReader { geo in
                    ZStack(alignment: .trailing) {
                        RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.5))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.loopbacker.opacity(0.65))
                            .frame(width: max(2, CGFloat(fraction) * geo.size.width))
                            .animation(.linear(duration: 0.15), value: duckGainDB)
                    }
                }
                .frame(height: 10)
                Text(String(format: "%.1f dB", duckGainDB))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Current duck gain, \(String(format: "%.1f", duckGainDB)) dB")
        }
    }

    // MARK: - Duck what I hear (Part B)

    private var listenDuckPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "ear.trianglebadge.exclamationmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(callDuckSettings.listenDuckEnabled ? Color.loopbacker : Color.secondary)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Duck What I Hear").font(.headline)
                    Text("Lowers apps like Spotify or a browser on your own speakers/headphones while people in a call are talking.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle(isOn: Binding(
                    get: { callDuckSettings.listenDuckEnabled },
                    set: { callDuckSettings.listenDuckEnabled = $0; callDuckSettings.save() }
                )) {
                    Text(callDuckSettings.listenDuckEnabled ? "On" : "Off").font(.caption.weight(.semibold))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.loopbacker)
            }

            if callDuckSettings.listenDuckEnabled {
                listenDuckStatusRow
                ParameterSliderRow(
                    label: "Amount", description: "How far ducked apps are pulled down",
                    value: Binding(
                        get: { callDuckSettings.listenDuckAmountDB },
                        set: { callDuckSettings.listenDuckAmountDB = $0; callDuckSettings.save() }),
                    range: CallDuckSettings.duckAmountRange, unit: "dB")

                Toggle(isOn: Binding(
                    get: { callDuckSettings.listenDuckTrigger == .both },
                    set: { callDuckSettings.listenDuckTrigger = $0 ? .both : .callVoices; callDuckSettings.save() }
                )) {
                    Text("Also duck while I'm talking").font(.caption)
                }
                .toggleStyle(.checkbox)

                appPicker
            }
        }
        .padding(Metrics.panelPadding)
        .glassPanel(cornerRadius: Metrics.panelRadius, tint: callDuckSettings.listenDuckEnabled ? Color.loopbacker.opacity(0.08) : nil)
    }

    private var appPicker: some View {
        let candidates = appCaptureService.availableApps.filter {
            !currentCallAppBundleIDs.contains($0.id) && $0.id != Bundle.main.bundleIdentifier
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Apps to duck").font(.caption).foregroundStyle(.secondary)
            if candidates.isEmpty {
                Text("No other apps are producing audio right now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(candidates) { app in
                    Toggle(isOn: Binding(
                        get: { callDuckSettings.listenDuckBundleIDs.contains(app.id) },
                        set: { isOn in
                            if isOn {
                                if !callDuckSettings.listenDuckBundleIDs.contains(app.id) {
                                    callDuckSettings.listenDuckBundleIDs.append(app.id)
                                }
                            } else {
                                callDuckSettings.listenDuckBundleIDs.removeAll { $0 == app.id }
                            }
                            callDuckSettings.save()
                        }
                    )) {
                        HStack(spacing: 6) {
                            if let icon = app.icon {
                                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                            }
                            Text(app.name).font(.caption)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    @ViewBuilder
    private var callMonitorStatusRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch callAudioMonitor.permission {
            case .denied:
                statusExplainer(icon: "lock.fill", text: "System Audio Recording permission was denied; call-voice ducking can't hear the call.", tint: .orange)
            default:
                switch callAudioMonitor.state {
                case .noCallAppRunning:
                    statusExplainer(icon: "person.slash", text: "No call app (Zoom, Discord, Teams, Slack) is running right now.", tint: .secondary)
                case .failed(let error):
                    statusExplainer(icon: "exclamationmark.triangle.fill", text: error.errorDescription ?? "The call audio monitor failed to start.", tint: .orange)
                case .running, .stopped:
                    EmptyView()
                }
            }
            extraCallAppPicker
        }
    }

    /// Browsers and other non-catalog apps only become a far-end "call" source once the user
    /// explicitly adds them here (see `CallAudioMonitor`'s class doc for why: a browser tab
    /// running a web call can't be told apart from any other tab). Only running apps are
    /// offered, and never a currently-ducked app (that would make "duck what I hear" and "this
    /// is a call" contradict each other for the same app).
    private var extraCallAppPicker: some View {
        let candidates = appCaptureService.availableApps.filter {
            !CallAppAdviceCatalog.all.map(\.id).contains($0.id)
                && !callDuckSettings.listenDuckBundleIDs.contains($0.id)
                && $0.id != Bundle.main.bundleIdentifier
        }
        return DisclosureGroup("Also treat a running app as a call (e.g. a browser tab)") {
            if candidates.isEmpty {
                Text("No other apps are producing audio right now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(candidates) { app in
                    Toggle(isOn: Binding(
                        get: { callDuckSettings.extraCallAppBundleIDs.contains(app.id) },
                        set: { isOn in
                            if isOn {
                                callDuckSettings.extraCallAppBundleIDs.insert(app.id)
                            } else {
                                callDuckSettings.extraCallAppBundleIDs.remove(app.id)
                            }
                            callDuckSettings.save()
                        }
                    )) {
                        Text(app.name).font(.caption)
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private var listenDuckStatusRow: some View {
        switch listenDucker.permission {
        case .denied:
            statusExplainer(icon: "lock.fill", text: "System Audio Recording permission was denied; Loopbacker can't replay ducked apps' audio.", tint: .orange)
        default:
            switch listenDucker.state {
            case .noPhysicalOutput:
                statusExplainer(icon: "speaker.slash", text: "Your default output isn't a physical speaker right now.", tint: .secondary)
            case .noAppsSelected:
                statusExplainer(icon: "app.dashed", text: "Pick at least one app below to duck.", tint: .secondary)
            case .failed(let error):
                statusExplainer(icon: "exclamationmark.triangle.fill", text: error.errorDescription ?? "Listen ducking failed to start.", tint: .orange)
            case .running, .stopped:
                EmptyView()
            }
        }
    }

    private func statusExplainer(icon: String, text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

