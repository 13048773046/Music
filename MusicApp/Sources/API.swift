import Foundation

enum API {
    static let base = URL(string: "https://www.dbmt999.asia/music/api")!

    /// 歌曲列表：可传 userId（拿点赞态）；keyword 非空时返回「相关歌曲流」
    /// （歌名/歌手/专辑/上传者匹配，随机 10 首，不足补全随机）
    static func tracks(userId: String? = nil, keyword: String? = nil) async throws -> [Track] {
        var components = URLComponents(url: base.appendingPathComponent("tracks"),
                                       resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        if let userId, !userId.isEmpty {
            items.append(URLQueryItem(name: "userId", value: userId))
        }
        if let keyword, !keyword.isEmpty {
            items.append(URLQueryItem(name: "q", value: keyword))
        }
        if !items.isEmpty {
            components.queryItems = items
        }
        var req = URLRequest(url: components.url!)
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode([Track].self, from: data)
    }

    /// 单曲详情：按 id 精确查询（用户上传 + 采集歌曲都覆盖，通知点击跳转播放用）
    static func track(id: String) async throws -> Track {
        var req = URLRequest(url: base.appendingPathComponent("track/\(id)"))
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Track.self, from: data)
    }

    /// 搜索歌曲：按歌名/歌手模糊匹配
    static func search(_ keyword: String) async throws -> [Track] {
        var components = URLComponents(url: base.appendingPathComponent("search"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: keyword)]
        var req = URLRequest(url: components.url!)
        req.timeoutInterval = 15
        applyAuth(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode([Track].self, from: data)
    }

    static func streamURL(_ id: String) -> URL {
        base.appendingPathComponent("stream").appendingPathComponent(id)
    }

    /// 获取带签名时效的播放 URL（防链接泄露/盗链）：
    /// 先向 /api/stream-url/{id} 签发短效签名；接口不可用（老服务）时回退普通 URL
    static func signedStreamURL(for id: String) async -> URL {
        let signURL = base.appendingPathComponent("stream-url").appendingPathComponent(id)
        var req = URLRequest(url: signURL)
        // 网络差时快速回退普通 URL：避免切歌后长时间卡在签名请求，新歌迟迟无法开始加载
        req.timeoutInterval = 6
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let exp = obj["exp"] as? Int, let sig = obj["sig"] as? String {
            var comps = URLComponents(url: streamURL(id), resolvingAgainstBaseURL: false)
            comps?.queryItems = [URLQueryItem(name: "exp", value: String(exp)),
                                 URLQueryItem(name: "sig", value: sig)]
            if let signed = comps?.url { return signed }
        }
        return streamURL(id)
    }

    /// 隐藏式分享短链（汽水风格）：https://域名/s/{8位短码}/ → H5 分享页；失败返回 nil
    static func shareLink(for id: String) async -> String? {
        let url = base.appendingPathComponent("share-url").appendingPathComponent(id)
        if let (data, _) = try? await URLSession.shared.data(from: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = obj["code"] as? String, !code.isEmpty,
           let host = base.host() {
            return "https://\(host)/s/\(code)/"
        }
        return nil
    }

    // MARK: - 鉴权请求基础设施（Bearer Token + 401 统一处理）

    /// 为请求附加当前登录用户的 Bearer Token（旧会话无 token 时不附加，依赖后端兼容模式）
    private static func applyAuth(_ req: inout URLRequest) {
        if let token = AuthManager.shared.authToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    /// 鉴权接口返回 401 时：清除本地登录态（下次进 App 要求重新登录）并抛错
    private static func checkAuth(_ resp: URLResponse?) throws {
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 {
            AuthManager.shared.handleUnauthorized()
            throw APIError.message("登录已过期，请重新登录")
        }
    }

    /// 上报类接口（播放/分享）：401 只静默清理登录态，不抛错打断播放流程
    private static func noticeAuthFailure(_ resp: URLResponse?) {
        if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
            AuthManager.shared.handleUnauthorized()
        }
    }

    // MARK: - 互动：播放 / 点赞 / 评论 / 分享

    static func reportPlay(_ trackId: String) async {
        var req = URLRequest(url: base.appendingPathComponent("play").appendingPathComponent(trackId))
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        applyAuth(&req)
        let (_, resp) = (try? await URLSession.shared.data(for: req)) ?? (Data(), nil)
        noticeAuthFailure(resp)
    }

    static func toggleLike(trackId: String, userId: String) async throws -> (liked: Bool, count: Int) {
        var req = URLRequest(url: base.appendingPathComponent("like").appendingPathComponent(trackId))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["userId": userId])
        applyAuth(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkAuth(resp)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (liked: (obj?["liked"] as? Bool) ?? false,
                count: (obj?["likeCount"] as? Int) ?? 0)
    }

    @discardableResult
    static func reportShare(_ trackId: String) async -> Int {
        var req = URLRequest(url: base.appendingPathComponent("share").appendingPathComponent(trackId))
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        applyAuth(&req)
        let (data, resp) = (try? await URLSession.shared.data(for: req)) ?? (Data(), nil)
        noticeAuthFailure(resp)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        return obj["shareCount"] as? Int ?? 0
    }

    // MARK: - 行为采集与个性化推荐

    /// 用户行为事件（批量上报，失败静默不打断播放流程）
    /// event: like / comment_open / comment / share / listen / search / skip
    /// value: listen 为本次新增收听秒数；meta 为 JSON 字符串（listen 携带 {fraction, plays, seconds}）
    struct BehaviorEvent: Encodable {
        let trackId: String
        let event: String
        var value: Double = 0
        var meta: String? = nil

        /// 生成 JSON 字符串形式的 meta
        static func metaJSON(_ dict: [String: Any]) -> String? {
            guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    /// 批量上报行为事件（失败静默，不打断播放流程）。
    /// 优先走 WebSocket 实时上报（即时通讯通道）：行为数据实时入库并触发 recommend 事件推送；
    /// WS 未连接（未登录/断线重连中）时回退 HTTP /api/behavior，保证行为不丢。
    static func reportBehavior(_ events: [BehaviorEvent]) async {
        guard !events.isEmpty else { return }
        if NotificationBus.shared.sendBehavior(events) { return }
        var req = URLRequest(url: base.appendingPathComponent("behavior"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10
        applyAuth(&req)
        let payload = ["events": events.map { try? JSONEncoder().encode($0) }
            .compactMap { $0 }.compactMap { try? JSONSerialization.jsonObject(with: $0) }]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        let (_, resp) = (try? await URLSession.shared.data(for: req)) ?? (Data(), nil)
        noticeAuthFailure(resp)
    }

    /// 个性化推荐：基于用户行为返回 20 首相关歌曲（未登录/无行为时后端返回随机兜底）。
    /// - Parameter excluding: 已推荐过的歌曲 id（推荐流无限续推防重复，后端逐条排除）
    /// - Parameter fresh: 长时间重开 App 的新鲜会话——后端加大随机扰动/探索权重，
    ///   让重新开始的一批推荐带随机性、不固定重复上次
    /// - Parameter lat/lng/hour: M2 天气×时段场景上下文——后端据此叠加"应景推荐"（个性化×场景双向融合）；
    ///   传 nil 时后端按时段兜底场景，推荐照常返回
    static func recommend(userId: String? = nil, excluding: [String] = [],
                           fresh: Bool = false, source: String? = nil,
                           lat: Double? = nil, lng: Double? = nil,
                           hour: Int? = nil) async throws -> [Track] {
        var components = URLComponents(url: base.appendingPathComponent("recommend"),
                                       resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        let uid = userId ?? AuthManager.shared.currentUser?.id
        if let uid, !uid.isEmpty {
            items.append(URLQueryItem(name: "userId", value: uid))
        }
        if !excluding.isEmpty {
            items.append(URLQueryItem(name: "exclude", value: excluding.joined(separator: ",")))
        }
        if fresh {
            items.append(URLQueryItem(name: "fresh", value: "1"))
        }
        if let source, !source.isEmpty {
            items.append(URLQueryItem(name: "source", value: source))
        }
        // M2 场景上下文：定位可用时叠加；不可用时缺省（后端时段兜底，不阻塞推荐）
        if let lat {
            items.append(URLQueryItem(name: "lat", value: String(format: "%.4f", lat)))
        }
        if let lng {
            items.append(URLQueryItem(name: "lng", value: String(format: "%.4f", lng)))
        }
        if let hour {
            items.append(URLQueryItem(name: "hour", value: String(hour)))
        }
        if !items.isEmpty {
            components.queryItems = items
        }
        var req = URLRequest(url: components.url!)
        req.timeoutInterval = 15
        applyAuth(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode([Track].self, from: data)
    }

    /// 天气×心情场景快照（M2）：发现页"今日心情卡片"用。
    /// 失败（网络/参数/服务不可用）返回 nil，调用方静默降级为"仅时段"。
    struct WeatherInfo: Decodable {
        let ok: Bool
        let temp: Double?
        let code: Int?
        let hour: Int?
        let scene: String?
        let sceneLabel: String?
    }

    static func fetchWeather(lat: Double, lng: Double, hour: Int? = nil) async -> WeatherInfo? {
        var components = URLComponents(url: base.appendingPathComponent("weather"),
                                       resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "lat", value: String(format: "%.4f", lat)),
            URLQueryItem(name: "lng", value: String(format: "%.4f", lng)),
        ]
        if let hour {
            items.append(URLQueryItem(name: "hour", value: String(hour)))
        }
        components.queryItems = items
        var req = URLRequest(url: components.url!)
        req.timeoutInterval = 10
        let (data, resp) = (try? await URLSession.shared.data(for: req)) ?? (Data(), nil)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }
        return try? JSONDecoder().decode(WeatherInfo.self, from: data)
    }

    /// 我的喜欢：用户点赞过的歌曲列表（上传+采集混合，按点赞时间倒序）
    static func likedTracks(userId: String? = nil) async throws -> [Track] {
        var components = URLComponents(url: base.appendingPathComponent("likes"),
                                       resolvingAgainstBaseURL: false)!
        let uid = userId ?? AuthManager.shared.currentUser?.id
        if let uid, !uid.isEmpty {
            components.queryItems = [URLQueryItem(name: "userId", value: uid)]
        }
        var req = URLRequest(url: components.url!)
        req.timeoutInterval = 15
        applyAuth(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode([Track].self, from: data)
    }

    // MARK: - 我的页面分页数据（my-tracks / my-likes / my-comments）

    /// 分页响应通用结构：{ list, total, hasMore }
    struct PageResult<T: Decodable>: Decodable {
        let list: [T]
        let total: Int
        let hasMore: Bool
    }

    /// 我的评论条目（含对应歌曲信息，点击可直接播放）
    struct MyComment: Codable, Identifiable, Hashable {
        let trackId: String
        let content: String
        let created: Double?
        let title: String?
        let artist: String?

        var id: String { "\(trackId)-\(Int(created ?? 0))" }
    }

    /// 分页请求公共逻辑：拼 page/pageSize 参数 + Bearer 鉴权 + 解码 PageResult
    private static func fetchPage<T: Decodable>(path: String, page: Int?,
                                                pageSize: Int) async throws -> PageResult<T> {
        var components = URLComponents(url: base.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)!
        if let page {
            components.queryItems = [URLQueryItem(name: "page", value: String(page)),
                                     URLQueryItem(name: "pageSize", value: String(pageSize))]
        }
        var req = URLRequest(url: components.url!)
        req.timeoutInterval = 15
        applyAuth(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkAuth(resp)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(PageResult<T>.self, from: data)
    }

    /// 我的上传作品（分页）；page 传 nil 时后端返回全量（兼容旧服务）
    static func myTracks(page: Int? = nil, pageSize: Int = 20) async throws -> PageResult<Track> {
        try await fetchPage(path: "my-tracks", page: page, pageSize: pageSize)
    }

    /// 我的点赞歌曲（分页，上传+采集混合）
    static func myLikes(page: Int? = nil, pageSize: Int = 20) async throws -> PageResult<Track> {
        try await fetchPage(path: "my-likes", page: page, pageSize: pageSize)
    }

    /// 我的评论（分页）
    static func myComments(page: Int? = nil, pageSize: Int = 20) async throws -> PageResult<MyComment> {
        try await fetchPage(path: "my-comments", page: page, pageSize: pageSize)
    }

    /// 我的页统计：累计听歌时长（秒）。统一封装，AppPreloader 与 MineView 共用。
    static func myStats() async throws -> Int {
        var req = URLRequest(url: base.appendingPathComponent("my-stats"))
        req.timeoutInterval = 15
        applyAuth(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkAuth(resp)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        return (obj["totalSeconds"] as? Int) ?? 0
    }

    struct Comment: Codable, Identifiable, Hashable {
        let id: String
        let userId: String
        let userName: String
        let content: String
        let created: Double
        /// 评论图片（服务端文件名，经 /api/comment-image/{name} 访问；旧评论无图时为 nil）
        let images: [String]?
    }

    static func fetchComments(trackId: String) async throws -> [Comment] {
        let url = base.appendingPathComponent("comments").appendingPathComponent(trackId)
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([Comment].self, from: data)
    }

    static func postComment(trackId: String, userId: String, userName: String, content: String,
                            images: [String] = []) async throws {
        var req = URLRequest(url: base.appendingPathComponent("comment").appendingPathComponent(trackId))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "userId": userId, "userName": userName, "content": content, "images": images
        ])
        applyAuth(&req)
        let (_, resp) = try await URLSession.shared.data(for: req)
        try checkAuth(resp)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    /// 上传评论图片（multipart，服务端校验图片格式/大小），返回服务端文件名
    static func uploadCommentImage(_ imageData: Data) async throws -> String {
        var body = MultipartBody()
        body.file("image", fileName: "comment.jpg", contentType: "image/jpeg", fileData: imageData)
        body.finish()
        var req = URLRequest(url: base.appendingPathComponent("upload-comment-image"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(body.boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.data
        req.timeoutInterval = 30
        applyAuth(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkAuth(resp)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String, !name.isEmpty else {
            throw URLError(.badServerResponse)
        }
        return name
    }

    /// 评论图片访问 URL
    static func commentImageURL(_ name: String) -> URL {
        base.appendingPathComponent("comment-image").appendingPathComponent(name)
    }

    static func coverURL(_ id: String) -> URL {
        base.appendingPathComponent("cover").appendingPathComponent(id)
    }

    static func lyricURL(_ id: String) -> URL {
        base.appendingPathComponent("lyric").appendingPathComponent(id)
    }

    /// 歌词内存缓存：听歌模式切换恢复、切回同一首歌时歌词秒出，不重复请求。
    /// 设置上限防膨胀（长滑数百首后防止歌词文本常驻内存），内存警告时全清。
    private static let lyricLock = NSLock()
    private static var lyricCache: [String: String] = [:]
    private static let lyricCacheMax = 300

    static func fetchLyric(_ id: String) async throws -> String {
        lyricLock.lock()
        let cached = lyricCache[id]
        lyricLock.unlock()
        if let cached { return cached }
        let (data, resp) = try await URLSession.shared.data(from: lyricURL(id))
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        lyricLock.lock()
        if lyricCache.count >= lyricCacheMax {
            lyricCache.removeAll()   // 达到上限：整清（歌词可随时重新拉取，无需复杂淘汰）
        }
        lyricCache[id] = text
        lyricLock.unlock()
        return text
    }

    /// 清空歌词缓存（内存警告时调用）
    static func clearLyricCache() {
        lyricLock.lock()
        lyricCache.removeAll()
        lyricLock.unlock()
    }

    static func avatarURL(_ id: String) -> URL {
        base.appendingPathComponent("avatar").appendingPathComponent(id)
    }

    static func backgroundURL(_ id: String) -> URL {
        base.appendingPathComponent("background").appendingPathComponent(id)
    }

    // MARK: - Multipart 表单构建（复用，消除各接口重复粘贴的 field/filePart）

    /// 增量构建 multipart/form-data 请求体
    private struct MultipartBody {
        let boundary: String
        private(set) var data = Data()

        init() {
            boundary = "Boundary-\(UUID().uuidString)"
        }

        mutating func field(_ name: String, _ value: String) {
            data.append(Data("--\(boundary)\r\n".utf8))
            data.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            data.append(Data("\(value)\r\n".utf8))
        }

        mutating func file(_ name: String, fileName: String, contentType: String, fileData: Data) {
            data.append(Data("--\(boundary)\r\n".utf8))
            data.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n".utf8))
            data.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
            data.append(fileData)
            data.append(Data("\r\n".utf8))
        }

        mutating func finish() {
            data.append(Data("--\(boundary)--\r\n".utf8))
        }
    }

    // MARK: - 用户注册 / 登录（multipart）

    /// 注册：账号由后端自动生成 6 位数字，无需客户端提交
    static func register(password: String, name: String,
                         avatarData: Data?,
                         gender: String = "", age: Int = 0, signature: String = "",
                         backgroundData: Data?) async throws -> User {
        var body = MultipartBody()
        body.field("password", password)
        body.field("name", name)
        body.field("gender", gender)
        body.field("age", String(age))
        body.field("signature", signature)
        if let avatarData {
            body.file("avatar", fileName: "avatar.jpg", contentType: "image/jpeg", fileData: avatarData)
        }
        if let backgroundData {
            body.file("background", fileName: "background.jpg", contentType: "image/jpeg", fileData: backgroundData)
        }
        body.finish()
        return try await submitUser(path: "register", boundary: body.boundary, body: body.data)
    }

    static func login(account: String, password: String) async throws -> User {
        var body = MultipartBody()
        body.field("account", account)
        body.field("password", password)
        body.finish()
        return try await submitUser(path: "login", boundary: body.boundary, body: body.data)
    }

    /// 更新当前用户资料（可选替换头像/背景图）
    static func updateProfile(account: String, name: String, gender: String, age: Int,
                              signature: String, city: String,
                              avatarData: Data?, backgroundData: Data?) async throws -> User {
        var body = MultipartBody()
        body.field("account", account)
        body.field("name", name)
        body.field("gender", gender)
        body.field("age", String(age))
        body.field("signature", signature)
        body.field("city", city)
        if let avatarData {
            body.file("avatar", fileName: "avatar.jpg", contentType: "image/jpeg", fileData: avatarData)
        }
        if let backgroundData {
            body.file("background", fileName: "background.jpg", contentType: "image/jpeg", fileData: backgroundData)
        }
        body.finish()
        return try await submitUser(path: "profile/update", boundary: body.boundary, body: body.data,
                                    authed: true)
    }

    /// 修改密码（需登录）：旧密码校验通过后更新为新密码
    static func changePassword(old: String, new: String) async throws {
        var body = MultipartBody()
        body.field("old_password", old)
        body.field("new_password", new)
        body.finish()

        var req = URLRequest(url: base.appendingPathComponent("change-password"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(body.boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = body.data
        applyAuth(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        try checkAuth(resp)
        guard (200...299).contains(http.statusCode) else {
            if let err = try? JSONDecoder().decode([String: String].self, from: data),
               let msg = err["err"] {
                throw APIError.message(msg)
            }
            throw URLError(.badServerResponse)
        }
    }

    /// 版本更新检查结果（/api/check-update）
    struct UpdateCheck: Decodable {
        let hasUpdate: Bool
        let id: String?
        let title: String?
        let content: String?
        let version: String?
        let forceUpdate: Int?
        let downloadUrl: String?
        let downloadUrlIos: String?
    }

    /// 手动检查版本更新
    static func checkUpdate() async -> UpdateCheck? {
        var req = URLRequest(url: base.appendingPathComponent("check-update"))
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONDecoder().decode(UpdateCheck.self, from: data) else { return nil }
        return obj
    }

    private static func submitUser(path: String, boundary: String, body: Data,
                                   authed: Bool = false) async throws -> User {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = body
        if authed {
            applyAuth(&req)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if authed {
            try checkAuth(resp)
        }
        guard (200...299).contains(http.statusCode) else {
            if let err = try? JSONDecoder().decode([String: String].self, from: data),
               let msg = err["err"] {
                throw APIError.message(msg)
            }
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(User.self, from: data)
    }

    static func upload(data: Data, filename: String, title: String, artist: String, album: String,
                       userId: String = "",
                       coverData: Data? = nil, coverFilename: String? = nil) async throws {
        var body = MultipartBody()
        body.field("title", title)
        body.field("artist", artist)
        body.field("album", album)
        body.field("userId", userId)
        body.file("file", fileName: filename, contentType: "audio/mpeg", fileData: data)
        if let coverData, let coverFilename {
            body.file("cover", fileName: coverFilename, contentType: "image/jpeg", fileData: coverData)
        }
        body.finish()

        var req = URLRequest(url: base.appendingPathComponent("upload"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(body.boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 180
        req.httpBody = body.data
        applyAuth(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkAuth(resp)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            if let err = try? JSONDecoder().decode([String: String].self, from: data),
               let msg = err["err"] {
                throw APIError.message(msg)
            }
            throw URLError(.badServerResponse)
        }
    }

    // MARK: - 消息通知

    /// 官方通知消息（聊天记录样式）
    struct OfficialMessage: Codable, Identifiable, Hashable {
        let id: String
        let content: String
        let created: Double
        let sender: String?
    }

    /// 用户互动通知（点赞/评论/分享）
    struct Notification: Codable, Identifiable, Hashable {
        let id: String
        let type: String        // like / comment / share / official
        let title: String?
        let content: String?
        let fromUser: String?
        let fromUserId: String?
        let commentId: String?  // 评论类通知对应评论 id（点击定位到那条评论）
        let trackId: String?
        let trackTitle: String?
        let isRead: Int         // 0=未读 1=已读
        let created: Double

        var unread: Bool { isRead == 0 }
    }

    /// WebSocket 实时推送地址（wss://…/music/api/ws?token=xxx）
    static func wsURL(token: String) -> URL? {
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        comps.scheme = "wss"
        var path = comps.path
        if !path.hasSuffix("/") { path += "/" }
        comps.path = path + "ws"
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
        return comps.url
    }

    /// 获取官方通知列表（聊天记录，只读）
    static func officialMessages() async throws -> [OfficialMessage] {
        let url = base.appendingPathComponent("official-messages")
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        applyAuth(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkAuth(resp)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        struct MsgList: Decodable { let list: [OfficialMessage] }
        return try JSONDecoder().decode(MsgList.self, from: data).list
    }

    /// 获取我的互动通知列表
    static func notifications() async throws -> (list: [Notification], unread: Int) {
        let url = base.appendingPathComponent("notifications")
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        applyAuth(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkAuth(resp)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        struct NotifResp: Decodable {
            let list: [Notification]
            let unread: Int
        }
        let r = try JSONDecoder().decode(NotifResp.self, from: data)
        return (r.list, r.unread)
    }

    /// 标记所有通知为已读
    static func markNotificationsRead() async {
        var req = URLRequest(url: base.appendingPathComponent("notifications/read"))
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        applyAuth(&req)
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - 播放历史
    /// 记录播放历史
    static func recordHistory(trackId: String, title: String, artist: String, cover: String) async {
        var req = URLRequest(url: base.appendingPathComponent("history"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10
        applyAuth(&req)
        let body: [String: Any] = ["trackId": trackId, "title": title, "artist": artist, "cover": cover]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }

    /// 获取播放历史
    static func fetchHistory(page: Int = 1, pageSize: Int = 30) async throws -> [HistoryTrack] {
        var req = URLRequest(url: base.appendingPathComponent("history?page=\(page)&size=\(pageSize)"))
        req.timeoutInterval = 15
        applyAuth(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkAuth(resp)
        struct Resp: Decodable { let list: [HistoryTrack] }
        let r = try JSONDecoder().decode(Resp.self, from: data)
        return r.list
    }

    // MARK: - 搜索历史
    /// 记录搜索历史
    static func recordSearch(keyword: String) async {
        var req = URLRequest(url: base.appendingPathComponent("search/history"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10
        applyAuth(&req)
        let body: [String: Any] = ["keyword": keyword]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }

    /// 获取搜索历史
    static func fetchSearchHistory() async throws -> [SearchHistoryItem] {
        var req = URLRequest(url: base.appendingPathComponent("search/history"))
        req.timeoutInterval = 15
        applyAuth(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkAuth(resp)
        struct Resp: Decodable { let list: [SearchHistoryItem] }
        let r = try JSONDecoder().decode(Resp.self, from: data)
        return r.list
    }

    /// 清空搜索历史
    static func clearSearchHistory() async {
        var req = URLRequest(url: base.appendingPathComponent("search/history"))
        req.httpMethod = "DELETE"
        req.timeoutInterval = 10
        applyAuth(&req)
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - 歌单
    /// 获取我的歌单列表
    static func fetchPlaylists() async throws -> [Playlist] {
        var req = URLRequest(url: base.appendingPathComponent("playlists"))
        req.timeoutInterval = 15
        applyAuth(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkAuth(resp)
        struct Resp: Decodable { let list: [Playlist] }
        let r = try JSONDecoder().decode(Resp.self, from: data)
        return r.list
    }

    /// 创建歌单
    static func createPlaylist(name: String, description: String = "") async throws -> String {
        var req = URLRequest(url: base.appendingPathComponent("playlists"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10
        applyAuth(&req)
        let body: [String: Any] = ["name": name, "description": description]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        struct R: Decodable { let playlistId: String }
        let r = try JSONDecoder().decode(R.self, from: data)
        return r.playlistId
    }

    /// 获取歌单歌曲列表
    static func fetchPlaylistTracks(_ playlistId: String) async throws -> (playlist: Playlist, tracks: [HistoryTrack]) {
        var req = URLRequest(url: base.appendingPathComponent("playlists/\(playlistId)/tracks"))
        req.timeoutInterval = 15
        applyAuth(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkAuth(resp)
        struct Resp: Decodable { let playlist: Playlist; let list: [HistoryTrack] }
        let r = try JSONDecoder().decode(Resp.self, from: data)
        return (r.playlist, r.list)
    }

    /// 添加歌曲到歌单
    static func addToPlaylist(playlistId: String, trackId: String, title: String, artist: String, cover: String) async throws {
        var req = URLRequest(url: base.appendingPathComponent("playlists/\(playlistId)/tracks"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10
        applyAuth(&req)
        let body: [String: Any] = ["trackId": trackId, "title": title, "artist": artist, "cover": cover]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw APIError.message("无响应")
        }
        guard http.statusCode == 200 else {
            throw APIError.message("HTTP \(http.statusCode)")
        }
    }

    /// 从歌单删除歌曲
    static func removeFromPlaylist(playlistId: String, trackId: String) async {
        var req = URLRequest(url: base.appendingPathComponent("playlists/\(playlistId)/tracks/\(trackId)"))
        req.httpMethod = "DELETE"
        req.timeoutInterval = 10
        applyAuth(&req)
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - 通知软删除
    /// 软删除单条通知
    static func deleteNotification(_ id: String) async {
        var req = URLRequest(url: base.appendingPathComponent("notifications/\(id)"))
        req.httpMethod = "DELETE"
        req.timeoutInterval = 10
        applyAuth(&req)
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - 评论点赞
    /// 点赞/取消点赞评论
    static func toggleCommentLike(_ commentId: String) async throws -> (liked: Bool, count: Int) {
        var req = URLRequest(url: base.appendingPathComponent("comments/\(commentId)/like"))
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        applyAuth(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        struct R: Decodable { let liked: Bool; let likeCount: Int }
        let r = try JSONDecoder().decode(R.self, from: data)
        return (r.liked, r.likeCount)
    }

    // MARK: - 用户主页
    /// 获取用户主页信息
    static func fetchUserProfile(_ userId: String) async throws -> UserProfile {
        var req = URLRequest(url: base.appendingPathComponent("user/\(userId)/profile"))
        req.timeoutInterval = 15
        applyAuth(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkAuth(resp)
        struct Resp: Decodable {
            let userId: String; let account: String; let name: String; let avatar: String
            let signature: String; let created: Double; let gender: String; let age: Int
            let trackCount: Int; let likeCount: Int
            let followerCount: Int; let followingCount: Int; let mutualCount: Int
            let isFollowing: Bool
            let backgroundImage: String; let city: String
        }
        let r = try JSONDecoder().decode(Resp.self, from: data)
        return UserProfile(userId: r.userId, account: r.account, name: r.name, avatar: r.avatar,
                          signature: r.signature, created: r.created, gender: r.gender, age: r.age,
                          trackCount: r.trackCount, likeCount: r.likeCount,
                          followerCount: r.followerCount, followingCount: r.followingCount,
                          mutualCount: r.mutualCount, isFollowing: r.isFollowing,
                          backgroundImage: r.backgroundImage, city: r.city)
    }

    /// 关注/取关用户
    static func toggleFollow(_ userId: String) async throws -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("user/\(userId)/follow"))
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        applyAuth(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        struct R: Decodable { let isFollowing: Bool }
        let r = try JSONDecoder().decode(R.self, from: data)
        return r.isFollowing
    }

    /// 获取用户上传的歌曲
    static func fetchUserTracks(_ userId: String) async throws -> [Track] {
        var req = URLRequest(url: base.appendingPathComponent("user/\(userId)/tracks"))
        req.timeoutInterval = 15
        applyAuth(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkAuth(resp)
        struct Resp: Decodable { let list: [Track] }
        let r = try JSONDecoder().decode(Resp.self, from: data)
        return r.list
    }
}

// MARK: - 数据模型
struct HistoryTrack: Decodable, Identifiable {
    let id: String
    let trackId: String
    let title: String
    let artist: String
    let cover: String
    let source: String
    let created: Double
}

struct SearchHistoryItem: Decodable, Identifiable {
    let id: String
    let keyword: String
    let created: Double
}

struct Playlist: Decodable, Identifiable {
    let id: String
    let name: String
    let cover: String
    let description: String
    let trackCount: Int
    let created: Double
}

struct UserProfile: Decodable {
    let userId: String
    let account: String
    let name: String
    let avatar: String
    let signature: String
    let created: Double
    let gender: String
    let age: Int
    let trackCount: Int
    let likeCount: Int
    let followerCount: Int
    let followingCount: Int
    let mutualCount: Int
    let isFollowing: Bool
    let backgroundImage: String
    let city: String
}
