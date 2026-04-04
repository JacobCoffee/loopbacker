import SwiftUI

enum AppTab: String, CaseIterable {
    case routing = "Routing"
    case effects = "Effects"

    var icon: String {
        switch self {
        case .routing: return "point.3.connected.trianglepath.dotted"
        case .effects: return "waveform.badge.magnifyingglass"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var audioDeviceManager: AudioDeviceManager
    @EnvironmentObject var audioRouter: AudioRouter
    @State private var showSourcePicker = false
    @State private var connectorPositions: [ConnectorEnd: CGRect] = [:]
    @State private var selectedTab: AppTab = .routing
    @AppStorage("appearanceOverride") private var appearanceOverride: String = "system"

    private var colorSchemeOverride: ColorScheme? {
        switch appearanceOverride {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private var appearanceIcon: String {
        switch appearanceOverride {
        case "light": return "sun.max.fill"
        case "dark": return "moon.fill"
        default: return "circle.lefthalf.filled"
        }
    }

    /// Force NSWindow appearance so NSColor(name:) adaptive theme colors resolve correctly
    private func applyAppearance(_ value: String) {
        let nsAppearance: NSAppearance?
        switch value {
        case "light": nsAppearance = NSAppearance(named: .aqua)
        case "dark": nsAppearance = NSAppearance(named: .darkAqua)
        default: nsAppearance = nil
        }
        for window in NSApplication.shared.windows {
            window.appearance = nsAppearance
        }
    }

    private var appearanceTooltip: String {
        switch appearanceOverride {
        case "light": return "Light mode (click for dark)"
        case "dark": return "Dark mode (click for auto)"
        default: return "Auto appearance (click for light)"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            tabContent
            ToolbarView()
        }
        .background(LoopbackerTheme.bgDeep)
        .preferredColorScheme(colorSchemeOverride)
        .onChange(of: appearanceOverride) { _, newValue in
            applyAppearance(newValue)
        }
        .onAppear {
            // Apply initial appearance override
            applyAppearance(appearanceOverride)
            audioDeviceManager.populateInitialSources(into: routingState)
            // Apply saved effects preset to the audio router
            audioRouter.currentEffectsPreset = routingState.effectsPreset
            audioRouter.updateEffectsPreset(routingState.effectsPreset)
            // Start routing for saved state after a brief settle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                syncAudioRouting(sources: routingState.sources, routes: routingState.routes)
                syncOutputRouting(destinations: routingState.outputDestinations)
                // Start monitoring for any sources that have a saved monitor output
                for source in routingState.sources where !source.monitorOutputUID.isEmpty && source.isEnabled && !source.isMuted {
                    audioRouter.startMonitoring(sourceDeviceUID: source.deviceUID, outputDeviceUID: source.monitorOutputUID)
                }
            }
        }
        .onChange(of: routingState.sources) { _, newSources in
            syncAudioRouting(sources: newSources, routes: routingState.routes)
        }
        .onChange(of: routingState.routes) { _, newRoutes in
            syncAudioRouting(sources: routingState.sources, routes: newRoutes)
        }
        // Re-sync when devices are hotplugged (e.g. M2 connected/disconnected)
        .onChange(of: audioDeviceManager.systemDevices) { _, _ in
            syncAudioRouting(sources: routingState.sources, routes: routingState.routes)
        }
        .onReceive(audioRouter.$sourceMeterLevels) { levels in
            updateSourceMeters(levels)
        }
        .onReceive(audioRouter.$outputMeterLevels) { levels in
            updateOutputMeters(levels)
        }
        .onChange(of: routingState.effectsPreset) { _, newPreset in
            audioRouter.currentEffectsPreset = newPreset
            audioRouter.updateEffectsPreset(newPreset)
        }
    }

    // MARK: - Audio routing sync

    /// Starts/stops audio routing based on which sources are enabled, not muted, and have routes
    private func syncAudioRouting(sources: [AudioSource], routes: [AudioRoute]) {
        let routedSourceIDs = Set(routes.map(\.sourceId))

        for source in sources {
            let hasRoutes = routedSourceIDs.contains(source.id)
            let shouldRoute = source.isEnabled && !source.isMuted && hasRoutes && !source.deviceUID.isEmpty

            if shouldRoute {
                audioRouter.startRouting(sourceDeviceUID: source.deviceUID)
            } else {
                if !source.deviceUID.isEmpty {
                    audioRouter.stopRouting(sourceDeviceUID: source.deviceUID)
                }
            }

            // Monitor: only manage stop. Start is handled by the picker in SourceCardView.
            if !shouldRoute && !source.monitorOutputUID.isEmpty {
                audioRouter.stopOutputRouting(virtualDeviceUID: "monitor:\(source.deviceUID)")
            }
        }
    }

    /// Starts/stops output routing based on saved output destinations
    private func syncOutputRouting(destinations: [OutputDestination]) {
        for dest in destinations {
            if dest.isEnabled && !dest.physicalOutputUID.isEmpty {
                audioRouter.startOutputRouting(
                    virtualDeviceUID: dest.virtualDeviceUID,
                    physicalOutputUID: dest.physicalOutputUID
                )
            }
        }
    }

    /// Push meter levels from AudioRouter into the source channel models.
    /// Only updates when the new value differs meaningfully (> 0.01) to avoid
    /// unnecessary SwiftUI redraws.
    private func updateSourceMeters(_ levels: [String: [Int: Float]]) {
        for i in routingState.sources.indices {
            let uid = routingState.sources[i].deviceUID
            guard let channelLevels = levels[uid] else {
                // No levels -- zero out only if not already zero
                for j in routingState.sources[i].channels.indices {
                    if routingState.sources[i].channels[j].meterLevel > 0.01 {
                        routingState.sources[i].channels[j].meterLevel = 0.0
                    }
                }
                continue
            }
            for j in routingState.sources[i].channels.indices {
                let chId = routingState.sources[i].channels[j].id
                let newLevel = channelLevels[chId] ?? 0.0
                let oldLevel = routingState.sources[i].channels[j].meterLevel
                if abs(newLevel - oldLevel) > 0.01 {
                    routingState.sources[i].channels[j].meterLevel = newLevel
                }
            }
        }
    }

    /// Push meter levels from AudioRouter into the output channel models.
    /// Only updates when the new value differs meaningfully (> 0.01).
    private func updateOutputMeters(_ levels: [Int: Float]) {
        for i in routingState.outputChannels.indices {
            let chId = routingState.outputChannels[i].id
            let newLevel = levels[chId] ?? 0.0
            let oldLevel = routingState.outputChannels[i].meterLevel
            if abs(newLevel - oldLevel) > 0.01 {
                routingState.outputChannels[i].meterLevel = newLevel
            }
        }
    }

    // MARK: - Header bar with integrated tab switcher

    private var headerBar: some View {
        HStack(spacing: 12) {
            if let logoURL = Bundle.main.url(forResource: "logo", withExtension: "png"),
               let nsImage = NSImage(contentsOf: logoURL) {
                Image(nsImage: nsImage)
                    .resizable()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Text("Loopbacker")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(LoopbackerTheme.textPrimary)

            // Tab switcher -- integrated into header
            tabSwitcher
                .padding(.leading, 8)

            Spacer()

            // Pending connection hint
            if routingState.pendingConnector != nil {
                HStack(spacing: 4) {
                    Image(systemName: "hand.tap")
                        .font(.system(size: 10))
                    Text("Click a channel to connect, or Esc to cancel")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(LoopbackerTheme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(LoopbackerTheme.accent.opacity(0.1))
                .clipShape(Capsule())
                .transition(.opacity)
            }

            // Appearance toggle
            Button(action: {
                switch appearanceOverride {
                case "system": appearanceOverride = "light"
                case "light": appearanceOverride = "dark"
                default: appearanceOverride = "system"
                }
            }) {
                Image(systemName: appearanceIcon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(LoopbackerTheme.textMuted)
                    .frame(width: 28, height: 28)
                    .background(LoopbackerTheme.bgCard)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(LoopbackerTheme.border, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .tooltip(appearanceTooltip)

            HStack(spacing: 4) {
                Image(systemName: "waveform")
                    .font(.system(size: 10))
                Text("48 kHz / 32-bit")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
            }
            .foregroundColor(LoopbackerTheme.textMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(LoopbackerTheme.bgCard)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(LoopbackerTheme.border, lineWidth: 0.5))
            .tooltip("Virtual device audio format: 48 kHz sample rate, 32-bit float")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(LoopbackerTheme.bgSurface)
        .overlay(
            Rectangle().fill(LoopbackerTheme.border).frame(height: 0.5),
            alignment: .bottom
        )
    }

    // MARK: - Tab switcher

    private var tabSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedTab = tab
                    }
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 10, weight: .semibold))
                        Text(tab.rawValue.uppercased())
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(1.0)
                    }
                    .foregroundColor(selectedTab == tab ? LoopbackerTheme.accent : LoopbackerTheme.textMuted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                    .background(
                        ZStack {
                            if selectedTab == tab {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(LoopbackerTheme.accent.opacity(0.1))
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(LoopbackerTheme.accent.opacity(0.25), lineWidth: 0.5)
                            } else {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.clear)
                            }
                        }
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(LoopbackerTheme.bgInset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(LoopbackerTheme.border, lineWidth: 0.5)
        )
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .routing:
            routingArea
                .coordinateSpace(name: "routing")
                .transition(.opacity)
        case .effects:
            EffectsView()
                .transition(.opacity)
        }
    }

    // MARK: - Main routing area

    private var routingArea: some View {
        ZStack {
            gridBackground
                .onTapGesture {
                    // Cancel pending connection when clicking empty space
                    withAnimation { routingState.cancelPendingConnection() }
                }

            HStack(alignment: .top, spacing: 0) {
                sourcesColumn
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 420)

                Spacer(minLength: 80)

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .trailing, spacing: 20) {
                        outputColumn
                            .frame(minWidth: 240, idealWidth: 300, maxWidth: 380)

                        outputRoutingSection
                            .frame(minWidth: 240, idealWidth: 300, maxWidth: 380)
                    }
                }
            }
            .padding(20)

            CableView(connectorPositions: connectorPositions)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onPreferenceChange(ConnectorPositionKey.self) { positions in
            self.connectorPositions = positions
        }
        .onExitCommand {
            routingState.cancelPendingConnection()
        }
    }

    // MARK: - Sources column

    private var sourcesColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader(title: "Sources", icon: "waveform.path", tip: "Audio input devices to capture from")

                Spacer()

                if !routingState.sources.isEmpty {
                    Text("\(routingState.sources.count) device\(routingState.sources.count == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundColor(LoopbackerTheme.textMuted)
                }

                Button(action: { showSourcePicker = true }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(LoopbackerTheme.accent)
                        .shadow(color: LoopbackerTheme.accentGlow, radius: 4)
                }
                .buttonStyle(.plain)
                .tooltip("Add an audio input device as a source for routing")
                .popover(isPresented: $showSourcePicker) {
                    sourcePickerPopover
                }
            }

            if routingState.sources.isEmpty {
                emptySourcesPlaceholder
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 10) {
                        ForEach($routingState.sources) { $source in
                            SourceCardView(source: $source)
                                .contextMenu {
                                    Button {
                                        withAnimation {
                                            routingState.removeSource(source.id)
                                        }
                                    } label: {
                                        Label("Remove \(source.name)", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
        }
    }

    private var emptySourcesPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "plus.circle.dashed")
                .font(.system(size: 28))
                .foregroundColor(LoopbackerTheme.textMuted)

            Text("Click + to add an audio source")
                .font(.system(size: 12))
                .foregroundColor(LoopbackerTheme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Output column

    private var outputColumn: some View {
        VStack(alignment: .trailing, spacing: 12) {
            HStack {
                Spacer()
                sectionHeader(title: "Output Channels", icon: "speaker.wave.2", tip: "Virtual device channels that apps like Discord see")
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 10) {
                    OutputChannelView()
                }
            }
        }
    }

    // MARK: - Output routing section

    private var outputRoutingSection: some View {
        VStack(alignment: .trailing, spacing: 12) {
            HStack {
                Spacer()
                sectionHeader(title: "Output Routing", icon: "arrow.right.circle", tip: "Route app audio from virtual devices to physical outputs")
            }

            OutputRoutingView()
        }
    }

    // MARK: - Section header

    private func sectionHeader(title: String, icon: String, tip: String = "") -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(LoopbackerTheme.accent)

            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(LoopbackerTheme.textSecondary)
                .tracking(1.5)
        }
        .tooltip(tip.isEmpty ? title : tip)
    }

    // MARK: - Grid background

    private var gridBackground: some View {
        Canvas { context, size in
            let gridSpacing: CGFloat = 30
            let lineColor = Color(white: 0.12).opacity(0.3)

            var x: CGFloat = 0
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(lineColor), lineWidth: 0.5)
                x += gridSpacing
            }

            var y: CGFloat = 0
            while y < size.height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(lineColor), lineWidth: 0.5)
                y += gridSpacing
            }

            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let gradient = Gradient(colors: [
                Color(red: 0.0, green: 0.83, blue: 0.67).opacity(0.03),
                Color.clear
            ])
            context.fill(
                Path(ellipseIn: CGRect(
                    x: center.x - 300, y: center.y - 200,
                    width: 600, height: 400
                )),
                with: .radialGradient(gradient, center: center, startRadius: 0, endRadius: 300)
            )
        }
    }

    // MARK: - Source picker popover

    private var sourcePickerPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ADD SOURCE")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(LoopbackerTheme.textSecondary)
                .tracking(1.5)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider().background(LoopbackerTheme.border)

            let inputDevices = audioDeviceManager.systemDevices.filter { $0.isInput && !$0.name.contains("Loopbacker") }

            if inputDevices.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "speaker.slash")
                            .font(.system(size: 20))
                            .foregroundColor(LoopbackerTheme.textMuted)
                        Text("No input devices found")
                            .font(.system(size: 12))
                            .foregroundColor(LoopbackerTheme.textMuted)
                    }
                    .padding(.vertical, 20)
                    Spacer()
                }
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(inputDevices) { device in
                            devicePickerRow(device)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 300)
            }
        }
        .frame(width: 280)
        .background(LoopbackerTheme.bgCard)
    }

    private func devicePickerRow(_ device: SystemAudioDevice) -> some View {
        let alreadyAdded = routingState.sources.contains { $0.name == device.name }

        return Button(action: {
            guard !alreadyAdded else { return }
            let newSource = audioDeviceManager.createSource(from: device)
            withAnimation(.easeInOut(duration: 0.2)) {
                routingState.sources.append(newSource)
                routingState.save()
            }
            showSourcePicker = false
        }) {
            HStack(spacing: 10) {
                Image(systemName: device.isInput ? "mic.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .foregroundColor(alreadyAdded ? LoopbackerTheme.textMuted : LoopbackerTheme.accent)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(alreadyAdded ? LoopbackerTheme.textMuted : LoopbackerTheme.textPrimary)

                    Text("\(device.inputChannelCount) in / \(device.outputChannelCount) out")
                        .font(.system(size: 10))
                        .foregroundColor(LoopbackerTheme.textMuted)
                }

                Spacer()

                if alreadyAdded {
                    Text("Added")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(LoopbackerTheme.textMuted)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(alreadyAdded)
    }
}
