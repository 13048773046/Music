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

    /// 批量上报行为事件到 /api/behavior（401 静默清理登录态，不抛错）
    static func reportBehavior(_ events: [BehaviorEvent]) async {
        guard !events.isEmpty else { return }
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

    /// 个性化推荐：基于用户行为返回 20 首相关歌曲（未登录/无行为时后端返回随机兜底）
    static func recommend(userId: String? = nil) async throws -> [Track] {
        var components = URLComponents(url: base.appendingPathComponent("recommend"),
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

    struct Comment: Codable, Identifiable, Hashable {
        let id: String
        let userId: String
        let userName: String
        let content: String
        let created: Double
    }

    static func fetchComments(trackId: String) async throws -> [Comment] {
        let url = base.appendingPathComponent("comments").appendingPathComponent(trackId)
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([Comment].self, from: data)
    }

    static func postComment(trackId: String, userId: String, userName: String, content: String) async throws {
        var req = URLRequest(url: base.appendingPathComponent("comment").appendingPathComponent(trackId))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "userId": userId, "userName": userName, "content": content
        ])
        applyAuth(&req)
        let (_, resp) = try await URLSession.shared.data(for: req)
        try checkAuth(resp)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    static func coverURL(_ id: String) -> URL {
        base.appendingPathComponent("cover").appendingPathComponent(id)
    }

    static func lyricURL(_ id: String) -> URL {
        base.appendingPathComponent("lyric").appendingPathComponent(id)
    }

    /// 歌词内存缓存：听歌模式切换恢复、切回同一首歌时歌词秒出，不重复请求
    private static let lyricLock = NSLock()
    private static var lyricCache: [String: String] = [:]

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
        lyricCache[id] = text
        lyricLock.unlock()
        return text
    }

    static func avatarURL(_ id: String) -> URL {
        base.appendingPathComponent("avatar").appendingPathComponent(id)
    }

    static func backgroundURL(_ id: String) -> URL {
        base.appendingPathComponent("background").appendingPathComponent(id)
    }

    // MARK: - 用户注册 / 登录（multipart）

    static func register(account: String, password: String, name: String,
                         avatarData: Data?,
                         gender: String = "", age: Int = 0, signature: String = "",
                         backgroundData: Data?) async throws -> User {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func field(_ n: String, _ v: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(n)\"\r\n\r\n".utf8))
            body.append(Data("\(v)\r\n".utf8))
        }
        func filePart(_ n: String, _ v: Data) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(n)\"; filename=\"\(n).jpg\"\r\n".utf8))
            body.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
            body.append(v)
            body.append(Data("\r\n".utf8))
        }
        field("account", account)
        field("password", password)
        field("name", name)
        field("gender", gender)
        field("age", String(age))
        field("signature", signature)
        if let avatarData { filePart("avatar", avatarData) }
        if let backgroundData { filePart("background", backgroundData) }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return try await submitUser(path: "register", boundary: boundary, body: body)
    }

    static func login(account: String, password: String) async throws -> User {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func field(_ n: String, _ v: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(n)\"\r\n\r\n".utf8))
            body.append(Data("\(v)\r\n".utf8))
        }
        field("account", account)
        field("password", password)
        body.append(Data("--\(boundary)--\r\n".utf8))
        return try await submitUser(path: "login", boundary: boundary, body: body)
    }

    /// 更新当前用户资料（可选替换头像/背景图）
    static func updateProfile(account: String, name: String, gender: String, age: Int,
                              signature: String,
                              avatarData: Data?, backgroundData: Data?) async throws -> User {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func field(_ n: String, _ v: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(n)\"\r\n\r\n".utf8))
            body.append(Data("\(v)\r\n".utf8))
        }
        func filePart(_ n: String, _ v: Data) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(n)\"; filename=\"\(n).jpg\"\r\n".utf8))
            body.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
            body.append(v)
            body.append(Data("\r\n".utf8))
        }
        field("account", account)
        field("name", name)
        field("gender", gender)
        field("age", String(age))
        field("signature", signature)
        if let avatarData { filePart("avatar", avatarData) }
        if let backgroundData { filePart("background", backgroundData) }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return try await submitUser(path: "profile/update", boundary: boundary, body: body,
                                    authed: true)
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
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        func filePart(_ name: String, _ fileName: String, _ contentType: String, _ fileData: Data) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n".utf8))
            body.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
            body.append(fileData)
            body.append(Data("\r\n".utf8))
        }

        field("title", title)
        field("artist", artist)
        field("album", album)
        field("userId", userId)
        filePart("file", filename, "audio/mpeg", data)
        if let coverData, let coverFilename {
            filePart("cover", coverFilename, "image/jpeg", coverData)
        }
        body.append(Data("--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: base.appendingPathComponent("upload"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 180
        req.httpBody = body
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
}
