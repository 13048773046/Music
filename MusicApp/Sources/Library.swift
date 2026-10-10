import SwiftUI

/// 歌曲库全局单例：启动页就开始拉取歌曲列表，
/// 首页/发现页直接复用已缓存的数据，减少进 App 后的等待。
final class Library: ObservableObject {
    static let shared = Library()

    @Published var tracks: [Track] = []
    @Published var isLoaded = false

    private init() {}

    func load() async {
        do {
            // 带上当前登录用户 id，让后端返回每首歌的 commentCount 与 isLiked
            let list = try await API.tracks(userId: AuthManager.shared.currentUser?.id)
            await MainActor.run {
                self.tracks = list
                self.isLoaded = true
                // 首次拿到列表且播放器还没有队列时，自动播第一首
                if PlayerManager.shared.queue.isEmpty, !list.isEmpty {
                    PlayerManager.shared.play(list[0], in: list)
                }
            }
        } catch {
            await MainActor.run { self.isLoaded = true }
        }
    }
}
