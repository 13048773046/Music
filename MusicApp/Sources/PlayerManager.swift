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
    /// 3D 环绕音效实时引擎
    private let enginePlayer = AudioEnginePlayer()
    /// 当前是否在用引擎播放（3D 模式）
    private var usingEngine = false

    @Published var queue: [Track] = []
    @Published var currentIndex: Int = -1
    @Published var isPlaying = false
    @Published var progress: Double = 0
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var playMode: PlayMode = .listLoop
    /// 首页播放页背景是否偏浅（供透明导航栏决定文字颜色）
    @Published var playerCardBackgroundLight: Bool = true
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

    private var pendingArtwork: UIImage?
    /// 已构建好的锁屏 artwork 对象（切歌时重建一次，进度刷新不再重复创建，降低 0.1s 刷新开销）
    private var currentArtwork: MPMediaItemArtwork?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?

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

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10),   // 0.1s：进度条等 UI 平滑（歌词另有逐帧实时源）
            queue: .main
        ) { [weak self] time in
            guard let self = self else { return }
            let sec = CMTimeGetSeconds(time)
            self.currentTime = sec.isFinite ? sec : 0
            let d = CMTimeGetSeconds(self.player.currentItem?.duration ?? .zero)
            if d.isFinite, d > 0 {
                self.duration = d
                self.progress = min(max(self.currentTime / d, 0), 1)
            }
            // 缓冲状态：播放点数据未到达时（卡顿/加载中）显示加载动画
            self.isBuffering = (self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
            // 已缓冲进度：当前已加载区间的终点 / 总时长
            if let item = self.player.currentItem, self.duration > 0,
               let range = item.loadedTimeRanges.first?.timeRangeValue {
                let bufferEnd = CMTimeGetSeconds(range.start) + CMTimeGetSeconds(range.duration)
                self.bufferProgress = min(max(bufferEnd / self.duration, 0), 1)
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

        // 音频流加载失败（网络中断/资源损坏/服务器返回错误）：UI 展示重试，避免 App 静默卡死
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.loadFailed = true
            self?.isBuffering = false
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
        if queue != tracks {
            queue = tracks
        }
        if let index = tracks.firstIndex(of: track) {
            currentIndex = index
        }
        playCurrent()
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
        guard duration > 0 else { return }
        if usingEngine {
            enginePlayer.seek(toSeconds: fraction * duration)
        } else {
            let target = CMTime(seconds: fraction * duration, preferredTimescale: 600)
            player.seek(to: target)
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

    private func playCurrent(flushReason: ListenFlushReason? = nil) {
        guard let current = current else { return }
        // 先结算上一首的收听：真正切歌才可能产生“跳过”负向信号；
        // 同一首歌重播（单曲循环/音效重载）只结算有效收听，不算跳过
        let sameTrack = (listen.trackId == current.id)
        flushListen(flushReason ?? (sameTrack ? .heartbeat : .switchTrack))
        // 新歌：重置收听状态；同一首歌重播：保留累计（用于“听了几遍”）
        if !sameTrack {
            listen = ListenState(trackId: current.id)
        }
        usingEngine = (selectedEQ == "3D 环绕")
        // 状态立即重置，UI 先反馈（避免切歌后旧状态残留）
        isPlaying = true
        duration = 0
        progress = 0
        currentTime = 0
        bufferProgress = 0
        isBuffering = true
        loadFailed = false
        pendingArtwork = nil
        currentArtwork = nil

        // 关键：切歌瞬间同步终止上一首的播放与加载，而不是等新歌 URL 就绪后再替换——
        // 1) AVPlayer：清空当前 item，立刻断开旧音频流（正在进行的缓冲/播放立即停止）
        // 2) 3D 环绕引擎：取消正在进行的整曲下载任务并停止引擎
        // 这样即使新歌的签名 URL 还在网络请求中，上一首也已经不再发声、不再占用带宽
        player.pause()
        player.volume = 1.0   // 切歌时音量增益复位，防止残留状态影响新歌
        player.replaceCurrentItem(with: nil)
        enginePlayer.stop()

        Task {
            // 优先获取签名时效播放 URL（防链接泄露/盗链），失败自动回退普通 URL
            let url = await API.signedStreamURL(for: current.id)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // 切歌后旧任务迟到响应直接丢弃，防止覆盖新歌状态
                guard self.current?.id == current.id else { return }
                if self.usingEngine {
                    self.enginePlayer.onProgress = { [weak self] cur, dur in
                        guard let self = self else { return }
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
                    self.enginePlayer.load(url: url, mode: .surround3D)
                } else {
                    self.player.replaceCurrentItem(with: AVPlayerItem(url: url))
                    self.player.play()
                }
                self.updateNowPlaying()
            }
        }
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
                self.updateNowPlaying()
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

        center.playCommand.addTarget { [weak self] _ in
            self?.resumePlayback()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pausePlayback()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.toggle()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.next()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.seek(toSeconds: e.positionTime)
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
                // 必须按当前实际播放器恢复：3D 环绕走 enginePlayer，原音走 AVPlayer。
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

    /// 恢复播放：按当前播放器分派（3D 环绕 → enginePlayer；原音 → AVPlayer）。
    /// 锁屏/通知栏/来电恢复都走这里，避免双播放器同播导致音量叠加。
    private func resumePlayback() {
        if usingEngine {
            enginePlayer.play()
        } else {
            player.play()
        }
        isPlaying = true
        updateNowPlaying()
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
        updateNowPlaying()
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

    private func updateNowPlaying() {
        guard let current = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyArtist: current.artist ?? "未知歌手",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyPlaybackProgress: progress
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
