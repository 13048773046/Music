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

/// 侧边栏「听歌模式」：默认模式（默认随机流）/ 我的喜欢（点赞列表循环）/ 新鲜模式（完全随机）
enum ListenMode: String, CaseIterable {
    case normal = "默认模式"
    case liked = "我的喜欢"
    case fresh = "新鲜模式"

    var icon: String {
        switch self {
        case .normal: return "list.bullet"
        case .liked: return "heart"
        case .fresh: return "sparkles"
        }
    }
}

final class PlayerManager: NSObject, ObservableObject {
    static let shared = PlayerManager()

    let player = AVPlayer()
    /// 引擎音效实时处理引擎（3D 立体/360 环绕/复古/现场/流行/摇滚）
    private let enginePlayer = AudioEnginePlayer()
    /// 当前是否在用引擎播放（任一引擎音效模式；歌词等组件据此决定取数源）
    private(set) var usingEngine = false

    @Published var queue: [Track] = []
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
    /// 缓冲卡死检测：连续缓冲超过阈值且播放点无进展 → 判定加载失败走自愈
    private var bufferingStallStart: Date?
    private var stallProgressAtStart: Double = 0
    /// 缓冲卡死判定阈值：缓冲超过 15s 且进度无变化
    private let stallTimeout: TimeInterval = 15

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
        ) { [weak self] _ in
            guard let self else { return }
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

        // 内存压力：清空图片/主色/歌词缓存，防止长滑播放后内存膨胀被系统杀进程
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            CoverImageCache.shared.clear()
            CoverPalette.clearCache()
            API.clearLyricCache()
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
        }
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

    func play(_ track: Track, in tracks: [Track]) {
        guard !tracks.isEmpty else { return }   // 空队列不进入播放
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
    /// 行为：置失败状态供 UI 展示重试，并对当前歌做一次有限自动重试（网络瞬时抖动自愈）。
    private func handlePlaybackFailure() {
        guard !loadFailed else { return }   // 已在失败状态，避免重复触发自动重试
        loadFailed = true
        isBuffering = false
        isPlaying = false   // 实际已无声：锁屏/UI 同步为暂停态，避免「显示播放中但无声音」
        bufferingStallStart = nil
        updateNowPlaying(force: true)
        guard let trackId = current?.id, autoRetriedTrackId != trackId else { return }
        autoRetriedTrackId = trackId
        // 延迟 2s 自动重试一次；期间用户手动切歌/重试成功则取消
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self,
                  self.current?.id == trackId,   // 仍是同一首歌（未手动切走）
                  self.loadFailed else { return } // 期间未恢复（手动重试成功则跳过）
            self.playCurrent(flushReason: .heartbeat)
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
    /// 通知歌曲成为当前播放；播完后自动接回原有队列（不替换整个流、不丢上下文），
    /// 避免「只有一首歌」播完即停。
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
        } else if let found = queue.firstIndex(where: { $0.id == track.id }) {
            // 本就在当前流中：定位播放（不改变队列）
            currentIndex = found
        } else {
            // 不在当前流：替换当前位置（播完自然续接原流下一位，模式/队列保持）
            var q = queue
            q[idx] = track
            queue = q
            currentIndex = idx
        }
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
        switch playMode {
        case .singleLoop:
            playCurrent()
            return
        case .shuffle:
            let target = randomIndex(excluding: currentIndex)
            currentIndex = target
        default:
            currentIndex = (currentIndex + 1) % queue.count
        }
        playCurrent()
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
    /// - 默认模式：恢复默认全随机流 + 用户自选循环模式
    /// - 我的喜欢：只播用户点赞过的歌曲，播完回到第一首循环
    /// - 新鲜模式：完全随机（队列打乱 + 随机播放）
    func applyListenMode(_ mode: ListenMode) {
        guard mode != listenMode || mode == .liked else {
            // 同模式重复点击默认/新鲜：不重复切换；我的喜欢每次尝试恢复/刷新缓存
            return
        }
        let previous = listenMode
        saveSession(for: previous)
        listenMode = mode
        switch mode {
        case .normal:
            restoreNormalStream()
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
    /// normal 会话恢复时同步发现页数据源，保证首页列表与播放流一致。
    private func restoreSession(_ s: ModeSession) {
        guard !s.queue.isEmpty, s.queue.indices.contains(s.currentIndex) else { return }
        if s.mode == .normal {
            let lib = Library.shared
            lib.tracks = s.queue
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
        case .liked: switchToLiked(fallback: nil)
        case .fresh: switchToFresh(fallback: nil)
        }
    }

    /// 默认模式：优先恢复缓存会话；无缓存才切回 Library 默认全随机流，恢复保存的循环模式
    private func restoreNormalStream() {
        playMode = savedNormalMode
        if let s = sessions[.normal], !s.queue.isEmpty {
            restoreSession(s)
            return
        }
        let lib = Library.shared
        // 队列不在默认流中（如喜欢/新鲜/搜索流）时切回；未加载则先加载，加载完自动切回
        if queue != lib.tracks {
            if !lib.isLoaded {
                Task {
                    await lib.load()
                    await MainActor.run {
                        guard listenMode == .normal else { return }
                        if let cur = current, lib.tracks.contains(where: { $0.id == cur.id }) {
                            play(cur, in: lib.tracks)
                        } else if let first = lib.tracks.first {
                            play(first, in: lib.tracks)
                        }
                    }
                }
                return
            }
            if let cur = current, lib.tracks.contains(where: { $0.id == cur.id }) {
                play(cur, in: lib.tracks)
            } else if let first = lib.tracks.first {
                play(first, in: lib.tracks)
            }
        }
    }

    /// 我的喜欢：有缓存恢复缓存；无缓存拉取点赞列表（列表循环，播完回第一首）。
    /// 拉取失败或列表为空时回退上一模式，不出现「模式已切、歌曲没换」。
    private func switchToLiked(fallback: ListenMode?) {
        if let s = sessions[.liked], !s.queue.isEmpty {
            restoreSession(s)
            return
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
                guard !list.isEmpty else {
                    if let fb = fallback { handleFailedSwitch(fallback: fb) }
                    return
                }
                let s = ModeSession(queue: list, currentIndex: 0,
                                    wasPlaying: true, mode: .liked)
                sessions[.liked] = s
                restoreSession(s)
            }
        }
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

        // 关键：切歌瞬间同步终止上一首的播放与加载，而不是等新歌 URL 就绪后再替换——
        // 1) AVPlayer：清空当前 item，立刻断开旧音频流（正在进行的缓冲/播放立即停止）
        // 2) 引擎播放器：取消正在进行的整曲下载任务并停止引擎
        // 这样即使新歌的签名 URL 还在网络请求中，上一首也已经不再发声、不再占用带宽
        player.pause()
        player.volume = 1.0   // 切歌时音量增益复位，防止残留状态影响新歌
        player.replaceCurrentItem(with: nil)
        enginePlayer.stop()

        let task = Task {
            // 优先获取签名时效播放 URL（防链接泄露/盗链），失败自动回退普通 URL
            let url = await API.signedStreamURL(for: current.id)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // 切歌后旧任务迟到响应直接丢弃，防止覆盖新歌状态
                guard self.current?.id == current.id else { return }
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
                    let item = AVPlayerItem(url: url)
                    self.player.replaceCurrentItem(with: item)
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
            }
        }
        loadTask = task
        loadArtworkIfNeeded()
        Task { await API.reportPlay(current.id) }
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
                // 被打断（如微信发语音）：UI 显示暂停状态
                self.isPlaying = false
            } else if typeValue == AVAudioSession.InterruptionType.ended.rawValue {
                // 打断结束：系统允许恢复时重新激活会话并继续播放。
                // 必须按当前实际播放器恢复：引擎音效走 enginePlayer，原音走 AVPlayer。
                // 之前无条件 player.play() 会导致 3D 模式下两个播放器同时输出同一首歌，
                // 音量叠加翻倍、声音错乱（时大时小的直接来源）。
                guard let option = info[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
                if AVAudioSession.InterruptionOptions(rawValue: option).contains(.shouldResume) {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    self.resumePlayback()
                }
            }
        }
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
            // 先确保音频会话激活（后台期间可能被停用），再恢复引擎
            try? AVAudioSession.sharedInstance().setActive(true)
            self?.enginePlayer.restartIfNeeded()
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
