import AVFoundation
import QuartzCore   // CACurrentMediaTime（可靠单调时钟）

/// 引擎整曲下载的进度代理：把 URLSessionDownloadTask 的下载进度按 URL 转发给对应引擎实例。
/// （downloadTask 无 completion-handler 进度 API，必须走 delegate；共享会话共享一个代理）
final class EngineDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    static let shared = EngineDownloadDelegate()
    /// url.absoluteString → 进度回调
    private var handlers: [String: (Double) -> Void] = [:]
    private let lock = NSLock()

    func register(url: String, handler: @escaping (Double) -> Void) {
        lock.lock(); handlers[url] = handler; lock.unlock()
    }
    func unregister(url: String) {
        lock.lock(); handlers[url] = nil; lock.unlock()
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0,
              let desc = downloadTask.taskDescription else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        lock.lock()
        let handler = handlers[desc]
        lock.unlock()
        DispatchQueue.main.async { handler?(min(max(fraction, 0), 1)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}

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
    /// prepare 是否就绪（已下载、引擎已启动、已 schedule）
    private var isPrepared = false
    /// 引擎运行状态低频检查计数（progress timer 内每 ~1s 检查一次）。
    /// AVAudioEngine 长时间运行可能被系统异常停止且不触发配置变化通知 → 静默无声，
    /// 兜底：检测到未运行时自动 restartIfNeeded 续播。
    private var restoreCheckCounter = 0

    /// 进度回调（每秒约 10 次）
    var onProgress: ((Double, Double) -> Void)?   // (currentSeconds, durationSeconds)
    var onCompletion: (() -> Void)?
    var onLoadingChanged: ((Bool) -> Void)?
    /// 加载/播放失败回调（下载失败、文件损坏等）：上层据此进入失败自愈（重试 UI + 自动重试）
    var onLoadFailed: (() -> Void)?

    /// 整曲下载用共享会话：避免每次切歌新建 URLSession（每个 session 自带连接池与资源，
    /// 频繁新建会造成资源浪费与潜在泄漏）。downloadTask 会把整曲下载到临时文件，缓存策略仅影响 URL 缓存命中。
    /// delegate 用于上报下载进度（「原音→引擎」无缝切换时 UI 显示加载百分比）。
    private static let downloadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config,
                                 delegate: EngineDownloadDelegate.shared,
                                 delegateQueue: nil)
        return session
    }()

    /// 下载进度回调（0...1，主线程）
    var onDownloadProgress: ((Double) -> Void)?

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
        // 失真默认纯干直通（预设值在 apply(mode:) 按音效覆盖）
        distortion.loadFactoryPreset(.multiDecimated1)
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

    /// 预下载整曲并就绪（不启动播放、不上报进度 Timer）。
    /// 用途：原音 → 引擎音效的无缝接力——AVPlayer 继续出声，引擎在后台下载；
    /// 就绪后调用 playFrom(seconds:autoPlay:) 从当前进度接管，用户感知不到加载。
    /// 完成/失败回调均回主线程；下载进度经 onDownloadProgress 上报（0...1）。
    func prepare(url: URL, mode: Mode, completion: @escaping () -> Void) {
        stop()
        isPrepared = false
        onLoadingChanged?(true)
        pendingURL = url
        EngineDownloadDelegate.shared.register(url: url.absoluteString) { [weak self] f in
            self?.onDownloadProgress?(f)
        }

        let task = Self.downloadSession.downloadTask(with: url) { [weak self] tempURL, _, error in
            guard let self = self else { return }
            // 切歌/切音效后旧任务迟到响应：直接丢弃，防止旧内容覆盖新状态
            guard self.pendingURL == url else {
                EngineDownloadDelegate.shared.unregister(url: url.absoluteString)
                return
            }
            self.pendingURL = nil
            EngineDownloadDelegate.shared.unregister(url: url.absoluteString)
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
                self.isPrepared = true
                DispatchQueue.main.async {
                    self.onLoadingChanged?(false)
                    completion()
                }
            } catch {
                print("[AudioEngine] load error: \(error)")
                DispatchQueue.main.async {
                    self.onLoadingChanged?(false)
                    self.onLoadFailed?()
                }
            }
        }
        task.taskDescription = url.absoluteString
        currentTask = task
        task.resume()
    }

    /// 从 URL 加载并播放（先下载到临时文件）。
    /// - startSeconds: 初始播放位置（无缝续播：跨播放器切换时从该秒数接续，0 = 从头）
    /// - autoPlay: 下载完成后是否立即播放（false = 就绪但保持暂停，pausedFrame 已定位，
    ///   之后 play() 会从该位置续播）
    func load(url: URL, mode: Mode, startSeconds: Double = 0, autoPlay: Bool = true) {
        prepare(url: url, mode: mode) { [weak self] in
            guard let self = self else { return }
            if autoPlay {
                self.playFrom(seconds: startSeconds, autoPlay: true)
            } else {
                // 暂停态：只定位，就绪后由 resumePlayback 从该位置起播
                self.seek(toSeconds: startSeconds)
            }
        }
    }

    /// 从指定位置播放（必须已 prepare 就绪）。
    /// - autoPlay: false 时只定位就绪（pausedFrame），由后续 play() 从该位置起播
    func playFrom(seconds: Double, autoPlay: Bool = true) {
        guard isPrepared, let format = fileFormat, totalFrames > 0 else { return }
        let target = AVAudioFramePosition(seconds * format.sampleRate)
        let clamped = max(0, min(target, totalFrames - 1))
        pausedFrame = clamped
        schedule(from: clamped)
        if autoPlay {
            playerNode.play()
            isPlaying = true
            playStartFrame = clamped
            playStartTime = CACurrentMediaTime()
            startTimer()
        }
    }

    /// 引擎应恢复运行时调用（回前台 / 音频会话配置变化）：
    /// AVAudioEngine 可能被系统停止（后台优化/配置变更），引擎不再输出 → 无声。
    /// 这里检测到未运行就重启并重新挂载，从推算位置续播（进度不丢）。
    func restartIfNeeded() {
        guard isPlaying else { return }
        guard !engine.isRunning else { return }
        do {
            let resume = currentFrame()   // 引擎停止期间进度时钟仍在走，以推算位置续播
            try engine.start()
            schedule(from: resume)
            playerNode.play()
            playStartFrame = resume
            playStartTime = CACurrentMediaTime()
            startTimer()
            print("[AudioEngine] restarted at \(resume) frames")
        } catch {
            print("[AudioEngine] restart failed: \(error)")
        }
    }

    /// 调度世代号：每次 schedule/stop 递增，完成回调据此识别「正常播完」与「被 stop 打断」。
    /// AVAudioPlayerNode.stop() 会触发尚未播完 segment 的 completionHandler，
    /// 若不区分，拖动条 seek / 切歌时旧回调会误判为播放完成 → 误切下一首。
    private var scheduleGen = 0

    private func schedule(from frame: AVAudioFramePosition) {
        guard let file = audioFile, let format = fileFormat else { return }
        playerNode.stop()
        scheduleGen += 1
        let gen = scheduleGen
        let framesToPlay = totalFrames - frame
        guard framesToPlay > 0 else { return }
        playerNode.scheduleSegment(
            file,
            startingFrame: frame,
            frameCount: AVAudioFrameCount(framesToPlay),
            at: nil
        ) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.scheduleGen == gen, self.isPlaying else { return }
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
        isPrepared = false
        playerNode.stop()
        scheduleGen += 1   // 失效所有未播完 segment 的完成回调
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

    /// 进度 Timer：必须调度在主线程 RunLoop 上。
    /// load() 的下载完成回调在后台线程，若直接 Timer.scheduledTimer 会把 timer 挂到后台线程
    /// （其 RunLoop 不运行）——timer 永不触发 → onProgress 从不回调 → 进度/歌词/拖动条全卡死。
    /// 统一回主线程创建，回调即主线程，写 @Published 也安全。
    private func startTimer() {
        stopTimer()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 期间可能已 stop 再 start（异步竞态）：以最新状态为准
            guard self.isPlaying else { return }
            guard self.progressTimer == nil else { return }
            self.progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                // 播放完成兜底：scheduleSegment 的 completionHandler 在部分 iOS 版本/
                // 部分文件格式下播放到末尾不触发（AVAudioPlayerNode 已知问题），
                // 若完全依赖它，「播完自动切下一首」会失效。
                // 用进度时钟判定播到末尾（容差 1024 帧 ≈ 23ms），触发完成回调。
                // 幂等：先置 isPlaying=false 再回调，无论 completionHandler 是否已触发，
                // 另一路径的 guard isPlaying 都会拦住，保证只切一次歌。
                if self.isPlaying, self.totalFrames > 0,
                   self.currentFrame() >= self.totalFrames - 1024 {
                    print("[AudioEngine] playback completed (timer fallback)")
                    self.isPlaying = false
                    self.pausedFrame = self.totalFrames
                    self.stopTimer()
                    self.onCompletion?()
                    return
                }
                // 长时间播放兜底：AVAudioEngine 可能被系统异常停止且未触发配置变化通知
                // （长时间运行/后台优化/音频栈异常），每 ~1s 检查一次，未运行时自动重启续播，
                // 防止长时间播放后引擎静默停止导致无声。
                self.restoreCheckCounter += 1
                if self.restoreCheckCounter >= 10 {
                    self.restoreCheckCounter = 0
                    if self.isPlaying, self.totalFrames > 0, !self.engine.isRunning {
                        self.restartIfNeeded()
                    }
                }
                self.onProgress?(self.currentSeconds(), self.durationSeconds())
            }
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
        } else {
            // 暂停态：也必须重新挂载目标段，否则 play() 时仍播上一次调度的位置（从旧位置起播）
            schedule(from: clamped)
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
            distortion.loadFactoryPreset(.multiDecimated1)   // 采样降级：Lo-Fi 磁带质感
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
