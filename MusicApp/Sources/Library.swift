import SwiftUI

/// 歌曲库全局单例：启动页就开始拉取歌曲列表，
/// 首页/发现页直接复用已缓存的数据，减少进 App 后的等待。
final class Library: ObservableObject {
    static let shared = Library()

    @Published var tracks: [Track] = []
    @Published var isLoaded = false
    /// 是否正在拉取下一批，防止重复触发
    private var isLoadingMore = false

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

    /// 拉取下一批随机歌曲并追加到列表末尾（后端每次返回随机 10 首，去重后拼接）
    func loadMore() async {
        guard !isLoadingMore else { return }
        isLoadingMore = true
        do {
            let list = try await API.tracks(userId: AuthManager.shared.currentUser?.id)
            await MainActor.run {
                let existing = Set(self.tracks.map { $0.id })
                let fresh = list.filter { !existing.contains($0.id) }
                self.tracks.append(contentsOf: fresh)
            }
        } catch {
            // 失败静默，下次滑动再试
        }
        isLoadingMore = false
    }
}
