import SwiftUI

/// 歌曲库全局单例：启动页就开始拉取歌曲列表，
/// 首页/发现页直接复用已缓存的数据，减少进 App 后的等待。
/// 同时承担「相关歌曲流」：搜索点击播放后，以搜索词为上下文，
/// 每次向后端取 10 首相关随机歌曲（相关优先，不足补全随机），
/// 首页上下滑动即可在相关歌曲间切换。
final class Library: ObservableObject {
    static let shared = Library()

    @Published var tracks: [Track] = []
    @Published var isLoaded = false
    /// 当前相关流关键词（搜索播放建立；nil = 普通全随机流）
    @Published var searchContext: String? = nil
    /// 是否正在拉取下一批，防止重复触发
    private var isLoadingMore = false

    private init() {}

    /// 普通全随机流：清空搜索上下文，拉取随机 10 首
    func load() async {
        searchContext = nil
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

    /// 建立搜索相关流：以当前点击的歌曲为首播（立即播放），
    /// 随后台拉取第一批相关歌曲（10 首随机，相关优先），滑到末尾自动续拉。
    func startSearchStream(keyword: String, first: Track) {
        searchContext = keyword
        tracks = [first]
        PlayerManager.shared.play(first, in: tracks)
        Task { await loadMore() }
    }

    /// 拉取下一批歌曲并追加到列表末尾（后端每次返回随机 10 首，去重后拼接）。
    /// 有搜索上下文时取相关流，否则取全量随机流。
    func loadMore() async {
        guard !isLoadingMore else { return }
        isLoadingMore = true
        do {
            let list = try await API.tracks(userId: AuthManager.shared.currentUser?.id,
                                            keyword: searchContext)
            await MainActor.run {
                let existing = Set(self.tracks.map { $0.id })
                let fresh = list.filter { !existing.contains($0.id) }
                if !fresh.isEmpty {
                    self.tracks.append(contentsOf: fresh)
                }
            }
        } catch {
            // 失败静默，下次滑动再试
        }
        isLoadingMore = false
    }
}
