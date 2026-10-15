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
// 镜台 Diorama：3D 走廊 + 相机飞行正对
// 歌词行是走廊空间中的实体：当前句正对相机，前后句沿走廊弯曲纵深退远；
// 相机（视角）随播放沿走廊平滑飞行，逐句正对；切句用单调滚动模拟飞行推进。
// ============================================================

struct DioramaLyricView: View {
    let lines: [KRCLine]
    let progress: Double
    var fontSize: CGFloat = 30

    private var rowGap: CGFloat { fontSize * 1.6 }
    private static let scrollDuration: Double = 0.32
    private let anglePerLine: Double = 13        // 走廊侧弯角（度/句）
    private let bendRadius: CGFloat = 46          // 走廊横向弯曲半径
    private let zPerspective: CGFloat = 0.42      // 透视强度

    private func depthScale(_ d: Int) -> Double { pow(0.78, Double(abs(d))) }
    private func depthOpacity(_ d: Int) -> Double { pow(0.58, Double(abs(d))) }

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
            let scrolling = c > 0 && t < 1
            let base = scrolling ? c - 1 : c
            let offsetY = scrolling ? -rowGap * CGFloat(eased) : 0

            ZStack(alignment: .center) {
                ForEach((base - 3)..<(base + 4), id: \.self) { li in
                    if lines.indices.contains(li) {
                        corridorRow(li: li, c: c, display: display, eased: eased)
                    }
                }
            }
            .offset(y: offsetY)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 相机运镜（Folia diorama 的镜头缓移：扫视 + 推拉 + 游移）
            .modifier(CameraMotion())
            // 双向防溢出：走廊纵深超高时整体等比缩放，完整显示
            .modifier(FitFrame(estWidth: CGFloat(maxChars) * fontSize * 1.05,
                               estHeight: fontSize * 11.2))
        }
    }

    private func advance(_ raw: Double, _ c: Int) -> Double {
        if c != tracker.lastC { tracker.lastC = c; tracker.maxT = 0 }
        tracker.maxT = max(tracker.maxT, raw)
        return tracker.maxT
    }

    @ViewBuilder
    private func corridorRow(li: Int, c: Int, display: Double, eased: Double) -> some View {
        let line = lines[li]
        let rawD = li - c
        let isCurrent = li == c
        let isOld = li == c - 1

        // 切句飞行：新句从走廊深处推进，旧句退远淡出
        let scrollIn = isCurrent && eased > 0 ? (1 - eased) : 0.0
        let scrollOut = isOld && eased > 0 ? eased : 0.0
        let effD = Double(rawD) + scrollIn - scrollOut

        let scale = isCurrent ? (0.82 + 0.26 * (1 - scrollIn)) : depthScale(rawD) * (isOld ? (1 - 0.3 * eased) : 1)
        let opacity = isCurrent ? (0.35 + 0.65 * (1 - scrollIn)) : depthOpacity(rawD) * (isOld ? (1 - 0.45 * eased) : 1)
        let bend = effD * anglePerLine
        // 走廊横向弯曲：随纵深 sin 弯曲 + 纵深缩放
        let xBend = CGFloat(sin(effD * 0.45)) * bendRadius * CGFloat(depthScale(rawD))
        let yOff = CGFloat(effD) * rowGap

        LyricRowView(
            line: line,
            currentTime: li <= c ? display : -1,
            scale: scale,
            opacity: opacity,
            tint: .white,
            fontSize: fontSize,
            fontWeight: .semibold
        )
        .rotation3DEffect(.degrees(bend), axis: (x: 0, y: 1, z: 0), perspective: zPerspective)
        .offset(x: xBend, y: yOff)
        .shadow(color: isCurrent ? .white.opacity(0.28) : .clear, radius: 22)
        .zIndex(Double(-abs(li - c)))
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
