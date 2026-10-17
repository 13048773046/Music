import Foundation

/// 启动页期间的全局预加载：主界面出现前并行拉取「发现页推荐 / 播放页曲库与播放流 / 我的页数据」，
/// 全部就绪后启动页才放行进入主界面（启动页 = 数据就绪驱动，不再固定时长）。
/// 各请求失败静默（ready 仍置位，进入后对应页面自行兜底加载/降级展示）。
final class AppPreloader: ObservableObject {
    static let shared = AppPreloader()

    /// 发现页「猜你喜欢」推荐
    @Published var recommended: [Track] = []
    @Published var discoverRecommendedReady: Bool = false

    /// 播放页：曲库加载完成（Library.load 内部已恢复会话或起新鲜流）
    @Published var playerReady: Bool = false

    /// 天气×时段场景（今日心情卡片）：带 2.5s 超时——定位授权可能等待用户响应，超时视作就绪
    @Published var weatherReady: Bool = false

    /// 我的页：听歌时长 + 三个列表第一页
    @Published var mineStatsSeconds: Int = 0
    @Published var works: [Track] = []
    @Published var worksTotal: Int = 0
    @Published var likes: [Track] = []
    @Published var likesTotal: Int = 0
    @Published var comments: [API.MyComment] = []
    @Published var commentsTotal: Int = 0
    @Published var mineLoaded: Bool = false

    /// 启动数据是否全部就绪（发现 / 播放 / 我的）：启动页放行条件。
    /// 天气场景不参与放行——后台独立加载（DiscoverView 展示时自取，失败降级「仅时段」）。
    var startupReady: Bool {
        discoverRecommendedReady && playerReady && mineLoaded
    }

    private init() {}

    /// 切换账号/新账号登录后失效「我的页」预加载数据：
    /// 下次进入「我的」页会自行按新账号重新拉取，避免展示旧账号数据。
    func invalidateMine() {
        mineLoaded = false
        mineStatsSeconds = 0
        works = []
        worksTotal = 0
        likes = []
        likesTotal = 0
        comments = []
        commentsTotal = 0
    }

    /// 启动时并行预加载：发现页推荐 / 播放页曲库 / 我的页统计与列表（天气场景后台独立加载，不阻塞启动页）
    func preload() async {
        async let r: Void = loadRecommended()
        async let p: Void = loadPlayer()
        async let m: Void = loadMine()
        _ = await (r, p, m)
        // 天气：放后台异步跑（不参与启动放行；DiscoverView 展示心情卡片时自取，失败降级「仅时段」）
        Task { await loadWeather() }
    }

    // MARK: - 发现页

    private func loadRecommended() async {
        defer { discoverRecommendedReady = true }
        // source=discover：发现页猜你喜欢不参与播放页首页的 3 小时推送去重，
        // 也不占用去重窗口（启动预加载的歌不应影响播放页推荐流）
        if let tracks = try? await API.recommend(source: "discover") {
            recommended = Array(tracks.prefix(6))
        }
    }

    // MARK: - 播放页

    private func loadPlayer() async {
        // Library.load 幂等（isLoaded 直接返回 / inFlight 复用同一任务）；其内部完成时
        // 已恢复上次会话或启动新鲜个性化推荐流（player.queue 就绪）
        await Library.shared.load()
        playerReady = true
    }

    // MARK: - 天气×时段场景

    private func loadWeather() async {
        // 定位授权/定位可能等待用户响应 → 最多等 2.5s，超时视作就绪（DiscoverView 自行降级「仅时段」）
        let fetch = Task { await WeatherContext.shared.refresh() }
        let timeout = Task { try? await Task.sleep(nanoseconds: 2_500_000_000) }
        _ = await (fetch.value, timeout.value)
        weatherReady = true
    }

    // MARK: - 我的页

    private func loadMine() async {
        defer { mineLoaded = true }
        // 未登录没有我的页数据：直接返回（stats/likes/comments 均需鉴权）
        guard AuthManager.shared.authToken != nil else { return }
        async let s: Void = fetchStats()
        async let w: Void = fetchWorks()
        async let l: Void = fetchLikes()
        async let c: Void = fetchComments()
        _ = await (s, w, l, c)
    }

    private func fetchStats() async {
        if let seconds = try? await API.myStats() {
            mineStatsSeconds = seconds
        }
    }

    private func fetchWorks() async {
        if let r = try? await API.myTracks(page: 1, pageSize: 20) {
            works = r.list
            worksTotal = r.total
        }
    }

    private func fetchLikes() async {
        if let r = try? await API.myLikes(page: 1, pageSize: 20) {
            likes = r.list
            likesTotal = r.total
        }
    }

    private func fetchComments() async {
        if let r = try? await API.myComments(page: 1, pageSize: 20) {
            comments = r.list
            commentsTotal = r.total
        }
    }
}
