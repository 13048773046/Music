import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: Library
    @State private var state: LoadState = .loading
    @State private var latest: [Track] = []
    @State private var recommended: [Track] = []

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                Group {
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
                            icon: "sparkles",
                            title: "暂时没有可发现的内容",
                            message: "去首页上传歌曲后，这里会有推荐"
                        )

                    case .loaded:
                        content
                    }
                }
            }
            .navigationBarHidden(true)
            .task {
                if case .loaded = state {} else {
                    await load()
                }
            }
        }
        .tint(Theme.accent)
    }

    // MARK: - 内容

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                // 头部
                header

                if !recommended.isEmpty {
                    // 默认推荐位 = 猜你喜欢：基于听歌行为的个性化推荐（未登录/无行为时后端随机兜底）
                    sectionTitle("猜你喜欢", subtitle: "根据你的听歌行为推荐")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(recommended) { track in
                                RecommendCard(track: track) {
                                    playRecommended(track)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }

                if !latest.isEmpty {
                    sectionTitle("最新上架", subtitle: "刚刚入库的新鲜音乐")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(latest) { track in
                                LatestCard(track: track) {
                                    library.playFromDiscover(track)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }

                sectionTitle("全部歌曲", subtitle: "共 \(library.tracks.count) 首")
                LazyVStack(spacing: 10) {
                    ForEach(library.tracks) { track in
                        TrackRow(track: track) {
                            library.playFromDiscover(track)
                        }
                        .softCard(radius: 14, padding: 8)
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 12)
            .padding(.bottom, 120)
        }
        .refreshable {
            await load()
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("发现音乐")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Text("好听的不止一首")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
            ZStack {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 42, height: 42)
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 19, weight: .bold))
                .foregroundColor(Theme.textPrimary)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - 加载（复用启动页预加载的 Library 数据）

    func load() async {
        if library.isLoaded {
            applySections()
            return
        }
        state = .loading
        await library.load()
        applySections()
    }

    private func applySections() {
        if library.tracks.isEmpty {
            state = .empty
        } else {
            buildSections(from: library.tracks)
            state = .loaded
        }
        // 默认推荐位 = 猜你喜欢：启动页已预加载则直接用，否则异步拉取（失败静默）
        let pre = AppPreloader.shared
        if pre.discoverRecommendedReady {
            recommended = pre.recommended
        } else {
            Task { await loadRecommended() }
        }
    }

    /// 拉取个性化推荐填充「猜你喜欢」区块（失败静默，区块自动隐藏）
    private func loadRecommended() async {
        do {
            let tracks = try await API.recommend()
            guard !Task.isCancelled else { return }
            recommended = Array(tracks.prefix(6))
        } catch {
            // 静默：接口不可用或网络失败时不展示该区块
        }
    }

    /// 播放「猜你喜欢」推荐歌曲：以推荐列表为队列（后续续拉切回普通全随机流）
    private func playRecommended(_ track: Track) {
        library.searchContext = nil
        if !library.tracks.contains(where: { $0.id == track.id }) {
            library.tracks.append(track)
        }
        player.playInNormalMode(track, in: recommended)
    }

    /// 最新 = 按入库时间倒序前 6；猜你喜欢区块由 loadRecommended() 异步填充
    private func buildSections(from list: [Track]) {
        let sorted = list.sorted { ($0.created ?? 0) > ($1.created ?? 0) }
        latest = Array(sorted.prefix(6))
    }
}

// MARK: - 推荐大卡片

private struct RecommendCard: View {
    let track: Track
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    AlbumArt(size: 190, title: track.title, coverURL: track.coverURL, radius: 18)
                    Text("推荐")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.accent, in: Capsule())
                        .padding(8)
                }

                Text(track.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .foregroundColor(Theme.textPrimary)
                Text(track.artist ?? "未知歌手")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: 190, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 最新上架卡片

private struct LatestCard: View {
    let track: Track
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                AlbumArt(size: 150, title: track.title, coverURL: track.coverURL, radius: 16)
                Text(track.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .foregroundColor(Theme.textPrimary)
                Text(track.artist ?? "未知歌手")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
            .softCard(radius: 18, padding: 12)
        }
        .buttonStyle(.plain)
    }
}
