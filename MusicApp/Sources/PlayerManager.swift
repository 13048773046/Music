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
    /// 已缓冲进度 0...1（取 currentItem.loadedTimeRanges 中包含当前播放点的一段）
    @Published var bufferProgress: Double = 0
    /// 是否正在缓冲（等待网络数据，用于进度条加载动画）
    @Published var isBuffering: Bool = false
    /// 当前音频加载失败（网络中断/资源损坏/流不可用），UI 展示重试入口
    @Published var loadFailed: Bool = false
    /// 全局音效选择（切歌不重置）
    @Published var selectedEQ: String = "原音"

    private var pendingArtwork: UIImage?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?

    override init() {
        super.init()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)

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
            self?.next()
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
    }

    /// 切换音效后重新加载当前歌曲以应用新音效
    func reloadCurrent() {
        guard current != nil else { return }
        playCurrent()
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

    func toggle() {
        guard current != nil else { return }
        if isPlaying {
            if usingEngine { enginePlayer.pause() } else { player.pause() }
        } else {
            if usingEngine { enginePlayer.play() } else { player.play() }
        }
        isPlaying.toggle()
        updateNowPlaying()
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

    private func playCurrent() {
        guard let current = current else { return }
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

        Task {
            // 优先获取签名时效播放 URL（防链接泄露/盗链），失败自动回退普通 URL
            let url = await API.signedStreamURL(for: current.id)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self = self, self.current?.id == current.id else { return }
                if self.usingEngine {
                    self.enginePlayer.stop()
                    self.enginePlayer.onProgress = { [weak self] cur, dur in
                        guard let self = self else { return }
                        self.currentTime = cur
                        self.duration = dur
                        self.progress = dur > 0 ? min(cur / dur, 1) : 0
                        self.updateNowPlaying()
                    }
                    self.enginePlayer.onCompletion = { [weak self] in
                        self?.next()
                    }
                    self.enginePlayer.onLoadingChanged = { [weak self] loading in
                        self?.isBuffering = loading
                        if !loading { self?.bufferProgress = 1 }
                    }
                    self.enginePlayer.load(url: url, mode: .surround3D)
                    self.player.pause()
                } else {
                    self.enginePlayer.stop()
                    self.player.replaceCurrentItem(with: AVPlayerItem(url: url))
                    self.player.play()
                }
                self.updateNowPlaying()
            }
        }
        loadArtworkIfNeeded()
        Task { await API.reportPlay(current.id) }
    }

    /// 异步加载歌曲封面用于锁屏展示（无封面则保持默认渐变封面）
    private func loadArtworkIfNeeded() {
        guard let url = current?.coverURL else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                self.pendingArtwork = image
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
                // 打断结束：系统允许恢复时重新激活会话并继续播放
                guard let option = info[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
                if AVAudioSession.InterruptionOptions(rawValue: option).contains(.shouldResume) {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    self.player.play()
                    self.isPlaying = true
                    self.updateNowPlaying()
                }
            }
        }
    }

    private func resumePlayback() {
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    private func pausePlayback() {
        player.pause()
        isPlaying = false
        updateNowPlaying()
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
        info[MPMediaItemPropertyArtwork] = pendingArtwork.map { image in
            MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        } ?? Self.fallbackArtwork
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
