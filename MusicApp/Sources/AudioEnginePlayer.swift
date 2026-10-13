import AVFoundation
import QuartzCore   // CACurrentMediaTime（可靠单调时钟）

/// 音效实时处理引擎（原音 + 5 种引擎音效）。
///
/// 管线：
/// ```
/// playerNode ──→ directMix ───────────────────────────────→ output   （原音直通）
/// playerNode ──→ eqLow  → delayLow → mixLow ─┐
/// playerNode ──→ eqMid  →──────────→ mixMid ──┼→ reverb → distortion → output
/// playerNode ──→ eqHigh → delayHigh → mixHigh┘
/// ```
/// 每种音效 = 一组参数（三分频 EQ 增益/分频点、左右延迟、混响预设、三路混音增益、失真染色），
/// 运行时切换参数即切换音效：不重建图、不重新下载整曲，进度与歌词保持连续。
///
/// 进度计算不依赖 AVAudioEngine 渲染时间线（playerNode.lastRenderTime /
/// playerTime(forNodeTime:) 在真机上采样时间域与文件采样率可能不一致、
/// sampleTime 可能无效，导致进度恒为 0 —— 进度条/歌词全部卡死的根源），
/// 改为「真实单调时钟 + 文件采样率」推算：play 时记录起点帧与时刻，
/// currentFrame = 起点帧 + 已播放秒数 × 文件采样率，与硬件采样率/引擎状态无关。
final class AudioEnginePlayer {

    /// 音效模式。与 UI 选项一一对应（PlayerManager 负责名称 → 模式的映射）
    enum Mode: String, CaseIterable {
        case original     // 原音
        case surround3D   // 3D 立体音效
        case surround360  // 360 环绕
        case retro        // 复古
        case live         // 现场
        case pop          // 流行
        case rock         // 摇滚
    }

    // MARK: - 节点

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    /// 三分频路由：低通 250Hz（贝斯/底鼓）/ 带通 1.8k（人声主体）/ 高通 6kHz（镲片/空气感）
    private let eqLow = AVAudioUnitEQ(numberOfBands: 1)
    private let eqMid = AVAudioUnitEQ(numberOfBands: 1)
    private let eqHigh = AVAudioUnitEQ(numberOfBands: 1)
    private let mixLow = AVAudioMixerNode()
    private let mixMid = AVAudioMixerNode()
    private let mixHigh = AVAudioMixerNode()
    private let delayLow = AVAudioUnitDelay()
    private let delayHigh = AVAudioUnitDelay()
    private let reverb = AVAudioUnitReverb()
    /// 失真染色（复古磁带感 / 摇滚失真）；wetDryMix=0 时纯干直通
    private let distortion = AVAudioUnitDistortion()
    /// 直通 mixer（原音模式用）
    private let directMix = AVAudioMixerNode()

    // MARK: - 状态

    private var audioFile: AVAudioFile?
    private var fileFormat: AVAudioFormat?
    private var totalFrames: AVAudioFramePosition = 0
    private var isPlaying = false
    private var mode: Mode = .original
    /// 播放起点帧与起点时刻（可靠时钟进度计算）
    private var playStartFrame: AVAudioFramePosition = 0
    private var playStartTime: TimeInterval = 0
    private var pausedFrame: AVAudioFramePosition = 0
    private var progressTimer: Timer?
    /// 当前下载任务与目标 URL：快速切歌时取消旧任务、丢弃旧回调，防止旧歌覆盖新歌
    private var currentTask: URLSessionDownloadTask?
    private var pendingURL: URL?

