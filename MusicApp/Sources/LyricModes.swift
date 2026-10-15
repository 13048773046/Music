import SwiftUI
import AVFoundation

// ============================================================
// 全屏歌词 8 种展示模式 —— 1:1 对标 Folia (chthollyphile/folia-major)
// 每个模式视觉语言对应 Folia visualizer 同名实现：
//   tilt 浮名  -> VisualizerTilt（大字排版+随机斜体行+字符交错+逐字脉冲）
//   diorama 镜台 -> VisualizerDiorama（3D 走廊+相机飞行正对）
//   partita 云阶 -> VisualizerPartita（分栏 chunk 布局）
//   lumiere 流光 -> VisualizerLumiere（光线逐字点亮）
//   pendolo 时计 -> VisualizerPendolo（钟表扫光+旋转行）
//   cadenza 倾诉 -> VisualizerCadenza（光束聚焦+片段落点）
//   monet 心象  -> VisualizerMonet（海报歌词栏滚动）
//   cappella 群唱 -> VisualizerCappella（气泡对话）
// 切换后 UserDefaults 持久化，下次打开保持。
// ============================================================

// MARK: - 模式枚举

enum LyricDisplayMode: String, CaseIterable, Identifiable {
    case tilt = "浮名"
    case diorama = "镜台"
    case partita = "云阶"
    case lumiere = "流光"
    case pendolo = "时计"
    case cadenza = "倾诉"
    case monet = "心象"
    case cappella = "群唱"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .tilt: return "textformat.alt"
        case .diorama: return "cube"
        case .partita: return "rectangle.split.3x1"
        case .lumiere: return "sparkles"
        case .pendolo: return "clock.fill"
        case .cadenza: return "textformat.size"
        case .monet: return "photo"
        case .cappella: return "bubble.left.and.bubble.right.fill"
        }
    }
}

enum LyricModeStore {
    private static let key = "lyric_display_mode"
    static var current: LyricDisplayMode {
        get {
            let raw = UserDefaults.standard.string(forKey: key) ?? ""
            return LyricDisplayMode(rawValue: raw) ?? .diorama
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

// MARK: - 公共驱动（各模式共用）

/// 播放跟随时间：引擎音效模式（AVPlayer 无 currentItem）直接取外部进度
func lyricDisplayTime(_ progress: Double) -> Double {
    let pm = PlayerManager.shared
    if pm.usingEngine { return progress }
    let now = CMTimeGetSeconds(pm.player.currentTime())
    let safe = now.isFinite ? now : 0
    return abs(progress - safe) < 0.6 ? safe : progress
}

/// 二分定位当前歌词行（-1 = 未到第一行）
func lyricCurrentIndex(_ display: Double, lines: [KRCLine]) -> Int {
    guard !lines.isEmpty else { return -1 }
    var lo = 0, hi = lines.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if lines[mid].start <= display { lo = mid + 1 } else { hi = mid }
    }
    return lo - 1
}

/// 逐字时间戳：词内按非空白字符均分（Folia buildCharTimings 的 fallback 同款）
struct LyricCharTiming { let index: Int; let start: Double; let end: Double }

func lyricCharTimings(_ line: KRCLine) -> [LyricCharTiming] {
    var result: [LyricCharTiming] = []
    var ci = 0
    for word in line.words {
        let chars = Array(word.text)
        let nonSpace = chars.filter { !$0.isWhitespace }
        let count = max(nonSpace.count, 1)
        let span = max(word.end - word.start, 0.05)
        let cd = span / Double(count)
        var k = 0
        for ch in chars {
            if ch.isWhitespace { continue }
            result.append(LyricCharTiming(index: ci, start: word.start + Double(k) * cd,
                                           end: word.start + Double(k + 1) * cd))
            ci += 1; k += 1
        }
    }
    return result
}

/// 逐字脉冲强度（Folia getCharPulseIntensity）：
/// 唱到该字时 sin 脉冲隆起，唱完后余晖从 0.25 缓慢回落
func charPulseIntensity(_ now: Double, _ start: Double, _ end: Double) -> Double {
    let raw = max(end - start, 0.05)
    let dur = min(max(raw, 0.2), 0.9)
    let elapsed = now - start
    if elapsed < 0 { return 0 }
    if elapsed <= dur {
        return sin((elapsed / dur) * .pi)
    }
    let after = elapsed - dur
    let ramp = dur * 1.2
    if after >= ramp { return 0.25 }
    return 0.25 * (after / ramp)
}

/// 已唱宽度（逐词推进，含词内线性插值）——Folia reveal fraction 连续版
func lyricFillWidth(_ line: KRCLine, at now: Double, fontSize: CGFloat, weight: UIFont.Weight) -> CGFloat {
    guard now >= 0 else { return 0 }
    let font = UIFont.systemFont(ofSize: fontSize, weight: weight)
    var w: CGFloat = 0
    for word in line.words {
        let cw = (word.text as NSString).size(withAttributes: [.font: font]).width
        if now >= word.end {
            w += cw
        } else if now >= word.start {
            let span = max(word.end - word.start, 0.001)
            w += cw * min(max((now - word.start) / span, 0), 1)
            break
        } else { break }
    }
    return w
}

/// 文本估算宽度（中文字符宽≈字号，安全系数 1.05；用于溢出自适应缩放）
func lyricEstWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
    let chars = text.filter { !$0.isWhitespace }.count
    return CGFloat(chars) * fontSize * 1.05
}

/// 防溢出：内容超宽时按可用宽度等比缩放（任何模式都不会跑出屏幕外）
struct FitWidth: ViewModifier {
    let estWidth: CGFloat
    func body(content: Content) -> some View {
        GeometryReader { g in
            content
                .scaleEffect(min(1, g.size.width / max(estWidth, 1)), anchor: .center)
                .frame(width: g.size.width, height: g.size.height, alignment: .center)
        }
    }
}

/// 防溢出（双向）：内容超高/超宽时按可用尺寸等比缩放，保证完整显示在容器内
struct FitFrame: ViewModifier {
    let estWidth: CGFloat
    let estHeight: CGFloat
    func body(content: Content) -> some View {
        GeometryReader { g in
            content
                .scaleEffect(min(1,
                                 g.size.width / max(estWidth, 1),
                                 g.size.height / max(estHeight, 1)),
                             anchor: .center)
                .frame(width: g.size.width, height: g.size.height, alignment: .center)
        }
    }
}

// ============================================================
// 浮名 Tilt：大字排版 + 随机斜体行 + 字符上下交错 + 逐字脉冲
// ============================================================

struct TiltLyricView: View {
    let lines: [KRCLine]
    let progress: Double
    var fontSize: CGFloat = 34

    // 切句淡入时长
    private static let enterDuration: Double = 0.55
    private final class Tracker { var lastC: Int = -2 }
    @State private var tracker = Tracker()

    /// 最长歌词行字符数（用于溢出自适应缩放估算）
    private var maxChars: Int {
        (lines.map { $0.text.filter { !$0.isWhitespace }.count }.max() ?? 1)
    }

