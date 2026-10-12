import AVFoundation

/// 3D 环绕音效实时处理引擎。
///
/// 管线（3D 模式）：
/// ```
/// playerNode ──┬─→ eqLow  (lowPass 250Hz)  ──→ leftBus  (pan -0.45, 微延迟)
///              ├─→ eqMid  (bandPass 250–6k) ─→ centerBus (pan 0)
///              └─→ eqHigh (highPass 6kHz)   ─→ rightBus (pan +0.45, 微延迟)
///                                                         │
///                                                  reverb (wet 35%)
///                                                         │
///                                                    outputNode
/// ```
/// 原音模式：playerNode → outputNode 直通。
final class AudioEnginePlayer {

    enum Mode: String {
        case original       // 原音
        case surround3D     // 3D 环绕
    }

    // MARK: - 节点

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let eqLow = AVAudioUnitEQ(numberOfBands: 1)
    private let eqMid = AVAudioUnitEQ(numberOfBands: 1)
    private let eqHigh = AVAudioUnitEQ(numberOfBands: 1)
    private let mixLow = AVAudioMixerNode()
    private let mixMid = AVAudioMixerNode()
    private let mixHigh = AVAudioMixerNode()
    private let delayLow = AVAudioUnitDelay()
    private let delayHigh = AVAudioUnitDelay()
    private let reverb = AVAudioUnitReverb()
    /// 直通 mixer（原音模式用）
    private let directMix = AVAudioMixerNode()

    // MARK: - 状态

    private var audioFile: AVAudioFile?
    private var fileFormat: AVAudioFormat?
    private var totalFrames: AVAudioFramePosition = 0
    private var isPlaying = false
    private var mode: Mode = .original
    private var startedFrame: AVAudioFramePosition = 0
    private var pausedFrame: AVAudioFramePosition = 0
    private var isConfigured = false
    private var progressTimer: Timer?
    /// 当前下载任务与目标 URL：快速切歌时取消旧任务、丢弃旧回调，防止旧歌覆盖新歌
    private var currentTask: URLSessionDownloadTask?
    private var pendingURL: URL?

    /// 进度回调（每秒约 10 次）
    var onProgress: ((Double, Double) -> Void)?   // (currentSeconds, durationSeconds)
    var onCompletion: (() -> Void)?
    var onLoadingChanged: ((Bool) -> Void)?

    /// 整曲下载用共享会话：避免每次切歌新建 URLSession（每个 session 自带连接池与资源，
    /// 频繁新建会造成资源浪费与潜在泄漏）。downloadTask 会把整曲下载到临时文件，缓存策略仅影响 URL 缓存命中。
    private static let downloadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    // MARK: - 配置

    init() {
        configureNodes()
        buildGraph()
    }

    private func configureNodes() {
        // 低通：< 250Hz（贝斯/底鼓）
        if let band = eqLow.bands.first {
            band.filterType = .lowPass
            band.frequency = 250
            band.bandwidth = 0.5
            band.gain = 0
        }
        // 带通：250Hz – 6kHz（人声主体）
        if let band = eqMid.bands.first {
            band.filterType = .bandPass
            band.frequency = 1800
            band.bandwidth = 2.5
            band.gain = 0
        }
        // 高通：> 6kHz（镲片/空气感）
        if let band = eqHigh.bands.first {
            band.filterType = .highPass
            band.frequency = 6000
            band.bandwidth = 0.5
            band.gain = 0
        }
        // 左右微延迟制造相位差立体感（不要混响/回声）。
        // 注意：wetDryMix 必须保持低值——干湿信号叠加会形成梳状滤波，
        // 某些频段随音乐时变被增强/抵消，听感就是声音时大时小、飘忽。
        delayLow.delayTime = 0.018   // 低频略偏左
        delayLow.feedback = 0
        delayLow.wetDryMix = 12
        delayHigh.delayTime = 0.012  // 高频略偏右
        delayHigh.feedback = 0
        delayHigh.wetDryMix = 12
        // 小房间自然反射（不是大厅环绕感）：近场音响在房间里的听感
        reverb.loadFactoryPreset(.smallRoom)
        reverb.wetDryMix = 8

        // 分频声像：三条分频路信号叠加输出，若各路增益保持 0.9/1.0/0.9 会整体过载
        // （总响度约为原音的 1.6~2.8 倍，切到 3D 模式瞬间音量猛增）。
        // 补偿为 0.55/0.6/0.55，三路 RMS 叠加 ≈ 1.0，与「原音」响度基本一致。
        mixLow.outputVolume = 0.55
        mixMid.outputVolume = 0.6
        mixHigh.outputVolume = 0.55
    }

    private func buildGraph() {
        engine.attach(playerNode)
        engine.attach(eqLow)
        engine.attach(eqMid)
        engine.attach(eqHigh)
        engine.attach(mixLow)
        engine.attach(mixMid)
        engine.attach(mixHigh)
        engine.attach(delayLow)
        engine.attach(delayHigh)
        engine.attach(reverb)
        engine.attach(directMix)

        let output = engine.outputNode
        let format = output.inputFormat(forBus: 0)
        fileFormat = format

        // 原音直通
        engine.connect(playerNode, to: directMix, format: format)
        engine.connect(directMix, to: output, format: format)

        // 3D 分频链（默认也连上，但通过 mute 控制开关）
        engine.connect(playerNode, to: eqLow, format: format)
        engine.connect(eqLow, to: delayLow, format: format)
        engine.connect(delayLow, to: mixLow, format: format)

        engine.connect(playerNode, to: eqMid, format: format)
        engine.connect(eqMid, to: mixMid, format: format)

        engine.connect(playerNode, to: eqHigh, format: format)
        engine.connect(eqHigh, to: delayHigh, format: format)
        engine.connect(delayHigh, to: mixHigh, format: format)

        // 三路分频 → reverb → output
        engine.connect(mixLow, to: reverb, format: format)
        engine.connect(mixMid, to: reverb, format: format)
        engine.connect(mixHigh, to: reverb, format: format)
        engine.connect(reverb, to: output, format: format)
    }

