import SwiftUI

// MARK: - KRC / LRC 歌词模型（毫秒级逐字时间戳）

struct KRWord: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let start: Double  // 秒
    var end: Double    // 秒（LRC 兼容时需要按下一行开始时间修正）
}

struct KRCLine: Equatable, Identifiable {
    let id = UUID()
    var words: [KRWord]
    let start: Double
    let end: Double

    var text: String { words.map(\.text).joined() }
}

/// 解析歌词文本：自动识别 KRC（含 `<起始ms,持续ms>` 逐字时间戳）与标准 LRC。
/// - KRC：以毫秒级逐字时间戳驱动卡拉OK式逐字高亮（每字独立 start/end）。
/// - LRC：整句退化为一个字（start=行时间，end 由下一行决定）。
/// 元信息行（[offset:]/[ti:]/[ar:]/[al:]/[by:]）自动跳过。
func parseLyrics(_ text: String) -> [KRCLine] {
    guard !text.isEmpty else { return [] }
    let rowRegex = try! NSRegularExpression(pattern: "\\[(\\d+):(\\d+)(?:[.:](\\d+))?(?:,(\\d+))?\\]")
    let wordRegex = try! NSRegularExpression(pattern: "<(\\d+),(\\d+)>([^<]*)")

    var lines: [KRCLine] = []
    for raw in text.components(separatedBy: .newlines) {
        let ns = raw as NSString
        guard let rowMatch = rowRegex.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)),
              rowMatch.range.location == 0 else { continue }
        let mm = Double(ns.substring(with: rowMatch.range(at: 1))) ?? 0
        let ss = Double(ns.substring(with: rowMatch.range(at: 2))) ?? 0
        var frac: Double = 0
        if rowMatch.range(at: 3).location != NSNotFound {
            let f = Double(ns.substring(with: rowMatch.range(at: 3))) ?? 0
            frac = f / (f >= 100 ? 1000 : 100)   // 三位=毫秒，两位=百分秒
        }
        let rowStart = mm * 60 + ss + frac

        let bodyStart = rowMatch.range.length
        let bodyNS = ns.substring(with: NSRange(location: bodyStart, length: ns.length - bodyStart)) as NSString

        var words: [KRWord] = []
        var wordFound = false
        wordRegex.enumerateMatches(in: bodyNS as String, range: NSRange(location: 0, length: bodyNS.length)) { m, _, _ in
            guard let m = m else { return }
            let stMs = Double(bodyNS.substring(with: m.range(at: 1))) ?? 0
            let durMs = Double(bodyNS.substring(with: m.range(at: 2))) ?? 0
            let txt = bodyNS.substring(with: m.range(at: 3))
            guard !txt.isEmpty else { return }
            words.append(KRWord(text: txt, start: stMs / 1000, end: (stMs + durMs) / 1000))
            wordFound = true
        }

        if !wordFound {
            // 标准 LRC：整句一个字（end 在排序后由下一行修正）
            let txt = bodyNS.trimmingCharacters(in: .whitespaces)
            guard !txt.isEmpty else { continue }
            words = [KRWord(text: txt, start: rowStart, end: rowStart)]
        }
        guard !words.isEmpty else { continue }
        // 过滤平台水印/贡献者等非歌词元信息行（如「滚动歌词&翻译贡献者：xxx」）
        let joined = words.map(\.text).joined()
        if joined.contains("滚动歌词") || joined.contains("翻译贡献者") || joined.contains("贡献者") {
            continue
        }
        lines.append(KRCLine(words: words,
                             start: words.first?.start ?? rowStart,
                             end: words.last?.end ?? rowStart))
    }

    guard !lines.isEmpty else { return [] }
    lines.sort { $0.start < $1.start }
    // LRC 行（end == start）的结束时间取下一行开始时间
    for i in lines.indices where lines[i].end <= lines[i].start {
        let nextStart = (i + 1 < lines.count) ? lines[i + 1].start : lines[i].start + 3
        if nextStart > lines[i].start {
            lines[i].words[lines[i].words.count - 1].end = nextStart
        }
    }
    return lines
}

// MARK: - 两句滚动歌词预览（歌名/作者下方，互动行上方）

/// 只显示「当前播放的一句 + 下一句」的滚动歌词：
/// - **丝滑填充（无闪烁）**：`TimelineView(.animation)` 按屏幕刷新率逐帧驱动填充进度，
///   填充用**单个 Text + 线性渐变前景**实现——渐变 stops 的边界位置 = 时间进度，
///   纯颜色渲染、无 mask/GeometryReader 布局依赖，逐帧更新也不会闪；
/// - **滚动与字号同步过渡**：下一句用 `scaleEffect` 呈现约 14pt，**放大进度直接绑定滚动
///   位移（offsetY 插值驱动 scale）**，往上滚动的同时文字同步放大到 18pt，
///   滚动结束即放大到位，复位后无缝衔接为当前句，无先后之分、无跳变；
/// - **连续滚动**：三行渲染（当前句+下一句+再下一句），切句时容器上滑一个行块，
///   滑动结束帧与复位帧视口逐像素一致；行视图以歌词内容为 identity，实例跨切句保留。
///
/// 性能：行视图 Equatable 局部刷新（仅填充行/放大行随进度重绘）；二分定位当前行（O(log n)）。
struct LyricPreview: View {
    let lines: [KRCLine]
    /// 外部进度（秒）：播放页传入，包含拖动条 scrub 预览位置
    let progress: Double
    let tint: Color

