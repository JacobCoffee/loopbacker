import SwiftUI
import AppKit

struct SoundboardView: View {
    @EnvironmentObject var soundboardState: SoundboardState
    @EnvironmentObject var soundboardPlayer: SoundboardPlayer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isDragTarget = false
    @State private var pendingClearAll = false
    @State private var editingItem: SoundboardItem?

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: Metrics.panelSpacing)]

    var body: some View {
        Group {
            if soundboardState.items.isEmpty {
                emptyState
            } else {
                soundGrid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer
        }
        .overlay {
            if isDragTarget {
                RoundedRectangle(cornerRadius: Metrics.panelRadius)
                    .strokeBorder(Color.loopbacker, style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                    .padding(Metrics.canvasMargin / 2)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragTarget) { providers in
            handleDrop(providers)
        }
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .confirmationDialog("Remove all sounds?", isPresented: $pendingClearAll, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) {
                soundboardPlayer.stopAll()
                soundboardState.removeAll()
            }
        } message: {
            Text("This removes every sound from the soundboard. This can't be undone.")
        }
        .sheet(item: $editingItem) { item in
            SoundPadEditorView(item: binding(for: item.id), onClose: { editingItem = nil })
        }
    }

    private var subtitle: String {
        let n = soundboardState.items.count
        return "\(n) sound\(n == 1 ? "" : "s")"
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: addFile) {
                Label("Add Files…", systemImage: "doc.badge.plus")
            }
            .help("Add audio files to the soundboard")

            Button(action: addFolder) {
                Label("Add Folder…", systemImage: "folder.badge.plus")
            }
            .help("Add every audio file in a folder")

            if !soundboardPlayer.playingIDs.isEmpty {
                Button(role: .destructive) {
                    soundboardPlayer.stopAll()
                } label: {
                    Label("Stop All", systemImage: "stop.fill")
                }
                .help("Stop every playing sound")
            }

            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2")
                    .foregroundStyle(.secondary)
                Slider(value: volumeBinding, in: 0...1)
                    .tint(.loopbacker)
                    .frame(width: 120)
            }
            .help("Global soundboard volume")

            Button(role: .destructive) {
                pendingClearAll = true
            } label: {
                Label("Clear All", systemImage: "trash")
            }
            .disabled(soundboardState.items.isEmpty)
            .help("Remove every sound from the soundboard")
        }
        GlobalToolbar()
    }

    private var volumeBinding: Binding<Float> {
        Binding(
            get: { soundboardPlayer.globalVolume },
            set: { soundboardPlayer.globalVolume = $0 }
        )
    }

    // MARK: - Grid

    private var soundGrid: some View {
        ScrollView {
            GlassEffectContainer(spacing: Metrics.panelSpacing) {
                LazyVGrid(columns: columns, spacing: Metrics.panelSpacing) {
                    ForEach(soundboardState.items) { item in
                        SoundPad(
                            item: item,
                            isPlaying: soundboardPlayer.playingIDs.contains(item.id),
                            reduceMotion: reduceMotion,
                            action: { soundboardPlayer.play(item: item) },
                            onPress: { soundboardPlayer.press(item: item) },
                            onRelease: { soundboardPlayer.release(item: item) },
                            onShowInFinder: { showInFinder(item) },
                            onEdit: { editingItem = item },
                            onRemove: { remove(item) }
                        )
                    }
                }
            }
            .padding(Metrics.canvasMargin)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private func showInFinder(_ item: SoundboardItem) {
        guard let url = item.resolveURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func remove(_ item: SoundboardItem) {
        soundboardPlayer.stop(id: item.id)
        soundboardState.remove(id: item.id)
    }

    /// A two-way binding into `soundboardState.items` for the given pad, used by the editor
    /// sheet. Falls back to a throwaway value if the pad was removed while the sheet was open.
    private func binding(for id: UUID) -> Binding<SoundboardItem> {
        Binding(
            get: {
                soundboardState.items.first(where: { $0.id == id })
                    ?? SoundboardItem(name: "", fileBookmark: Data())
            },
            set: { newValue in
                guard let index = soundboardState.items.firstIndex(where: { $0.id == id }) else { return }
                soundboardState.items[index] = newValue
                soundboardState.save()
            }
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        EmptyStateView(
            title: "Drop audio files here",
            message: "or use Add Files and Add Folder in the toolbar\nMP3, WAV, M4A, AIFF, FLAC, CAF",
            symbol: "music.quarternote.3"
        ) {
            Button(action: addFile) {
                Label("Add Files…", systemImage: "doc.badge.plus")
            }
            .buttonStyle(.glassProminent)
            .tint(.loopbacker)

            Button(action: addFolder) {
                Label("Add Folder…", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.glass)
            .tint(nil)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        let level = SignalMeter.normalized(linearPeak: soundboardPlayer.meterLevel)
        return HStack(spacing: 12) {
            SignalMeter(level: level, axis: .horizontal, thickness: 6)
                .frame(width: 140)

            Text(SignalMeter.dbString(level))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)

            Spacer()

            Text("Sounds are copied to app storage")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Metrics.panelPadding)
        .padding(.vertical, 10)
        .glassPanel(cornerRadius: Metrics.innerRadius)
        .padding(.horizontal, Metrics.canvasMargin)
        .padding(.bottom, Metrics.canvasMargin / 2)
    }

    // MARK: - File/folder pickers

    private func addFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .mpeg4Movie]
        if panel.runModal() == .OK {
            for url in panel.urls {
                soundboardState.addFile(url: url)
            }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            soundboardState.addFolder(url: url)
        }
    }

    // MARK: - Drag and drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let extensions = Set(["mp3", "m4a", "wav", "aiff", "aif", "mp4", "caf", "flac"])
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier("public.file-url") }
        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      extensions.contains(url.pathExtension.lowercased()) else { return }
                DispatchQueue.main.async {
                    soundboardState.addFile(url: url)
                }
            }
        }
        // URLs resolve asynchronously, so accept the drop when it carries files at all.
        return !fileProviders.isEmpty
    }
}