    var body: some View {
        TimelineView(.animation) { _ in
            let display = lyricDisplayTime(progress)
            let c = lyricCurrentIndex(display, lines: lines)
            let _ = tick(c)

            VStack(spacing: fontSize * 0.5) {
                // 前一句：小字余晖，上浮淡出
                if c - 1 >= 0 {
                    TiltSegmentRow(line: lines[c - 1], display: display,
                                   fontSize: fontSize * 0.34, weight: .regular,
                                   isTilt: false, isPassed: true)
                        .opacity(0.45)
                        .offset(y: -fontSize * 0.3)
                }
                // 当前句：大字排版（斜体行/交错/逐字脉冲）
                if c >= 0 && c < lines.count {
                    TiltActiveLine(line: lines[c], display: display, fontSize: fontSize)
                }
                // 下一句：小字预备，淡入
                if c + 1 < lines.count {
                    TiltSegmentRow(line: lines[c + 1], display: -1,
                                   fontSize: fontSize * 0.34, weight: .regular,
                                   isTilt: false, isPassed: false)
                        .opacity(0.30)
                        .offset(y: fontSize * 0.3)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 双向防溢出：拆行排版超高/超宽时整体等比缩放，完整显示
            .modifier(FitFrame(estWidth: 14 * fontSize * 1.05,
                               estHeight: fontSize * 8.9))
        }
    }

    /// 切句标记（TimelineView 闭包是 ViewBuilder，赋值 if 须收敛到方法）
    private func tick(_ c: Int) -> Bool {
        if c != tracker.lastC { tracker.lastC = c; return true }
        return false
    }
}

/// 当前句大字排版：概率拆 1-4 行，随机一行斜体（字符上下交错），逐字脉冲 + 顺序淡入
private struct TiltActiveLine: View {
    let line: KRCLine
    let display: Double
    var fontSize: CGFloat

    // Folia determineLineCount：字符数对数概率拆行
    private func splitLines(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return [] }
        let n = trimmed.count
        if n <= 14 { return [trimmed] }
        if n <= 28 { return splitByPunctuation(trimmed, into: 2) }
        if n <= 42 { return splitByPunctuation(trimmed, into: 3) }
        return splitByPunctuation(trimmed, into: 4)
    }

    private func splitByPunctuation(_ text: String, into k: Int) -> [String] {
        // 优先在标点/空格处切，尽量均匀
        let chars = Array(text)
        var cut: [Int] = []
        let target = Double(text.count) / Double(k)
        var acc = 0.0
        var idx = 0
        while idx < chars.count && cut.count < k - 1 {
            acc += 1
            if acc >= target, "，。、？！；：,.?!;: ".contains(chars[idx]) {
                cut.append(idx + 1)
                acc = 0
            }
            idx += 1
        }
        guard !cut.isEmpty else {
            // 无标点：按近似长度均切
            let step = max(1, text.count / k)
            return stride(from: 0, to: text.count, by: step).map {
                String(text[text.index(text.startIndex, offsetBy: $0)..<text.index(text.startIndex, offsetBy: min($0 + step, text.count))])
            }
        }
        var segs: [String] = []
        var start = text.startIndex
        for c in cut {
            let end = text.index(text.startIndex, offsetBy: min(c, text.count))
            segs.append(String(text[start..<end]))
            start = end
        }
        segs.append(String(text[start...]))
        return segs
    }

    // Folia seededRandom：同 seed 同结果（切歌不跳变）
    private func seeded(_ seed: Double, _ offset: Double = 0) -> Double {
        let x = sin(seed * 1000 + offset) * 10000
        return x - floor(x)
    }

    var body: some View {
        // 斜体行选择：用行起始时间做种子（Folia tiltStyleProbability ~45%）
        let segments = splitLines(line.text)
        let tiltProbability = 0.45
        let hasTilt = seeded(line.start) < tiltProbability
        let safeCount = max(segments.count, 1)
        let tiltIndex = hasTilt ? Int(seeded(line.start, 200) * Double(safeCount)) % safeCount : -1
        let lineDuration = max(line.end - line.start, 2.0)

        if segments.isEmpty {
            // 空文本/纯省略号：仅显示一个占位符
            Text("♪")
                .font(.system(size: fontSize * 0.8, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
        } else {
            VStack(spacing: fontSize * 0.42) {
                ForEach(Array(segments.enumerated()), id: \.offset) { si, segText in
                    TiltGlyphLine(text: segText, display: display,
                                  fontSize: fontSize, isTilt: si == tiltIndex,
                                  lineStart: line.start, lineDuration: lineDuration)
                }
            }
        }
    }
}

/// 单行字符渲染：Canvas 逐字绘制（脉冲缩放 / 斜体行上下交错 / 顺序淡入）
private struct TiltGlyphLine: View {
    let text: String
    let display: Double
    let fontSize: CGFloat
    let isTilt: Bool
    let lineStart: Double
    let lineDuration: Double

    var body: some View {
        let chars = Array(text)
        let nonSpaceCount = max(chars.filter { !$0.isWhitespace }.count, 1)
        let charDuration = lineDuration / Double(nonSpaceCount)
        let widths = chars.map { ch in
            (String(ch) as NSString).size(withAttributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: isTilt ? .light : .regular)
            ]).width
        }
        let totalWidth = widths.reduce(0, +)
        let letterSpacing = isTilt ? fontSize * 0.15 : fontSize * 0.08
        let yOffset = fontSize / 6

        Canvas { ctx, size in
            var x: CGFloat = 0
            var visualIdx = 0
            for (ti, ch) in chars.enumerated() {
                if ch.isWhitespace { x += fontSize * 0.25; continue }
                let w = widths[ti]
                let ci = visualIdx
                visualIdx += 1

                // 逐字脉冲（Folia getCharPulseIntensity）：唱到该字 sin 隆起，之后余晖
                let start = lineStart + Double(ci) * charDuration
                let end = start + charDuration
                let intensity: Double
                if display < lineStart {
                    intensity = 0
                } else {
                    intensity = charPulseIntensity(display, start, end)
                }
                let scale = 1 + intensity * (isTilt ? 0.18 : 0.15)
                // 顺序淡入：行可见后每字延迟 0.04s（Folia delay ci*0.04/0.05）
                let appearDelay = Double(ci) * 0.04
                let appear: Double = display < lineStart
                    ? 0
                    : min(max((display - lineStart - appearDelay) / 0.5, 0), 1)
                // 斜体行字符上下交错（Folia yStagger ±1 * yOffset）
                let staggerY = isTilt ? (ci % 2 == 0 ? -1 : 1) * yOffset : 0

                let h = fontSize
                let xPos = x + w / 2
                let yPos = size.height / 2 + staggerY
                var text = Text(verbatim: String(ch))
                    .font(.system(size: fontSize, weight: isTilt ? .light : .regular))
                if isTilt { text = text.italic() }
                text = text.foregroundColor(.white.opacity(0.9 * appear))

                ctx.draw(text, in: CGRect(x: xPos - w * scale / 2, y: yPos - h * scale / 2,
                                          width: w * scale, height: h * scale))
                x += w + letterSpacing
            }
        }
        .frame(width: totalWidth + letterSpacing * CGFloat(max(nonSpaceCount - 1, 0)),
               height: fontSize * 1.4)
        // 防溢出：超过可用宽度自动等比缩小
        .modifier(FitWidth(estWidth: totalWidth + letterSpacing * CGFloat(max(nonSpaceCount - 1, 0))))
    }
}

/// 前后句小字行（Tilt 的 subtitle 层）
private struct TiltSegmentRow: View {
    let line: KRCLine
    let display: Double
    let fontSize: CGFloat
    let weight: Font.Weight
    let isTilt: Bool
    let isPassed: Bool

