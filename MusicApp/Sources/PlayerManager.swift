import AVFoundation
import MediaPlayer
import UIKit

// MARK: - 播放模式

enum PlayMode: CaseIterable {
    case listLoop   // 列表循环
    case singleLoop // 单曲循环
    case shuffle    // 随机播放

    var symbol: String {
        switch self {
        case .listLoop: return "repeat"
        case .singleLoop: return "repeat.1"
        case .shuffle: return "shuffle"
        }
    }

    var label: String {
        switch self {
        case .listLoop: return "列表循环"
        case .singleLoop: return "单曲循环"
        case .shuffle: return "随机播放"
        }
    }
}

/// 侧边栏「听歌模式」：默认模式（推荐流）/ 我的作品（作品列表循环）/ 我的喜欢（点赞列表循环）/ 新鲜模式（完全随机）
enum ListenMode: String, CaseIterable {
    case normal = "默认模式"
    case works = "我的作品"
    case liked = "我的喜欢"
    case fresh = "新鲜模式"

    var icon: String {
        switch self {
        case .normal: return "list.bullet"
        case .works: return "music.note.list"
        case .liked: return "heart"
        case .fresh: return "sparkles"
        }
    }
}

final class PlayerManager: NSObject, ObservableObject {
    static let shared = PlayerManager()

    let player = AVQueuePlayer()
    /// 引擎音效实时处理引擎（3D 立体/360 环绕/复古/现场/流行/摇滚）
    private let enginePlayer = AudioEnginePlayer()
    /// 当前是否在用引擎播放（任一引擎音效模式；歌词等组件据此决定取数源）
    private(set) var usingEngine = false

    @Published var queue: [Track] = []
    /// 队列内容级变化版本号：原位插入/替换时 +1，
    /// VerticalPager 据此识别「队列内容变了但队首/长度未变」的场景并强制重建页面，
    /// 避免复用旧索引的缓存页面（导致显示信息与播放音频不符）。
    @Published private(set) var queueRevision = 0
    @Published var currentIndex: Int = -1
    @Published var isPlaying = false
    @Published var progress: Double = 0
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var playMode: PlayMode = .listLoop
    /// 首页播放页背景是否偏浅（供透明导航栏决定文字颜色）。
    /// 初始 false：切歌/加载中背景为深色渐变，配白色文字；封面主色就绪后按亮度更新。
    @Published var playerCardBackgroundLight: Bool = false
    /// 当前歌曲封面提取的主色（原始值未压暗）；nil = 加载中/无封面。
    /// 播放页背景 = 主色×0.4，侧边栏背景 = 主色×0.3（比播放页再暗一档）
    @Published var playerCardDominant: UIColor? = nil
    /// 已缓冲进度 0...1（取 currentItem.loadedTimeRanges 中包含当前播放点的一段）
    @Published var bufferProgress: Double = 0
    /// 是否正在缓冲（等待网络数据，用于进度条加载动画）
    @Published var isBuffering: Bool = false
    /// 当前音频加载失败（网络中断/资源损坏/流不可用），UI 展示重试入口
    @Published var loadFailed: Bool = false
    /// 全局音效选择（切歌不重置）
    @Published var selectedEQ: String = "原音"
    /// 侧边栏听歌模式：默认模式 / 我的喜欢 / 新鲜模式
    @Published var listenMode: ListenMode = .normal
    /// 切到「我的喜欢/新鲜模式」前记住的循环模式，切回默认模式时恢复
    private var savedNormalMode: PlayMode = .listLoop

    // MARK: - 原音 → 引擎 无缝接力（下载期间原音继续出声）

    /// 引擎预加载切换任务：取消旧任务防迟到接管
    private var engineSwitchTask: Task<Void, Never>?
    /// 是否正在为「原音 → 引擎」后台预下载（UI 显示加载百分比）
    @Published private(set) var engineSwitchInProgress: Bool = false
    /// 引擎整曲下载进度 0...1（engineSwitchInProgress 期间有效）
    @Published private(set) var engineDownloadFraction: Double = 0
    /// 加载期间（duration==0）的待应用拖动位置：就绪后立即跳到该处
    private var pendingSeekFraction: Double?

    private var pendingArtwork: UIImage?
    /// 已构建好的锁屏 artwork 对象（切歌时重建一次，进度刷新不再重复创建，降低 0.1s 刷新开销）
    private var currentArtwork: MPMediaItemArtwork?
    /// 锁屏信息最近一次刷新时间（updateNowPlaying 节流用）
    private var lastNowPlayingUpdate: TimeInterval = 0
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?

    // MARK: - 播放池健壮性（企业级防护）

    /// 切歌/重载的加载任务：快速连续切歌时取消旧任务，
    /// 避免旧签名 URL 请求继续占用带宽、迟到响应覆盖新歌状态。
    private var loadTask: Task<Void, Never>?
    /// 已做过「自动重试一次」的歌曲 id：防止同一首歌无限自动重试；
    /// 切到新歌时重置。手动重试按钮不受影响。
    private var autoRetriedTrackId: String?
    /// 连续播放失败计数：失败自动切下一首时累加，切到新歌或手动播放时重置；
    /// 达到上限（3 首）则停止自动切歌，避免无限循环。
    private var consecutiveFailCount: Int = 0
    /// 连续失败自动切歌上限
    private let maxConsecutiveFails = 3
    /// 缓冲卡死检测：连续缓冲超过阈值且播放点无进展 → 判定加载失败走自愈
    private var bufferingStallStart: Date?
    private var stallProgressAtStart: Double = 0
    /// 缓冲卡死判定阈值：缓冲超过 15s 且进度无变化
    private let stallTimeout: TimeInterval = 15

    // MARK: - 下一首预加载（只预热签名 URL + 连接头部，不整首下载）

    /// 预加载窗口：当前歌之后预加载的歌曲数（下一首、下下一首、下下下一首…）
    private let prefetchAheadCount = 4
    /// 签名播放 URL 缓存：trackId → URL。
    /// 切歌时优先复用，省去再向后端签发的网络往返，显著缩短切歌等待（“秒开”）；用掉即移除。
    private var signedURLPool: [String: URL] = [:]
    /// 签名 URL 缓存的 FIFO 顺序（超限时淘汰最旧）
    private var urlPoolOrder: [String] = []
    /// 签名 URL 缓存上限（超出淘汰最旧，防止无限堆积）
    private let urlPoolLimit = 16
    /// 进行中的预加载任务（切歌/队列变化时取消，防错加载）
    private var prefetchTask: Task<Void, Never>?

    // MARK: - 个性化推荐流（汽水式无限听歌流）

    /// 已推荐过的歌曲 id（推荐流无限续推时传给后端 exclude，防止重复推荐同一批）
    private var recommendedIds: Set<String> = []
    /// 推荐流每次续拉最大排除量（防止 exclude 参数无限膨胀）
    private let recommendedExcludeCap = 500


    // MARK: - 收听行为追踪（个性化推荐数据源）

    /// 单曲收听状态：按 trackId 归属，切歌/重播时更新
    private struct ListenState {
        var trackId: String = ""
        var seconds: Double = 0      // 本次会话累计收听秒数（真实出声才累计）
        var reported: Double = 0     // 已上报基线（每次只上报差值，避免重复计数）
        var completedPlays: Int = 0  // 完整听完整首的次数（同一首歌听了几遍）
    }
    private var listen = ListenState()
    private var listenTimer: Timer?

    /// 收听结算触发原因：switchTrack 用于快速切走的“跳过”负向信号判定
    private enum ListenFlushReason { case switchTrack, pause, complete, heartbeat, background }

    override init() {
        super.init()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)

        // 显式固定播放音量：App 不提供音量调节，确保任何情况下输出增益恒为 1.0，
        // 避免被异常状态（如流中断重建、模式切换残留）影响导致忽大忽小
        player.volume = 1.0

        // 关闭 AVQueuePlayer 自动前进（默认 .advance）：
        // 播完统一由 didPlayToEndTime → next() 唯一驱动前进。若保持系统自动前进，
        // 系统内部前进与代码 advanceToNextItem 存在时序竞争，偶发「自动切歌跳到下下首」
        // （实际播放下下首、界面索引仍是下一首，音频与信息错位一位）。
        player.actionAtItemEnd = .pause

