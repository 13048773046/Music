import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: Library
    @Environment(\.scenePhase) private var scenePhase
    @State private var state: LoadState = .loading
    @State private var latest: [Track] = []
    @State private var recommended: [Track] = []
    /// 切前台刷新节流：距上次刷新 ≥ 5 分钟才重拉（后端 3 小时去重保证不重复）
    @State private var lastRecommendAt: Date = .distantPast

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
        // 实时数据事件：个性化推荐更新 / 歌曲列表变化
        .onReceive(NotificationBus.shared.$lastDataEvent) { ev in
            guard let ev else { return }
            switch ev.event {
            case "recommend":
                Task { await loadRecommended() }
            case "track_list":
                Task {
                    await library.load(force: true)
                    applySections()
                }
            default:
                break
            }
        }
        // 切前台（App 从后台回前台）且距上次刷新 ≥5 分钟：重拉个性化推荐。
        // 之前"第二次打开还是同一批"的根因之一：切回前台不刷新，展示/播放的仍是旧推荐；
        // 后端 3 小时去重保证重拉拿到新一批（不重复推同一首）。
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            guard Date().timeIntervalSince(lastRecommendAt) >= 300 else { return }
            lastRecommendAt = Date()
            Task { await loadRecommended() }
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
                    HStack(alignment: .bottom, spacing: 12) {
                        sectionTitle("猜你喜欢", subtitle: recommendSubtitle)
                        Spacer()
                        // 换一批：后端多路召回每次含随机探索噪声，重拉即得到不同推荐
                        Button {
                            Task { await loadRecommended() }
                        } label: {
                            Label("换一批", systemImage: "arrow.clockwise")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Theme.accent)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 20)
                        .padding(.bottom, 2)
                    }
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
            // 下拉刷新：重拉曲库（新上传的歌立即可见）+ 同步刷新个性化推荐（多路召回含随机探索，结果会变化）
            await library.load(force: true)
            applySections()
            await loadRecommended()
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
            .shadow(color: Theme.accent.opacity(0.4), radius: 12, x: 0, y: 4)
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

    /// 推荐理由动态副标题：展示当前推荐里的理由标签集合（个性化推送的直观体现）
    private var recommendSubtitle: String {
        var seen = Set<String>()
        let unique = recommended.compactMap { $0.reason }.filter { reason in
            !reason.isEmpty && seen.insert(reason).inserted
        }
        if unique.isEmpty { return "根据你的听歌行为推荐" }
        return unique.prefix(3).joined(separator: " · ")
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

    /// 播放「猜你喜欢」推荐歌曲：以推荐列表为队列（后续滑到队尾自动续拉下一批推荐）。
    /// 不把推荐曲 append 进 library.tracks——那会污染发现页「全部歌曲」数据源。
    /// 播放前把本批推荐 id 记入播放器去重集合，保证无限续推不重复本批。
    private func playRecommended(_ track: Track) {
        library.searchContext = nil
        player.noteRecommended(recommended.map { $0.id })
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
                    // 推荐理由角标：后端多路召回返回的来源标签（相似歌曲/常听歌手/同风格/热门/新歌/为你探索）
                    Text(track.reason ?? "推荐")
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
        .buttonStyle(PressableButtonStyle())
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
        .buttonStyle(PressableButtonStyle())
    }
}
