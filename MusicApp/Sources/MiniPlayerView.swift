import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var player: PlayerManager
    var onOpenHome: () -> Void

    var body: some View {
        if let current = player.current {
            VStack(spacing: 0) {
                ProgressView(value: player.progress)
                    .progressViewStyle(.linear)
                    .tint(.purple)

                HStack(spacing: 12) {
                    AlbumArt(size: 42, title: current.title, coverURL: current.coverURL)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(current.title)
                            .font(.subheadline)
                            .lineLimit(1)
                            .foregroundColor(.primary)
                        Text(current.artist ?? "未知歌手")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        player.toggle()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 38))
                            .foregroundColor(.primary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture {
                    onOpenHome()
                }
            }
            .background(.ultraThinMaterial)
        }
    }
}
