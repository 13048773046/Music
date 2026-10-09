import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss
    @State private var dragging = false
    @State private var dragFraction: Double = 0

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.purple.opacity(0.35), .blue.opacity(0.22), .black.opacity(0.08)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.primary)
                    }
                    Spacer()
                    Text("正在播放")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Color.clear
                        .frame(width: 18, height: 18)
                }
                .padding(.horizontal, 20)

                Spacer(minLength: 8)

                if let current = player.current {
                    AlbumArt(size: 280, title: current.title)
                        .shadow(color: .black.opacity(0.25), radius: 24, y: 14)
                        .scaleEffect(dragging ? 0.96 : 1)
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: dragging)

                    VStack(spacing: 6) {
                        Text(current.title)
                            .font(.title2.bold())
                            .lineLimit(1)
                        Text(current.artist ?? "未知歌手")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        if let album = current.album, !album.isEmpty {
                            Text(album)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }

                    VStack(spacing: 6) {
                        Slider(
                            value: Binding(
                                get: { dragging ? dragFraction : player.progress },
                                set: { dragFraction = $0 }
                            ),
                            in: 0...1,
                            onEditingChanged: { editing in
                                dragging = editing
                                if !editing {
                                    player.seek(toFraction: dragFraction)
                                }
                            }
                        )
                        .tint(.accentColor)

                        HStack {
                            Text(formatTime(player.currentTime))
                                .font(.caption2.monospacedDigit())
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(formatTime(player.duration))
                                .font(.caption2.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack(spacing: 54) {
                        Button {
                            player.previous()
                        } label: {
                            Image(systemName: "backward.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.primary)
                        }
                        .buttonStyle(.plain)

                        Button {
                            player.toggle()
                        } label: {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 74))
                                .foregroundColor(.primary)
                        }
                        .buttonStyle(.plain)

                        Button {
                            player.next()
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 8)
                } else {
                    Spacer()
                    Text("没有正在播放的歌曲")
                        .foregroundColor(.secondary)
                    Spacer()
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 24)
        }
    }
}
