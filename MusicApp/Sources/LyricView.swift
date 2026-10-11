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
/// 注：UI 采用整句高亮模式（整句跟随行时间点亮/切换），逐字时间戳仅保留原始解析结果。
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

/// 平滑滚动过渡 + 整句高亮全部由 `TimelineView(.animation)` 帧驱动，单一时间源：
///
/// **切句平滑滚动（保留原过渡动画，去除结尾回弹）**
/// 滚动进度 `t` = 距当前行 start 的时间 / 0.28s，每帧按时间戳插值：
/// - 滚动期间行集合为 `[旧行, 当前行, 预备行]`，容器上滑 `-step * easeOutCubic(t)`
/// - 旧行同步淡出并轻微缩小，当前行从 0.8 放大到 1.0，全部由同一 `t` 驱动，天然同步
/// - **单调化**：AVPlayer 时间在流式播放时可能毫秒级抖动/回退，若直接驱动 `t`，
///   位移会跟着回退，表现为"滚上去又弹回来"的小回弹。这里用引用类型记录已到达的
///   最大进度（class 属性不触发 SwiftUI 重绘），进度只增不减；切句（当前行变化）时
///   重置，保证每次滚动平滑单向、无回弹。
///
/// **整句高亮（无逐字扫描）**
/// 当前句整句白色、下一句灰色小字，行切换由行标签时间驱动（到点整句切换），
/// 单 Text 渲染，无 mask、无字宽测量，最轻量。
///
/// 性能：行视图 Equatable 局部刷新；二分定位当前行；每帧仅一次 AVPlayer 时间查询。
struct LyricPreview: View {
    let lines: [KRCLine]
    /// 外部进度（秒）：播放页传入，包含拖动条 scrub 预览位置
    let progress: Double
    let tint: Color

    // 固定排版尺寸（字号 20 行高约 26，间距 8）
    private static let rowHeight: CGFloat = 26
    private static let rowGap: CGFloat = 8
    private static let step: CGFloat = rowHeight + rowGap   // 单次滚动步长
    // 视口只露两行：当前句 + 下一句。第三行（预备行）在 frame 外被 clipped，
    // 在页面上自然被点赞/评论/分享按钮挡住，滚动时从下方滑上来接替下一句。
    private static let viewHeight: CGFloat = rowHeight * 2 + rowGap
    /// 切句滚动时长（秒）：滚动进度 = 距当前行 start 的时间 / 该值
    private static let scrollDuration: Double = 0.28

    /// 滚动单调化追踪器：记录已到达的最大滚动进度与当前行，
    /// class 引用属性不触发 SwiftUI 重绘，可安全在 TimelineView 每帧更新。
    private final class ScrollTracker {
        var maxT: Double = 0
        var lastC: Int = -2
    }
    @State private var tracker = ScrollTracker()

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

    /// 每帧推进滚动状态：切句（当前行变化）时重置单调进度；
    /// 否则滚动进度只增不减，AVPlayer 时间抖动不会让位移回退（无回弹）。
    /// 返回 Void，在 TimelineView 内以 `let _ = advanceTracker(...)` 声明形式调用
    /// （ViewBuilder 不允许直接写赋值语句）。
    private func advanceTracker(c: Int, display: Double) {
        if c != tracker.lastC {
            tracker.lastC = c
            tracker.maxT = 0
        }
        let tRaw = c > 0 ? min(max((display - lines[c].start) / Self.scrollDuration, 0), 1) : 1
        if tRaw > tracker.maxT {
            tracker.maxT = tRaw
        }
    }

    var body: some View {
        TimelineView(.animation) { _ in
            let display = displayTime()
            let c = currentIndex(display)
            // 切句重置 + 滚动进度单调化（副作用在辅助函数中完成，闭包内只用声明）
            let _ = advanceTracker(c: c, display: display)
            // 滚动进度：切句瞬间（display 刚过当前行 start）为 0，0.28s 后为 1。
            // 单调化：只增不减，AVPlayer 时间抖动不会让位移回退（无回弹）。
            let t = max(c > 0 ? min(max((display - lines[c].start) / Self.scrollDuration, 0), 1) : 1,
                        tracker.maxT)
            let eased = c > 0 ? 1 - (1 - t) * (1 - t) * (1 - t) : 0   // easeOutCubic：起快收慢，跟手不拖沓
            // 滚动中展示 [旧行, 当前行, 预备行] 并上滑；滚动结束后 [当前行, 预备行, 预备预备]
            let scrolling = c > 0 && t < 1
            let base = scrolling ? c - 1 : c
            let offsetY = scrolling ? -Self.step * eased : 0

            VStack(spacing: Self.rowGap) {
                ForEach(0..<3, id: \.self) { idx in
                    let li = base + idx
                    if lines.indices.contains(li) {
                        let line = lines[li]
                        // 当前行：随滚动放大到满字号 + 整句点亮；
                        // 旧行（仅滚动期间）：整句白色，同步淡出缩小；
                        // 预备行：恒灰小字。
                        let isCurrent = li == c
                        let isOld = li == c - 1
                        let scale: Double = isCurrent
                            ? (scrolling ? 0.8 + 0.2 * eased : 1.0)
                            : (isOld ? 1.0 - 0.15 * eased : 0.8)
                        let opacity = isOld ? 1 - eased : 1.0
                        LyricRowView(
                            line: line,
                            isActive: isCurrent || isOld,   // 当前句与滑出中的旧句都整句点亮
                            scale: scale,
                            opacity: opacity,
                            tint: tint
                        )
                    }
                }
            }
            .offset(y: offsetY)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Self.viewHeight, alignment: .top)
        .clipped()
    }
}

// MARK: - 单行歌词（整句高亮）

/// 整句跟随歌词文件的行时间点亮：当前句（及滚出中的旧句）整句白色，
/// 未到的句子灰色小字；行切换由行标签时间驱动（到点整句切换），
/// 无逐字扫描、无 mask、无测量，单 Text 渲染，最轻量。
private struct LyricRowView: View, Equatable {
    let line: KRCLine
    /// 是否整句点亮（当前句 / 滚动中正在滑出的旧句）
    let isActive: Bool
    let scale: Double       // 当前句固定 1.0；下一句固定 0.8 小字
    let opacity: Double     // 旧句滚动淡出
    let tint: Color

    static func == (lhs: LyricRowView, rhs: LyricRowView) -> Bool {
        lhs.line == rhs.line &&
        lhs.isActive == rhs.isActive &&
        lhs.scale == rhs.scale &&
        lhs.opacity == rhs.opacity &&
        lhs.tint == rhs.tint
    }

    var body: some View {
        Text(line.text)
            .font(.system(size: 20, weight: .medium))
            .foregroundColor(isActive ? .white : tint.opacity(baseOpacity))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(CGFloat(scale), anchor: .leading)
            .opacity(opacity)
    }

    private var baseOpacity: Double {
        let t = (scale - 0.8) / 0.2
        return 0.4 + 0.1 * min(max(t, 0), 1)
    }
}
