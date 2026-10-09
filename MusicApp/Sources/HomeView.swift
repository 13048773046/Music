import SwiftUI

/// 首页：汽水音乐风格，上下滑动切换歌曲的沉浸式播放页
struct HomeView: View {
    @EnvironmentObject private var player: PlayerManager
    @State private var tracks: [Track] = []
    @State private var state: LoadState = .loading

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            switch state {
            case .loading:
                VStack(spacing: 14) {
                    ProgressView()
                        .tint(Theme.accent)
                    Text("加载中…")
                        .font(.footnote)
                        .foregroundColor(Theme.textSecondary)
                }

            case .failed(let message):
                StatusPlaceholder(
                    icon: "wifi.exclamationmark",
                    title: "加载失败",
                    message: message
                ) {
                    Task { await load() }
                }

            case .empty:
                StatusPlaceholder(
                    icon: "music.note.list",
                    title: "还没有歌曲",
                    message: "去「我的」页面上传你的第一首歌"
                )

            case .loaded:
                if tracks.isEmpty {
                    EmptyView()
                } else {
                    // 竖滑页直接绑定播放器全局索引：
                    // 无论从发现页/我的页切回首页，还是通知栏/锁屏切歌，
                    // 首页都会自动跳到当前正在播放的那一首
                    VerticalPager(
                        currentIndex: Binding(
                            get: { player.currentIndex },
                            set: { player.currentIndex = $0 }
                        ),
                        tracks: tracks,
                        onPageChanged: { index in
                            guard tracks.indices.contains(index) else { return }
                            player.play(tracks[index], in: tracks)
                        }
                    )
                    .ignoresSafeArea()
                }
            }
        }
        .task {
            if case .loaded = state {} else {
                await load()
            }
        }
        .onChange(of: tracks) { newTracks in
            // 首次加载且播放器还没有队列时，自动播放第一首
            if player.queue.isEmpty, !newTracks.isEmpty {
                player.play(newTracks[0], in: newTracks)
            }
        }
    }

    func load() async {
        state = .loading
        do {
            let list = try await API.tracks()
            tracks = list
            state = list.isEmpty ? .empty : .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
