import SwiftUI
import AppKit

struct SoundboardView: View {
    @EnvironmentObject var soundboardState: SoundboardState
    @EnvironmentObject var soundboardPlayer: SoundboardPlayer
    @State private var isDragTarget = false

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 170))]

    private var meterColor: Color {
        let level = soundboardPlayer.meterLevel
        if level > 0.9 { return LoopbackerTheme.danger }
        if level > 0.7 { return LoopbackerTheme.warning }
        return LoopbackerTheme.accent
    }

    var body: some View {
        ZStack {
            // Background
            LoopbackerTheme.bgDeep

            VStack(spacing: 0) {
                // Header
                header
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 16)

                if soundboardState.items.isEmpty {
                    emptyState
                    Spacer()
                } else {
                    // Sound grid
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(soundboardState.items) { item in
                                SoundButton(
                                    item: item,
                                    isPlaying: soundboardPlayer.playingIDs.contains(item.id)
                                ) {
                                    soundboardPlayer.play(item: item)
                                }
                                .contextMenu {
                                    if let url = item.resolveURL() {
                                        Button("Show in Finder") {
                                            NSWorkspace.shared.activateFileViewerSelecting([url])
                                        }
                                    }
                                    Divider()
                                    Button("Remove", role: .destructive) {
                                        soundboardPlayer.stop(id: item.id)
                                        soundboardState.remove(id: item.id)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                    }
                }

                // Bottom bar
                bottomBar
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $isDragTarget) { providers in
            handleDrop(providers)
        }
        .overlay(
            isDragTarget ? RoundedRectangle(cornerRadius: 12)
                .strokeBorder(LoopbackerTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                .padding(8)
            : nil
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LoopbackerTheme.accent.opacity(0.15))
                    .frame(width: 40, height: 40)

                Image(systemName: "music.quarternote.3")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(LoopbackerTheme.accent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Soundboard")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(LoopbackerTheme.textPrimary)

                Text("\(soundboardState.items.count) sound\(soundboardState.items.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundColor(LoopbackerTheme.textSecondary)
            }

            Spacer()

            // Add file
            Button(action: addFile) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("FILE")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                }
                .foregroundColor(LoopbackerTheme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(LoopbackerTheme.accent.opacity(0.1)))
                .overlay(Capsule().strokeBorder(LoopbackerTheme.accent.opacity(0.25), lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            // Add folder
            Button(action: addFolder) {
                HStack(spacing: 4) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("FOLDER")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                }
                .foregroundColor(LoopbackerTheme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(LoopbackerTheme.accent.opacity(0.1)))
                .overlay(Capsule().strokeBorder(LoopbackerTheme.accent.opacity(0.25), lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            // Stop all
            if !soundboardPlayer.playingIDs.isEmpty {
                Button(action: { soundboardPlayer.stopAll() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9))
                        Text("STOP ALL")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(LoopbackerTheme.danger)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(LoopbackerTheme.danger.opacity(0.1)))
                    .overlay(Capsule().strokeBorder(LoopbackerTheme.danger.opacity(0.25), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "music.quarternote.3")
                .font(.system(size: 40))
                .foregroundColor(LoopbackerTheme.textMuted)

            Text("Drop audio files here")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(LoopbackerTheme.textSecondary)

            Text("or use the FILE / FOLDER buttons above")
                .font(.system(size: 11))
                .foregroundColor(LoopbackerTheme.textMuted)

            Text("MP3, WAV, M4A, AIFF, FLAC, CAF")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(LoopbackerTheme.textMuted)
                .padding(.top, 4)

            Spacer()
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            // Global volume
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 11))
                .foregroundColor(LoopbackerTheme.textSecondary)

            Slider(value: Binding(
                get: { soundboardPlayer.globalVolume },
                set: { soundboardPlayer.globalVolume = $0 }
            ), in: 0...1)
            .tint(LoopbackerTheme.accent)
            .frame(width: 120)

            // Output level meter
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(LoopbackerTheme.bgInset)
                    .frame(width: 80, height: 6)

                RoundedRectangle(cornerRadius: 2)
                    .fill(meterColor)
                    .frame(width: 80 * CGFloat(min(soundboardPlayer.meterLevel, 1.0)), height: 6)
                    .animation(.linear(duration: 0.05), value: soundboardPlayer.meterLevel)
            }

            Spacer()

            Text("Sounds are copied to app storage")
                .font(.system(size: 9))
                .foregroundColor(LoopbackerTheme.textMuted)

            if !soundboardState.items.isEmpty {
                Button(action: {
                    soundboardPlayer.stopAll()
                    soundboardState.removeAll()
                }) {
                    Text("Clear All")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(LoopbackerTheme.danger)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(LoopbackerTheme.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LoopbackerTheme.border, lineWidth: 0.5))
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
        var handled = false
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                if extensions.contains(url.pathExtension.lowercased()) {
                    DispatchQueue.main.async {
                        soundboardState.addFile(url: url)
                    }
                    handled = true
                }
            }
        }
        return handled
    }
}

// MARK: - Sound button

private struct SoundButton: View {
    let item: SoundboardItem
    let isPlaying: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                // Play/stop icon
                ZStack {
                    if isPlaying {
                        // Animated waveform
                        HStack(spacing: 2) {
                            ForEach(0..<4, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(LoopbackerTheme.accent)
                                    .frame(width: 3, height: CGFloat.random(in: 8...20))
                                    .animation(
                                        .easeInOut(duration: 0.3 + Double(i) * 0.1)
                                        .repeatForever(autoreverses: true),
                                        value: isPlaying
                                    )
                            }
                        }
                        .frame(height: 24)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 16))
                            .foregroundColor(isHovering ? LoopbackerTheme.accent : LoopbackerTheme.textSecondary)
                    }
                }
                .frame(height: 28)

                // Name
                Text(item.emoji.isEmpty ? item.name : "\(item.emoji) \(item.name)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(isPlaying ? LoopbackerTheme.accent : LoopbackerTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 80)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isPlaying ? LoopbackerTheme.accent.opacity(0.12) : LoopbackerTheme.bgCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isPlaying ? LoopbackerTheme.accent.opacity(0.5) :
                        isHovering ? LoopbackerTheme.accent.opacity(0.25) : LoopbackerTheme.border,
                        lineWidth: isPlaying ? 1.5 : 0.5
                    )
            )
            .shadow(
                color: isPlaying ? LoopbackerTheme.accent.opacity(0.15) : .clear,
                radius: 8
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