    /// 进度回调（每秒约 10 次）
    var onProgress: ((Double, Double) -> Void)?   // (currentSeconds, durationSeconds)
    var onCompletion: (() -> Void)?
    var onLoadingChanged: ((Bool) -> Void)?
    /// 加载/播放失败回调（下载失败、文件损坏等）：上层据此进入失败自愈（重试 UI + 自动重试）
    var onLoadFailed: (() -> Void)?

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
        // 延迟默认参数（apply(mode:) 会按音效覆盖）
        delayLow.delayTime = 0.018
        delayLow.feedback = 0
        delayLow.wetDryMix = 12
        delayHigh.delayTime = 0.012
        delayHigh.feedback = 0
        delayHigh.wetDryMix = 12
        // 混响默认（apply 覆盖）
        reverb.loadFactoryPreset(.smallRoom)
        reverb.wetDryMix = 8
        // 失真默认纯干直通
        distortion.loadFactoryPreset(.speechTape)
        distortion.wetDryMix = 0
        // 分频混音默认（apply 覆盖）。三路 RMS 叠加 ≈ 1.0，响度与原音基本一致，
        // 避免「切音效瞬间音量猛增/时大时小」
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
        engine.attach(distortion)
        engine.attach(directMix)

        let output = engine.outputNode
        let format = output.inputFormat(forBus: 0)
        fileFormat = format

        // 原音直通
        engine.connect(playerNode, to: directMix, format: format)
        engine.connect(directMix, to: output, format: format)

        // 三分频链
        engine.connect(playerNode, to: eqLow, format: format)
        engine.connect(eqLow, to: delayLow, format: format)
        engine.connect(delayLow, to: mixLow, format: format)

        engine.connect(playerNode, to: eqMid, format: format)
        engine.connect(eqMid, to: mixMid, format: format)

        engine.connect(playerNode, to: eqHigh, format: format)
        engine.connect(eqHigh, to: delayHigh, format: format)
        engine.connect(delayHigh, to: mixHigh, format: format)