    var body: some View {
        Text(line.text)
            .font(.system(size: fontSize, weight: weight))
            .foregroundColor(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }
}

// ============================================================
// 镜台 Diorama：Folia 1:1 移植 —— 3D 走廊 + 随机摆位 + 电影运镜 + 相机回正
// 源码依据：folia-ref/src/components/visualizer/diorama/（Folia 开源真实实现）
//  · cameraPath.ts：buildDioramaPath 乌龟步进走廊（双频正弦 yaw/pitch）、
//    getDioramaTextPlacement 确定性随机摆位、getDioramaShot 13 种运镜加权选取+相邻去重、
//    resolveShotOffset 各运镜偏移曲线（1:1）、resolveCameraDrift 手持有呼吸感、
//    resolveReadHeadTruck 逐词横向跟摄、resolveHoldSettle 句末构图释放
//  · CameraRig.tsx：smoothDamp 临界阻尼平滑追踪 read-head；reading-alignment 回正——
//    行开始前 0.6s 起 ramp、开始后 0.35s 完全"回正"到文字平面，每运镜有回正上限
//  · dioramaSceneConstants.ts：挂载窗口 LINES_BEHIND=2/LINES_AHEAD=3、邻行透明度曲线、
//    FOG_NEAR=12/FOG_FAR=30 雾带、LINE_FONT_SIZE=0.62 世界字号、长行 fit 按 hero 固定
// ============================================================

// MARK: - 镜台 3D 数学工具（Folia 1:1）

private struct DVec3 {
    var x: Double
    var y: Double
    var z: Double
    static let zero = DVec3(x: 0, y: 0, z: 0)
}

private func dvAdd(_ a: DVec3, _ b: DVec3) -> DVec3 { DVec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
private func dvSub(_ a: DVec3, _ b: DVec3) -> DVec3 { DVec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
private func dvScale(_ a: DVec3, _ s: Double) -> DVec3 { DVec3(x: a.x * s, y: a.y * s, z: a.z * s) }
private func dvCross(_ a: DVec3, _ b: DVec3) -> DVec3 {
    DVec3(x: a.y * b.z - a.z * b.y,
          y: a.z * b.x - a.x * b.z,
          z: a.x * b.y - a.y * b.x)
}
private func dvNorm(_ a: DVec3) -> DVec3 {
    let l = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
    if l < 1e-9 { return .zero }
    return dvScale(a, 1 / l)
}
private func dvLen(_ a: DVec3) -> Double { (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot() }

private func dFract(_ x: Double) -> Double { x - floor(x) }
/// Folia seededUnit 1:1：同 seed 同结果（切歌不跳变）
private func dSeeded(_ seed: Double) -> Double { dFract(sin(seed * 12.9898) * 43758.5453) }
/// Folia hashSeed 1:1（31 哈希 mod 100000）
private func dHash(_ seed: String) -> Double {
    if seed.isEmpty { return 1 }
    var h = 0
    for u in seed.unicodeScalars { h = (h * 31 + Int(u.value)) % 100000 }
    return Double(h == 0 ? 1 : h)
}
private func dClamp01(_ v: Double) -> Double { min(max(v, 0), 1) }
private func dClamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
private func dSmoothstep01(_ t: Double) -> Double { let c = dClamp01(t); return c * c * (3 - 2 * c) }
private func dEaseInOut(_ p: Double) -> Double { dSmoothstep01(p) }
/// Folia smoothDamp 1:1（Unity 式临界阻尼，带回弹速度，起停都平滑）
private func dSmoothDamp(_ current: Double, _ target: Double, _ velocity: Double,
                         _ smoothTime: Double, _ dt: Double) -> (value: Double, velocity: Double) {
    let t = max(smoothTime, 0.0001)
    let omega = 2 / t
    let x = omega * dt
    let exp = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
    let change = current - target
    let temp = (velocity + omega * change) * dt
    let newVel = (velocity - omega * temp) * exp
    let value = target + (change + temp) * exp
    return (value, newVel)
}

/// 走廊局部坐标系（行锚点 + 正交基）
private struct DioramaFrame {
    var position: DVec3
    var forward: DVec3
    var right: DVec3
    var up: DVec3
}

/// 单行文字摆位（Folia getDioramaTextPlacement）
private struct DioramaPlacement {
    var offsetR: Double
    var offsetU: Double
    var scale: Double
    var roll: Double
    var yaw: Double
    var lookR: Double
}

/// 13 种电影运镜（Folia DioramaShotKind）
private enum DioramaShotKind: String, CaseIterable {
    case pushIn, pullBack, orbit, track, crane, hold, swell, spiral, pendulum, flyby, arc, float, glide
}

/// 镜头偏移（行局部系：right/up/back）
private struct DioramaShotOffset {
    var right: Double
    var up: Double
    var back: Double
}

private struct DioramaDrift {
    var swayX: Double
    var swayY: Double
    var lift: Double
    var dist: Double
}

/// 相机平滑状态（引用类型，TimelineView 每帧更新不触发额外重绘）
private final class DioramaCamState {
    var pos = DVec3.zero
    var vel = DVec3.zero
    var look = DVec3.zero
    var lookVel = DVec3.zero
    var yaw = 0.0
    var pitch = 0.0
    var roll = 0.0
    var initDone = false
}

private struct DioramaView {
    // MARK: 常量（Folia dioramaSceneConstants / cameraPath 1:1）
    static let STEP = 8.0               // 行距（世界单位）
    static let HERO = 5.2               // 相机主距离
    static let LIFT = 0.5               // 相机抬升
    static let MAX_YAW = 0.5            // 路径最大偏航（rad）
    static let MAX_PITCH = 0.32         // 路径最大俯仰（rad）
    static let TEXT_OFFSET_R = 1.8      // 摆位横向幅度
    static let TEXT_OFFSET_U = 1.2      // 摆位纵向幅度
    static let TEXT_ROLL = 0.2          // 摆位滚转（rad）
    static let TEXT_YAW = 0.16          // 摆位偏航（rad）
    static let TEXT_LOOK = 1.1          // 三分法取景偏移
    static let SWAY_AMP = 0.4           // 手持有呼吸：横摆
    static let LIFT_AMP = 0.4           // 手持有呼吸：升降
    static let DIST_AMP = 0.5           // 手持有呼吸：远近
    static let SMOOTH_TIME = 0.42       // normal 相机平滑时间
    static let MOVE_SCALE = 1.0         // normal 运镜幅度
    static let DRIFT_SCALE = 0.62       // normal 呼吸幅度
    static let WEAVE = 1.0              // normal 摆位幅度
    static let FOG_NEAR = 12.0          // 雾带近
    static let FOG_FAR = 30.0           // 雾带远
    static let LINE_FONT_SIZE = 0.62    // 世界字号（em→世界单位）
    static let TARGET_FRAME_WIDTH_FRACTION = 0.72
    static let MIN_FIT_SCALE = 0.28
    static let SAFE_FRAME_FRACTION = 0.92
    static let PX = 30.0                // 世界单位 → 屏幕点
    static let FOV = 55.0               // 垂直 FOV（度）
    static let ASPECT = 1.75            // 横屏视口宽高比
    // 回正（CameraRig ALIGN_*）
    static let ALIGN_LEAD_IN = 0.6
    static let ALIGN_SETTLE = 0.35
    static let ALIGN_RELEASE = 1.0
    static let ALIGN_RATE = 1.2

    /// buildDioramaPath 1:1：乌龟步进走廊，heading 双频正弦 yaw/pitch
    static func buildFrames(count: Int, seed: Double) -> [DioramaFrame] {
        let n = max(count, 1)
        let base = seed
        var positions: [DVec3] = []
        var pos = DVec3.zero
        for i in 0...n {
            positions.append(pos)
            let yaw = MAX_YAW * (sin(Double(i) * 0.23 + base * 0.017) * 0.62
                                 + sin(Double(i) * 0.11 + base * 0.041 + 1.3) * 0.38)
            let pitch = MAX_PITCH * sin(Double(i) * 0.17 + base * 0.029 + 0.7)
            let cp = cos(pitch)
            let dir = DVec3(x: sin(yaw) * cp, y: sin(pitch), z: -cos(yaw) * cp)
            pos = DVec3(x: pos.x + dir.x * STEP, y: pos.y + dir.y * STEP, z: pos.z + dir.z * STEP)
        }
        var frames: [DioramaFrame] = []
        let upWorld = DVec3(x: 0, y: 1, z: 0)
        for i in 0..<n {
            let fwd = dvNorm(dvSub(positions[i + 1], positions[i]))
            let right = dvNorm(dvCross(fwd, upWorld))
            let up = dvNorm(dvCross(right, fwd))
            frames.append(DioramaFrame(position: positions[i], forward: fwd, right: right, up: up))
        }
        return frames
    }

    /// getDioramaTextPlacement 1:1
    static func placement(_ i: Int, _ seed: Double, weave: Double) -> DioramaPlacement {
        let idx = max(i, 0)
        let jitterR = (dSeeded(seed + Double(idx * 11 + 2)) - 0.5) * 0.6
        let jitterU = (dSeeded(seed + Double(idx * 11 + 4)) - 0.5) * 0.6
        let wanderR = sin(Double(idx) * 0.47 + seed * 0.019) * 0.7 + jitterR
        let wanderU = sin(Double(idx) * 0.29 + seed * 0.027 + 0.9) * 0.7 + jitterU
        return DioramaPlacement(
            offsetR: wanderR * TEXT_OFFSET_R * weave,
            offsetU: wanderU * TEXT_OFFSET_U * weave,
            scale: 0.82 + dSeeded(seed + Double(idx * 11 + 5)) * 0.46,
            roll: (dSeeded(seed + Double(idx * 11 + 6)) - 0.5) * 2 * TEXT_ROLL * weave,
            yaw: (dSeeded(seed + Double(idx * 11 + 7)) - 0.5) * 2 * TEXT_YAW * weave,
            lookR: (dSeeded(seed + Double(idx * 11 + 8)) - 0.5) * 2 * TEXT_LOOK * weave)
    }

    /// 行在走廊中的世界锚点（路径 + 摆位偏移）
    static func worldAnchor(_ i: Int, frames: [DioramaFrame], seed: Double) -> DVec3 {
        let f = frames[max(0, min(i, frames.count - 1))]
        let pl = placement(i, seed, weave: WEAVE)
        return DVec3(x: f.position.x + f.right.x * pl.offsetR + f.up.x * pl.offsetU,
                     y: f.position.y + f.right.y * pl.offsetR + f.up.y * pl.offsetU,
                     z: f.position.z + f.right.z * pl.offsetR + f.up.z * pl.offsetU)
    }

    /// 行长（世界单位）
    static func lineWidth(_ line: KRCLine) -> Double {
        let chars = Double(line.text.filter { !$0.isWhitespace }.count)
        return max(chars * LINE_FONT_SIZE, 0.5)
    }

    /// 长行 fit（按 hero 距离固定，真实 dolly 缩放）——Folia fit scale
    static func fitScale(_ line: KRCLine) -> Double {
        let halfW = HERO * tan(FOV * Double.pi / 180 / 2) * ASPECT
        return dClamp(TARGET_FRAME_WIDTH_FRACTION * halfW / lineWidth(line), MIN_FIT_SCALE, 1)
    }

    /// 可见半宽（hero 距离 × 安全帧比例）
    static func visibleHalfWidth() -> Double {
        HERO * tan(FOV * Double.pi / 180 / 2) * ASPECT * SAFE_FRAME_FRACTION
    }

    /// resolveReadHeadTruck 1:1（tanh 饱和横向跟摄）
    static func readHeadTruck(_ wordProgress: Double, _ trackWidth: Double, _ visibleHalfWidth: Double) -> Double {
        if trackWidth <= 0 { return 0 }
        let wordOffset = (dClamp01(wordProgress) - 0.5) * trackWidth
        let allowed = max(abs(visibleHalfWidth - trackWidth / 2), 0.001)
        let th = (exp(2 * wordOffset / allowed) - 1) / (exp(2 * wordOffset / allowed) + 1)
        return allowed * th
    }

    /// 行内演唱进度（词 reveal 比例）
    static func wordProgress(_ line: KRCLine, _ now: Double) -> Double {
        let words = line.words
        if words.isEmpty { return now >= line.start ? 1 : 0 }
        for (k, w) in words.enumerated() {
            if now >= w.end {
                if k == words.count - 1 { return 1 }
            } else if now >= w.start {
                let span = max(w.end - w.start, 0.001)
                return (Double(k) + dClamp01((now - w.start) / span)) / Double(words.count)
            } else {
                return Double(k) / Double(words.count)
            }
        }
        return 1
    }

    // MARK: 13 种运镜（Folia getDioramaShot + resolveShotOffset 1:1）

    /// 行音符特征（长音/短促，用于运镜倾向）
    private static func noteProfile(_ line: KRCLine?) -> (maxNote: Double, avgNote: Double, count: Int) {
        guard let line else { return (0, 0, 0) }
        var maxNote = 0.0, sum = 0.0, count = 0
        for w in line.words {
            let d = w.end - w.start
            if d > 0 { maxNote = max(maxNote, d); sum += d; count += 1 }
        }
        return (maxNote, count > 0 ? sum / Double(count) : 0, count)
    }

    /// computeShotWeights 1:1（normal 模式）
    private static func shotWeights(_ i: Int, _ lines: [KRCLine]) -> [DioramaShotKind: Double] {
        var w: [DioramaShotKind: Double] = [.pushIn: 1, .pullBack: 1, .orbit: 1, .track: 1, .crane: 1,
                                            .hold: 1, .swell: 0.85, .spiral: 0.9, .pendulum: 1,
                                            .flyby: 0.9, .arc: 1, .float: 0.9, .glide: 1]
        let line = lines.indices.contains(i) ? lines[i] : nil
        let prev = i > 0 && lines.indices.contains(i - 1) ? lines[i - 1] : nil
        let wordCount = line?.words.count ?? 0
        // 副歌近似：长句多词（KRCLine 无 isChorus 字段，用词数代理）
        let isChorus = wordCount >= 10
        let sectionStart = prev != nil && line != nil && (line!.start - prev!.end) > 0.6
        let np = noteProfile(line)
        let hasLongNote = np.maxNote >= 1.3
        let staccato = np.count >= 4 && np.avgNote > 0 && np.avgNote <= 0.34

        if isChorus {
            w[.orbit]! += 2.4; w[.pushIn]! += 1.8; w[.spiral]! += 1.2; w[.crane]! += 0.8
            w[.flyby]! += 0.6; w[.arc]! += 1.0; w[.glide]! += 0.6
            w[.hold]! -= 0.6; w[.track]! -= 0.2
        } else {
            w[.track]! += 1.1; w[.crane]! += 0.9; w[.hold]! += 0.9; w[.pendulum]! += 0.8
            w[.float]! += 0.8; w[.glide]! += 0.6; w[.arc]! += 0.4
        }
        if wordCount >= 8 {
            w[.track]! += 1.6; w[.pullBack]! += 1; w[.orbit]! -= 0.4; w[.pushIn]! -= 0.3
        } else if wordCount <= 3 {
            w[.pushIn]! += 1.4; w[.orbit]! += 0.9; w[.hold]! += 0.5; w[.track]! -= 0.8
        }
        if sectionStart { w[.pullBack]! += 2.2; w[.crane]! += 1.4; w[.glide]! += 1.0; w[.pushIn]! -= 0.4 }
        if hasLongNote { w[.swell]! += 2.4; w[.spiral]! += 1.0; w[.float]! += 1.2; w[.pendulum]! += 0.6; w[.orbit]! += 0.8; w[.arc]! += 0.6; w[.hold]! += 0.3; w[.track]! -= 0.5 }
        if staccato { w[.track]! += 1.4; w[.flyby]! += 1.5; w[.pushIn]! += 0.8; w[.swell]! -= 1.6; w[.hold]! -= 0.8; w[.crane]! -= 0.4 }
        for k in DioramaShotKind.allCases { w[k] = max(w[k] ?? 0, 0.05) }
        return w
    }

    private static func pickShot(_ w: [DioramaShotKind: Double], _ u: Double) -> DioramaShotKind {
        let total = DioramaShotKind.allCases.reduce(0.0) { $0 + (w[$1] ?? 0) }
        var acc = dClamp01(u) * total
        for k in DioramaShotKind.allCases {
            acc -= w[k] ?? 0
            if acc <= 0 { return k }
        }
        return .hold
    }

    /// getDioramaShot 1:1（加权选取 + 与前两行去重）
    static func getShot(_ i: Int, _ lines: [KRCLine], _ seed: Double) -> DioramaShotKind {
        guard lines.indices.contains(i) else { return .hold }
        let pick = pickShot(shotWeights(i, lines), dSeeded(seed + Double(i * 101 + 7)))
        let prev1 = i > 0 ? pickShot(shotWeights(i - 1, lines), dSeeded(seed + Double((i - 1) * 101 + 7))) : nil
        let prev2 = i > 1 ? pickShot(shotWeights(i - 2, lines), dSeeded(seed + Double((i - 2) * 101 + 7))) : nil
        if pick == prev1 || pick == prev2 {
            var pool = DioramaShotKind.allCases.filter { $0 != pick && $0 != prev1 && $0 != prev2 }
            if pool.isEmpty { pool = DioramaShotKind.allCases.filter { $0 != pick } }
            let alt = dSeeded(seed + Double(i * 53 + 19))
            return pool[Int(dClamp01(alt) * Double(pool.count)) % pool.count]
        }
        return pick
    }

    /// resolveShotOffset 1:1：13 种运镜的相机偏移曲线（行局部系 right/up/back）
    static func shotOffset(_ kind: DioramaShotKind, progress: Double, wordProgress: Double,
                           hero: Double, lift: Double, seed: Double, lineIndex: Int, moveScale: Double) -> DioramaShotOffset {
        let e = dEaseInOut(progress)
        let dir = dSeeded(seed + Double(lineIndex * 7 + 3)) < 0.5 ? -1.0 : 1.0
        var right = 0.0
        var up = lift
        var back = hero
        switch kind {
        case .pushIn:
            back = hero * (1.5 - 0.8 * e); up = lift * (1.2 - 0.5 * e) + 0.15
        case .pullBack:
            back = hero * (0.85 + 1.15 * e); up = lift + 1.7 * e
        case .orbit:
            let theta = dir * 0.55 * (2 * e - 1)
            right = hero * sin(theta); back = hero * cos(theta); up = lift + 0.4
        case .track:
            right = dir * hero * 0.34 * sin(Double.pi * dClamp01(wordProgress))
            back = hero * 1.06; up = lift + 0.12
        case .crane:
            let from = dir > 0 ? -1.5 : 2.4
            let to = dir > 0 ? 2.4 : -1.4
            up = from + (to - from) * e; back = hero * 1.05
        case .swell:
            let theta = dir * 0.4 * e
            right = hero * sin(theta) * 1.1; back = hero * (1.0 + 0.35 * e); up = lift + 1.2 * e + 0.3
        case .spiral:
            let theta = dir * 0.7 * (2 * e - 1)
            right = hero * sin(theta) * 0.85; back = hero * (1.05 - 0.1 * e); up = lift - 0.8 + 2.4 * e
        case .pendulum:
            right = dir * hero * 0.45 * (2 * e - 1)
            up = lift + 0.9 - 0.9 * sin(Double.pi * e); back = hero * 1.02
        case .flyby:
            right = dir * hero * (0.7 - 1.4 * e); back = hero * (0.78 + 0.12 * sin(Double.pi * e)); up = lift + 0.05
        case .arc:
            let theta = dir * 0.5 * sin(Double.pi * e)
            right = hero * sin(theta) * 1.3; back = hero * (1.05 + 0.12 * (1 - cos(theta))); up = lift + 0.5 * sin(Double.pi * e)
        case .float:
            right = dir * hero * 0.16 * sin(e * Double.pi * 2)
            up = lift + 0.6 + 0.5 * sin(e * Double.pi * 2 + 1.0)
            back = hero * (1.05 + 0.06 * sin(e * Double.pi))
        case .glide:
            right = dir * hero * 0.22 * e; up = lift + 1.4 * e; back = hero * (1.15 - 0.25 * e)
        case .hold:
            up = lift + 0.3 * sin(progress * Double.pi); back = hero
        }
        let m = moveScale
        return DioramaShotOffset(right: right * m,
                                 up: lift + (up - lift) * m,
                                 back: hero + (back - hero) * m)
    }

    /// resolveCameraDrift 1:1：双频正弦手持有呼吸
    static func cameraDrift(_ time: Double, _ seed: Double, _ scale: Double) -> DioramaDrift {
        let ph = seed * 0.017
        return DioramaDrift(
            swayX: (sin(time * 0.11 + ph) * 0.6 + sin(time * 0.047 + ph * 1.7) * 0.4) * SWAY_AMP * scale,
            swayY: sin(time * 0.09 + ph * 0.7) * SWAY_AMP * 0.5 * scale,
            lift: (sin(time * 0.13 + ph * 1.3) * 0.6 + sin(time * 0.061 + ph * 2.1) * 0.4) * LIFT_AMP * scale,
            dist: sin(time * 0.05 + ph * 1.1) * DIST_AMP * scale)
    }

    /// resolveHoldSettle 1:1：句完 3s 后构图缓慢释放
    static func holdSettle(_ secondsHeld: Double) -> Double {
        let t = dClamp01((secondsHeld - 3) / 5)
        return 1 - t * t * (3 - 2 * t)
    }

    /// 回正需求（CameraRig readNeed 1:1）：行开始前 ramp in，开始后 0.35s 完全回正
    static func readNeed(_ line: KRCLine, _ now: Double, ceiling: Double) -> Double {
        let rampIn = dSmoothstep01((now - (line.start - ALIGN_LEAD_IN)) / (ALIGN_LEAD_IN + ALIGN_SETTLE))
        let renderEnd = max(line.end, line.start)
        let rampOut = 1 - dSmoothstep01((now - renderEnd) / ALIGN_RELEASE)
        return min(rampIn, rampOut) * ceiling
    }

    /// 每运镜回正上限（CameraRig ALIGN_SHOT_CEILING 1:1）
    static func shotCeiling(_ kind: DioramaShotKind) -> Double {
        switch kind {
        case .hold: return 0.9
        case .pushIn, .track: return 0.85
        case .swell: return 0.8
        case .float: return 0.78
        case .glide: return 0.72
        case .crane, .pullBack: return 0.7
        case .arc: return 0.62
        case .pendulum: return 0.6
        case .orbit: return 0.55
        case .spiral, .flyby: return 0.5
        }
    }

    /// 邻行透明度（dioramaSceneConstants resolveNeighborLineOpacity 1:1）
    static func neighborOpacity(_ offset: Int) -> Double {
        switch offset {
        case -1: return 0.3
        case -2: return 0.1
        case 1: return 0.34
        case 2: return 0.16
        case 3: return 0.06
        default: return 0
        }
    }
}

/// 镜台：3D 走廊 + 相机运镜 + 回正（Folia 1:1）
struct DioramaLyricView: View {
    let lines: [KRCLine]
    let progress: Double
    var fontSize: CGFloat = 30
    var seed: String = "diorama"

    private final class Tracker { var lastC: Int = -2 }
    private final class PathCache { var frames: [DioramaFrame] = [] }
    @State private var tracker = Tracker()
    @State private var cam = DioramaCamState()
    @State private var pathCache = PathCache()

    var body: some View {
        TimelineView(.animation) { ctx in
            let display = lyricDisplayTime(progress)
            let c = lyricCurrentIndex(display, lines: lines)
            let _ = tick(c)
            let seedD = dHash(seed)
            // 走廊路径（每歌缓存一次）
            let _ = Self.ensurePath(cache: pathCache, count: lines.count, seed: seedD)
            let frames = pathCache.frames
            let idx = dClamp(Double(c), 0, Double(max(lines.count - 1, 0)))
            let now = display

            // 每帧驱动相机（Folia CameraRig 逻辑）
            let _ = Self.driveCamera(cam: cam, lines: lines, frames: frames, c: idx, now: now, seed: seedD)

            // 渲染挂载窗口 c-2..c+3
            ZStack {
                ForEach((c - 2)...(c + 3), id: \.self) { i in
                    if i >= 0 && i < lines.count {
                        Self.rowView(i: i, c: c, lines: lines, frames: frames,
                                     cam: cam, seed: seedD, now: now, fontSize: fontSize)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 双向防溢出：走廊纵深超高时整体等比缩放，完整显示
            .modifier(FitFrame(estWidth: CGFloat(maxChars) * fontSize * 1.05,
                               estHeight: fontSize * 11.2))
        }
    }

    private func tick(_ c: Int) -> Bool {
        if c != tracker.lastC { tracker.lastC = c; return true }
        return false
    }

    private var maxChars: Int {
        (lines.map { $0.text.filter { !$0.isWhitespace }.count }.max() ?? 1)
    }

    // MARK: 相机驱动（1:1 CameraRig：SmoothDamp 追踪 read-head + 镜头偏移 + 回正）

    private static func driveCamera(cam: DioramaCamState, lines: [KRCLine], frames: [DioramaFrame],
                            c: Double, now: Double, seed: Double) {
        guard !lines.isEmpty, frames.count > 0 else { return }
        let idx = Int(c)
        let line = lines[idx]
        let frame = frames[idx]
        let pl = DioramaView.placement(idx, seed, weave: DioramaView.WEAVE)
        let wp = DioramaView.wordProgress(line, now)
        let dur = max(line.end - line.start, 0.001)
        let pr = line.end > line.start ? dClamp01((now - line.start) / dur) : (now >= line.start ? 1 : 0)
        let shot = DioramaView.getShot(idx, lines, seed)
        let settle = DioramaView.holdSettle(now - line.end)
        let so = DioramaView.shotOffset(shot, progress: pr, wordProgress: wp,
                                        hero: DioramaView.HERO, lift: DioramaView.LIFT,
                                        seed: seed, lineIndex: idx, moveScale: DioramaView.MOVE_SCALE * settle)
        let dr = DioramaView.cameraDrift(now, seed, DioramaView.DRIFT_SCALE * settle)
        // read-head：文字实际位置 + 逐词横向跟摄
        let truck = DioramaView.readHeadTruck(wp, DioramaView.lineWidth(line), DioramaView.visibleHalfWidth()) * settle
        let headR = pl.offsetR + truck
        let headU = pl.offsetU
        let readHead = DVec3(
            x: frame.position.x + frame.right.x * headR + frame.up.x * headU,
            y: frame.position.y + frame.right.y * headR + frame.up.y * headU,
            z: frame.position.z + frame.right.z * headR + frame.up.z * headU)
        // 相机目标位姿（行局部系合成世界）
        let offRight = so.right + dr.swayX
        let offUp = so.up + dr.swayY + dr.lift
        let offBack = so.back + dr.dist
        let camTarget = DVec3(
            x: frame.position.x + frame.right.x * offRight + frame.up.x * offUp - frame.forward.x * offBack,
            y: frame.position.y + frame.right.y * offRight + frame.up.y * offUp - frame.forward.y * offBack,
            z: frame.position.z + frame.right.z * offRight + frame.up.z * offUp - frame.forward.z * offBack)
        let lookTarget = DVec3(
            x: readHead.x + frame.right.x * pl.lookR * settle,
            y: readHead.y + frame.right.y * pl.lookR * settle,
            z: readHead.z + frame.right.z * pl.lookR * settle)
        // 回正需求
        let readTarget = DioramaView.readNeed(line, now, ceiling: DioramaView.shotCeiling(shot))
        // 平滑推进（TimelineView 以 60fps 驱动）
        let dt = 1.0 / 60.0
        let sx = dSmoothDamp(cam.pos.x, camTarget.x, cam.vel.x, DioramaView.SMOOTH_TIME, dt)
        let sy = dSmoothDamp(cam.pos.y, camTarget.y, cam.vel.y, DioramaView.SMOOTH_TIME, dt)
        let sz = dSmoothDamp(cam.pos.z, camTarget.z, cam.vel.z, DioramaView.SMOOTH_TIME, dt)
        let lx = dSmoothDamp(cam.look.x, lookTarget.x, cam.lookVel.x, DioramaView.SMOOTH_TIME, dt)
        let ly = dSmoothDamp(cam.look.y, lookTarget.y, cam.lookVel.y, DioramaView.SMOOTH_TIME, dt)
        let lz = dSmoothDamp(cam.look.z, lookTarget.z, cam.lookVel.z, DioramaView.SMOOTH_TIME, dt)
        cam.pos = DVec3(x: sx.value, y: sy.value, z: sz.value)
        cam.vel = DVec3(x: sx.velocity, y: sy.velocity, z: sz.velocity)
        cam.look = DVec3(x: lx.value, y: ly.value, z: lz.value)
        cam.lookVel = DVec3(x: lx.velocity, y: ly.velocity, z: lz.velocity)
        if !cam.initDone {
            cam.initDone = true
            cam.pos = camTarget
            cam.look = lookTarget
        }
        // 相机朝向：lookAt read-head
        let dir = dvSub(cam.look, cam.pos)
        cam.yaw = atan2(dir.x, -dir.z)
        cam.pitch = atan2(dir.y, (dir.x * dir.x + dir.z * dir.z).squareRoot())
        // 回正：相机滚转向文字平面平滑（当前行正对）
        let alignTargetRoll = pl.roll * readTarget
        cam.roll += (alignTargetRoll - cam.roll) * (1 - exp(-DioramaView.ALIGN_RATE * dt))
    }

    private static func ensurePath(cache: PathCache, count: Int, seed: Double) {
        if cache.frames.isEmpty {
            cache.frames = DioramaView.buildFrames(count: count, seed: seed)
        }
    }

    // MARK: 行渲染（世界→相机→屏幕投影 + 雾化 + 3D 倾斜）

    @ViewBuilder
    private static func rowView(i: Int, c: Int, lines: [KRCLine], frames: [DioramaFrame],
                        cam: DioramaCamState, seed: Double, now: Double, fontSize: CGFloat) -> some View {
        // 世界坐标
        let frame = frames[i]
        let pl = DioramaView.placement(i, seed, weave: DioramaView.WEAVE)
        let wx = frame.position.x + frame.right.x * pl.offsetR + frame.up.x * pl.offsetU
        let wy = frame.position.y + frame.right.y * pl.offsetR + frame.up.y * pl.offsetU
        let wz = frame.position.z + frame.right.z * pl.offsetR + frame.up.z * pl.offsetU
        // 相机空间
        let dx = wx - cam.pos.x
        let dy = wy - cam.pos.y
        let dz = wz - cam.pos.z
        let cY = cos(cam.yaw), sY = sin(cam.yaw)
        let cP = cos(cam.pitch), sP = sin(cam.pitch)
        let x1 = dx * cY - dz * sY
        let z1 = dx * sY + dz * cY
        let y2 = dy * cP - z1 * sP
        let z2 = dy * sP + z1 * cP
        let isBehind = z2 <= 0.35
        let factor = isBehind ? 1.0 : DioramaView.PX / z2
        let sx = x1 * factor
        let sy = y2 * factor
        let sc = isBehind ? 0.001 : DioramaView.HERO / z2 * pl.scale * DioramaView.fitScale(lines[i])
        let fog = isBehind ? 0 : dClamp01((DioramaView.FOG_FAR - z2) / (DioramaView.FOG_FAR - DioramaView.FOG_NEAR))
        let baseOp = i == c ? 1.0 : DioramaView.neighborOpacity(i - c)
        let op = isBehind ? 0 : baseOp * fog
        // 3D 倾斜：当前行随回正抵消滚转（正对），邻行保持摆位滚转/偏航
        let rollDeg = i == c ? (pl.roll - cam.roll) * 57.2958 : pl.roll * 57.2958
        let yawDeg = i == c ? pl.yaw * 57.2958 * 0.4 : pl.yaw * 57.2958
        // 深度雾化模糊（远行轻微虚化）
        let blurR = isBehind ? 0 : max(0, (DioramaView.FOG_FAR - z2) / (DioramaView.FOG_FAR - DioramaView.FOG_NEAR) - 0.55) * 6
        // zIndex：近的在上
        let zI = isBehind ? -999 : -z2

        let line = lines[i]
        if i == c {
            // 当前行：逐字卡拉OK + 辉光
            LyricRowView(line: line, currentTime: now, scale: 1.0, opacity: 1.0,
                         tint: .white, fontSize: fontSize, fontWeight: .semibold)
                .shadow(color: .white.opacity(0.30), radius: 20)
                .offset(x: CGFloat(sx), y: CGFloat(sy))
                .scaleEffect(CGFloat(sc))
                .rotation3DEffect(.degrees(rollDeg), axis: (x: 0, y: 0, z: 1), perspective: 0.55)
                .rotation3DEffect(.degrees(yawDeg), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
                .opacity(op)
                .blur(radius: CGFloat(blurR))
                .zIndex(zI)
        } else {
            // 邻行：单色整行，雾化退远
            Text(line.text)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .offset(x: CGFloat(sx), y: CGFloat(sy))
                .scaleEffect(CGFloat(sc))
                .rotation3DEffect(.degrees(rollDeg), axis: (x: 0, y: 0, z: 1), perspective: 0.55)
                .rotation3DEffect(.degrees(yawDeg), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
                .opacity(op)
                .blur(radius: CGFloat(blurR))
                .zIndex(zI)
        }
    }
}
// ============================================================
// 云阶 Partita：分栏 chunk 布局
// 当前句按标点拆成块、稳定分栏；词在栏内逐字点亮，当前词放大高亮；
// 前/后句单行小字（余晖 / 预备）。
// ============================================================

struct PartitaLyricView: View {
    let lines: [KRCLine]
    let progress: Double
    var fontSize: CGFloat = 26

    private static let scrollDuration: Double = 0.26
    private final class Tracker { var maxT: Double = 0; var lastC: Int = -2 }
    @State private var tracker = Tracker()

    /// 最长歌词行字符数（用于溢出自适应缩放估算）
    private var maxChars: Int {
        (lines.map { $0.text.filter { !$0.isWhitespace }.count }.max() ?? 1)
    }

    var body: some View {
        TimelineView(.animation) { _ in
            let display = lyricDisplayTime(progress)
            let c = lyricCurrentIndex(display, lines: lines)
            let raw = c > 0 ? min(max((display - lines[c].start) / Self.scrollDuration, 0), 1) : 1
            let t = advance(raw, c)
            let eased = c > 0 ? 1 - (1 - t) * (1 - t) * (1 - t) : 0
            let base = (c > 0 && t < 1) ? c - 1 : c
            let offsetY = (c > 0 && t < 1) ? -fontSize * CGFloat(2.1 * eased) : 0

            VStack(spacing: fontSize * 1.1) {
                // 前句余晖
                if c - 1 >= 0 {
                    LyricRowView(line: lines[c - 1], currentTime: display,
                                 scale: 0.85, opacity: 0.35, tint: .white,
                                 fontSize: fontSize * 0.5, fontWeight: .regular)
                }
                // 当前句：分栏
                if c >= 0 && c < lines.count {
                    partitaChunks(lines[c], display: display)
                }
                // 后句预备
                if c + 1 < lines.count {
                    LyricRowView(line: lines[c + 1], currentTime: -1,
                                 scale: 0.85, opacity: 0.30, tint: .white,
                                 fontSize: fontSize * 0.5, fontWeight: .regular)
                }
            }
            .offset(y: offsetY)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 双向防溢出：分栏超高/超宽时整体等比缩放
            .modifier(FitFrame(estWidth: CGFloat(maxChars) * fontSize * 1.05,
                               estHeight: fontSize * 4.6))
        }
    }

    private func advance(_ raw: Double, _ c: Int) -> Double {
        if c != tracker.lastC { tracker.lastC = c; tracker.maxT = 0 }
        tracker.maxT = max(tracker.maxT, raw)
        return tracker.maxT
    }

    /// 当前句拆 1-2 块分栏；块内逐词点亮，当前词放大高亮
    @ViewBuilder
    private func partitaChunks(_ line: KRCLine, display: Double) -> some View {
        let words = line.words
        if words.count <= 1 {
            LyricRowView(line: line, currentTime: display, scale: 1.0, opacity: 1.0,
                         tint: .white, fontSize: fontSize, fontWeight: .semibold)
                .shadow(color: .white.opacity(0.3), radius: 18)
        } else {
            let mid = max(words.count / 2, 1)
            let first = Array(words[..<mid])
            let second = Array(words[mid...])
            HStack(alignment: .center, spacing: fontSize * 0.8) {
                chunkGlyphs(first, display: display, fontSize: fontSize)
                chunkGlyphs(second, display: display, fontSize: fontSize)
            }
            .shadow(color: .white.opacity(0.28), radius: 16)
        }
    }

    /// 块内逐词渲染：词按时间戳点亮，当前演唱词放大 + 高亮
    @ViewBuilder
    private func chunkGlyphs(_ words: [KRWord], display: Double, fontSize: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: fontSize * 0.14) {
            ForEach(Array(words.enumerated()), id: \.offset) { wi, word in
                let isActive = display >= word.start && display < word.end
                let isPassed = display >= word.end
                let pulse = isActive ? charPulseIntensity(display, word.start, word.end) : 0.0
                Text(word.text)
                    .font(.system(size: fontSize, weight: isActive ? .bold : .semibold))
                    .foregroundColor(.white.opacity(isPassed ? 0.95 : (isActive ? 1.0 : 0.35)))
                    .shadow(color: isActive ? .white.opacity(0.5 + 0.3 * pulse) : .clear, radius: 12)
                    .scaleEffect(isActive ? 1 + 0.08 * pulse : 1.0, anchor: .bottom)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        // 防溢出：长句自动等比缩小
        .modifier(FitWidth(estWidth: lyricEstWidth(words.map { $0.text }.joined(), fontSize: fontSize)))
    }
}

// ============================================================
// 流光 Lumiere：光线逐字点亮
// 暗场里已唱字被白光逐一点亮（带辉光），当前字最亮脉冲；整行上方一束光；
// 前句余晖、后句淡入。
// ============================================================

struct LumiereLyricView: View {
    let lines: [KRCLine]
    let progress: Double
    var fontSize: CGFloat = 28

    private static let scrollDuration: Double = 0.26
    private final class Tracker { var maxT: Double = 0; var lastC: Int = -2 }
    @State private var tracker = Tracker()

    /// 最长歌词行字符数（用于溢出自适应缩放估算）
    private var maxChars: Int {
        (lines.map { $0.text.filter { !$0.isWhitespace }.count }.max() ?? 1)
    }

    var body: some View {
        TimelineView(.animation) { ctx in
            let display = lyricDisplayTime(progress)
            let c = lyricCurrentIndex(display, lines: lines)
            let raw = c > 0 ? min(max((display - lines[c].start) / Self.scrollDuration, 0), 1) : 1
            let t = advance(raw, c)
            let eased = c > 0 ? 1 - (1 - t) * (1 - t) * (1 - t) : 0
            let base = (c > 0 && t < 1) ? c - 1 : c
            let offsetY = (c > 0 && t < 1) ? -fontSize * CGFloat(1.9 * eased) : 0
            let glowBreath = 0.5 + 0.5 * sin(ctx.date.timeIntervalSinceReferenceDate * 0.5)

            ZStack {
                // 行上方一束光（绘光感）
                LinearGradient(colors: [.white.opacity(0.10 + 0.04 * glowBreath), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: fontSize * 1.6)

                VStack(spacing: fontSize * 1.35) {
                    ForEach((base - 1)...(base + 1), id: \.self) { li in
                        if lines.indices.contains(li) {
                            lumiereRow(line: lines[li], li: li, c: c, display: display, fontSize: fontSize)
                        }
                    }
                }
                .offset(y: offsetY)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 双向防溢出：逐字长行超高/超宽时整体等比缩放
            .modifier(FitFrame(estWidth: CGFloat(maxChars) * fontSize * 1.05,
                               estHeight: fontSize * 6.1))
        }
    }

    private func advance(_ raw: Double, _ c: Int) -> Double {
        if c != tracker.lastC { tracker.lastC = c; tracker.maxT = 0 }
        tracker.maxT = max(tracker.maxT, raw)
        return tracker.maxT
    }

    /// 逐字点亮：已唱字白+辉光，当前字最亮，未唱 0.2
    @ViewBuilder
    private func lumiereRow(line: KRCLine, li: Int, c: Int, display: Double, fontSize: CGFloat) -> some View {
        let isCurrent = li == c
        let isOld = li == c - 1
        let timings = lyricCharTimings(line)
        let chars = Array(line.text)
        // 非空格序号映射（逐字时间戳按非空格序编号）
        let nonSpaceMap: [Int: Int] = {
            var m: [Int: Int] = [:]
            var k = 0
            for (ci, ch) in chars.enumerated() where !ch.isWhitespace { m[ci] = k; k += 1 }
            return m
        }()

        HStack(alignment: .firstTextBaseline, spacing: fontSize * 0.02) {
            ForEach(Array(chars.enumerated()), id: \.offset) { ci, ch in
                if ch.isWhitespace {
                    Text(" ").font(.system(size: fontSize))
                } else {
                    let timing = timings.first { $0.index == (nonSpaceMap[ci] ?? 0) }
                    let start = timing?.start ?? Double(ci) * 0.1
                    let end = timing?.end ?? start + 0.1
                    let isLit = li < c || (li == c && display >= start)
                    let isSinging = li == c && display >= start && display < end
                    let pulse = isSinging ? charPulseIntensity(display, start, end) : 0.0
                    let litOpacity = isLit ? (isSinging ? 1.0 : 0.85) : 0.20
                    Text(verbatim: String(ch))
                        .font(.system(size: fontSize, weight: isSinging ? .semibold : .medium))
                        .foregroundColor(.white.opacity(litOpacity))
                        .shadow(color: .white.opacity((isSinging ? 0.75 + 0.25 * pulse : 0.35) * (isLit ? 1 : 0)), radius: isSinging ? 14 : 6)
                        .scaleEffect(isSinging ? 1 + 0.05 * pulse : 1, anchor: .bottom)
                }
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .center)
        .opacity(isCurrent ? 1.0 : (isOld ? 0.5 : 0.35))
        .scaleEffect(isCurrent ? 1 : 0.7, anchor: .center)
        // 防溢出：长句自动等比缩小
        .modifier(FitWidth(estWidth: lyricEstWidth(line.text, fontSize: fontSize)))
    }
}

// ============================================================
// 时计 Pendolo：钟表扫光 + 旋转行
// 当前句逐字点亮 + 已唱边界纵向扫光条；整行随播放缓慢钟摆摆动；
// 底部表盘刻度弧线装饰。
// ============================================================

struct PendoloLyricView: View {
    let lines: [KRCLine]
    let progress: Double
    var fontSize: CGFloat = 28

    private final class Tracker { var maxT: Double = 0; var lastC: Int = -2 }
    @State private var tracker = Tracker()

    /// 最长歌词行字符数（用于溢出自适应缩放估算）
    private var maxChars: Int {
        (lines.map { $0.text.filter { !$0.isWhitespace }.count }.max() ?? 1)
    }

    var body: some View {
        TimelineView(.animation) { ctx in
            let display = lyricDisplayTime(progress)
            let c = lyricCurrentIndex(display, lines: lines)
            let raw = c > 0 ? min(max((display - lines[c].start) / 0.25, 0), 1) : 1
            let _ = advance(raw, c)
            let t = ctx.date.timeIntervalSinceReferenceDate
            let swing = sin(t * 0.9) * 1.6   // 钟摆摆角

            ZStack {
                // 底部表盘刻度弧线
                PendoloDial()
                    .frame(height: fontSize * 2.4)
                    .opacity(0.22)
                    .offset(y: fontSize * 1.2)

                VStack(spacing: fontSize * 1.2) {
                    if c - 1 >= 0 {
                        LyricRowView(line: lines[c - 1], currentTime: display,
                                     scale: 0.8, opacity: 0.3, tint: .white,
                                     fontSize: fontSize * 0.5, fontWeight: .regular)
                    }
                    if c >= 0 && c < lines.count {
                        pendoloActiveLine(lines[c], display: display)
                            .rotationEffect(.degrees(swing), anchor: .bottom)
                    }
                    if c + 1 < lines.count {
                        LyricRowView(line: lines[c + 1], currentTime: -1,
                                     scale: 0.8, opacity: 0.28, tint: .white,
                                     fontSize: fontSize * 0.5, fontWeight: .regular)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 双向防溢出：钟摆+表盘超高时整体等比缩放
                .modifier(FitFrame(estWidth: CGFloat(maxChars) * fontSize * 1.05,
                                   estHeight: fontSize * 8.7))
            }
        }
    }

    private func advance(_ raw: Double, _ c: Int) -> Double {
        if c != tracker.lastC { tracker.lastC = c; tracker.maxT = 0 }
        tracker.maxT = max(tracker.maxT, raw)
        return tracker.maxT
    }

    /// 当前句：逐字卡拉OK + 已唱边界扫光条
    @ViewBuilder
    private func pendoloActiveLine(_ line: KRCLine, display: Double) -> some View {
        let fill = lyricFillWidth(line, at: display, fontSize: fontSize, weight: .semibold)
        ZStack(alignment: .leading) {
            Text(line.text)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundColor(.white.opacity(0.30))
            Text(line.text)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundColor(.white)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: fill)
                }
            // 扫光条：已唱边界一道纵向亮光
            Text(line.text)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundColor(.clear)
                .overlay(alignment: .leading) {
                    LinearGradient(colors: [.clear, .white.opacity(0.9), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(width: fontSize * 0.5)
                        .offset(x: fill - fontSize * 0.25)
                }
                .mask(Text(line.text).font(.system(size: fontSize, weight: .semibold)))
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .center)
        .shadow(color: .white.opacity(0.25), radius: 16)
    }
}

/// 表盘刻度弧线（Canvas 绘制，确定性）
private struct PendoloDial: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let cx = w / 2, cy = h / 2
            let r = min(w, h) / 2 * 0.92
            // 外弧
            var arc = Path()
            arc.addArc(center: CGPoint(x: cx, y: cy), radius: r,
                       startAngle: .degrees(140), endAngle: .degrees(40), clockwise: false)
            ctx.stroke(arc, with: .color(.white.opacity(0.5)), lineWidth: 1.2)
            // 刻度
            for i in 0..<24 {
                let a = Double.pi * (0.78 + Double(i) / 24.0 * 0.44)
                let p1 = CGPoint(x: cx + CGFloat(cos(a)) * r, y: cy + CGFloat(sin(a)) * r)
                let p2 = CGPoint(x: cx + CGFloat(cos(a)) * (r - 5), y: cy + CGFloat(sin(a)) * (r - 5))
                var tick = Path()
                tick.move(to: p1)
                tick.addLine(to: p2)
                ctx.stroke(tick, with: .color(.white.opacity(0.4)), lineWidth: 1)
            }
        }
    }
}

// ============================================================
// 倾诉 Cadenza：光束聚焦 + 片段落点
// 当前句大字居中，中央一束垂直光束；当前演唱词放大 + 高亮；
// 前句漂移余晖、后句淡入预备。
// ============================================================

struct CadenzaLyricView: View {
    let lines: [KRCLine]
    let progress: Double
    var fontSize: CGFloat = 32

    private final class Tracker { var lastC: Int = -2 }
    @State private var tracker = Tracker()

    /// 最长歌词行字符数（用于溢出自适应缩放估算）
    private var maxChars: Int {
        (lines.map { $0.text.filter { !$0.isWhitespace }.count }.max() ?? 1)
    }

    var body: some View {
        TimelineView(.animation) { ctx in
            let display = lyricDisplayTime(progress)
            let c = lyricCurrentIndex(display, lines: lines)
            let _ = tick(c)
            let t = ctx.date.timeIntervalSinceReferenceDate
            let floatY = 5.0 * sin(t * 0.5)
            ZStack {
                // 中央垂直光束
                LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.05), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: fontSize * 2.6)
                    .blur(radius: 18)

                VStack(spacing: fontSize * 0.7) {
                    // 前句：上漂余晖
                    if c - 1 >= 0 {
                        LyricRowView(line: lines[c - 1], currentTime: display,
                                     scale: 0.8, opacity: 0.3, tint: .white,
                                     fontSize: fontSize * 0.5, fontWeight: .regular)
                            .offset(y: -fontSize * 0.35)
                    }
                    // 当前句：大字 + 当前词强调
                    if c >= 0 && c < lines.count {
                        cadenzaFocusLine(lines[c], display: display)
                    }
                    // 后句：预备
                    if c + 1 < lines.count {
                        LyricRowView(line: lines[c + 1], currentTime: -1,
                                     scale: 0.8, opacity: 0.25, tint: .white,
                                     fontSize: fontSize * 0.5, fontWeight: .regular)
                            .offset(y: fontSize * 0.35)
                    }
                }
                .offset(y: floatY)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 双向防溢出：光束+大字超高时整体等比缩放
            .modifier(FitFrame(estWidth: CGFloat(maxChars) * fontSize * 1.05,
                               estHeight: fontSize * 4.2 + 10))
        }
    }

    private func tick(_ c: Int) -> Bool {
        if c != tracker.lastC { tracker.lastC = c; return true }
        return false
    }

    /// 当前句逐词渲染：演唱词放大 + 白辉光，其余词正常
    @ViewBuilder
    private func cadenzaFocusLine(_ line: KRCLine, display: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: fontSize * 0.12) {
            ForEach(Array(line.words.enumerated()), id: \.offset) { wi, word in
                let isActive = display >= word.start && display < word.end
                let isPassed = display >= word.end
                let pulse = isActive ? charPulseIntensity(display, word.start, word.end) : 0.0
                Text(word.text)
                    .font(.system(size: fontSize, weight: isActive ? .bold : .semibold))
                    .foregroundColor(.white.opacity(isPassed ? 0.95 : (isActive ? 1 : 0.4)))
                    .shadow(color: isActive ? .white.opacity(0.55 + 0.35 * pulse) : .clear, radius: 20)
                    .scaleEffect(isActive ? 1 + 0.1 * pulse : 1, anchor: .bottom)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.55)
        // 防溢出：长句自动等比缩小
        .modifier(FitWidth(estWidth: lyricEstWidth(line.text, fontSize: fontSize)))
    }
}

// ============================================================
// 心象 Monet：海报歌词栏
// 背景主色光晕 + 歌词栏（rail）：前句向上滚出、当前句居中逐字扫字、后句下方预备；
// 整栏随播放呼吸。
// ============================================================

struct MonetLyricView: View {
    let lines: [KRCLine]
    let progress: Double
    var fontSize: CGFloat = 28

    private static let scrollDuration: Double = 0.3
    private final class Tracker { var maxT: Double = 0; var lastC: Int = -2 }
    @State private var tracker = Tracker()

    /// 最长歌词行字符数（用于溢出自适应缩放估算）
    private var maxChars: Int {
        (lines.map { $0.text.filter { !$0.isWhitespace }.count }.max() ?? 1)
    }

    var body: some View {
        TimelineView(.animation) { ctx in
            let display = lyricDisplayTime(progress)
            let c = lyricCurrentIndex(display, lines: lines)
            let raw = c > 0 ? min(max((display - lines[c].start) / Self.scrollDuration, 0), 1) : 1
            let t = advance(raw, c)
            let eased = c > 0 ? 1 - (1 - t) * (1 - t) * (1 - t) : 0
            let base = (c > 0 && t < 1) ? c - 1 : c
            let offsetY = (c > 0 && t < 1) ? -fontSize * CGFloat(1.55 * eased) : 0
            let glow = 0.5 + 0.5 * sin(ctx.date.timeIntervalSinceReferenceDate * 0.45)

            ZStack {
                // 海报中央光晕（呼吸）
                RadialGradient(colors: [.white.opacity(0.10 + 0.05 * glow), .clear],
                               center: .center, startRadius: 0, endRadius: 420)
                    .frame(width: 760, height: 760)

                // 歌词栏：前句 / 当前句 / 后句
                VStack(spacing: fontSize * 1.05) {
                    if c - 1 >= 0 {
                        LyricRowView(line: lines[c - 1], currentTime: display,
                                     scale: 0.82, opacity: 0.32, tint: .white,
                                     fontSize: fontSize * 0.5, fontWeight: .regular)
                            .blur(radius: 0.4)
                    }
                    if c >= 0 && c < lines.count {
                        LyricRowView(line: lines[c], currentTime: display,
                                     scale: 1.0, opacity: 1.0, tint: .white,
                                     fontSize: fontSize, fontWeight: .semibold)
                            .shadow(color: .white.opacity(0.22), radius: 14)
                    }
                    if c + 1 < lines.count {
                        LyricRowView(line: lines[c + 1], currentTime: -1,
                                     scale: 0.82, opacity: 0.26, tint: .white,
                                     fontSize: fontSize * 0.5, fontWeight: .regular)
                            .blur(radius: 0.4)
                    }
                }
                .offset(y: offsetY)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 双向防溢出：歌词栏超高/超宽时整体等比缩放
            .modifier(FitFrame(estWidth: CGFloat(maxChars) * fontSize * 1.05,
                               estHeight: fontSize * 4.2))
        }
    }

    private func advance(_ raw: Double, _ c: Int) -> Double {
        if c != tracker.lastC { tracker.lastC = c; tracker.maxT = 0 }
        tracker.maxT = max(tracker.maxT, raw)
        return tracker.maxT
    }
}

// ============================================================
// 群唱 Cappella：气泡对话
// 已唱句以聊天气泡左右交替浮现（上滑淡入），当前句气泡高亮放大并逐字点亮；
// 最多保留最近 5 个气泡。
// ============================================================

struct CappellaLyricView: View {
    let lines: [KRCLine]
    let progress: Double
    var fontSize: CGFloat = 22

    private final class Tracker { var lastC: Int = -2 }
    @State private var tracker = Tracker()

    /// 最长歌词行字符数（用于溢出自适应缩放估算）
    private var maxChars: Int {
        (lines.map { $0.text.filter { !$0.isWhitespace }.count }.max() ?? 1)
    }

    var body: some View {
        TimelineView(.animation) { _ in
            let display = lyricDisplayTime(progress)
            let c = lyricCurrentIndex(display, lines: lines)
            let _ = tick(c)

            VStack(alignment: .center, spacing: fontSize * 0.55) {
                // 最近 5 个气泡：c-4..c（已唱 + 当前）
                ForEach(max(c - 4, 0)...max(c, 0), id: \.self) { li in
                    if li <= c && lines.indices.contains(li) {
                        cappellaBubble(lines[li], li: li, c: c, display: display)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, fontSize)
            // 双向防溢出：气泡队列超高时整体等比缩放，完整显示
            .modifier(FitFrame(estWidth: CGFloat(maxChars) * fontSize * 0.78 * 1.05,
                               estHeight: fontSize * 10.9))
        }
    }

    private func tick(_ c: Int) -> Bool {
        if c != tracker.lastC { tracker.lastC = c; return true }
        return false
    }

    @ViewBuilder
    private func cappellaBubble(_ line: KRCLine, li: Int, c: Int, display: Double) -> some View {
        let isCurrent = li == c
        let isLeft = li % 2 == 0
        let age = c - li
        // 已唱句随年龄淡出（保持队列感）；新气泡由下方滑入（外层 VStack 生长 + 无动画切句）
        let bubbleOpacity = isCurrent ? 1.0 : max(0.45 - Double(age) * 0.08, 0.18)

        HStack {
            if isLeft { Spacer(minLength: 26) }
            LyricRowView(
                line: line,
                currentTime: li <= c ? display : -1,
                scale: isCurrent ? 1.0 : 0.92,
                opacity: isCurrent ? 1.0 : bubbleOpacity,
                tint: .white,
                fontSize: isCurrent ? fontSize : fontSize * 0.78,
                fontWeight: isCurrent ? .semibold : .regular
            )
            .padding(.horizontal, fontSize * 0.55)
            .padding(.vertical, fontSize * 0.32)
            .background(
                (isCurrent ? Color.white.opacity(0.13) : Color.white.opacity(0.06)),
                in: RoundedRectangle(cornerRadius: fontSize * 0.8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: fontSize * 0.8, style: .continuous)
                    .stroke(isCurrent ? Color.white.opacity(0.35) : Color.clear, lineWidth: 1)
            )
            .shadow(color: isCurrent ? .white.opacity(0.2) : .clear, radius: 12)
            .scaleEffect(isCurrent ? 1.0 : 0.96)
            if !isLeft { Spacer(minLength: 26) }
        }
    }
}

// ============================================================
// 模式选择浮层（顶栏按钮弹出，网格 2 列；页面内 overlay，不依赖 sheet——
// 避免横屏 fullScreenCover 下 sheet 在部分 iOS 16 机型弹不出的兼容问题）
// ============================================================

struct LyricModePickerOverlay: View {
    @Binding var selection: LyricDisplayMode
    @Binding var isPresented: Bool

    private let columns = [GridItem(.flexible(), spacing: 14),
                           GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ZStack {
            // 半透明遮罩：点空白处关闭
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(alignment: .leading, spacing: 18) {
                Text("歌词展示")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)

                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(LyricDisplayMode.allCases) { mode in
                        Button {
                            selection = mode
                            LyricModeStore.current = mode
                            isPresented = false
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: mode.icon)
                                    .font(.system(size: 20))
                                    .foregroundColor(selection == mode ? .white : .white.opacity(0.62))
                                Text(mode.rawValue)
                                    .font(.system(size: 13, weight: selection == mode ? .semibold : .medium))
                                    .foregroundColor(selection == mode ? .white : .white.opacity(0.62))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                (selection == mode ? Color.white.opacity(0.18) : Color.white.opacity(0.08)),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(selection == mode ? Color.white.opacity(0.5) : .clear, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 420)
            .background(Color(hex: 0x1e1e21), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(28)
        }
        .transition(.opacity)
        .zIndex(50)
    }
}
