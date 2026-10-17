import SwiftUI

/// 播放历史页面（数据源：本地存储 LocalPlayHistory，MRU 最近播放置顶）
struct HistoryView: View {
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss
    @State private var items: [LocalPlayHistory.Item] = []

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if items.isEmpty {
                    emptyState
                        .padding(.top, 80)
                } else {
                    // 头部统计
                    headerCard
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 8)

                    // 历史列表
                    ForEach(items) { item in
                        historyRow(item)
                            .padding(.horizontal, 16)
                    }
                }
            }
        }
        .appBottomTabSpacing()
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("播放历史")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                }
            }
        }
        .onAppear {
            items = LocalPlayHistory.load()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.card)
                    .frame(width: 80, height: 80)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 32))
                    .foregroundColor(Theme.textTertiary)
            }
            Text("暂无播放历史")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Text("你听过的歌曲会记录在这里（仅保存在本机）")
                .font(.system(size: 13))
                .foregroundColor(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var headerCard: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("最近听过")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Text("共 \(items.count) 首歌曲")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
            Image(systemName: "clock")
                .font(.system(size: 24))
                .foregroundColor(Theme.accent.opacity(0.6))
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private func historyRow(_ item: LocalPlayHistory.Item) -> some View {
        Button {
            let track = Track(id: item.id, title: item.title, artist: item.artist,
                              album: nil, cover: item.cover, size: nil,
                              dur: nil, durText: nil, created: item.created,
                              playCount: nil, likeCount: nil, shareCount: nil,
                              commentCount: nil, userId: nil, userName: nil,
                              hasLyric: nil, isLiked: nil, reason: nil)
            player.play(track, in: [track])
        } label: {
            HStack(spacing: 12) {
                AlbumArt(size: 48, title: item.title, coverURL: URL(string: item.cover), radius: 10)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Text(item.artist)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(Theme.accent.opacity(0.7))
            }
            .padding(.vertical, 10)
        }
        .buttonStyle(PressableButtonStyle())
    }
}
