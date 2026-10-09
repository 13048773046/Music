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

    private var pendingArtwork: UIImage?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    override init() {
        super.init()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)

        setupRemoteCommands()

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 2),
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
            player.pause()
        } else {
            player.play()
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
        let target = CMTime(seconds: fraction * duration, preferredTimescale: 600)
        player.seek(to: target)
    }

    func seek(toSeconds seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    // MARK: - Private

    private func playCurrent() {
        guard let current = current else { return }
        player.replaceCurrentItem(with: AVPlayerItem(url: API.streamURL(current.id)))
        player.play()
        isPlaying = true
        duration = 0
        progress = 0
        currentTime = 0
        bufferProgress = 0
        isBuffering = true   // 新歌曲开始加载，立即展示缓冲动画
        pendingArtwork = nil
        updateNowPlaying()
        loadArtworkIfNeeded()
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
