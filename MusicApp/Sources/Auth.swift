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
    var isLoggedIn: Bool { currentUser != nil }

    private let serviceName = "app.star2936.guava3291.auth"
    private let accountName = "session"

    private init() {
        restore()
    }

    /// 启动时从 Keychain 恢复登录态，恢复成功则直接进首页，不再要求登录
    private func restore() {
        guard let data = Keychain.load(service: serviceName, account: accountName),
              let user = try? JSONDecoder().decode(User.self, from: data) else { return }
        currentUser = user
    }

    func login(account: String, password: String) async throws {
        let user = try await API.login(account: account, password: password)
        saveSession(user)
    }

    func register(account: String, password: String, name: String, avatarData: Data?,
                  gender: String, age: Int, signature: String,
                  backgroundData: Data?) async throws {
        let user = try await API.register(account: account, password: password, name: name,
                                          avatarData: avatarData, gender: gender, age: age,
                                          signature: signature, backgroundData: backgroundData)
        saveSession(user)
    }

    func logout() {
        currentUser = nil
        Keychain.delete(service: serviceName, account: accountName)
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

    private func saveSession(_ user: User) {
        if let data = try? JSONEncoder().encode(user) {
            Keychain.save(data, service: serviceName, account: accountName)
        }
        currentUser = user
    }
}

// MARK: - 接口错误信息

enum APIError: Error {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let msg): return msg
        }
    }
}