        // 三路分频 → 混响 → 失真染色 → 输出
        engine.connect(mixLow, to: reverb, format: format)
        engine.connect(mixMid, to: reverb, format: format)
        engine.connect(mixHigh, to: reverb, format: format)
        engine.connect(reverb, to: distortion, format: format)
        engine.connect(distortion, to: output, format: format)
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
                DispatchQueue.main.async {
                    self.onLoadingChanged?(false)
                    self.onLoadFailed?()   // 上层自愈：重试 UI + 有限自动重试
                }
                return
            }
            guard let tempURL = tempURL else {
                DispatchQueue.main.async {
                    self.onLoadingChanged?(false)
                    self.onLoadFailed?()
                }
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
                DispatchQueue.main.async {
                    self.onLoadingChanged?(false)
                    self.onLoadFailed?()
                }
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
    }

    func play() {
        guard !isPlaying else { return }
        playerNode.play()
        isPlaying = true
        // 记录播放起点（可靠时钟进度）
        playStartFrame = pausedFrame
        playStartTime = CACurrentMediaTime()
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
        playStartFrame = 0
        stopTimer()
        // 释放已打开音频文件句柄与格式引用（切歌后旧文件不再被引用，
        // 避免文件句柄残留导致磁盘/内存资源占用）
        audioFile = nil
        fileFormat = nil
        totalFrames = 0
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
            playStartFrame = clamped
            playStartTime = CACurrentMediaTime()
        }
    }

    /// 运行时切换音效参数（引擎模式之间切换用，不重载音频、进度连续）
    func setMode(_ mode: Mode) {
        self.mode = mode
        apply(mode: mode)
    }

    /// 每种音效的参数表：先全部关断，再按模式开启对应组合。
    /// 参数设计原则：三路分频混音叠加后 RMS ≈ 1.0，保证各音效响度一致、切换不突兀。
    private func apply(mode: Mode) {
        self.mode = mode
        // 全关
        directMix.outputVolume = 0
        mixLow.outputVolume = 0
        mixMid.outputVolume = 0
        mixHigh.outputVolume = 0
        reverb.wetDryMix = 0
        distortion.wetDryMix = 0
        delayLow.feedback = 0
        delayLow.wetDryMix = 0
        delayHigh.feedback = 0
        delayHigh.wetDryMix = 0
        // 分频点复位（复古会下调高频分频点）
        eqHigh.bands.first?.frequency = 6000

        switch mode {
        case .original:
            // 原音：仅直通
            directMix.outputVolume = 1.0

        case .surround3D:
            // 3D 立体音效：三分频 + 左右微延迟相位差 + 小房间自然反射
            mixLow.outputVolume = 0.55
            mixMid.outputVolume = 0.6
            mixHigh.outputVolume = 0.55
            delayLow.delayTime = 0.018   // 低频略偏左
            delayLow.feedback = 0
            delayLow.wetDryMix = 12
            delayHigh.delayTime = 0.012  // 高频略偏右
            delayHigh.feedback = 0
            delayHigh.wetDryMix = 12
            reverb.loadFactoryPreset(.smallRoom)
            reverb.wetDryMix = 8

        case .surround360:
            // 360 环绕：左右延迟差拉大（声像更宽）+ 中厅反射 → 环绕流动感
            mixLow.outputVolume = 0.5
            mixMid.outputVolume = 0.55
            mixHigh.outputVolume = 0.5
            delayLow.delayTime = 0.030   // 左路更晚 → 偏右
            delayLow.feedback = 0
            delayLow.wetDryMix = 20
            delayHigh.delayTime = 0.006  // 右路更早 → 偏左
            delayHigh.feedback = 0
            delayHigh.wetDryMix = 20
            reverb.loadFactoryPreset(.mediumHall)
            reverb.wetDryMix = 18

        case .retro:
            // 复古：高频路衰减（磁带高切）+ 原音混底保清晰 + 磁带感失真 + 轻微单声道回声
            directMix.outputVolume = 0.25
            mixLow.outputVolume = 0.5
            mixMid.outputVolume = 0.5
            mixHigh.outputVolume = 0.35
            eqHigh.bands.first?.frequency = 4500   // 高切：高频分频点下调
            delayLow.delayTime = 0.085
            delayLow.feedback = 0.35
            delayLow.wetDryMix = 18
            delayHigh.delayTime = 0.06
            delayHigh.feedback = 0.3
            delayHigh.wetDryMix = 16
            distortion.loadFactoryPreset(.speechTape)
            distortion.wetDryMix = 18

        case .live:
            // 现场：大厅混响 + 原音干湿混合（更自然的现场距离感）
            directMix.outputVolume = 0.35
            mixLow.outputVolume = 0.5
            mixMid.outputVolume = 0.55
            mixHigh.outputVolume = 0.5
            reverb.loadFactoryPreset(.largeHall)
            reverb.wetDryMix = 26

        case .pop:
            // 流行：人声路（中频）更突出 + 轻厅堂润色
            directMix.outputVolume = 0.2
            mixLow.outputVolume = 0.45
            mixMid.outputVolume = 0.7
            mixHigh.outputVolume = 0.5
            reverb.loadFactoryPreset(.mediumHall)
            reverb.wetDryMix = 10

        case .rock:
            // 摇滚：V 形 EQ（低频/高频更响、中频稍收）+ 轻微失真染色 + 紧凑混响
            directMix.outputVolume = 0.15
            mixLow.outputVolume = 0.65
            mixMid.outputVolume = 0.45
            mixHigh.outputVolume = 0.6
            delayLow.delayTime = 0.014
            delayLow.feedback = 0
            delayLow.wetDryMix = 10
            delayHigh.delayTime = 0.010
            delayHigh.feedback = 0
            delayHigh.wetDryMix = 10
            reverb.loadFactoryPreset(.mediumRoom)
            reverb.wetDryMix = 12
            distortion.loadFactoryPreset(.multiDistortedSquared)
            distortion.wetDryMix = 12
        }
    }

    // MARK: - 进度（可靠时钟，与引擎渲染时间线解耦）

    private func currentFrame() -> AVAudioFramePosition {
        guard isPlaying, let format = fileFormat, format.sampleRate > 0 else { return pausedFrame }
        let elapsed = CACurrentMediaTime() - playStartTime
        guard elapsed >= 0, elapsed.isFinite else { return playStartFrame }
        let frames = playStartFrame + AVAudioFramePosition(elapsed * format.sampleRate)
        return min(frames, max(totalFrames - 1, 0))
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
