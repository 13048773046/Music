import SwiftUI

/// 播放历史页面
struct HistoryView: View {
    @EnvironmentObject private var player: PlayerManager
    @State private var items: [HistoryTrack] = []
    @State private var isLoading = false
    @State private var page = 1
    @State private var hasMore = true

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if items.isEmpty && isLoading {
                    ProgressView()
                        .padding(.top, 60)
                } else if items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 40))
                            .foregroundColor(Theme.textTertiary)
                        Text("暂无播放历史")
                            .font(.system(size: 15))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .padding(.top, 80)
                } else {
                    ForEach(items) { item in
                        historyRow(item)
                    }
                    if hasMore {
                        ProgressView()
                            .padding(.vertical, 16)
                            .onAppear { loadMore() }
                    }
                }
            }
        }
        .navigationTitle("播放历史")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Task { await reload() } }
    }

    private func historyRow(_ item: HistoryTrack) -> some View {
        Button {
            // 点击历史记录：播放这首歌
            let track = Track(id: item.trackId, title: item.title, artist: item.artist,
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
                Image(systemName: "play.fill")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func reload() async {
        page = 1
        hasMore = true
        await loadPage()
    }

    private func loadMore() {
        guard !isLoading, hasMore else { return }
        Task { await loadPage() }
    }

    private func loadPage() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let newItems = try await API.fetchHistory(page: page, pageSize: 30)
            if page == 1 {
                items = newItems
            } else {
                items.append(contentsOf: newItems)
            }
            hasMore = newItems.count >= 30
            page += 1
        } catch {
            // 静默失败
        }
    }
}
