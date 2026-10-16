import Foundation
import Security

// MARK: - 用户模型

struct User: Codable, Identifiable, Hashable {
    let id: String
    let account: String
    let name: String
    let avatar: String?        // 服务端头像文件名，空字符串/缺省 = 无头像
    let gender: String?         // 男 / 女 / 保密
    let age: Int?
    let background: String?    // 服务端背景图文件名
    let signature: String?      // 用户签名
    let ip: String?            // 最近登录 IP（后端自动获取）
    let created: Double?       // 注册时间戳
    /// 登录/注册时后端签发的 Bearer Token；旧会话无 token（兼容模式下仍可用，严格模式下需重新登录）
    var token: String?

    /// 头像/背景图 URL 一律按用户 id 请求；后端无图时返回 404，CachedCoverImage 自动占位
    var avatarURL: URL {
        API.avatarURL(id)
    }

    var backgroundURL: URL? {
        guard let background, !background.isEmpty else { return nil }
        return API.backgroundURL(id)
    }
}

// MARK: - 极简 Keychain 存取（登录态杀后台、重装后仍保留）

enum Keychain {
    private static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ data: Data, service: String, account: String) {
        var attrs = query(service: service, account: account)
        SecItemDelete(attrs as CFDictionary)
        attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func load(service: String, account: String) -> Data? {
        var q = query(service: service, account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess
            ? result as? Data
            : nil
    }

    static func delete(service: String, account: String) {
        SecItemDelete(query(service: service, account: account) as CFDictionary)
    }
}

// MARK: - 登录态管理（全局单例）

final class AuthManager: ObservableObject {
    static let shared = AuthManager()

    @Published var currentUser: User?
    /// 本地保存过的账号（含历史账号），供「切换账号」弹窗展示
    @Published private(set) var savedAccounts: [User] = []
    var isLoggedIn: Bool { currentUser != nil }
    /// 当前登录用户的 Bearer Token（可能为 nil：旧会话，后端兼容模式下仍可用）
    var authToken: String? { currentUser?.token }

    private let serviceName = "app.star2936.guava3291.auth"
    private let accountName = "session"
    private let savedIdsKey = "saved_account_ids"

    private init() {
        restore()
    }

    /// 历史账号在 Keychain 中的条目名：acct.<userID>
    private func acctKey(_ id: String) -> String { "acct.\(id)" }

    private func persistAccountIds(_ list: [User]) {
        UserDefaults.standard.set(list.map { $0.id }, forKey: savedIdsKey)
    }

    /// 接口返回 401（token 失效/被严格模式拒绝）时调用：清除本地登录态，下次进 App 需重新登录。
    /// 由 URLSession 回调线程触发，@Published 写入必须回到主线程。
    func handleUnauthorized() {
        guard currentUser != nil else { return }
        DispatchQueue.main.async {
            guard let cu = self.currentUser else { return }
            self.currentUser = nil
            Keychain.delete(service: self.serviceName, account: self.accountName)
            // token 失效：同时从历史账号列表移除，避免切换到失效会话
            self.savedAccounts.removeAll { $0.id == cu.id }
            Keychain.delete(service: self.serviceName, account: self.acctKey(cu.id))
            self.persistAccountIds(self.savedAccounts)
        }
    }

    /// 启动时从 Keychain 恢复登录态（当前会话 + 历史账号列表）
    private func restore() {
        if let data = Keychain.load(service: serviceName, account: accountName),
           let user = try? JSONDecoder().decode(User.self, from: data) {
            currentUser = user
        }
        let ids = UserDefaults.standard.stringArray(forKey: savedIdsKey) ?? []
        var list: [User] = []
        for id in ids {
            guard let data = Keychain.load(service: serviceName, account: acctKey(id)),
                  let u = try? JSONDecoder().decode(User.self, from: data) else { continue }
            list.append(u)
        }
        // 旧版本升级：当前会话未记录在列表里时补入（排最前）
        if let cu = currentUser, !list.contains(where: { $0.id == cu.id }) {
            list.insert(cu, at: 0)
            persistAccountIds(list)
        }
        savedAccounts = list
    }

    func login(account: String, password: String) async throws {
        let user = try await API.login(account: account, password: password)
        saveSession(user)
    }

    func register(password: String, name: String, avatarData: Data?,
                  gender: String, age: Int, signature: String,
                  backgroundData: Data?) async throws {
        let user = try await API.register(password: password, name: name,
                                          avatarData: avatarData, gender: gender, age: age,
                                          signature: signature, backgroundData: backgroundData)
        saveSession(user)
    }

    func logout() {
        currentUser = nil
        Keychain.delete(service: serviceName, account: accountName)
        // 历史账号保留：重新登录后仍可在「切换账号」弹窗看到并一键切回
    }

    /// 切换账号：从本地历史会话切到目标账号，并重建实时通知连接
    func switchAccount(to user: User) {
        guard user.id != currentUser?.id else { return }
        guard let data = Keychain.load(service: serviceName, account: acctKey(user.id)),
              let saved = try? JSONDecoder().decode(User.self, from: data) else { return }
        currentUser = saved
        if let d = try? JSONEncoder().encode(saved) {
            Keychain.save(d, service: serviceName, account: accountName)
        }
        // 切到的账号排到列表最前
        var list = savedAccounts.filter { $0.id != saved.id }
        list.insert(saved, at: 0)
        savedAccounts = list
        persistAccountIds(list)
        // 换 token 重建 WebSocket 连接 + 刷新未读数（登录态布尔值不变，不走 MusicApp 的 onChange）
        NotificationBus.shared.resetAndReconnect()
        Task { await NotificationBus.shared.refreshUnread() }
    }

    /// 更新资料，成功后同步刷新本地登录态
    func updateProfile(name: String, gender: String, age: Int, signature: String,
                       avatarData: Data?, backgroundData: Data?) async throws {
        guard let u = currentUser else { return }
        let updated = try await API.updateProfile(account: u.account, name: name,
                                                  gender: gender, age: age,
                                                  signature: signature,
                                                  avatarData: avatarData,
                                                  backgroundData: backgroundData)
        saveSession(updated)
    }

    /// WebSocket 推送资料更新（多端同步）：合并当前 token 后刷新登录态
    func applyRemoteProfile(_ user: User) {
        guard currentUser != nil else { return }
        saveSession(user)
    }

    /// 修改密码（校验旧密码后更新）
    func changePassword(old: String, new: String) async throws {
        try await API.changePassword(old: old, new: new)
    }

    private func saveSession(_ user: User) {
        // 后端 profile/update 响应不含 token：合并保留已有 token，避免覆盖丢失导致后续请求 401
        var u = user
        if u.token == nil {
            u.token = currentUser?.token
        }
        if let data = try? JSONEncoder().encode(u) {
            Keychain.save(data, service: serviceName, account: accountName)
            // 同时写入历史账号条目（登录/注册/更新资料都会同步）
            Keychain.save(data, service: serviceName, account: acctKey(u.id))
        }
        // 账号列表去重，当前账号排最前
        var list = savedAccounts.filter { $0.id != u.id }
        list.insert(u, at: 0)
        savedAccounts = list
        persistAccountIds(list)
        currentUser = u
    }
}

// MARK: - 接口错误信息

enum APIError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let msg): return msg
        }
    }
}
