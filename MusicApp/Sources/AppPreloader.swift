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

    /// 启动时并行预加载
    func preload() async {
        async let r: Void = loadRecommended()
        async let m: Void = loadMine()
        _ = await (r, m)
    }

    // MARK: - 发现页

    private func loadRecommended() async {
        defer { discoverRecommendedReady = true }
        if let tracks = try? await API.recommend() {
            recommended = Array(tracks.prefix(6))
        }
    }

    // MARK: - 我的页

    private func loadMine() async {
        defer { mineLoaded = true }
        guard let token = AuthManager.shared.authToken else { return }
        async let s: Void = fetchStats(token)
        async let w: Void = fetchWorks(token)
        async let l: Void = fetchLikes(token)
        async let c: Void = fetchComments(token)
        _ = await (s, w, l, c)
    }

    private func fetchStats(_ token: String) async {
        var req = URLRequest(url: API.base.appendingPathComponent("my-stats"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        mineStatsSeconds = (obj["totalSeconds"] as? Int) ?? 0
    }

    private func fetchWorks(_ token: String) async {
        if let r = try? await API.myTracks(page: 1, pageSize: 20) {
            works = r.list
            worksTotal = r.total
        }
    }

    private func fetchLikes(_ token: String) async {
        if let r = try? await API.myLikes(page: 1, pageSize: 20) {
            likes = r.list
            likesTotal = r.total
        }
    }

    private func fetchComments(_ token: String) async {
        if let r = try? await API.myComments(page: 1, pageSize: 20) {
            comments = r.list
            commentsTotal = r.total
        }
    }
}
