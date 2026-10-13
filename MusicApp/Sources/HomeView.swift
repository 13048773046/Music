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
                if !player.queue.isEmpty {
                    // 竖滑页直接绑定播放器全局队列与索引：
                    // 无论普通全随机流、搜索相关流、发现页/搜索点击播放、
                    // 还是通知栏/锁屏切歌，首页都会自动同步到当前正在播放的那一首；
                    // 队列被整体替换（普通流↔相关流）时由 VerticalPager 重建页面
                    VerticalPager(
                        currentIndex: Binding(
                            get: { player.currentIndex },
                            set: { player.currentIndex = $0 }
                        ),
                        tracks: player.queue,
                        revision: player.queueRevision,
                        onPageChanged: { index in
                            guard player.queue.indices.contains(index) else { return }
                            player.play(player.queue[index], in: player.queue)
                            // 滑到倒数第二首附近，提前预取下一批（相关流/全随机由 Library 决定）
                            if index >= player.queue.count - 2 {
                                Task { await library.loadMore() }
                            }
                        }
                    )
                    .ignoresSafeArea()
                } else {
                    // 队列为空（曲库加载完成但无歌）：提示上传
                    StatusPlaceholder(
                        icon: "music.note.list",
                        title: "还没有歌曲",
                        message: "去「我的」页面上传你的第一首歌"
                    )
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