    // 固定排版尺寸（字号 18 行高约 22，间距 8）
    private static let rowHeight: CGFloat = 22
    private static let rowGap: CGFloat = 8
    private static let step: CGFloat = rowHeight + rowGap   // 单次滚动步长
    private static let viewHeight: CGFloat = rowHeight * 2 + rowGap + 4

    /// 当前渲染的三行内容锚点（滚动动画期间不更新，动画结束后更新并复位位移）
    @State private var anchor: Int = 0
    @State private var offsetY: CGFloat = 0
    @State private var isScrolling = false

    /// 播放跟随：正常播放用实时播放时间（逐帧精确、丝滑）；拖动 scrub 预览时用外部进度
    private var displayProgress: Double {
        let now = PlayerManager.shared.currentTime
        return abs(progress - now) < 0.6 ? now : progress
    }

    /// 当前行索引（-1 = 尚未到第一行歌词）
    private var currentIndex: Int {
        guard !lines.isEmpty else { return -1 }
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].start <= displayProgress { lo = mid + 1 } else { hi = mid }
        }
        return lo - 1
    }

    /// 渲染的三行：anchor 起的三句（不足则少）
    private var visibleLines: [KRCLine] {
        guard !lines.isEmpty else { return [] }
        var out: [KRCLine] = []
        for i in anchor..<min(anchor + 3, lines.count) {
            out.append(lines[i])
        }
        return out
    }

    /// 滚动进度 0...1（滚动动画期间随 offsetY 逐帧插值，同步驱动下一句放大）
    private var scrollProgress: Double {
        guard Self.step > 0 else { return 0 }
        return min(Double(-offsetY / Self.step), 1)
    }

    var body: some View {
        TimelineView(.animation) { _ in
            GeometryReader { geo in
                VStack(spacing: Self.rowGap) {
                    ForEach(Array(visibleLines.enumerated()), id: \.element.id) { idx, line in
                        // 第 0 行恒为当前句（传实时进度 → 逐字平滑填充）；
                        // 第 1 行（下一句）放大进度绑定滚动进度 → 滚动与放大同步，传 -1 恒为灰；
                        // 第 2 行（再下一句）恒为小字灰
                        let scale = idx == 0 ? 1.0
                            : (idx == 1 ? 0.78 + 0.22 * scrollProgress : 0.78)
                        LyricRowView(
                            line: line,
                            progress: idx == 0 ? displayProgress : -1,
                            scale: scale,
                            tint: tint
                        )
                    }
                }
                .offset(y: offsetY)
                .frame(width: geo.size.width, alignment: .leading)
            }
        }
        .frame(height: Self.viewHeight)
        .clipped()
        .onChange(of: currentIndex) { newIdx in
            scrollIfNeeded(to: newIdx)
        }
    }

    /// 切句滚动：整体上滑一个行块；位移逐帧插值时下一句同步放大（见 scrollProgress）
    private func scrollIfNeeded(to newIdx: Int) {
        let target = newIdx < 0 ? 0 : newIdx
        guard target != anchor, !isScrolling, !lines.isEmpty else { return }
        isScrolling = true
        withAnimation(.easeInOut(duration: 0.25)) {
            offsetY = -Self.step
        }
        // 动画结束后换内容 + 无动画复位（结束帧与复位帧视口内容一致；此时下一句已放大到位）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.27) {
            anchor = target
            offsetY = 0
            isScrolling = false
        }
    }
}

// MARK: - 单行歌词（左对齐 + 逐字平滑填充 + 滚动同步字号过渡）

/// 逐字卡拉OK填充：每个字在其 KRC 时间区间 [start, end) 内从灰色**平滑渐变**到白色，
/// 字唱完变白后下一个字开始平滑变白，以此类推、无缝衔接。
/// 进度由 TimelineView 逐帧传入，每帧颜色微变 → 60fps 连续渐变，无闪烁、无跳变。
private struct LyricRowView: View, Equatable {
    let line: KRCLine
    /// 当前播放进度（秒）；非当前行传 -1 → 整行恒为灰色（未唱状态）
    let progress: Double
    /// 0.78...1.0：下一句在滚动期间同步放大
    let scale: Double
    let tint: Color

    /// 底色透明度：随放大同步从 0.4 过渡到 0.5
    private var baseOpacity: Double {
        let t = (scale - 0.78) / 0.22
        return 0.4 + 0.1 * min(max(t, 0), 1)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(line.words.indices, id: \.self) { i in
                Text(line.words[i].text)
                    .foregroundColor(wordColor(line.words[i]))
            }
        }
        .font(.system(size: 18, weight: .medium))
        .lineLimit(1)
        .scaleEffect(scale, anchor: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 单个字的颜色：未唱=灰 / 正唱=灰→白按字内时间平滑渐变 / 已唱=白
    private func wordColor(_ w: KRWord) -> Color {
        if progress < w.start {
            return tint.opacity(baseOpacity)          // 未唱：灰
        }
        if progress >= w.end {
            return .white                             // 已唱：白
        }
        // 正唱：字内时间占比 0→1，颜色从灰平滑渐变到白
        let t = (progress - w.start) / max(w.end - w.start, 0.001)
        return lerpColor(tint.opacity(baseOpacity), .white, min(max(t, 0), 1))
    }

    /// 颜色线性插值（UIColor 分量），用于逐字平滑填充
    private func lerpColor(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let ua = UIColor(a), ub = UIColor(b)
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        ua.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        ub.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let k = CGFloat(min(max(t, 0), 1))
        return Color(UIColor(red: ar + (br - ar) * k,
                             green: ag + (bg - ag) * k,
                             blue: ab + (bb - ab) * k,
                             alpha: aa + (ba - aa) * k))
    }
}
