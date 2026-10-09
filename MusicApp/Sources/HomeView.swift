import SwiftUI

/// 首页：汽水音乐风格，上下滑动切换歌曲的沉浸式播放页
/// 歌曲列表直接复用 Library 单例（启动页已开始预加载），进页面即播。
struct HomeView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: Library
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
                    Task { await refresh() }
                }

            case .empty:
                StatusPlaceholder(
                    icon: "music.note.list",
                    title: "还没有歌曲",
                    message: "去「我的」页面上传你的第一首歌"
                )

            case .loaded:
                if !library.tracks.isEmpty {
                    // 竖滑页直接绑定播放器全局索引：
                    // 无论从发现页/我的页切回首页，还是通知栏/锁屏切歌，
                    // 首页都会自动跳到当前正在播放的那一首
                    VerticalPager(
                        currentIndex: Binding(
                            get: { player.currentIndex },
                            set: { player.currentIndex = $0 }
                        ),
                        tracks: library.tracks,
                        onPageChanged: { index in
                            guard library.tracks.indices.contains(index) else { return }
                            player.play(library.tracks[index], in: library.tracks)
                        }
                    )
                    .ignoresSafeArea()
                }
            }
        }
        .task { await refresh() }
    }

    func refresh() async {
        // 启动页已经预加载过：直接用缓存，避免重复请求
        if library.isLoaded {
            state = library.tracks.isEmpty ? .empty : .loaded
            return
        }
        state = .loading
        await library.load()
        state = library.tracks.isEmpty ? .empty : .loaded
    }
}
