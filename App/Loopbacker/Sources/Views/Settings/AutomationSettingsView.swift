import SwiftUI
import AppKit

/// Automation settings: rules that auto-switch the effects preset by running/frontmost app,
/// priority order (list order), a fallback preset, and restore-previous-on-quit. The rules list
/// itself lives in `PresetAutoSwitchState`/`PresetAutoSwitcher` (Services/Control), shared with
/// the live switcher so this tab and the running engine always agree.
struct AutomationSettingsView: View {
    @EnvironmentObject var rulesState: PresetAutoSwitchState
    @EnvironmentObject var autoSwitcher: PresetAutoSwitcher

    @State private var showAddRule = false
    @State private var newRuleApp: RunningApp?
    @State private var newRulePreset: NamedPreset?
    @State private var newRuleMatch: PresetAutoSwitchMatch = .launched
    @State private var newRuleRestorePrevious = false

    private var presets: [NamedPreset] { ControlCenter.shared.availablePresets() }

    var body: some View {
        Form {
            Section {
                if let active = autoSwitcher.activeRule {
                    LabeledContent("Active Rule", value: active.summary)
                } else if let fallback = rulesState.fallbackPresetID,
                          let name = presets.first(where: { $0.id == fallback })?.name {
                    LabeledContent("Active", value: "Fallback: \(name)")
                }

                Picker("Fallback Preset", selection: Binding(
                    get: { rulesState.fallbackPresetID ?? "" },
                    set: { newValue in
                        rulesState.fallbackPresetID = newValue.isEmpty ? nil : newValue
                        rulesState.save()
                        autoSwitcher.evaluate()
                    }
                )) {
                    Text("None").tag("")
                    ForEach(presets) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
            } header: {
                Text("Preset Auto-Switch")
            } footer: {
                Text("Applies when no rule below matches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Rules") {
                if rulesState.rules.isEmpty {
                    Text("No rules yet. Add one to switch the effects preset automatically when an app runs or becomes frontmost.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rulesState.rules) { rule in
                        ruleRow(rule)
                    }
                    .onMove { rulesState.moveRule(fromOffsets: $0, toOffset: $1) }
                }

                Button {
                    resetAddRuleForm()
                    showAddRule = true
                } label: {
                    Label("Add Rule", systemImage: "plus.circle")
                }
                .popover(isPresented: $showAddRule, arrowEdge: .bottom) {
                    addRulePopover
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Rule row

    private func ruleRow(_ rule: PresetAutoSwitchRule) -> some View {
        HStack {
            Toggle(isOn: Binding(
                get: { rule.isEnabled },
                set: { rulesState.setRuleEnabled(id: rule.id, isEnabled: $0); autoSwitcher.evaluate() }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.summary)
                    if rule.restorePreviousOnQuit {
                        Text("Restores the previous preset when \(rule.appName) quits")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button(role: .destructive) {
                rulesState.removeRule(id: rule.id)
                autoSwitcher.evaluate()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete rule for \(rule.appName)")
        }
    }

    // MARK: - Add rule

    private var addRulePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add Automation Rule")
                .font(.headline)

            Picker("App", selection: $newRuleApp) {
                Text("Choose an app…").tag(RunningApp?.none)
                ForEach(RunningApp.runningApps()) { app in
                    Text(app.name).tag(RunningApp?.some(app))
                }
            }
            Button("Browse for App…") { browseForApp() }
                .buttonStyle(.link)
                .font(.caption)

            Picker("Preset", selection: $newRulePreset) {
                Text("Choose a preset…").tag(NamedPreset?.none)
                ForEach(presets) { preset in
                    Text(preset.name).tag(NamedPreset?.some(preset))
                }
            }

            Picker("When", selection: $newRuleMatch) {
                ForEach(PresetAutoSwitchMatch.allCases) { match in
                    Text(match.title).tag(match)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Restore previous preset on quit", isOn: $newRuleRestorePrevious)
                .disabled(newRuleMatch == .frontmost)
                .help("Only meaningful for \"App Running\": reverts to whatever preset was active before this rule took over")

            HStack {
                Spacer()
                Button("Cancel") { showAddRule = false }
                    .buttonStyle(.bordered)
                Button("Add") { addRule() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newRuleApp == nil || newRulePreset == nil)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func resetAddRuleForm() {
        newRuleApp = nil
        newRulePreset = nil
        newRuleMatch = .launched
        newRuleRestorePrevious = false
    }

    private func addRule() {
        guard let app = newRuleApp, let preset = newRulePreset else { return }
        rulesState.addRule(PresetAutoSwitchRule(
            appBundleID: app.bundleID, appName: app.name,
            presetID: preset.id, presetName: preset.name,
            matchOn: newRuleMatch, restorePreviousOnQuit: newRuleMatch == .launched && newRuleRestorePrevious
        ))
        autoSwitcher.evaluate()
        showAddRule = false
    }

    private func browseForApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return }
        let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        newRuleApp = RunningApp(bundleID: bundleID, name: name)
    }
}

/// A picker entry for the "App" field: either a currently-running app or one chosen via
/// "Browse for App…". Not every app in this picker is actually running.
struct RunningApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    var id: String { bundleID }

    static func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in
                guard let bundleID = app.bundleIdentifier else { return nil }
                return RunningApp(bundleID: bundleID, name: app.localizedName ?? bundleID)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
