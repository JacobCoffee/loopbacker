import SwiftUI

struct ContentView: View {
    @EnvironmentObject var routingState: RoutingState
    @EnvironmentObject var audioDeviceManager: AudioDeviceManager
    @EnvironmentObject var audioRouter: AudioRouter
    @State private var showSourcePicker = false
    @State private var connectorPositions: [ConnectorEnd: CGRect] = [:]

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            routingArea
                .coordinateSpace(name: "routing")
            ToolbarView()
        }
        .background(LoopbackerTheme.bgDeep)
        .onAppear {
            audioDeviceManager.populateInitialSources(into: routingState)
            // Start routing for saved state after a brief settle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                syncAudioRouting(sources: routingState.sources, routes: routingState.routes)
                syncOutputRouting(destinations: routingState.outputDestinations)
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

    // MARK: - Header bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            colors: [LoopbackerTheme.accent.opacity(0.3), LoopbackerTheme.accent.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)

                Image(systemName: "cable.connector.horizontal")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(LoopbackerTheme.accent)
            }

            Text("Loopbacker")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(LoopbackerTheme.textPrimary)

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
            .help("Virtual device audio format: 48 kHz sample rate, 32-bit float")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(LoopbackerTheme.bgSurface)
        .overlay(
            Rectangle().fill(LoopbackerTheme.border).frame(height: 0.5),
            alignment: .bottom
        )
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
                sectionHeader(title: "Sources", icon: "waveform.path")

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
                .help("Add an audio input device as a source for routing")
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
                sectionHeader(title: "Output Channels", icon: "speaker.wave.2")
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
                sectionHeader(title: "Output Routing", icon: "arrow.right.circle")
            }

            OutputRoutingView()
        }
    }

    // MARK: - Section header

    private func sectionHeader(title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(LoopbackerTheme.accent)

            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(LoopbackerTheme.textSecondary)
                .tracking(1.5)
        }
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
