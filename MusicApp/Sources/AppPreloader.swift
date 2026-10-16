import Foundation

/// 启动页期间的全局预加载：主界面出现前并行拉取「发现页推荐」与「我的页统计+三个列表第一页」，
/// 进入后切换发现/我的立即有数据，不再转圈等待（失败静默，各页面会自行兜底加载）。
final class AppPreloader: ObservableObject {
    static let shared = AppPreloader()

    /// 发现页「猜你喜欢」推荐
    @Published var recommended: [Track] = []
    @Published var discoverRecommendedReady: Bool = false

    /// 我的页：听歌时长 + 三个列表第一页
    @Published var mineStatsSeconds: Int = 0
    @Published var works: [Track] = []
    @Published var worksTotal: Int = 0
    @Published var likes: [Track] = []
    @Published var likesTotal: Int = 0
    @Published var comments: [API.MyComment] = []
    @Published var commentsTotal: Int = 0
    @Published var mineLoaded: Bool = false

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

    /// 启动时并行预加载
    func preload() async {
        async let r: Void = loadRecommended()
        async let m: Void = loadMine()
        _ = await (r, m)
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