    // MARK: - 播放控制

    /// 从 URL 加载并播放（先下载到临时文件）
    func load(url: URL, mode: Mode) {
        stop()
        onLoadingChanged?(true)
        pendingURL = url

        let task = Self.downloadSession.downloadTask(with: url) { [weak self] tempURL, _, error in
            guard let self = self else { return }
            // 切歌后旧任务迟到响应：直接丢弃，防止旧歌覆盖新歌的音频/状态
            guard self.pendingURL == url else { return }
            self.pendingURL = nil
            if let error = error {
                print("[AudioEngine] download error: \(error)")
                DispatchQueue.main.async { self.onLoadingChanged?(false) }
                return
            }
            guard let tempURL = tempURL else {
                DispatchQueue.main.async { self.onLoadingChanged?(false) }
                return
            }
            do {
                // 拷贝到永久临时位置（downloadTask 完成后 tempURL 会被删）
                let permanent = FileManager.default.temporaryDirectory
                    .appendingPathComponent(url.lastPathComponent)
                if FileManager.default.fileExists(atPath: permanent.path) {
                    try FileManager.default.removeItem(at: permanent)
                }
                try FileManager.default.copyItem(at: tempURL, to: permanent)

                let file = try AVAudioFile(forReading: permanent)
                self.audioFile = file
                self.fileFormat = file.processingFormat
                self.totalFrames = file.length
                self.pausedFrame = 0
                self.apply(mode: mode)

                try self.engine.start()
                self.schedule(from: 0)
                self.play()
                DispatchQueue.main.async { self.onLoadingChanged?(false) }
            } catch {
                print("[AudioEngine] load error: \(error)")
                DispatchQueue.main.async { self.onLoadingChanged?(false) }
            }
        }
        currentTask = task
        task.resume()
    }

    private func schedule(from frame: AVAudioFramePosition) {
        guard let file = audioFile, let format = fileFormat else { return }
        playerNode.stop()
        let framesToPlay = totalFrames - frame
        guard framesToPlay > 0 else { return }
        playerNode.scheduleSegment(
            file,
            startingFrame: frame,
            frameCount: AVAudioFrameCount(framesToPlay),
            at: nil
        ) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.isPlaying else { return }
                self.onCompletion?()
            }
        }
        startedFrame = frame
    }

    func play() {
        guard !isPlaying else { return }
        playerNode.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        guard isPlaying else { return }
        pausedFrame = currentFrame()
        playerNode.pause()
        isPlaying = false
        stopTimer()
    }

    func stop() {
        currentTask?.cancel()
        currentTask = nil
        pendingURL = nil
        playerNode.stop()
        isPlaying = false
        pausedFrame = 0
        stopTimer()
        if engine.isRunning {
            engine.pause()
        }
    }

    private func startTimer() {
        stopTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.onProgress?(self.currentSeconds(), self.durationSeconds())
        }
    }

    private func stopTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    func seek(toSeconds seconds: Double) {
        guard let format = fileFormat, totalFrames > 0 else { return }
        let sampleRate = format.sampleRate
        let targetFrame = AVAudioFramePosition(seconds * sampleRate)
        let clamped = max(0, min(targetFrame, totalFrames - 1))
        pausedFrame = clamped
        if isPlaying {
            schedule(from: clamped)
            playerNode.play()
        }
    }

    func setMode(_ mode: Mode) {
        self.mode = mode
        apply(mode: mode)
    }

    private func apply(mode: Mode) {
        self.mode = mode
        switch mode {
        case .original:
            // 原音：直通 mixer 开，3D 链 mute
            directMix.outputVolume = 1.0
            mixLow.outputVolume = 0
            mixMid.outputVolume = 0
            mixHigh.outputVolume = 0
            reverb.wetDryMix = 0
        case .surround3D:
            // 3D 立体：直通关，分频链开，小房间自然反射。
            // 增益已按三路叠加补偿（见 configureNodes），响度与原音一致，不会时大时小
            directMix.outputVolume = 0
            mixLow.outputVolume = 0.55
            mixMid.outputVolume = 0.6
            mixHigh.outputVolume = 0.55
            reverb.wetDryMix = 8
        }
    }

    // MARK: - 进度

    private func currentFrame() -> AVAudioFramePosition {
        guard isPlaying, let nodeTime = playerNode.lastRenderTime,
              nodeTime.isSampleTimeValid else {
            return pausedFrame
        }
        guard let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
              playerTime.isSampleTimeValid else {
            return pausedFrame
        }
        return startedFrame + playerTime.sampleTime
    }

    func currentSeconds() -> Double {
        guard let format = fileFormat, format.sampleRate > 0 else { return 0 }
        return Double(currentFrame()) / format.sampleRate
    }

    func durationSeconds() -> Double {
        guard let format = fileFormat, format.sampleRate > 0 else { return 0 }
        return Double(totalFrames) / format.sampleRate
    }
}
