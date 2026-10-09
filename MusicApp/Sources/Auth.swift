import Foundation
import Security

// MARK: - 用户模型

struct User: Codable, Identifiable, Hashable {
    let id: String
    let account: String
    let name: String
    let avatar: String?   // 服务端头像文件名，空字符串/缺省 = 无头像

    var avatarURL: URL? {
        guard let avatar, !avatar.isEmpty else { return nil }
        return API.avatarURL(id)
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

    func register(account: String, password: String, name: String, avatarData: Data?) async throws {
        let user = try await API.register(account: account, password: password,
                                          name: name, avatarData: avatarData)
        saveSession(user)
    }

    func logout() {
        currentUser = nil
        Keychain.delete(service: serviceName, account: accountName)
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
