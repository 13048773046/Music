import SwiftUI

/// 歌曲库全局单例：启动页就开始拉取歌曲列表，
/// 首页/发现页直接复用已缓存的数据，减少进 App 后的等待。
///
/// 职责拆分：
/// - `tracks`：普通全随机流，是发现页的展示数据源，永不被搜索流污染；
/// - 播放队列：一律以 `PlayerManager.queue` 为唯一真相，首页竖滑播放器跟随它；
/// - 搜索相关流：搜索点击播放后建立（`searchContext` 记录关键词），
///   每次向后端取 10 首相关随机歌曲（相关优先，不足补全随机），
///   追加到播放队列；从发现页点击歌曲则切回普通全随机流。
final class Library: ObservableObject {
    static let shared = Library()

    /// 普通全随机流（发现页数据源）
    @Published var tracks: [Track] = []
    @Published var isLoaded = false
    /// 当前相关流关键词（搜索播放建立；nil = 普通全随机流）
    @Published var searchContext: String? = nil
    /// 是否正在拉取下一批，防止重复触发
    private var isLoadingMore = false

    /// 进行中的首屏加载任务（class box 提供身份比较；锁保护跨线程读写）：
    /// 并发调用者（启动页/首页/发现页）共享同一次加载并等待结果，
    /// 避免「双请求」或「第二个调用因防重入直接返回 → 页面永久停在 loading」。
    private final class LoadBox: @unchecked Sendable {
        let task: Task<Void, Never>
        init(_ task: Task<Void, Never>) { self.task = task }
    }
    private let loadLock = NSLock()
    private var inFlightLoad: LoadBox?

    private init() {}

    /// 普通全随机流：清空搜索上下文，拉取随机 10 首。
    /// - 已加载成功时直接返回（避免重复请求）；`force=true` 时强制重新拉取
    ///   （上传新歌后调用，让首页/发现页立即可见新歌）。
    /// - 加载进行中时等待同一任务完成，不重复发请求。
    /// - 加载失败不置 `isLoaded`，下次进入可自动重试。
    func load(force: Bool = false) async {
        if !force && isLoaded { return }
        loadLock.lock()
        let pending = inFlightLoad
        loadLock.unlock()
        if let pending {
            await pending.task.value
            return
        }
        let box = LoadBox(Task { [weak self] in
            guard let self else { return }
            self.searchContext = nil
            do {
                // 带上当前登录用户 id，让后端返回每首歌的 commentCount 与 isLiked
                let list = try await API.tracks(userId: AuthManager.shared.currentUser?.id)
                await MainActor.run {
                    self.tracks = list
                    self.isLoaded = true
                    // 首次拿到列表且播放器还没有队列时：先尝试恢复上次播放会话——
                    // 短时间重开 App 接着「上次那首的下一首」继续播；
                    // 无可恢复会话 / 长时间重开（如隔 10 分钟）→ 进入带随机性的新鲜个性化推荐流
                    if PlayerManager.shared.queue.isEmpty {
                        if !PlayerManager.shared.restoreLastSessionIfNeeded() {
                            PlayerManager.shared.startRecommendedStream(fallback: list, fresh: true)
                        }
                    }
                }
            } catch {
                // 失败静默：保持未加载状态，下次进入页面自动重试
            }
        })
        loadLock.lock()
        inFlightLoad = box
        loadLock.unlock()
        await box.task.value
        // 只清理自己发起的加载任务（期间可能有新的 force 加载替换了 inFlightLoad）
        loadLock.lock()
        if inFlightLoad === box {
            inFlightLoad = nil
        }
        loadLock.unlock()
    }

    /// 从发现页点击歌曲播放：切回默认模式并进入个性化推荐流（对齐汽水音乐）——
    /// 以点击的歌曲为当前曲，队列 = 多路召回个性化推荐（后续接推荐流）；
    /// 推荐拉取失败时回退「全部歌曲」全库流，保证点歌必有声音。
    func playFromDiscover(_ track: Track) {
        searchContext = nil
        PlayerManager.shared.startRecommendedStream(startingAt: track, fallback: tracks)
    }

    /// 建立搜索相关流：以当前点击的歌曲为首播（立即播放），
    /// 随后台拉取第一批相关歌曲（10 首随机，相关优先），滑到末尾自动续拉。
    func startSearchStream(keyword: String, first: Track) {
        searchContext = keyword
        PlayerManager.shared.playInNormalMode(first, in: [first])
        Task { await loadMore() }
    }

    /// 拉取下一批歌曲并追加到播放队列末尾（后端每次返回随机 10 首，去重后拼接）。
    /// 有搜索上下文时取相关流，否则取全量随机流。
    /// 仅在默认模式下续拉：喜欢/新鲜模式的队列是固定会话，滑到末尾不混入随机歌。
    func loadMore() async {
        guard PlayerManager.shared.listenMode == .normal else { return }
        guard !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let list = try await API.tracks(userId: AuthManager.shared.currentUser?.id,
                                            keyword: searchContext)
            await MainActor.run {
                let queue = PlayerManager.shared.queue
                let existing = Set(queue.map { $0.id })
                let fresh = list.filter { !existing.contains($0.id) }
                if !fresh.isEmpty {
                    PlayerManager.shared.queue.append(contentsOf: fresh)
                    // 长时间播放防护：队列超上限时修剪已播放头部，防无限累积
                    PlayerManager.shared.trimQueueIfNeeded()
                }
            }
        } catch {
            // 失败静默，下次滑动再试
        }
    }
}
