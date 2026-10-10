import Foundation

enum API {
    static let base = URL(string: "https://www.dbmt999.asia/music/api")!

    static func tracks(userId: String? = nil) async throws -> [Track] {
        var components = URLComponents(url: base.appendingPathComponent("tracks"),
                                       resolvingAgainstBaseURL: false)!
        if let userId, !userId.isEmpty {
            components.queryItems = [URLQueryItem(name: "userId", value: userId)]
        }
        var req = URLRequest(url: components.url!)
        req.timeoutInterval = 15
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
        if let (data, _) = try? await URLSession.shared.data(from: signURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let exp = obj["exp"] as? Int, let sig = obj["sig"] as? String {
            var comps = URLComponents(url: streamURL(id), resolvingAgainstBaseURL: false)
            comps?.queryItems = [URLQueryItem(name: "exp", value: String(exp)),
                                 URLQueryItem(name: "sig", value: sig)]
            if let signed = comps?.url { return signed }
        }
        return streamURL(id)
    }

    /// 隐藏式分享链接：H5 分享页（随机 token，不暴露歌曲 ID 与流地址）；失败返回 nil
    static func shareLink(for id: String) async -> String? {
        let url = base.appendingPathComponent("share-url").appendingPathComponent(id)
        if let (data, _) = try? await URLSession.shared.data(from: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = obj["token"] as? String, !token.isEmpty {
            return base.appendingPathComponent("share").appendingPathComponent(token).absoluteString
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

    static func fetchLyric(_ id: String) async throws -> String {
        let (data, resp) = try await URLSession.shared.data(from: lyricURL(id))
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return String(data: data, encoding: .utf8) ?? ""
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
