import SwiftUI

struct SourceCardView: View {
    @Binding var source: AudioSource
    @EnvironmentObject var routingState: RoutingState
    @State private var isHovering = false
    @State private var showOptions = false

    private var hasActiveRoutes: Bool {
        routingState.routes.contains { $0.sourceId == source.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            header

            Divider()
                .background(LoopbackerTheme.border)

            // Channel strips
            VStack(spacing: 4) {
                ForEach(source.channels) { channel in
                    ChannelStripView(
                        channel: channel,
                        side: .source,
                        isSourceEnabled: source.isEnabled,
                        connectorEnd: .source(sourceId: source.id, channelId: channel.id)
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // Options disclosure
            if showOptions {
                optionsSection
            }

            optionsToggle
        }
        .background(
            RoundedRectangle(cornerRadius: LoopbackerTheme.cardCornerRadius)
                .fill(isHovering ? LoopbackerTheme.bgCardHover : LoopbackerTheme.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LoopbackerTheme.cardCornerRadius)
                .strokeBorder(
                    source.isEnabled && hasActiveRoutes
                        ? LoopbackerTheme.borderActive
                        : LoopbackerTheme.border,
                    lineWidth: source.isEnabled && hasActiveRoutes ? 1.5 : 0.5
                )
        )
        .shadow(
            color: source.isEnabled && hasActiveRoutes
                ? LoopbackerTheme.accentGlow.opacity(0.15)
                : Color.clear,
            radius: 8
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            // Device icon
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(source.isEnabled ? LoopbackerTheme.accent.opacity(0.15) : LoopbackerTheme.bgInset)
                    .frame(width: 32, height: 32)

                Image(systemName: source.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(source.isEnabled ? LoopbackerTheme.accent : LoopbackerTheme.textMuted)
            }

            // Device name
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(source.isEnabled ? LoopbackerTheme.textPrimary : LoopbackerTheme.textMuted)

                Text("\(source.channels.count) channel\(source.channels.count == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(LoopbackerTheme.textSecondary)
            }

            Spacer()

            // On/Off toggle
            enableToggle
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Custom toggle

    private var enableToggle: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                routingState.toggleSource(source.id)
            }
        }) {
            HStack(spacing: 4) {
                Circle()
                    .fill(source.isEnabled ? LoopbackerTheme.accent : LoopbackerTheme.textMuted)
                    .frame(width: 6, height: 6)
                    .shadow(color: source.isEnabled ? LoopbackerTheme.accentGlow : .clear, radius: 3)

                Text(source.isEnabled ? "ON" : "OFF")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(source.isEnabled ? LoopbackerTheme.accent : LoopbackerTheme.textMuted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(source.isEnabled ? LoopbackerTheme.accent.opacity(0.12) : LoopbackerTheme.bgInset)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        source.isEnabled ? LoopbackerTheme.accent.opacity(0.3) : LoopbackerTheme.border,
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Options section

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
                .background(LoopbackerTheme.border)

            HStack {
                Text("Pass-Thru")
                    .font(.system(size: 11))
                    .foregroundColor(LoopbackerTheme.textSecondary)

                Spacer()

                Toggle("", isOn: $source.isPassThrough)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(LoopbackerTheme.accent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Options toggle button

    private var optionsToggle: some View {
        HStack(spacing: 4) {
            Image(systemName: showOptions ? "chevron.up" : "chevron.down")
                .font(.system(size: 8, weight: .bold))
            Text("Options")
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(LoopbackerTheme.textMuted)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(LoopbackerTheme.bgInset.opacity(0.5))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                showOptions.toggle()
            }
        }
    }
}
