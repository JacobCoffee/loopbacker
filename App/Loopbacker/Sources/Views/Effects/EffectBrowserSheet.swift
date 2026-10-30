import SwiftUI

// MARK: - Effect browser

/// Sheet for inserting a new stage into the chain: built-in DSP stages plus the three hosted
/// catalogs (Audio Units, JSFX, Airwindows), each searchable and grouped by category.
struct EffectBrowserSheet: View {
    @EnvironmentObject var fxEngine: FXEngine
    @Environment(\.dismiss) private var dismiss

    /// Called with a built-in kind, or a hosted plugin ref to insert.
    let onInsertBuiltin: (FXNodeKind) -> Void
    let onInsertHosted: (FXPluginInfo) -> Void

    private enum Tab: String, CaseIterable, Identifiable {
        case builtin = "Built-in"
        case audioUnits = "Audio Units"
        case jsfx = "JSFX"
        case airwindows = "Airwindows"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .builtin
    @State private var query = ""
    @State private var selectedPlugin: FXPluginInfo?
    @State private var showAirwindowsToggleHint = false
    @AppStorage(AirwindowsLibrary.defaultsKeyMirror) private var airwindowsEnabled = AirwindowsLibrary.isEnabled

    init(onInsertBuiltin: @escaping (FXNodeKind) -> Void, onInsertHosted: @escaping (FXPluginInfo) -> Void) {
        self.onInsertBuiltin = onInsertBuiltin
        self.onInsertHosted = onInsertHosted
    }

    /// Opens straight to a given tab (0 = Built-in, 1 = Audio Units, 2 = JSFX, 3 = Airwindows),
    /// for offscreen render tests and previews.
    init(previewTabIndex: Int, onInsertBuiltin: @escaping (FXNodeKind) -> Void, onInsertHosted: @escaping (FXPluginInfo) -> Void) {
        self.onInsertBuiltin = onInsertBuiltin
        self.onInsertHosted = onInsertHosted
        let clamped = max(0, min(previewTabIndex, Tab.allCases.count - 1))
        _tab = State(initialValue: Tab.allCases[clamped])
    }

    private let builtinKinds: [FXNodeKind] = [
        .gate, .eq, .compressor, .leveler, .deEsser, .chorus, .pitchShift, .reverb, .delay, .limiter,
    ]

    var body: some View {
        VStack(spacing: 0) {
            header

            Picker("Source", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], Metrics.panelPadding)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search effects", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Metrics.innerRadius - 4))
            .padding(.horizontal, Metrics.panelPadding)
            .padding(.top, 8)

            if tab == .airwindows {
                Toggle("Show Airwindows library", isOn: $airwindowsEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(.loopbacker)
                    .padding(.horizontal, Metrics.panelPadding)
                    .padding(.top, 8)
                    .onChange(of: airwindowsEnabled) { _, newValue in
                        AirwindowsLibrary.isEnabled = newValue
                        Task { await fxEngine.refreshPlugins() }
                    }
            }

            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        content
                    }
                    .padding(Metrics.panelPadding)
                }
                .frame(minWidth: 320)