// MARK: - Sound pad

private struct SoundPad: View {
    let item: SoundboardItem
    let isPlaying: Bool
    let reduceMotion: Bool
    let action: () -> Void
    let onPress: () -> Void
    let onRelease: () -> Void
    let onShowInFinder: () -> Void
    let onEdit: () -> Void
    let onRemove: () -> Void

    /// Tracks whether a hold-to-play press is down, so a drag that leaves the pad still
    /// releases it (SwiftUI drag gestures don't get a separate "cancelled" callback).
    @State private var isHeld = false

    var body: some View {
        Group {
            if item.playMode == .holdToPlay {
                padContent.gesture(holdGesture)
            } else {
                Button(action: action) { padContent }
                    .buttonStyle(.glass)
                    .tint(isPlaying ? Color.loopbacker : nil)
            }
        }
        .help(helpText)
        .accessibilityLabel(item.name)
        .accessibilityValue(isPlaying ? "Playing" : "Stopped")
        .contextMenu {
            Button("Edit…", action: onEdit)
            Button("Show in Finder", action: onShowInFinder)
            Divider()
            Button("Remove", role: .destructive, action: onRemove)
        }
    }

    private var helpText: String {
        switch item.playMode {
        case .holdToPlay: "Hold to play \(item.name)"
        default: isPlaying ? "Stop \(item.name)" : "Play \(item.name)"
        }
    }

    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isHeld else { return }
                isHeld = true
                onPress()
            }
            .onEnded { _ in
                isHeld = false
                onRelease()
            }
    }

    private var padContent: some View {
        VStack(spacing: 8) {
            ZStack {
                if isPlaying {
                    Image(systemName: "waveform")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.loopbacker)
                        .symbolEffect(.variableColor.iterative, isActive: isPlaying && !reduceMotion)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 28)

            Text(item.emoji.isEmpty ? item.name : "\(item.emoji) \(item.name)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isPlaying ? Color.loopbacker : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 92)
        .padding(.horizontal, 6)
        .contentShape(RoundedRectangle(cornerRadius: Metrics.innerRadius))
        .glassEffect(Glass.regular.tint(isPlaying ? Color.loopbacker : nil), in: .rect(cornerRadius: Metrics.innerRadius))
    }
}
