import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: Library
    @Environment(\.scenePhase) private var scenePhase
    /// M2 天气×时段场景上下文（全局单例）：定位失败/拒绝 → 仅时段降级，不阻塞发现页
    @ObservedObject private var weather = WeatherContext.shared
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
                // 内容加载与天气刷新并行：天气（30 分钟节流，失败降级「仅时段」）绝不阻塞内容加载——
                // 否则定位授权等待（系统弹窗未决）会让发现页一直停在「加载中…」
                async let w: Void = { await weather.refresh() }()
                if case .loaded = state {} else {
                    await load()
                }
                _ = await w
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
            // M2：切前台也顺带刷新天气场景（WeatherContext 内部 30 分钟节流）
            Task { await weather.refresh() }
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

                // 今日心情卡片：天气可用 → 天气×时段场景；不可用 → 「仅时段」兜底卡片（卡片常驻不消失）。
                // 之前定位/天气失败时整卡隐藏，用户会疑惑"卡片去哪了"。
                if let label = weather.sceneLabel {
                    weatherCard(label: label, icon: weatherIcon(for: weather.scene))
                } else {
                    weatherCard(label: "\(timeOfDayLabel())时段", icon: timeOfDayIcon)
                }

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
            // 底部留白：动态 = 系统底部安全区 + App 内部 TabBar 高度 + 呼吸余量
            .padding(.bottom, TabBarMetrics.total + 24)
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

    // MARK: - 今日心情卡片（M2）

    /// 天气×时段场景卡片：展示场景标签 + 温度/城市；右上角可手动刷新（强制重取，绕过 30 分钟节流）
    private func weatherCard(label: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(Theme.accent)
                .frame(width: 48, height: 48)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text("今日心情 · \(label)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                HStack(spacing: 4) {
                    if let temp = weather.temperature {
                        Text("\(Int(temp.rounded()))°C")
                    }
                    if let city = weather.city, !city.isEmpty {
                        Text("· \(city)")
                    }
                }
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
            }
            Spacer()
            Button {
                Task { await weather.refresh(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.accent)
            }
            .buttonStyle(.plain)
        }
        .softCard(radius: 16, padding: 14)
        .padding(.horizontal, 20)
    }

    /// 场景 → SF Symbol 图标（与后端场景 key 一一对应；未知场景用 sparkles 兜底）
    private func weatherIcon(for scene: String?) -> String {
        switch scene {
        case "rain": return "cloud.rain.fill"
        case "snow": return "snowflake"
        case "hot": return "sun.max.fill"
        case "cold": return "thermometer.snowflake"
        case "clear_day_morning", "clear_day_afternoon": return "sun.max.fill"
        case "clear_day_evening": return "sunset.fill"
        case "night": return "moon.stars.fill"
        case "cloudy": return "cloud.fill"
        default: return "sparkles"
        }
    }

    /// 本地时段标签（天气不可用时的兜底卡片）：按小时返回「深夜/清晨/上午/中午/下午/傍晚/晚上」
    private var timeOfDayLabel: String {
        let h = weather.hour ?? Calendar.current.component(.hour, from: Date())
        switch h {
        case 0..<5: return "深夜"
        case 5..<8: return "清晨"
        case 8..<11: return "上午"
        case 11..<13: return "中午"
        case 13..<17: return "下午"
        case 17..<19: return "傍晚"
        default: return "晚上"
        }
    }

    /// 时段兜底图标
    private var timeOfDayIcon: String {
        let h = weather.hour ?? Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<8: return "sunrise.fill"
        case 8..<17: return "sun.max.fill"
        case 17..<19: return "sunset.fill"
        default: return "moon.stars.fill"
        }
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

    /// 拉取个性化推荐填充「猜你喜欢」区块（失败静默，区块自动隐藏）。
    /// source=discover：猜你喜欢不参与播放页首页的 3 小时推送去重，
    /// 换一批永远能拿到新候选（不再被去重窗口排空导致区块消失）。
    /// M2：附带场景参数（lat/lng/hour）——定位未就绪时传 nil，后端按时段兜底。
    private func loadRecommended() async {
        do {
            let tracks = try await API.recommend(source: "discover",
                                                 lat: weather.lat,
                                                 lng: weather.lng,
                                                 hour: weather.hour)
            guard !Task.isCancelled else { return }
            // 防御：接口返回空时不覆盖旧推荐（区块不消失），仅在新数据非空时更新
            if !tracks.isEmpty {
                recommended = Array(tracks.prefix(6))
            }
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
