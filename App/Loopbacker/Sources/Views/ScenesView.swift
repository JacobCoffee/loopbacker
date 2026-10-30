import AppKit
import SwiftUI

struct ScenesView: View {
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var audioRouter: AudioRouter
    @EnvironmentObject var audioDeviceManager: AudioDeviceManager
    @EnvironmentObject var sceneLoader: SceneLoader
    @EnvironmentObject var rulesState: AutomationRulesState
    @EnvironmentObject var automationRulesEngine: AutomationRulesEngine

    @State private var presetNames: [String] = []
    @State private var newPresetName: String = ""
    @State private var showSavePopover = false

    @State private var showAddRulePopover = false
    @State private var newRuleTriggerKind: RuleTriggerKind = .appLaunched
    @State private var newRuleAppBundleID: String = ""
    @State private var newRuleDeviceUID: String = ""
    @State private var newRuleSceneName: String = ""

    var body: some View {
        Group {
            if presetNames.isEmpty {
                emptyState
            } else {
                sceneList
            }
        }
        .navigationSubtitle("\(presetNames.count) saved")
        .toolbar { toolbarContent }
        .popover(isPresented: $showSavePopover, arrowEdge: .bottom) {
            savePopoverContent
        }
        .popover(isPresented: $showAddRulePopover, arrowEdge: .bottom) {
            addRulePopoverContent
        }
        .onAppear {
            presetNames = PresetManager.list()
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                newPresetName = ""
                showSavePopover = true
            } label: {
                Label("Save Current Config", systemImage: "plus.circle")
            }
        }
        GlobalToolbar()
    }

    private var savePopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save Scene")
                .font(.headline)

            TextField("Preset name", text: $newPresetName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit { savePreset() }

            HStack {
                Spacer()
                Button("Cancel") { showSavePopover = false }
                    .buttonStyle(.glass)
                    .tint(nil)
                Button("Save") { savePreset() }
                    .buttonStyle(.glassProminent)
                    .tint(.loopbacker)
                    .disabled(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }

    // MARK: - Scene list

    private var sceneList: some View {
        List {
            activeRuleRow

            Section("Scenes") {
                ForEach(presetNames, id: \.self) { name in
                    sceneRow(name: name)
                }
            }

            Section("Automation") {
                rulesPausedRow
                fallbackScenePicker

                if rulesState.rules.isEmpty {
                    Text("No rules yet. Add one to switch scenes automatically when an app runs, becomes frontmost, or a device connects.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rulesState.rules) { rule in
                        ruleRow(rule)
                    }
                }

                Button {
                    resetAddRuleForm()
                    showAddRulePopover = true
                } label: {
                    Label("Add Rule", systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .tint(.loopbacker)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var activeRuleRow: some View {
        if !rulesState.isPaused {
            if let rule = automationRulesEngine.activeRule {
                statusRow(symbol: "bolt.fill", text: "Active rule: \(rule.name)")
            } else if let fallback = rulesState.fallbackSceneName,
                      fallback == automationRulesEngine.lastAppliedSceneName {
                statusRow(symbol: "bolt.fill", text: "Fallback scene: \(fallback)")
            }
        }
    }

    private func statusRow(symbol: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(Color.loopbacker)
                .imageScale(.small)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    @ViewBuilder
    private var rulesPausedRow: some View {
        if rulesState.isPaused {
            HStack(spacing: 8) {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.secondary)
                Text("Rules paused until the matched condition changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Resume") {
                    rulesState.resume()
                    automationRulesEngine.evaluate()
                }
                .buttonStyle(.glass)
                .tint(nil)
                .controlSize(.small)
            }
            .help("Manually loading a scene pauses automation; resume to let rules take over again")
        }
    }

    private var fallbackScenePicker: some View {
        Picker("Fallback Scene", selection: Binding(
            get: { rulesState.fallbackSceneName ?? "" },
            set: { newValue in
                rulesState.fallbackSceneName = newValue.isEmpty ? nil : newValue
                rulesState.save()
                automationRulesEngine.evaluate()
            }
        )) {
            Text("None").tag("")
            ForEach(presetNames, id: \.self) { name in
                Text(name).tag(name)
            }
        }
        .pickerStyle(.menu)
        .help("Loaded when no rule matches")
    }

    private func sceneRow(name: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(Color.loopbacker)
                .frame(width: 20)

            Text(name)
                .font(.body.weight(.medium))
                .lineLimit(1)

            Spacer()

            Button("Load") { loadPreset(name: name) }
                .buttonStyle(.glass)
                .tint(.loopbacker)
                .help("Load the '\(name)' scene: shared routes keep running, only what changed is retargeted")

            Button(role: .destructive) {
                deletePreset(name: name)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete the '\(name)' scene")
            .accessibilityLabel("Delete \(name)")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Load") { loadPreset(name: name) }
            Button("Delete", role: .destructive) { deletePreset(name: name) }
        }
        .swipeActions {
            Button("Delete", role: .destructive) { deletePreset(name: name) }
        }
    }

    private func ruleRow(_ rule: AutomationRule) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { rulesState.setRuleEnabled(id: rule.id, isEnabled: $0); automationRulesEngine.evaluate() }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .tint(.loopbacker)
            .help(rule.isEnabled ? "Disable this rule" : "Enable this rule")

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                    .font(.callout)
                    .lineLimit(1)
                Text("\(rule.trigger.summary) → load “\(rule.action.sceneName ?? "?")”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if automationRulesEngine.activeRule?.id == rule.id {
                StatusTag(title: "Active", tint: .loopbacker, symbol: "checkmark.circle.fill")
            }

            Button(role: .destructive) {
                rulesState.removeRule(id: rule.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this rule")
            .accessibilityLabel("Delete rule \(rule.name)")
        }
        .padding(.vertical, 2)
    }

    // MARK: - Add Rule popover

    private var addRulePopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add Rule")
                .font(.headline)

            Picker("When", selection: $newRuleTriggerKind) {
                ForEach(RuleTriggerKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.menu)

            switch newRuleTriggerKind {
            case .appLaunched, .appQuit, .appFrontmost:
                Picker("App", selection: $newRuleAppBundleID) {
                    Text("Choose…").tag("")
                    ForEach(runningApps, id: \.bundleID) { app in
                        Text(app.name).tag(app.bundleID)
                    }
                }
                .pickerStyle(.menu)
            case .deviceAdded, .deviceRemoved:
                Picker("Device", selection: $newRuleDeviceUID) {
                    Text("Choose…").tag("")
                    ForEach(audioDeviceManager.systemDevices.filter(\.isInput)) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .pickerStyle(.menu)
            }

            Picker("Load Scene", selection: $newRuleSceneName) {
                Text("Choose…").tag("")
                ForEach(presetNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Spacer()
                Button("Cancel") { showAddRulePopover = false }
                    .buttonStyle(.glass)
                    .tint(nil)
                Button("Add") { addRule() }
                    .buttonStyle(.glassProminent)
                    .tint(.loopbacker)
                    .disabled(!canAddRule)
            }
        }
        .padding(16)
        .frame(width: 260)
    }

    private var canAddRule: Bool {
        guard !newRuleSceneName.isEmpty else { return false }
        switch newRuleTriggerKind {
        case .appLaunched, .appQuit, .appFrontmost: return !newRuleAppBundleID.isEmpty
        case .deviceAdded, .deviceRemoved: return !newRuleDeviceUID.isEmpty
        }
    }

    /// Apps running right now, as candidates for an app-based trigger. Uses `NSWorkspace`
    /// directly (not `AppCaptureService.availableApps`) so picking a trigger doesn't require
    /// Screen Recording permission.
    private var runningApps: [(bundleID: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app -> (bundleID: String, name: String)? in
                guard let bid = app.bundleIdentifier else { return nil }
                return (bundleID: bid, name: app.localizedName ?? bid)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func addRule() {
        guard canAddRule else { return }
        let trigger: RuleTrigger
        switch newRuleTriggerKind {
        case .appLaunched:
            trigger = .appLaunched(bundleID: newRuleAppBundleID, appName: appName(for: newRuleAppBundleID))
        case .appQuit:
            trigger = .appQuit(bundleID: newRuleAppBundleID, appName: appName(for: newRuleAppBundleID))
        case .appFrontmost:
            trigger = .appFrontmost(bundleID: newRuleAppBundleID, appName: appName(for: newRuleAppBundleID))
        case .deviceAdded:
            trigger = .deviceAdded(uid: newRuleDeviceUID, name: deviceName(for: newRuleDeviceUID))
        case .deviceRemoved:
            trigger = .deviceRemoved(uid: newRuleDeviceUID, name: deviceName(for: newRuleDeviceUID))
        }
        let rule = AutomationRule(
            name: "\(trigger.summary) → \(newRuleSceneName)",
            trigger: trigger,
            action: .loadScene(name: newRuleSceneName)
        )
        rulesState.addRule(rule)
        automationRulesEngine.evaluate()
        showAddRulePopover = false
    }

    private func resetAddRuleForm() {
        newRuleTriggerKind = .appLaunched
        newRuleAppBundleID = ""
        newRuleDeviceUID = ""
        newRuleSceneName = ""
    }

    private func appName(for bundleID: String) -> String {
        runningApps.first { $0.bundleID == bundleID }?.name ?? bundleID
    }

    private func deviceName(for uid: String) -> String {
        audioDeviceManager.systemDevices.first { $0.uid == uid }?.name ?? uid
    }

    // MARK: - Empty state

    private var emptyState: some View {
        EmptyStateView(
            title: "No Scenes",
            message: "Save the current sources, routes and outputs as a scene to switch setups in one click.",
            symbol: "square.stack.3d.up"
        ) {
            Button("Save Current") {
                newPresetName = ""
                showSavePopover = true
            }
            .buttonStyle(.glassProminent)
            .tint(.loopbacker)
        }
    }

    // MARK: - Actions

    private func savePreset() {
        let trimmed = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let data = routingState.exportConfig()
        PresetManager.save(name: trimmed, data: data)
        presetNames = PresetManager.list()
        newPresetName = ""
        showSavePopover = false
    }

    /// Loads a scene as a diff against the running config: routes shared with the current
    /// setup (e.g. the same mic) keep running, only what changed starts, stops, or retargets.
    private func loadPreset(name: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            _ = sceneLoader.loadScene(name: name)
        }
        automationRulesEngine.pauseForManualSelection(sceneName: name)
    }

    private func deletePreset(name: String) {
        PresetManager.delete(name: name)
        withAnimation(.easeInOut(duration: 0.2)) {
            presetNames = PresetManager.list()
        }
    }
}

/// Picker-friendly trigger category for the Add Rule form; expanded into a full `RuleTrigger`
/// once the user picks an app or device.
private enum RuleTriggerKind: String, CaseIterable, Identifiable {
    case appLaunched, appQuit, appFrontmost, deviceAdded, deviceRemoved

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appLaunched: "App Launched"
        case .appQuit: "App Quit"
        case .appFrontmost: "App Frontmost"
        case .deviceAdded: "Device Connected"
        case .deviceRemoved: "Device Removed"
        }
    }
}