        setupRemoteCommands()
        setupInterruptionHandling()
        setupEngineRestoreHandling()

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10),   // 0.1s：进度条等 UI 平滑（歌词另有逐帧实时源）
            queue: .main
        ) { [weak self] time in
            guard let self = self else { return }
            // 引擎音效模式（3D 立体/360 环绕/复古/现场/流行/摇滚）：AVPlayer 无 currentItem，
            // 其 periodic observer 会把 currentTime/progress/duration/isBuffering 全部写回 0，
            // 覆盖 enginePlayer.onProgress 的进度数据 → 进度条/歌词/拖动条卡死。必须整体隔离。
            guard !self.usingEngine else { return }
            let sec = CMTimeGetSeconds(time)
            self.currentTime = sec.isFinite ? sec : 0
            let d = CMTimeGetSeconds(self.player.currentItem?.duration ?? .zero)
            if d.isFinite, d > 0 {
                self.duration = d
                self.progress = min(max(self.currentTime / d, 0), 1)
                // 加载期间拖动待应用：AVPlayer 拿到真实时长后立即跳过去
                if let pf = self.pendingSeekFraction {
                    self.pendingSeekFraction = nil
                    let target = CMTime(seconds: pf * d, preferredTimescale: 600)
                    self.player.seek(to: target)
                    self.currentTime = pf * d
                    self.progress = pf
                }
            }
            // 缓冲状态：播放点数据未到达时（卡顿/加载中）显示加载动画
            self.isBuffering = (self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
            // 播放正常（非缓冲且在播放）：重置连续失败计数
            if !self.isBuffering && self.isPlaying {
                self.consecutiveFailCount = 0
            }
            // 已缓冲进度：当前已加载区间的终点 / 总时长
            if let item = self.player.currentItem, self.duration > 0,
               let range = item.loadedTimeRanges.first?.timeRangeValue {
                let bufferEnd = CMTimeGetSeconds(range.start) + CMTimeGetSeconds(range.duration)
                self.bufferProgress = min(max(bufferEnd / self.duration, 0), 1)
            }
            // 初始加载失败检测（404/网络断时 AVPlayerItem.status 变为 .failed，
            // 不触发 .AVPlayerItemFailedToPlayToEndTime 通知，只能轮询状态）
            if self.player.currentItem?.status == .failed {
                self.handlePlaybackFailure()
            }
            // 缓冲卡死检测：非新歌初始加载（已有 duration）却长时间无进展 → 自愈
            if self.isBuffering {
                if self.bufferingStallStart == nil {
                    self.bufferingStallStart = Date()
                    self.stallProgressAtStart = self.progress
                } else if let start = self.bufferingStallStart,
                          Date().timeIntervalSince(start) > self.stallTimeout,
                          self.duration > 0,
                          self.progress - self.stallProgressAtStart < 0.01 {
                    self.bufferingStallStart = nil
                    self.handlePlaybackFailure()
                }
            } else {
                self.bufferingStallStart = nil
            }
            self.updateNowPlaying()
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            // 只处理「当前正在播放的 item」的播完通知：actionAtItemEnd=.pause 下，
            // 播完的 item 仍停留在 currentItem，直到这里 advance 才移除。
            // 旧/残留 item 的迟到通知（用户已手动切走、队列被替换重建等）若也触发
            // 一次 next()，会再跳一首（播放与索引错位），必须按对象身份过滤。
            if let item = note.object as? AVPlayerItem, item !== self.player.currentItem {
                return
            }
            // 完整听完一首：累计“听了几遍”，并结算收听时长
            if self.listen.trackId == self.current?.id {
                self.listen.completedPlays += 1
            }
            self.flushListen(.complete)
            self.next()
        }

        // 音频流加载失败（网络中断/资源损坏/服务器返回错误）：统一走自愈路径
        // （UI 展示重试 + 有限自动重试一次），避免 App 静默卡死
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handlePlaybackFailure()
        }

        // 内存压力：清空图片/主色/歌词/URL 会话缓存，防止长滑播放后内存膨胀被系统杀进程
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            CoverImageCache.shared.clear()
            LyricsCache.shared.clear()
            CoverPalette.clearCache()
            API.clearLyricCache()
            URLCache.shared.removeAllCachedResponses()
        }

        // 收听心跳：每秒累计真实播放秒数，每 30s 自动上报一次（防 App 被杀丢失数据）
        listenTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.listenTick()
        }
        // 退后台/切应用前结算一次收听时长
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.flushListen(.background)
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.flushListen(.background)
            // 保存播放会话：杀 App 重开后，短时间间隔接着「上次那首的下一首」继续播
            self?.saveSessionToDisk()
            // 保持音频会话激活：防止后台期间会话被降权/停用导致音量被压低或无声
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }

    // MARK: - 播放会话持久化（杀 App 重开：短时间接着上次的下一首，长时间重新来）

    /// 短时间窗口：距上次保存 < 此值（默认 5 分钟）恢复会话、接着上次那首的下一首；
    /// 超过（如隔 10 分钟）则丢弃旧会话，重新进入带随机性的新鲜推荐流
    private static let sessionResumeWindow: TimeInterval = 300
    private static let sessionKey = "PlayerManager.savedSession.v1"
    /// 保存窗口：当前歌之前保留 N 首、之后保留 M 首（限制 UserDefaults 体积）
    private static let sessionKeepBefore = 30
    private static let sessionKeepAfter = 90

    private struct SavedSession: Codable {
        var queue: [Track]
        var currentIndex: Int
        var listenMode: String
        var playModeIndex: Int
        var savedNormalModeIndex: Int
        var searchContext: String?
        var wasPlaying: Bool
        var savedAt: TimeInterval
    }

    /// 把当前播放会话（队列 + 位置 + 模式 + 进度态）写入本地。
    /// 只在进入后台时保存一次：切歌后杀 App 必经后台回调，状态即最新，避免频繁写盘。
    private func saveSessionToDisk() {
        guard !queue.isEmpty, queue.indices.contains(currentIndex) else { return }
        // 截取当前歌附近的窗口（可上滑回退/下滑续听），控制 UserDefaults 体积
        let start = max(0, currentIndex - Self.sessionKeepBefore)
        let end = min(queue.count, currentIndex + Self.sessionKeepAfter + 1)
        let saved = Array(queue[start..<end])
        let idx = currentIndex - start
        let playIdx = PlayMode.allCases.firstIndex(of: playMode) ?? 0
        let normalIdx = PlayMode.allCases.firstIndex(of: savedNormalMode) ?? 0
        let s = SavedSession(queue: saved, currentIndex: idx,
                             listenMode: listenMode.rawValue,
                             playModeIndex: playIdx,
                             savedNormalModeIndex: normalIdx,
                             searchContext: Library.shared.searchContext,
                             wasPlaying: isPlaying,
                             savedAt: Date().timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: Self.sessionKey)
        }
    }

    /// 冷启动恢复上次播放会话：
    /// - 距上次保存 < sessionResumeWindow（短时间重开）：恢复队列并播「上次那首的下一首」
    ///   （上次在队尾则回绕第一首，与列表循环语义一致），保持原听歌模式/循环模式；
    /// - 超过窗口（长时间重开）：丢弃旧会话返回 false，由调用方重新进入新鲜推荐流；
    /// 数据损坏/队列为空/索引越界同样返回 false 并清掉脏数据。
    func restoreLastSessionIfNeeded() -> Bool {
        guard queue.isEmpty else { return false }
        guard let data = UserDefaults.standard.data(forKey: Self.sessionKey),
              let s = try? JSONDecoder().decode(SavedSession.self, from: data),
              !s.queue.isEmpty, s.queue.indices.contains(s.currentIndex) else {
            UserDefaults.standard.removeObject(forKey: Self.sessionKey)
            return false
        }
        // 长时间重开（如隔 10 分钟）：不接着上次，重新进带随机性的新鲜推荐流
        let age = Date().timeIntervalSince1970 - s.savedAt
        guard age < Self.sessionResumeWindow else {
            UserDefaults.standard.removeObject(forKey: Self.sessionKey)
            return false
        }
        // 恢复模式 / 循环模式 / 搜索上下文 / 队列
        listenMode = ListenMode(rawValue: s.listenMode) ?? .normal
        if PlayMode.allCases.indices.contains(s.playModeIndex) {
            playMode = PlayMode.allCases[s.playModeIndex]
        }
        if PlayMode.allCases.indices.contains(s.savedNormalModeIndex) {
            savedNormalMode = PlayMode.allCases[s.savedNormalModeIndex]
        }
        // 搜索上下文只属于 normal 模式：liked/works 恢复时清空，避免污染后续推荐流
        if listenMode == .normal {
            Library.shared.searchContext = s.searchContext
        } else {
            Library.shared.searchContext = nil
        }
        queue = s.queue
        // 恢复队列里的歌加入推荐去重集合：后续滑到队尾续推不重复这批
        recommendedIds.formUnion(s.queue.map { $0.id })
        // 接着上次那首的下一首（上次在最后一首则回绕第一首，列表循环语义）
        let resume = s.queue.indices.contains(s.currentIndex + 1) ? s.currentIndex + 1 : 0
        currentIndex = resume
        playCurrent(autoResume: s.wasPlaying)
        return true
    }

    deinit {
        listenTimer?.invalidate()
        loadTask?.cancel()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    /// 切换音效：直接应用（EQBSheet 调用入口）。
    /// - 引擎音效之间切换：只换引擎参数，不重新下载整曲，进度/歌词连续；
    /// - 原音 → 引擎：AVPlayer 继续出声（无感），引擎后台下载就绪后从当前进度无缝接管；
    /// - 引擎 → 原音：重载当前歌曲（引擎需下载整曲 / AVPlayer 走流）。
    /// - 加载失败状态下切换 = 重试加载。
    func applyEQ(_ name: String) {
        guard name != selectedEQ else { return }
        // 先取消进行中的引擎预加载切换（再次切换/切歌/失败都会重新发起）
        engineSwitchTask?.cancel()
        engineSwitchTask = nil
        engineSwitchInProgress = false
        engineDownloadFraction = 0
        if loadFailed {
            selectedEQ = name
            reloadCurrent()   // 失败态：切音效即重试（playCurrent 按新音效加载）
            return
        }
        let isEngine = (name != "原音")
        if usingEngine == isEngine {
            selectedEQ = name
            if isEngine {
                // 引擎模式间切换：直接换参数，无需重载
                enginePlayer.setMode(Self.engineMode(for: name))
                updateNowPlaying(force: true)
            }
            // 原音 → 原音：无操作
        } else if isEngine {
            // 原音 → 引擎：无缝接力。AVPlayer 继续播放（原音出声、可拖动），
            // 引擎在后台下载整曲；就绪后从 AVPlayer 当前进度无缝接管。
            guard let current = current else { return }
            let targetID = current.id
            let mode = Self.engineMode(for: name)
            selectedEQ = name
            engineSwitchInProgress = true
            engineDownloadFraction = 0
            let task = Task {
                let url = await API.signedStreamURL(for: targetID)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    // 预下载期间切歌/切回原音/再次切换：丢弃迟到接管并清状态
                    guard self.current?.id == targetID, self.selectedEQ != "原音" else {
                        self.engineSwitchInProgress = false
                        self.engineDownloadFraction = 0
                        return
                    }
                    // 引擎回调接线（接管后由引擎驱动进度/完成/缓冲）
                    self.enginePlayer.onProgress = { [weak self] cur, dur in
                        guard let self = self else { return }
                        // 加载期间拖动待应用：进度数据一到就跳过去
                        if let pf = self.pendingSeekFraction, dur > 0 {
                            self.pendingSeekFraction = nil
                            let t = pf * dur
                            self.enginePlayer.seek(toSeconds: t)
                            self.currentTime = t
                            self.progress = min(max(pf, 0), 1)
                            return
                        }
                        self.currentTime = cur
                        self.duration = dur
                        self.progress = dur > 0 ? min(cur / dur, 1) : 0
                        self.updateNowPlaying()
                    }
                    self.enginePlayer.onCompletion = { [weak self] in
                        guard let self else { return }
                        if self.listen.trackId == self.current?.id {
                            self.listen.completedPlays += 1
                        }
                        self.flushListen(.complete)
                        self.next()
                    }
                    self.enginePlayer.onLoadingChanged = { [weak self] loading in
                        self?.isBuffering = loading
                        if !loading { self?.bufferProgress = 1 }
                    }
                    self.enginePlayer.onDownloadProgress = { [weak self] f in
                        self?.engineDownloadFraction = f
                    }
                    // 预加载失败：AVPlayer 仍在正常播，回退原音继续，不触发失败自愈
                    self.enginePlayer.onLoadFailed = { [weak self] in
                        guard let self else { return }
                        DispatchQueue.main.async {
                            if self.engineSwitchInProgress {
                                self.engineSwitchInProgress = false
                                self.engineDownloadFraction = 0
                                self.selectedEQ = "原音"
                                self.updateNowPlaying(force: true)
                            } else {
                                self.handlePlaybackFailure()
                            }
                        }
                    }
                    self.enginePlayer.prepare(url: url, mode: mode) { [weak self] in
                        guard let self else { return }
                        self.engineSwitchInProgress = false
                        self.engineDownloadFraction = 0
                        // 就绪后再次确认未被切歌/切回原音
                        guard self.current?.id == targetID, self.selectedEQ != "原音" else {
                            self.enginePlayer.stop()   // 丢弃就绪结果，释放下载文件
                            return
                        }
                        // 无缝接管：取 AVPlayer 最新进度 → 停 AVPlayer → 引擎从该处续播
                        var resume = self.currentTime
                        if let pf = self.pendingSeekFraction, self.duration > 0 {
                            resume = pf * self.duration
                        }
                        self.pendingSeekFraction = nil
                        let shouldPlay = self.isPlaying
                        self.enginePlayer.playFrom(seconds: resume, autoPlay: shouldPlay)
                        self.usingEngine = true
                        self.player.pause()
                        self.player.replaceCurrentItem(with: nil)
                        self.updateNowPlaying(force: true)
                    }
                }
            }
            engineSwitchTask = task
        } else {
            // 引擎 → 原音：跨播放器切换。记录切换瞬间进度与播放状态，
            // AVPlayer 加载完成后从该位置无缝续播（不从头、不闪零）；暂停中切换则保持暂停。
            let wasPlaying = isPlaying
            let resumeSeconds = currentTime
            selectedEQ = name
            usingEngine = isEngine
            playCurrent(flushReason: .heartbeat,
                        resumeSeconds: resumeSeconds,
                        autoResume: wasPlaying,
                        preserveProgress: true)
        }
    }

    /// 音效名称 → 引擎模式映射（与 VerticalPager eqOptions 一一对应）
    static func engineMode(for name: String) -> AudioEnginePlayer.Mode {
        switch name {
        case "3D 立体音效": return .surround3D
        case "360 环绕": return .surround360
        case "复古": return .retro
        case "现场": return .live
        case "流行": return .pop
        case "摇滚": return .rock
        default: return .original
        }
    }

    /// 切换音效后重新加载当前歌曲以应用新音效（同曲重载，不算切歌/跳过）
    func reloadCurrent() {
        guard current != nil else { return }
        playCurrent(flushReason: .heartbeat)
    }

    var current: Track? {
        guard queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    // MARK: - AVPlayerItem ↔ 歌曲 id 关联（判断 AVQueuePlayer 队列是否已预取到目标歌）

    private static var trackIdAssocKey: UInt8 = 0
    /// 取 AVPlayerItem 上关联的歌曲 id（nil = 未关联）
    static func trackId(of item: AVPlayerItem) -> String? {
        objc_getAssociatedObject(item, &trackIdAssocKey) as? String
    }
    /// 在 AVPlayerItem 上关联歌曲 id（队列连续性判断用）
    static func setTrackId(_ id: String, on item: AVPlayerItem) {
        objc_setAssociatedObject(item, &trackIdAssocKey, id, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// 重建 AVQueuePlayer 队列：当前歌 + 后续若干首（用预取签名 URL，未命中的跳过）。
    /// AVQueuePlayer 会自动预取下一个 item 的数据，顺序切下一首时可秒开、无需等网络首包。
    private func prepareQueuePlayer(currentIndex idx: Int, currentURL: URL) {
        player.removeAllItems()
        let cur = AVPlayerItem(url: currentURL)
        cur.preferredForwardBufferDuration = 30   // 向前多缓冲 30s，减少卡顿
        Self.setTrackId(queue[idx].id, on: cur)
        player.insert(cur, after: nil)
        // 后续限 prefetchAheadCount 首，用已缓存的签名 URL（缓存未命中则先停，
        // 保持顺序；切到时兜底重建，之后由 syncPrefetchedItems 按就绪顺序补插）
        let end = min(idx + 1 + prefetchAheadCount, queue.count)
        for i in (idx + 1)..<end {
            guard let u = signedURLPool[queue[i].id] else { break }
            let item = AVPlayerItem(url: u)
            item.preferredForwardBufferDuration = 30
            Self.setTrackId(queue[i].id, on: item)
            player.insert(item, after: nil)
        }
    }

    /// 顺序切歌（advanceToNextItem）后补充队列：把「队列末尾歌之后」的后续歌补 insert，
    /// 让 AVQueuePlayer 始终保有「当前歌之后 prefetchAheadCount 首」可预取，避免连续切歌几首后队列耗尽。
    /// 已存在的项不重复插入；预取 URL 未命中的先停（保持顺序），就绪后由 syncPrefetchedItems 补插。
    private func topUpQueue() {
        guard !queue.isEmpty, let lastItem = player.items().last,
              let lastId = Self.trackId(of: lastItem),
              let lastIdx = queue.firstIndex(where: { $0.id == lastId }) else { return }
        let end = min(lastIdx + 1 + prefetchAheadCount, queue.count)
        var inserted = [String]()
        let existingIDs = player.items().compactMap { Self.trackId(of: $0) }
        for i in (lastIdx + 1)..<end {
            let t = queue[i]
            guard let u = signedURLPool[t.id] else { break }
            guard !inserted.contains(t.id), !existingIDs.contains(t.id) else { continue }
            inserted.append(t.id)
            let item = AVPlayerItem(url: u)
            item.preferredForwardBufferDuration = 30
            Self.setTrackId(t.id, on: item)
            player.insert(item, after: nil)
        }
    }

    func play(_ track: Track, in tracks: [Track]) {
        guard !tracks.isEmpty else { return }   // 空队列不进入播放
        consecutiveFailCount = 0   // 用户手动播放新歌：重置连续失败计数
        if queue != tracks {
            queue = tracks
        }
        if let index = tracks.firstIndex(of: track) {
            currentIndex = index
        } else if !queue.isEmpty {
            // 目标歌不在队列（极端竞态/调用错误）：兜底到队首，
            // 避免旧 currentIndex 指向错误歌曲
            currentIndex = 0
        }
        playCurrent()
    }

    /// 播放失败统一自愈入口（原音 AVPlayer 失败通知 / item status failed / 缓冲卡死 / 3D 引擎加载失败共用）。
    /// 行为：失败后自动切下一首；连续失败超过上限则停止，避免无限循环切歌。
    private func handlePlaybackFailure() {
        guard !loadFailed else { return }   // 已在失败状态，避免重复触发
        loadFailed = true
        isBuffering = false
        isPlaying = false
        bufferingStallStart = nil
        consecutiveFailCount += 1
        updateNowPlaying(force: true)

        // 连续失败超过上限：停止自动切歌，停在当前状态让用户手动处理
        guard consecutiveFailCount <= maxConsecutiveFails else {
            return
        }
        // 延迟 1.5s 自动切下一首；期间用户手动操作则取消
        let failIdx = currentIndex
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self,
                  self.loadFailed,
                  self.currentIndex == failIdx else { return } // 用户已手动切走
            self.next()
        }
    }

    /// 从搜索/发现页直接播放普通流歌曲：若当前处于「我的喜欢/新鲜」模式，
    /// 先保存该模式会话并切回默认模式，保证界面显示的模式与实际播放流一致。
    func playInNormalMode(_ track: Track, in tracks: [Track]) {
        if listenMode != .normal {
            saveSession(for: listenMode)
            listenMode = .normal
        }
        play(track, in: tracks)
    }

    /// 通知点击播放：延续用户当前听歌模式与音乐流。
    /// 通知歌曲插入到「当前歌曲之后」并播放——不丢原歌（上滑可回原曲）、
    /// 下滑（next）自动接回原有队列下一首，不是只有一首、播完即停。
    func playNotificationTrack(_ track: Track) {
        guard !queue.isEmpty else {
            // 无当前流（冷启动直接点通知）：退化为单曲播放
            play(track, in: [track])
            return
        }
        let idx = (queue.indices.contains(currentIndex) ? currentIndex : 0)
        if queue[idx].id == track.id {
            // 已是当前位置的歌曲：直接续播
            currentIndex = idx
            playCurrent()
            return
        }
        if let found = queue.firstIndex(where: { $0.id == track.id }) {
            // 本就在当前流中：定位播放（不改变队列）
            currentIndex = found
            playCurrent()
            return
        }
        // 不在当前流：插入到当前位置之后播放；队列长度+1，
        // 提升 revision 让 VerticalPager 强制重建页面（索引缓存的旧页会显示错歌）
        var q = queue
        q.insert(track, at: idx + 1)
        queue = q
        currentIndex = idx + 1
        queueRevision += 1
        playCurrent()
    }

    func toggle() {
        guard current != nil else { return }
        if isPlaying {
            pausePlayback()
        } else {
            resumePlayback()
        }
    }

    func next() {
        guard !queue.isEmpty else { return }
        // actionAtItemEnd=.pause 后系统不再自动前进，播完统一由 didPlayToEndTime → next()
        // 手动前进，消除「系统自动前进 与 代码 advanceToNextItem 双前进」的时序竞争
        // （曾偶发自动切歌跳到下下首：实际播放下下首、界面索引仍是下一首）。
        // syncIndexWithPlayer 保留作兜底防御：万一仍有外部因素（如遥控/系统行为）
        // 改变了 currentItem，先把索引同步到实际正在播放的歌曲，再决定是否推进。
        let prevIndex = currentIndex
        let autoAdvanced = syncIndexWithPlayer()
        switch playMode {
        case .singleLoop:
            // 单曲循环：无论自动前进到哪，都重播「刚播完的这首」
            currentIndex = prevIndex
            playCurrent()
            return
        case .shuffle:
            // shuffle 始终随机下一首：无论是否自动前进，队列顺序不适用随机语义。
            // （autoAdvanced 后 currentIndex 已同步到实际播放的歌，随机排除它即可）
            let target = randomIndex(excluding: currentIndex)
            currentIndex = target
            playCurrent()
        default:  // listLoop
            if autoAdvanced {
                // 下一首已在播：不再推进；到队尾时按模式续播/回绕，并补队列保持预缓冲
                adoptAutoAdvancedTrack()
                topUpQueue()
                if currentIndex >= queue.count - 1 {
                    if listenMode == .normal {
                        loadNextBatchOrLoop()
                    } else {
                        currentIndex = 0
                        playCurrent()
                    }
                }
            } else if currentIndex < queue.count - 1 {
                // 未到队尾：顺序切下一首（走 playCurrent 的 advance/重建逻辑）
                currentIndex += 1
                playCurrent()
            } else if listenMode == .normal {
                // 默认模式已到队尾：不立即回绕重播第一组，而是异步加载下一组随机新歌续播。
                // 之前列表循环在追加前就 `% queue.count` 回绕到第 0 首，
                // 导致「听完一组→加载第二组」时听到的仍是第一组。
                loadNextBatchOrLoop()
                return
            } else {
                // 非默认模式（喜欢/新鲜）到队尾：按列表循环回绕第一首
                currentIndex = 0
                playCurrent()
            }
        }
    }

    /// 自动切歌辅助：把 currentIndex 同步到 AVQueuePlayer 当前实际播放的歌曲（按 id 匹配）。
    /// 返回是否发生了同步，即 AVQueuePlayer 已自动前进、当前正在播「索引所指之外」的歌。
    @discardableResult
    private func syncIndexWithPlayer() -> Bool {
        guard !queue.isEmpty,
              let itemId = player.currentItem.flatMap({ Self.trackId(of: $0) }),
              let idx = queue.firstIndex(where: { $0.id == itemId }) else { return false }
        guard idx != currentIndex else { return false }
        currentIndex = idx
        return true
    }

    /// 自动切歌已生效（AVQueuePlayer 已在播新歌，未走 playCurrent）时：
    /// 结算上一首收听并把收听状态/自动重试机会切到新歌，避免时长记到上一首头上。
    private func adoptAutoAdvancedTrack() {
        guard let cur = current else { return }
        if listen.trackId != cur.id {
            flushListen(.switchTrack)   // 听完整首切走 frac≈1，不会产生 skip 信号
            listen = ListenState(trackId: cur.id)
            autoRetriedTrackId = nil
        }
    }

    /// 默认模式队尾续播（汽水式无限流）：
    /// - 推荐流（无搜索上下文）：异步拉取下一批「个性化推荐」（排除已推荐歌曲，防重复），
    ///   追加成功则从「新歌第一首」接续播放——每一首都是多路召回按口味推荐的歌；
    /// - 搜索相关流（有搜索上下文）：维持原有「关键词相关歌曲」续拉；
    /// 两种都无新歌（曲库不足/拉取失败）才回绕第一首（列表循环兜底，避免卡在队尾）。
    /// 追加期间若用户已手动切走（不再停在队尾），不覆盖用户当前位置。
    private func loadNextBatchOrLoop() {
        let lastIndex = currentIndex   // 队尾索引
        let baseCount = queue.count    // 追加前长度
        let isSearchStream = Library.shared.searchContext != nil
        Task { @MainActor in
            if isSearchStream {
                // 搜索相关流：关键词相关歌曲续拉（原有逻辑）
                await Library.shared.loadMore()
            } else {
                // 推荐流：拉下一批个性化推荐，排除已推荐 id，实现汽水式无限续推
                // M2：附带天气场景参数（定位未就绪时为 nil，后端按时段兜底）
                let excluding = Array(recommendedIds.suffix(recommendedExcludeCap))
                let next = (try? await API.recommend(excluding: excluding,
                                                     lat: WeatherContext.shared.lat,
                                                     lng: WeatherContext.shared.lng,
                                                     hour: WeatherContext.shared.hour)) ?? []
                if !next.isEmpty {
                    recommendedIds.formUnion(next.map { $0.id })
                    let existing = Set(queue.map { $0.id })
                    let fresh = next.filter { !existing.contains($0.id) }
                    if !fresh.isEmpty {
                        queue.append(contentsOf: fresh)
                        trimQueueIfNeeded()
                    }
                }
            }
            let grew = queue.count > baseCount
            let stillAtEnd = currentIndex == lastIndex
            if grew, stillAtEnd, listenMode == .normal {
                // 新歌追加成功且仍停在队尾：从新歌第一首续播
                currentIndex = baseCount
                playCurrent()
            } else if !grew, stillAtEnd {
                // 无新歌可用：回绕第一首，维持列表循环
                currentIndex = 0
                playCurrent()
            }
            // 追加成功但用户已切走：保持用户当前位置，不干预
        }
    }

    func previous() {
        guard !queue.isEmpty else { return }
        switch playMode {
        case .singleLoop:
            playCurrent()
            return
        case .shuffle:
            let target = randomIndex(excluding: currentIndex)
            currentIndex = target
        default:
            currentIndex = (currentIndex - 1 + queue.count) % queue.count
        }
        playCurrent()
    }

    /// 切换播放模式：列表循环 → 单曲循环 → 随机 → 列表循环
    func cyclePlayMode() {
        let all = PlayMode.allCases
        let idx = all.firstIndex(of: playMode) ?? 0
        playMode = all[(idx + 1) % all.count]
    }

    // MARK: - 侧边栏听歌模式（默认 / 我的喜欢 / 新鲜）

    /// 每种听歌模式独立维护一份播放会话：切走时缓存「队列 + 当前歌曲 + 播放状态」，
    /// 切回该模式时恢复队列，并播放「切走时那首歌的下一首」——不重复听刚听过的那首，
    /// 也不重新随机打乱（列表循环播到末尾则回绕第一首）。
    private struct ModeSession {
        var queue: [Track] = []
        var currentIndex: Int = -1     // 切走时正在播放的歌曲索引
        var wasPlaying: Bool = false
        var searchContext: String? = nil  // 默认模式下的相关流关键词（仅 normal 会话使用）
        var mode: ListenMode = .normal
    }

    private var sessions: [ListenMode: ModeSession] = [:]

    /// 切换侧边栏听歌模式。
    /// 切走前保存当前模式会话；目标模式有缓存则恢复缓存，无缓存才全新加载；
    /// 目标模式加载失败/无内容时回退上一模式，保证「听到的歌 = 看到的模式」。
    /// - 默认模式：恢复个性化推荐流 + 用户自选循环模式
    /// - 我的作品：只播用户上传的作品，列表循环播完回第一首（无限循环）
    /// - 我的喜欢：只播用户点赞过的歌曲，播完回到第一首循环
    /// - 新鲜模式：完全随机（队列打乱 + 随机播放）
    func applyListenMode(_ mode: ListenMode) {
        guard mode != listenMode || mode == .liked || mode == .works else {
            // 同模式重复点击默认/新鲜：不重复切换；我的喜欢/作品每次尝试恢复/刷新缓存
            return
        }
        let previous = listenMode
        saveSession(for: previous)
        listenMode = mode
        switch mode {
        case .normal:
            restoreNormalStream()
        case .works:
            switchToWorks(fallback: previous)
        case .liked:
            switchToLiked(fallback: previous)
        case .fresh:
            switchToFresh(fallback: previous)
        }
    }

    /// 保存当前模式会话快照（切走前调用）
    private func saveSession(for mode: ListenMode) {
        guard !queue.isEmpty else { return }
        sessions[mode] = ModeSession(
            queue: queue,
            currentIndex: currentIndex,
            wasPlaying: isPlaying,
            searchContext: mode == .normal ? Library.shared.searchContext : nil,
            mode: mode
        )
    }

    /// 恢复模式会话：换回该模式的队列，播放「切走时那首的下一首」（从头开始）。
    /// normal 会话恢复时同步搜索上下文；发现页「全部歌曲」保持独立全库数据，
    /// 不再被播放队列覆盖（默认流已是推荐流，队列 ≠ 发现页数据源）。
    private func restoreSession(_ s: ModeSession) {
        guard !s.queue.isEmpty, s.queue.indices.contains(s.currentIndex) else { return }
        if s.mode == .normal {
            let lib = Library.shared
            lib.searchContext = s.searchContext
        }
        // 切走时在最后一首：下一首回绕到第一首（列表循环语义）
        let resumeIndex = s.queue.indices.contains(s.currentIndex + 1) ? s.currentIndex + 1 : 0
        play(s.queue[resumeIndex], in: s.queue)
        if !s.wasPlaying { pausePlayback() }
    }

    /// 目标模式加载失败/无内容：回退到上一个模式。
    /// 上一模式无会话可恢复时回落到默认模式（曲库流保底），避免空队列挂起。
    private func handleFailedSwitch(fallback: ListenMode) {
        guard fallback != listenMode else { return }
        let hasSession: Bool
        switch fallback {
        case .normal: hasSession = sessions[.normal] != nil
        case .works: hasSession = sessions[.works] != nil
        case .liked: hasSession = sessions[.liked] != nil
        case .fresh: hasSession = sessions[.fresh] != nil
        }
        guard hasSession else {
            listenMode = .normal
            restoreNormalStream()
            return
        }
        listenMode = fallback
        switch fallback {
        case .normal: restoreNormalStream()
        case .works: switchToWorks(fallback: nil)
        case .liked: switchToLiked(fallback: nil)
        case .fresh: switchToFresh(fallback: nil)
        }
    }

    /// 默认模式：优先恢复缓存会话；无缓存才进入个性化推荐流（汽水式无限听歌流），恢复保存的循环模式。
    /// 推荐流拉取失败时回退 Library 全库流保底，避免空队列挂起。
    private func restoreNormalStream() {
        playMode = savedNormalMode
        if let s = sessions[.normal], !s.queue.isEmpty {
            restoreSession(s)
            return
        }
        startRecommendedStream(fallback: Library.shared.tracks)
    }

    /// 记录已推荐歌曲 id（外部以推荐列表为队列播放时调用），
    /// 供推荐流无限续推去重（exclude 已推荐批次）。
    func noteRecommended(_ ids: [String]) {
        recommendedIds.formUnion(ids)
    }

    /// 进入个性化推荐流（对齐汽水音乐「推荐即队列」的无限听歌体验）：
    /// 队列 = 后端多路召回 + MMR 重排的个性化推荐，滑到队尾自动续拉下一批推荐（不重复）。
    /// - Parameter track: 期望从这首歌开始（发现页点击歌曲时传入；不在推荐列表则置为队首，后续接推荐）
    /// - Parameter fallback: 推荐拉取失败时的保底队列（全库流），保证点歌必有声音
    /// - Parameter fresh: 长时间重开 App 的新鲜会话——后端加大随机扰动/探索权重，
    ///   重新开始的一批推荐带随机性、不固定重复上次
    func startRecommendedStream(startingAt track: Track? = nil, fallback: [Track] = [],
                                 fresh: Bool = false) {
        if listenMode != .normal {
            saveSession(for: listenMode)
            listenMode = .normal
        }
        let excluding = Array(recommendedIds.suffix(recommendedExcludeCap))
        Task { @MainActor in
            // M2：附带天气场景参数（定位未就绪时为 nil，后端按时段兜底）
            let list = (try? await API.recommend(excluding: excluding, fresh: fresh,
                                                 lat: WeatherContext.shared.lat,
                                                 lng: WeatherContext.shared.lng,
                                                 hour: WeatherContext.shared.hour)) ?? []
            if list.isEmpty {
                // 推荐不可用（未登录/曲库太小/网络失败）：回退保底队列
                if !fallback.isEmpty {
                    let base = fallback
                    if let track, base.contains(where: { $0.id == track.id }) {
                        play(track, in: base)
                    } else if let track {
                        play(track, in: [track] + base.filter { $0.id != track.id })
                    } else if let first = base.first {
                        play(first, in: base)
                    }
                } else if let track {
                    play(track, in: [track])
                }
                return
            }
            recommendedIds.formUnion(list.map { $0.id })
            if let track, let idx = list.firstIndex(where: { $0.id == track.id }) {
                // 目标歌就在推荐里：以它为当前曲，后续接推荐
                play(track, in: list)
            } else if let track {
                // 目标歌不在推荐列表：置为队首（当前曲），后续接推荐
                var q = list
                q.insert(track, at: 0)
                recommendedIds.insert(track.id)
                play(track, in: q)
            } else if let first = list.first {
                play(first, in: list)
            }
        }
    }

    /// 我的喜欢：有缓存恢复缓存；无缓存拉取点赞列表（列表循环，播完回第一首）。
    /// 拉取失败或列表为空时回退上一模式，不出现「模式已切、歌曲没换」。
    /// - Parameter startAt: 从「我的」页点击进入时传入目标歌曲——在会话/新列表里定位到它播放；
    ///   不在会话缓存（如新点赞）时强制重新拉取全量点赞列表。
    /// - Parameter known: 点击来源页已加载的列表（全量拉取失败时的兜底队列）。
    private func switchToLiked(fallback: ListenMode?, startAt: Track? = nil, known: [Track] = []) {
        if let s = sessions[.liked], !s.queue.isEmpty {
            if let startAt, !s.queue.contains(where: { $0.id == startAt.id }) {
                // 目标歌不在缓存会话（新点赞）：重新拉全量列表
            } else {
                if let startAt, let idx = s.queue.firstIndex(where: { $0.id == startAt.id }) {
                    play(startAt, in: s.queue)   // 定位到点击的歌播放
                    return
                }
                restoreSession(s)
                return
            }
        }
        savedNormalMode = playMode
        playMode = .listLoop
        guard let uid = AuthManager.shared.currentUser?.id else {
            if let fb = fallback { handleFailedSwitch(fallback: fb) }
            return
        }
        Task {
            let list = (try? await API.likedTracks(userId: uid)) ?? []
            await MainActor.run {
                guard listenMode == .liked else { return }   // 期间用户又切走了：丢弃
                var base = list
                if base.isEmpty, !known.isEmpty {
                    base = known   // 全量拉取失败：用点击来源页已加载的列表兜底
                }
                guard !base.isEmpty else {
                    if let fb = fallback { handleFailedSwitch(fallback: fb) }
                    return
                }
                var s = ModeSession(queue: base, currentIndex: 0,
                                   wasPlaying: true, mode: .liked)
                if let startAt, let idx = base.firstIndex(where: { $0.id == startAt.id }) {
                    s.currentIndex = idx
                    play(startAt, in: base)   // 从点击的歌曲开始，后续列表循环
                    return
                }
                sessions[.liked] = s
                restoreSession(s)
            }
        }
    }

    /// 我的作品：有缓存恢复缓存；无缓存循环拉取用户全部上传作品（列表循环，播完回第一首，无限循环）。
    /// 拉取失败或列表为空时回退上一模式，不出现「模式已切、歌曲没换」。
    /// - Parameter startAt: 从「我的」页点击进入时传入目标歌曲——在会话/新列表里定位到它播放；
    ///   不在会话缓存（如新上传）时强制重新拉取全量作品列表。
    /// - Parameter known: 点击来源页已加载的列表（全量拉取失败时的兜底队列）。
    private func switchToWorks(fallback: ListenMode?, startAt: Track? = nil, known: [Track] = []) {
        if let s = sessions[.works], !s.queue.isEmpty {
            if let startAt, !s.queue.contains(where: { $0.id == startAt.id }) {
                // 目标歌不在缓存会话（新上传）：重新拉全量列表
            } else {
                if let startAt, let idx = s.queue.firstIndex(where: { $0.id == startAt.id }) {
                    play(startAt, in: s.queue)   // 定位到点击的歌播放
                    return
                }
                restoreSession(s)
                return
            }
        }
        savedNormalMode = playMode
        playMode = .listLoop
        guard let uid = AuthManager.shared.currentUser?.id else {
            if let fb = fallback { handleFailedSwitch(fallback: fb) }
            return
        }
        Task {
            // 循环拉取全部作品（分页直到 hasMore=false；上限保护防止异常无限循环）
            var list: [Track] = []
            var page = 1
            while page <= 20 {
                guard let r = try? await API.myTracks(page: page, pageSize: 50) else { break }
                list += r.list
                if !r.hasMore { break }
                page += 1
            }
            await MainActor.run {
                guard listenMode == .works else { return }   // 期间用户又切走了：丢弃
                var base = list
                if base.isEmpty, !known.isEmpty {
                    base = known   // 全量拉取失败：用点击来源页已加载的列表兜底
                }
                guard !base.isEmpty else {
                    if let fb = fallback { handleFailedSwitch(fallback: fb) }
                    return
                }
                var s = ModeSession(queue: base, currentIndex: 0,
                                   wasPlaying: true, mode: .works)
                if let startAt, let idx = base.firstIndex(where: { $0.id == startAt.id }) {
                    s.currentIndex = idx
                    play(startAt, in: base)   // 从点击的作品开始，后续列表循环
                    return
                }
                sessions[.works] = s
                restoreSession(s)
            }
        }
    }

    /// 从「我的」页点击我的喜欢歌曲进入：切换侧边栏到「我的喜欢」模式，
    /// 队列 = 点赞列表（列表循环），从点击的歌曲开始播放；
    /// 后续切走再切回、加载失败回退，均走与侧边栏切换一致的会话/回退机制。
    func playLikedTrack(_ t: Track, known: [Track]) {
        if listenMode != .liked {
            saveSession(for: listenMode)
        }
        listenMode = .liked
        switchToLiked(fallback: nil, startAt: t, known: known)
    }

    /// 从「我的」页点击我的作品歌曲进入：切换侧边栏到「我的作品」模式，
    /// 队列 = 我的全部作品（列表循环，播到最后一个回到第一个无限循环），从点击的作品开始播放；
    /// 后续切走再切回、加载失败回退，均走与侧边栏切换一致的会话/回退机制。
    func playWorksTrack(_ t: Track, known: [Track]) {
        if listenMode != .works {
            saveSession(for: listenMode)
        }
        listenMode = .works
        switchToWorks(fallback: nil, startAt: t, known: known)
    }

    /// 新鲜模式：有缓存恢复缓存；无缓存基于曲库打乱（当前歌保持在首位继续播，避免切模式瞬间换歌）
    private func switchToFresh(fallback: ListenMode?) {
        if let s = sessions[.fresh], !s.queue.isEmpty {
            restoreSession(s)
            return
        }
        savedNormalMode = playMode
        playMode = .shuffle
        let lib = Library.shared
        let base = lib.tracks.isEmpty ? queue : lib.tracks
        guard !base.isEmpty else {
            if let fb = fallback { handleFailedSwitch(fallback: fb) }
            return
        }
        var fresh = base.shuffled()
        if let cur = current, let idx = fresh.firstIndex(where: { $0.id == cur.id }) {
            fresh.remove(at: idx)
            fresh.insert(cur, at: 0)
        }
        let s = ModeSession(queue: fresh, currentIndex: 0,
                            wasPlaying: true, mode: .fresh)
        sessions[.fresh] = s
        restoreSession(s)
    }

    private func randomIndex(excluding current: Int) -> Int {
        guard queue.count > 1 else { return 0 }
        var target = Int.random(in: 0..<queue.count)
        if target == current {
            target = (target + 1) % queue.count
        }
        return target
    }

    // MARK: - 下一首预加载

    /// 根据当前播放位置，为「接下来 N 首」预加载：
    /// 1) 预取并缓存签名播放 URL（切歌免再请求，缩短等待）；
    /// 长时间播放防护：控制播放队列上限，防止无限 loadMore 导致内存与索引成本持续累积。
    /// 队列超过上限且已播放较多时，移除「当前歌之前的已播放头部」（保留最近 keepBefore 首
    /// 供上滑回退），同步调整 currentIndex 并 bump 版本号通知页面。低频触发（每累积到上限一次）。
    func trimQueueIfNeeded() {
        let limit = 200      // 队列保留最近 200 首
        let keepBefore = 20  // 当前歌之前保留 20 首（可上滑回退）
        guard queue.count > limit, currentIndex > keepBefore else { return }
        let removeCount = currentIndex - keepBefore
        guard removeCount > 0 else { return }
        queue.removeFirst(removeCount)
        currentIndex -= removeCount
        queueRevision += 1   // 队列内容已变：通知 VerticalPager 刷新（当前页索引已同步）
    }

    /// 2) 用 AVURLAsset 预热连接/资源头部（只拉前一小部分 metadata，不整首下载）。
    /// 播放位置或队列变化时重新计算窗口；同一位置只预加载一次。
    /// 幂等且防重：切歌会取消旧任务，队列再变也不会错取已不在队列的歌。
    /// 两阶段执行：
    ///   阶段1 并行签发「接下来 N 首」的签名 URL 并立即补进 AVQueuePlayer，
    ///         让系统对下一首预缓冲真实音频数据（顺序切歌走 advanceToNextItem 秒开/无缝）；
    ///   阶段2 顺序预热元数据连接 + 封面 + 歌词 + 主色（不阻塞阶段1的 URL 就绪与入队）。
    private func schedulePrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
        guard !queue.isEmpty, queue.indices.contains(currentIndex) else { return }
        let start = currentIndex + 1
        let end = min(start + prefetchAheadCount, queue.count)
        guard start < end else { return }
        // 快照目标，异步期间队列变化不影响本次预取目标
        let targets = Array(queue[start..<end])
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            // 阶段1：并行签发 URL（各自一次轻量往返），谁先就绪谁先入队
            await withTaskGroup(of: Void.self) { group in
                for t in targets {
                    group.addTask { [weak self] in
                        await self?.warmURLOnly(t)
                    }
                }
            }
            // 阶段2：顺序预热元数据/封面/歌词/主色（URL 已全部在池中）
            for t in targets {
                guard !Task.isCancelled else { return }
                await self.warmMetadata(for: t)
            }
        }
    }

    /// 只签发并缓存签名 URL + 同步补进 AVQueuePlayer（音频预缓冲的关键路径）。
    /// URL 池与 AVQueuePlayer 都只允许主线程访问，入队统一在主线程完成。
    private func warmURLOnly(_ t: Track) async {
        guard !Task.isCancelled else { return }
        let cached = await MainActor.run { [weak self] in self?.signedURLPool[t.id] }
        if cached == nil {
            let fetched = await API.signedStreamURL(for: t.id)   // 非 Optional，恒返回可用 URL
            guard !Task.isCancelled else { return }
            _ = await MainActor.run { [weak self] () -> Bool in
                guard let self else { return false }
                if self.signedURLPool.count >= self.urlPoolLimit {
                    if let oldest = self.urlPoolOrder.first {
                        self.signedURLPool.removeValue(forKey: oldest)
                        self.urlPoolOrder.removeFirst()
                    }
                }
                self.signedURLPool[t.id] = fetched
                self.urlPoolOrder.append(t.id)
                self.syncPrefetchedItems()
                return true
            }
        } else {
            await MainActor.run { [weak self] in
                self?.syncPrefetchedItems()
            }
        }
    }

    /// 供外部（Library 冷启动等）提前预热单曲签名 URL：入池后 playCurrent 直接命中，
    /// 首曲播放省一次网络往返。不触发封面/歌词预热（避免冷启动做太多无用功）。
    func prewarm(_ t: Track) async {
        await warmURLOnly(t)
    }

    /// 把「已缓存签名 URL 的后续歌曲」持续补进 AVQueuePlayer：
    /// AVQueuePlayer 会自动预缓冲下一首的音频数据，顺序切歌时 advanceToNextItem 秒开。
    /// 严格保持队列顺序——第一个 URL 未就绪就停止，避免插队导致播放顺序错乱；
    /// 后续 URL 就绪时（warmURLOnly 回调）再继续补。引擎音效模式不操作 AVPlayer。
    private func syncPrefetchedItems() {
        guard !usingEngine, !queue.isEmpty, queue.indices.contains(currentIndex),
              !player.items().isEmpty else { return }
        guard let lastItem = player.items().last,
              let lastId = Self.trackId(of: lastItem),
              let lastIdx = queue.firstIndex(where: { $0.id == lastId }) else { return }
        let existingIDs = player.items().compactMap { Self.trackId(of: $0) }
        let end = min(lastIdx + 1 + prefetchAheadCount, queue.count)
        var inserted = [String]()
        for i in (lastIdx + 1)..<end {
            let t = queue[i]
            guard let url = signedURLPool[t.id] else { break }
            guard !inserted.contains(t.id), !existingIDs.contains(t.id) else { continue }
            let item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 30
            Self.setTrackId(t.id, on: item)
            player.insert(item, after: nil)
            inserted.append(t.id)
        }
    }

    /// 预热单首：URL 已由阶段1入池，这里用 AVURLAsset 预热连接/资源头部（只拉前一小部分 metadata），
    /// 再预取封面/歌词/主色到内存缓存，切到它时封面立即显示、歌词区直接命中。
    private func warmMetadata(for t: Track) async {
        guard !Task.isCancelled else { return }
        let url: URL? = await MainActor.run { [weak self] in self?.signedURLPool[t.id] }
        guard let url, !Task.isCancelled else { return }
        let asset = AVURLAsset(url: url)
        _ = try? await asset.load(.duration, .isPlayable)
        guard !Task.isCancelled else { return }
        await prefetchCover(for: t)
        await prefetchLyric(for: t)
        await prefetchPalette(for: t)
    }

    /// 预提取封面主色到 CoverPalette 缓存：命中缓存则直接返回；未命中则下载封面+提取主色+入库。
    /// 这样切到下一首时，loadBackground 的 CoverPalette.color 立即命中，
    /// 背景色与侧边栏主色（playerCardDominant 压暗 0.3）无需再等网络/计算。
    private func prefetchPalette(for t: Track) async {
        guard let url = t.coverURL, !Task.isCancelled else { return }
        _ = await CoverPalette.color(for: t.id, from: url)
    }

    /// 预取封面图到内存缓存（CoverImageCache）：切歌时 CachedCoverImage 立即命中。
    private func prefetchCover(for t: Track) async {
        guard let url = t.coverURL, !Task.isCancelled else { return }
        if CoverImageCache.shared.image(for: url) != nil { return }   // 已缓存
        guard !Task.isCancelled else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let img = UIImage(data: data), !Task.isCancelled else { return }
        CoverImageCache.shared.store(img, for: url)
    }

    /// 预取歌词到内存缓存（LyricsCache）：切歌时播放页直接查缓存，跳过网络+解析。
    private func prefetchLyric(for t: Track) async {
        guard t.hasLyric == true, !Task.isCancelled else { return }
        if LyricsCache.shared.lines(for: t.id) != nil { return }       // 已缓存
        guard !Task.isCancelled else { return }
        guard let text = try? await API.fetchLyric(t.id), !Task.isCancelled else { return }
        let lines = parseLyrics(text)
        if !lines.isEmpty { LyricsCache.shared.store(lines, for: t.id) }
    }


    func seek(toFraction fraction: Double) {
        if duration > 0 {
            if usingEngine {
                enginePlayer.seek(toSeconds: fraction * duration)
            } else {
                let target = CMTime(seconds: fraction * duration, preferredTimescale: 600)
                player.seek(to: target)
            }
        } else {
            // 加载中（duration 未知/为 0）：记住目标位置，就绪后立即跳过去，
            // 否则拖动会被静默丢弃、滑块弹回原位（原音→引擎下载期间可拖动）
            pendingSeekFraction = fraction
        }
    }

    func seek(toSeconds seconds: Double) {
        if usingEngine {
            enginePlayer.seek(toSeconds: seconds)
        } else {
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        }
    }

    // MARK: - Private

    private func playCurrent(flushReason: ListenFlushReason? = nil,
                             resumeSeconds: Double? = nil,
                             autoResume: Bool = true,
                             preserveProgress: Bool = false) {
        guard let current = current else { return }
        // 切歌/重载会终止一切进行中的切换：取消引擎预加载任务、清空待应用拖动
        engineSwitchTask?.cancel()
        engineSwitchTask = nil
        engineSwitchInProgress = false
        engineDownloadFraction = 0
        pendingSeekFraction = nil
        // 取消上一首的加载任务（快速连续切歌时旧签名 URL 请求不再继续）
        loadTask?.cancel()
        loadTask = nil
        // 先结算上一首的收听：真正切歌才可能产生“跳过”负向信号；
        // 同一首歌重播（单曲循环/音效重载）只结算有效收听，不算跳过
        let sameTrack = (listen.trackId == current.id)
        flushListen(flushReason ?? (sameTrack ? .heartbeat : .switchTrack))
        // 新歌：重置收听状态；同一首歌重播：保留累计（用于“听了几遍”）
        if !sameTrack {
            listen = ListenState(trackId: current.id)
            // 新歌重新获得一次自动重试机会（自动重试按歌曲 id 防重）
            autoRetriedTrackId = nil
        }
        usingEngine = (selectedEQ != "原音")
        // 状态立即重置，UI 先反馈（避免切歌后旧状态残留）。
        // autoResume=false（暂停中跨播放器切换）：保持暂停态，恢复播放时从续播位置走
        isPlaying = autoResume
        // 跨播放器无缝续播（原音↔引擎音效）：保留当前进度显示，
        // 加载完成后从 resumeSeconds 位置接续，避免进度闪烁归零
        if !preserveProgress {
            duration = 0
            progress = 0
            currentTime = 0
            bufferProgress = 0
        }
        isBuffering = true
        loadFailed = false
        pendingArtwork = nil
        currentArtwork = nil
        bufferingStallStart = nil

        // 顺序切下一首时，AVQueuePlayer 队列已预取目标歌（下一项）→ 保留队列不清空，
        // 在播放分支里用 advanceToNextItem 秒开；其余场景（跳播/插播/模式切换）才清空重建。
        // 三态判断：
        //  alreadyOnTarget —— AVQueuePlayer 已自动切到目标歌（播完自动续播）：不重建不 advance，直接续播；
        //  canAdvance      —— 队列下一项正是目标歌（预取就绪）：advanceToNextItem 秒开；
        //  两者皆否        —— 跳播/插播/模式切换：清空重建。
        let currentItemId = player.currentItem.flatMap { Self.trackId(of: $0) }
        let nextTrackId = player.items().count > 1 ? Self.trackId(of: player.items()[1]) : nil
        let alreadyOnTarget = (currentItemId == current.id)
        let canAdvance = (nextTrackId == current.id)
        if !alreadyOnTarget && !canAdvance {
            // 关键：切歌瞬间同步终止上一首的播放与加载，而不是等新歌 URL 就绪后再替换——
            // AVPlayer：清空当前 item，立刻断开旧音频流（正在进行的缓冲/播放立即停止），
            // 这样即使新歌的签名 URL 还在网络请求中，上一首也已经不再发声、不再占用带宽
            player.pause()
            player.volume = 1.0   // 切歌时音量增益复位，防止残留状态影响新歌
            player.replaceCurrentItem(with: nil)
        }
        if (alreadyOnTarget || canAdvance) && !autoResume {
            // B17：暂停状态下切歌（复用预取队列但保持暂停）——
            // 先停掉上一首的出声，避免"有声音却显示暂停"的不一致状态
            player.pause()
        }
        enginePlayer.stop()

        let task = Task { [weak self] in
            guard let self else { return }
            let trackId = current.id
            // 优先复用预取缓存 URL（切歌免再向后端签发，缩短切歌等待）；未命中才实时请求
            let url: URL
            let cached = await MainActor.run { () -> URL? in
                // self 已由外层 guard let self 解包为非 Optional，直接访问
                guard let c = self.signedURLPool[trackId] else { return nil }
                self.signedURLPool.removeValue(forKey: trackId)
                self.urlPoolOrder.removeAll { $0 == trackId }
                return c
            }
            if let cached {
                url = cached
            } else {
                url = await API.signedStreamURL(for: trackId)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // 切歌后旧任务迟到响应直接丢弃，防止覆盖新歌状态
                guard self.current?.id == trackId else { return }
                if self.usingEngine {
                    self.enginePlayer.onProgress = { [weak self] cur, dur in
                        guard let self = self else { return }
                        // 加载期间拖动待应用：进度数据一到就跳过去
                        if let pf = self.pendingSeekFraction, dur > 0 {
                            self.pendingSeekFraction = nil
                            let t = pf * dur
                            self.enginePlayer.seek(toSeconds: t)
                            self.currentTime = t
                            self.progress = min(max(pf, 0), 1)
                            return
                        }
                        self.currentTime = cur
                        self.duration = dur
                        self.progress = dur > 0 ? min(cur / dur, 1) : 0
                        self.updateNowPlaying()
                    }
                    self.enginePlayer.onCompletion = { [weak self] in
                        guard let self else { return }
                        // 完整听完一首：累计“听了几遍”，并结算收听时长
                        if self.listen.trackId == self.current?.id {
                            self.listen.completedPlays += 1
                        }
                        self.flushListen(.complete)
                        self.next()
                    }
                    self.enginePlayer.onLoadingChanged = { [weak self] loading in
                        self?.isBuffering = loading
                        if !loading { self?.bufferProgress = 1 }
                    }
                    // 3D 引擎加载失败也要走统一自愈（此前只 print，UI 无感知 → 静默卡死）
                    self.enginePlayer.onLoadFailed = { [weak self] in
                        guard let self else { return }
                        DispatchQueue.main.async {
                            self.handlePlaybackFailure()
                        }
                    }
                    self.enginePlayer.load(url: url,
                                           mode: Self.engineMode(for: self.selectedEQ),
                                           startSeconds: resumeSeconds ?? 0,
                                           autoPlay: autoResume)
                } else {
                    // 顺序切歌且队列已预取目标歌：直接 advanceToNextItem 秒开（AVQueuePlayer 已预缓冲音频）；
                    // 已由 AVQueuePlayer 自动切到目标歌（播完自动续播）：不重建不 advance，直接续播；
                    // 其余（跳播/插播/模式切换）：重建队列——当前歌 + 后续若干首（用预取签名 URL）
                    if canAdvance {
                        self.player.advanceToNextItem()
                        self.topUpQueue()   // 补充队列，保持后续始终有可预取
                    } else if !alreadyOnTarget {
                        self.prepareQueuePlayer(currentIndex: self.currentIndex, currentURL: url)
                    }
                    if let rs = resumeSeconds {
                        // 无缝续播：先定位到切换前进度，再按原播放状态决定是否播放
                        if autoResume {
                            self.player.seek(to: CMTime(seconds: rs, preferredTimescale: 600)) { _ in
                                DispatchQueue.main.async { self.player.play() }
                            }
                        } else {
                            self.player.seek(to: CMTime(seconds: rs, preferredTimescale: 600))
                        }
                    } else if autoResume {
                        self.player.play()
                    }
                }
                self.updateNowPlaying(force: true)   // 切歌：立即刷新锁屏信息
                // 新歌开始播放后，为「接下来 N 首」启动预加载（预热签名 URL + 连接头部）
                self.schedulePrefetch()
            }
        }
        loadTask = task
        loadArtworkIfNeeded()
        Task {
            await API.reportPlay(current.id)
            // 记录播放历史
            await API.recordHistory(
                trackId: current.id,
                title: current.title,
                artist: current.artist ?? "",
                cover: current.coverURL?.absoluteString ?? ""
            )
        }
    }

    /// 异步加载歌曲封面用于锁屏展示（无封面则保持默认渐变封面）。
    /// 下载完成时一次性构建 MPMediaItemArtwork 缓存起来，避免 0.1s 进度刷新反复创建。
    private func loadArtworkIfNeeded() {
        guard let url = current?.coverURL else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                // 切歌后旧封面迟到：丢弃，防止旧封面盖到新歌上
                guard self.current?.coverURL == url else { return }
                self.pendingArtwork = image
                self.currentArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.updateNowPlaying(force: true)   // 封面就绪：立即刷新锁屏封面
            }
        }.resume()
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true

        // MPRemoteCommandCenter 的回调在任意线程触发，
        // 而 @Published 状态的写入必须在主线程，否则存在数据竞争。
        // 所有命令统一转发回主线程执行。
        center.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.resumePlayback() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.pausePlayback() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.toggle() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let seconds = e.positionTime
            DispatchQueue.main.async { self?.seek(toSeconds: seconds) }
            return .success
        }
    }

    // MARK: - 音频打断处理（微信语音 / 来电等打断后自动恢复播放）

    private func setupInterruptionHandling() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let info = note.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt else { return }

            if typeValue == AVAudioSession.InterruptionType.began.rawValue {
                // 被打断（其他 App 抢占 / 来电 / 语音）：真正暂停当前播放器。
                // 之前只改 isPlaying 状态，AVPlayer 仍被系统静音挂着，
                // 恢复时容易状态错乱；引擎/原音两个播放器必须都停（防叠加）。
                self.enginePlayer.pause()
                self.player.pause()
                self.isPlaying = false
                self.updateNowPlaying(force: true)
            } else if typeValue == AVAudioSession.InterruptionType.ended.rawValue {
                // 打断结束：系统允许恢复时重新激活会话、复位音量并继续播放。
                // 必须按当前实际播放器恢复：引擎音效走 enginePlayer，原音走 AVPlayer。
                // 之前无条件 player.play() 会导致 3D 模式下两个播放器同时输出同一首歌，
                // 音量叠加翻倍、声音错乱（时大时小的直接来源）。
                guard let option = info[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
                if AVAudioSession.InterruptionOptions(rawValue: option).contains(.shouldResume) {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    self.restoreOutputVolume()
                    self.resumePlayback()
                }
            }
        }
    }

    /// 恢复输出音量：系统可能因打断 / 音频闪避（ducking）/ 后台降权改变输出增益，
    /// 恢复播放前统一复位，避免「切到其他应用再回来声音变小/变小后不复原」。
    private func restoreOutputVolume() {
        player.volume = 1.0
        enginePlayer.restoreVolume()
    }

    /// 引擎被系统停止后的自动恢复：
    /// 1) App 回前台：后台期间 AVAudioEngine 可能被系统停止（后台优化），引擎不再输出 → 回前台无声。
    /// 2) 音频会话配置变化（耳机插拔/采样率/蓝牙切换）：AVAudioEngine 会自动停止，
    ///    不处理则引擎播放从此无声（用户反馈「切后台再回来没声音」的直接来源）。
    /// 两者统一走 enginePlayer.restartIfNeeded()：检测引擎未运行则重启并挂载、从推算位置续播。
    private func setupEngineRestoreHandling() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // 先确保音频会话激活（后台期间可能被停用），再复位音量、恢复引擎
            try? AVAudioSession.sharedInstance().setActive(true)
            self.restoreOutputVolume()
            self.enginePlayer.restartIfNeeded()
            // 后台期间若被系统静音/暂停（无 interruption 通知的场景），回前台恢复播放
            if self.isPlaying, !self.usingEngine,
               self.player.rate == 0, self.player.currentItem != nil,
               !self.loadFailed {
                self.player.play()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.enginePlayer.restartIfNeeded()
        }
    }

    /// 恢复播放：按当前播放器分派（引擎音效 → enginePlayer；原音 → AVPlayer）。
    /// 锁屏/通知栏/来电恢复都走这里，避免双播放器同播导致音量叠加。
    /// 加载失败状态下点播放 = 重试加载（当前无有效 item，直接 play 会空转假播放）。
    private func resumePlayback() {
        if loadFailed {
            reloadCurrent()
            return
        }
        if usingEngine {
            enginePlayer.play()
        } else {
            player.play()
        }
        isPlaying = true
        updateNowPlaying(force: true)
    }

    private func pausePlayback() {
        // 暂停前结算一次收听时长（不触发“跳过”信号）
        flushListen(.pause)
        if usingEngine {
            enginePlayer.pause()
        } else {
            player.pause()
        }
        isPlaying = false
        updateNowPlaying(force: true)
    }

    // MARK: - 收听结算

    /// 每秒心跳：仅在真实出声时累计收听秒数（缓冲/加载/暂停不计入）
    private func listenTick() {
        guard current != nil, isPlaying, !loadFailed, !isBuffering else { return }
        listen.seconds += 1
        // 每 30s 自动上报一次，避免 App 被杀导致收听数据丢失
        if listen.seconds - listen.reported >= 30 {
            flushListen(.heartbeat)
        }
    }

    /// 结算当前收听段：所有播放时长都累计上报 listen（用于听歌时长统计）；
    /// 切走时进度 < 30% 且听了 ≥ 5 秒额外记为"跳过"（负向信号）
    private func flushListen(_ reason: ListenFlushReason) {
        guard !listen.trackId.isEmpty else { return }
        let delta = listen.seconds - listen.reported
        guard delta >= 1 else { return }
        let frac = duration > 0 ? min(listen.seconds / duration, 1.0) : 0
        // 所有播放时长都上报 listen（听歌时长统计用），不管听了多少
        let meta = API.BehaviorEvent.metaJSON([
            "fraction": (frac * 100).rounded() / 100,
            "plays": listen.completedPlays,
            "seconds": Int(listen.seconds)
        ])
        let ev = API.BehaviorEvent(trackId: listen.trackId, event: "listen",
                                   value: delta, meta: meta)
        Task { await API.reportBehavior([ev]) }
        listen.reported = listen.seconds
        // 切歌且听的时间很短（<30%），额外记 skip 负向信号
        if reason == .switchTrack && delta >= 5 && frac < 0.3 {
            let skipEv = API.BehaviorEvent(trackId: listen.trackId, event: "skip",
                                           value: 0, meta: API.BehaviorEvent.metaJSON(["fraction": (frac * 100).rounded() / 100]))
            Task { await API.reportBehavior([skipEv]) }
        }
    }

    private func updateNowPlaying(force: Bool = false) {
        guard let current = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        // 节流：进度每 0.1s 刷新，但锁屏信息无需那么频繁（每次写入都有开销）。
        // 切歌/暂停/恢复/封面就绪时 force=true 立即刷新，其余刷新间隔 ≥ 0.5s。
        let now = Date().timeIntervalSince1970
        if !force, now - lastNowPlayingUpdate < 0.5 { return }
        lastNowPlayingUpdate = now
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyArtist: current.artist ?? "未知歌手",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let album = current.album, !album.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        info[MPMediaItemPropertyArtwork] = currentArtwork ?? Self.fallbackArtwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// 无封面时的兜底锁屏封面：只生成一次并缓存，避免每 0.5s 进度刷新重复渲染
    private static let fallbackArtwork: MPMediaItemArtwork = {
        let size = CGSize(width: 600, height: 600)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let colors = [UIColor.systemPurple.cgColor, UIColor.systemBlue.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors,
                                         locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
            }
            let config = UIImage.SymbolConfiguration(pointSize: 180, weight: .light)
            if let symbol = UIImage(systemName: "music.note", withConfiguration: config) {
                symbol.draw(in: CGRect(x: size.width / 2 - 90,
                                       y: size.height / 2 - 90,
                                       width: 180,
                                       height: 180),
                            blendMode: .normal,
                            alpha: 0.85)
            }
        }
        return MPMediaItemArtwork(boundsSize: size) { _ in image }
    }()
}