                if let selectedPlugin, tab == .airwindows {
                    Divider()
                    detailPane(selectedPlugin)
                        .frame(width: 260)
                        .padding(Metrics.panelPadding)
                }
            }
            .frame(minHeight: 320)
        }
        .frame(width: 620, height: 520)
        .task { await fxEngine.refreshPlugins() }
    }

    private var header: some View {
        HStack {
            Text("Add Effect")
                .font(.headline)
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(.glass)
                .tint(nil)
                .controlSize(.small)
        }
        .padding(Metrics.panelPadding)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .builtin: builtinList
        case .audioUnits: hostedList(format: .audioUnit)
        case .jsfx: hostedList(format: .jsfx)
        case .airwindows: hostedList(format: .airwindows)
        }
    }

    private var builtinList: some View {
        let filtered = builtinKinds.filter {
            query.isEmpty || displayName($0).localizedCaseInsensitiveContains(query)
        }
        return ForEach(filtered, id: \.self) { kind in
            Button {
                onInsertBuiltin(kind)
                dismiss()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon(kind))
                        .foregroundStyle(Color.loopbacker)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(displayName(kind)).font(.body)
                        Text(effectDescription(kind))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(displayName(kind))
            .accessibilityHint(effectDescription(kind))
        }
    }

    @ViewBuilder
    private func hostedList(format: FXNodeKind) -> some View {
        let plugins = fxEngine.availablePlugins.filter { $0.ref.format == format }
        let filtered = plugins.filter {
            query.isEmpty || $0.ref.name.localizedCaseInsensitiveContains(query)
                || ($0.category ?? "").localizedCaseInsensitiveContains(query)
        }
        let grouped = Dictionary(grouping: filtered) { $0.category ?? "Other" }

        if filtered.isEmpty {
            emptyState(for: format)
        } else {
            ForEach(grouped.keys.sorted(), id: \.self) { category in
                Section {
                    ForEach(grouped[category] ?? [], id: \.id) { plugin in
                        hostedRow(plugin)
                    }
                } header: {
                    Text(category)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
        }
    }

    private func hostedRow(_ plugin: FXPluginInfo) -> some View {
        Button {
            selectedPlugin = plugin
            if plugin.ref.format != .airwindows {
                onInsertHosted(plugin)
                dismiss()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .foregroundStyle(Color.loopbacker)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(plugin.ref.name).font(.body)
                        if plugin.ref.format == .audioUnit {
                            StatusTag(title: plugin.isAUv3 ? "AUv3" : "AUv2", tint: .secondary)
                        }
                    }
                    if let summary = plugin.summary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                if plugin.ref.format == .airwindows {
                    Button("Insert") {
                        onInsertHosted(plugin)
                        dismiss()
                    }
                    .buttonStyle(.glass)
                    .tint(nil)
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(selectedPlugin?.id == plugin.id ? Color.loopbacker.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: Metrics.innerRadius - 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(plugin.ref.name)
        .accessibilityHint(plugin.summary ?? "")
    }

    @ViewBuilder
    private func detailPane(_ plugin: FXPluginInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(plugin.ref.name).font(.headline)
            if let category = plugin.category {
                Text(category).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(AirwindowsNode.documentation(for: plugin.ref) ?? plugin.summary ?? "No documentation available.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private func emptyState(for format: FXNodeKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch format {
            case .audioUnit:
                Text("No Audio Units found").font(.body.weight(.semibold))
                Text("Install an effect Audio Unit (AUv2 or AUv3) and it will appear here automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            case .jsfx:
                Text("No JSFX effects found").font(.body.weight(.semibold))
                Text("Drop .jsfx scripts into ~/Library/Application Support/REAPER/Effects, or Loopbacker's own JSFX folder, then reopen this browser.")
                    .font(.caption).foregroundStyle(.secondary)
            case .airwindows:
                if !AirwindowsLibrary.isEnabled {
                    Text("Airwindows library is off").font(.body.weight(.semibold))
                    Text("Turn on \"Show Airwindows library\" above to browse the ~500 bundled Airwindows effects.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No matches").font(.body.weight(.semibold))
                    Text("Try a different search term.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 20)
    }

    private func icon(_ kind: FXNodeKind) -> String {
        switch kind {
        case .gate: "waveform.path.ecg"
        case .eq: "slider.vertical.3"
        case .compressor: "arrow.down.right.and.arrow.up.left"
        case .leveler: "chart.bar.fill"
        case .deEsser: "s.circle"
        case .chorus: "waveform.path"
        case .pitchShift: "arrow.up.arrow.down"
        case .reverb: "drop.halffull"
        case .delay: "repeat"
        case .limiter: "gauge.with.dots.needle.67percent"
        case .audioUnit, .jsfx, .airwindows: "puzzlepiece.extension"
        }
    }

    private func displayName(_ kind: FXNodeKind) -> String {
        switch kind {
        case .gate: "Gate"
        case .eq: "EQ"
        case .compressor: "Compressor"
        case .leveler: "Leveler"
        case .deEsser: "De-Esser"
        case .chorus: "Chorus"
        case .pitchShift: "Pitch Shift"
        case .reverb: "Reverb"
        case .delay: "Delay"
        case .limiter: "Limiter"
        case .audioUnit: "Audio Unit"
        case .jsfx: "JSFX"
        case .airwindows: "Airwindows"
        }
    }

    private func effectDescription(_ kind: FXNodeKind) -> String {
        switch kind {
        case .gate: "Reduces background noise below a threshold"
        case .eq: "Shape tonal balance with parametric bands"
        case .compressor: "Tames dynamic range for consistent levels"
        case .leveler: "Holds your voice at a target loudness"
        case .deEsser: "Reduces harsh sibilance in vocals"
        case .chorus: "Thickens voice with modulated detuning"
        case .pitchShift: "Shift voice pitch up or down in semitones"
        case .reverb: "Adds room/hall spatial ambience"
        case .delay: "Echo effect with adjustable feedback"
        case .limiter: "Prevents clipping with a hard ceiling"
        case .audioUnit, .jsfx, .airwindows: "Hosted third-party effect"
        }
    }
}

private extension AirwindowsLibrary {
    /// `AirwindowsLibrary.isEnabled` already persists to this exact `UserDefaults` key; mirrored
    /// here so the sheet's toggle can bind through `@AppStorage` and still call the real setter.
    static let defaultsKeyMirror = "AirwindowsLibrary.isEnabled"
}
