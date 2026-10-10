import SwiftUI
import AVFoundation

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
/// - **整句从左到右平滑填满**：`TimelineView(.animation)` 按屏幕刷新率**逐帧**驱动填充进度，
///   填充用**遮罩矩形裁剪**（白色文字纹理只渲染一次，矩形宽度=进度×整句宽，GPU合成伸展），
///   进度每帧直接实时查询 AVPlayer（毫秒级），高帧率且开销小、流畅不卡；
/// - **滚动与字号同步过渡**：下一句用 `scaleEffect(0.8)` 呈现 16pt，**放大进度直接绑定滚动
///   位移（offsetY 插值驱动 scale）**，往上滚动的同时文字同步放大到 20pt，
///   滚动结束即放大到位，复位后无缝衔接为当前句，无先后之分、无跳变；
/// - **连续滚动**：三行渲染（当前句+下一句+再下一句），切句时容器上滑一个行块，
///   滑动结束帧与复位帧视口逐像素一致；行视图以歌词内容为 identity，实例跨切句保留。
///
/// 性能：行视图 Equatable 局部刷新；二分定位当前行（O(log n)）；每帧仅一次 AVPlayer 时间查询；
/// 逐字着色：每个 KRWord 独立判断是否已开始播放，已播白色、未播灰色，
/// 无 mask / GeometryReader / drawingGroup，字形一次性栅格化，最流畅。
struct LyricPreview: View {
    let lines: [KRCLine]
    /// 外部进度（秒）：播放页传入，包含拖动条 scrub 预览位置
    let progress: Double
    let tint: Color

    // 固定排版尺寸（字号 20 行高约 26，间距 8）
    private static let rowHeight: CGFloat = 26
    private static let rowGap: CGFloat = 8
    private static let step: CGFloat = rowHeight + rowGap   // 单次滚动步长
    // 三行完整高度：当前句 + 下一句 + 再下一句，避免第三行被互动按钮挡住
    private static let viewHeight: CGFloat = rowHeight * 3 + rowGap * 2

    /// 当前渲染的三行内容锚点（滚动动画期间不更新，动画结束后更新并复位位移）
    @State private var anchor: Int = 0
    @State private var offsetY: CGFloat = 0
    @State private var isScrolling = false

    /// 播放跟随：每帧直接实时查询 AVPlayer 当前时间（毫秒级），逐字高亮逐帧推进
    private var displayProgress: Double {
        let now = CMTimeGetSeconds(PlayerManager.shared.player.currentTime())
        let safe = now.isFinite ? now : 0
        return abs(progress - safe) < 0.6 ? safe : progress
    }

    /// 当前行索引（-1 = 尚未到第一行歌词）
    private var currentIndex: Int {
        guard !lines.isEmpty else { return -1 }
        let p = displayProgress
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].start <= p { lo = mid + 1 } else { hi = mid }
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
            let p = displayProgress
            VStack(spacing: Self.rowGap) {
                ForEach(0..<visibleLines.count, id: \.self) { idx in
                    let line = visibleLines[idx]
                    // 第 0 行 = 当前句（逐字高亮）；第 1 行（下一句）放大进度绑定滚动进度；
                    // 第 2 行（再下一句）恒为小字灰色。非当前行 currentTime 传 -1 → 全部字灰色。
                    let scale = idx == 0 ? 1.0
                        : (idx == 1 ? 0.8 + 0.2 * scrollProgress : 0.8)
                    LyricRowView(
                        line: line,
                        currentTime: idx == 0 ? p : -1,
                        scale: scale,
                        tint: tint
                    )
                }
            }
            .offset(y: offsetY)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Self.viewHeight, alignment: .top)
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

// MARK: - 单行歌词（逐字高亮：唱过的字白色，未到的字灰色）

private struct LyricRowView: View, Equatable {
    let line: KRCLine
    /// 当前播放秒数；-1 = 非当前行，所有字灰色
    let currentTime: Double
    let scale: Double       // 0.8...1.0：下一句在滚动期间同步放大到 20pt
    let tint: Color

    private var baseOpacity: Double {
        let t = (scale - 0.8) / 0.2
        return 0.4 + 0.1 * min(max(t, 0), 1)
    }

    var body: some View {
        HStack(spacing: 0) {
            // 逐字着色：每个字根据 KRC 时间戳判断是否已开始播放。
            // 没有 mask / GeometryReader，Text 从 leading 自然排列，左边距由外层 padding 控制。
            ForEach(line.words) { w in
                let played = currentTime >= w.start
                Text(w.text)
                    .foregroundColor(played ? .white : tint.opacity(baseOpacity))
            }
        }
        .font(.system(size: 20, weight: .medium))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .scaleEffect(scale, anchor: .leading)
    }
}
