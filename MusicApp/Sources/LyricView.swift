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
/// - KRC：`<st,dur>` 是**相对该行标签时间**的毫秒偏移，字的绝对时间 = 行时间 + st/1000，
///   行的展示开始时间 = 行标签时间；逐字卡拉OK高亮由每字绝对时间驱动。
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
            // 关键：KRC 的 <st,dur> 是相对本行标签时间的毫秒偏移，须换算为绝对秒数，
            // 否则各行时间轴重叠错乱（歌词填充一半就跳句/乱切句）
            words.append(KRWord(text: txt,
                                start: rowStart + stMs / 1000,
                                end: rowStart + (stMs + durMs) / 1000))
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
        // 行展示开始时间 = 行标签时间（到点即切句）；行结束 = 最后字绝对结束时间
        lines.append(KRCLine(words: words,
                             start: rowStart,
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

// MARK: - 两句固定歌词预览（歌名/作者下方，互动行上方）

/// **固定模式**：当前句永远显示在第 1 行、下一句在第 2 行，位置完全固定，
/// 无位移动画、无缩放动画、无滚动回弹；切句瞬间仅做极短淡入（0.12s，帧驱动）。
///
/// **逐字卡拉OK高亮（整行单 mask，无 GeometryReader）**
/// 白色整行文字用**一个**左对齐矩形 mask 裁剪，mask 宽度 = 已唱完字宽之和 + 正在唱的字宽×进度。
/// 每个字的渲染宽度在行出现时用 UIFont 一次性测量缓存，每帧只更新一个 CGFloat 宽度，
/// 不做任何布局测量；已唱完白、正在唱从左扫到右、未到灰。
///
/// 性能：行视图 Equatable 局部刷新；二分定位当前行；每帧仅一次 AVPlayer 时间查询 + 一次宽度累加。
struct LyricPreview: View {
    let lines: [KRCLine]
    /// 外部进度（秒）：播放页传入，包含拖动条 scrub 预览位置
    let progress: Double
    let tint: Color

    // 固定排版尺寸（字号 20 行高约 26，间距 8）
    private static let rowHeight: CGFloat = 26
    private static let rowGap: CGFloat = 8
    // 视口固定两行：当前句 + 下一句
    private static let viewHeight: CGFloat = rowHeight * 2 + rowGap
    /// 切句后当前行的淡入时长（秒）：仅透明度过渡，位置不动
    private static let fadeDuration: Double = 0.12

    /// 播放跟随：每帧直接实时查询 AVPlayer 当前时间（毫秒级），逐字高亮逐帧推进
    private func displayTime() -> Double {
        let now = CMTimeGetSeconds(PlayerManager.shared.player.currentTime())
        let safe = now.isFinite ? now : 0
        return abs(progress - safe) < 0.6 ? safe : progress
    }

    /// 当前行索引（-1 = 尚未到第一行歌词）
    private func currentIndex(_ display: Double) -> Int {
        guard !lines.isEmpty else { return -1 }
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].start <= display { lo = mid + 1 } else { hi = mid }
        }
        return lo - 1
    }

    var body: some View {
        TimelineView(.animation) { _ in
            let display = displayTime()
            let c = currentIndex(display)
            // 切句淡入：距当前行 start 0.12s 内透明度 0.25 → 1.0（smoothstep），
            // 之后恒定 1.0。位置固定，无位移无缩放无回弹。
            let fadeT = c >= 0 ? min(max((display - lines[c].start) / Self.fadeDuration, 0), 1) : 1
            let fade = fadeT * fadeT * (3 - 2 * fadeT)

            VStack(spacing: Self.rowGap) {
                // 当前句：固定第 1 行，逐字高亮
                if c >= 0, lines.indices.contains(c) {
                    LyricRowView(
                        line: lines[c],
                        currentTime: display,
                        scale: 1.0,
                        opacity: 0.25 + 0.75 * fade,
                        tint: tint
                    )
                }
                // 下一句：固定第 2 行，灰字
                if lines.indices.contains(c + 1) {
                    LyricRowView(
                        line: lines[c + 1],
                        currentTime: -1,
                        scale: 0.8,
                        opacity: 1.0,
                        tint: tint
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Self.viewHeight, alignment: .top)
        .clipped()
    }
}

// MARK: - 单行歌词（卡拉OK式逐字高亮，整行单 mask 裁剪）

/// 已唱完的字全白；正在唱的字从左扫到右（mask 宽度推进）；未到的字灰色。
/// 每个字的渲染宽度在行出现时一次性测量缓存，每帧只更新一个 CGFloat 宽度，零布局开销。
private struct LyricRowView: View, Equatable {
    let line: KRCLine
    /// 当前播放秒数；当前句传实时 display（逐字高亮），下一句传 -1（全灰）
    let currentTime: Double
    let scale: Double       // 当前句固定 1.0；下一句固定 0.8 小字
    let opacity: Double     // 当前句切句淡入用
    let tint: Color

    /// 逐字渲染宽度缓存（onAppear 一次性测量）
    @State private var charWidths: [CGFloat] = []

    /// 手动实现 Equatable：排除 @State 缓存属性（自动合成会被 State 包装器阻断）。
    /// 未变化的行（如预备行）由 SwiftUI 跳过重建，当前行/旧行因 currentTime 每帧变化而重建。
    static func == (lhs: LyricRowView, rhs: LyricRowView) -> Bool {
        lhs.line == rhs.line &&
        lhs.currentTime == rhs.currentTime &&
        lhs.scale == rhs.scale &&
        lhs.opacity == rhs.opacity &&
        lhs.tint == rhs.tint
    }

    /// 已唱区间宽度 = 已唱完字宽之和 + 正在唱的字宽 × 字内进度
    private var filledWidth: CGFloat {
        guard currentTime >= 0 else { return 0 }
        var w: CGFloat = 0
        for (i, word) in line.words.enumerated() {
            let cw = charWidths.indices.contains(i) ? charWidths[i] : 0
            if currentTime >= word.end {
                w += cw
            } else if currentTime >= word.start {
                let span = max(word.end - word.start, 0.001)
                let p = min(max((currentTime - word.start) / span, 0), 1)
                w += cw * p
                break
            } else {
                break
            }
        }
        return w
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // 底色：未唱部分（灰）
            Text(line.text)
                .foregroundColor(tint.opacity(baseOpacity))
            // 已唱区间：白色整行 + 单个左对齐矩形 mask（宽度=已唱区间），无 GeometryReader
            if currentTime >= 0 {
                Text(line.text)
                    .foregroundColor(.white)
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: filledWidth)
                    }
            }
        }
        .font(.system(size: 20, weight: .medium))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .scaleEffect(CGFloat(scale), anchor: .leading)
        .opacity(opacity)
        .onAppear { measure() }
    }

    private var baseOpacity: Double {
        let t = (scale - 0.8) / 0.2
        return 0.4 + 0.1 * min(max(t, 0), 1)
    }

    /// 用与 SwiftUI 同款字体一次性测量每个字的渲染宽度
    private func measure() {
        let font = UIFont.systemFont(ofSize: 20, weight: .medium)
        charWidths = line.words.map { w in
            (w.text as NSString).size(withAttributes: [.font: font]).width
        }
    }
}
