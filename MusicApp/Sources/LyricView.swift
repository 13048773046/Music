import SwiftUI
import AVFoundation

// MARK: - KRC / LRC 歌词模型（毫秒级逐字时间戳）

/// 逐字歌词单元：手动实现 Equatable（只比较内容字段，不含身份 id）。
/// 若依赖自动合成（曾含 `let id = UUID()`），每次解析重建的新对象 UUID 不同，
/// `==` 恒为 false，导致 LyricRowView 的 Equatable 局部刷新完全失效、
/// 歌词三行每帧全部重建——这是卡拉OK页掉帧的隐蔽根源。
struct KRWord: Equatable {
    let text: String
    let start: Double  // 秒
    var end: Double    // 秒（LRC 兼容时需要按下一行开始时间修正）

    static func == (lhs: KRWord, rhs: KRWord) -> Bool {
        lhs.text == rhs.text && lhs.start == rhs.start && lhs.end == rhs.end
    }
}

/// 歌词行：手动 Equatable（内容比较），保证同一行解析两次后相等。
struct KRCLine: Equatable {
    var words: [KRWord]
    let start: Double
    let end: Double

    var text: String { words.map(\.text).joined() }

    static func == (lhs: KRCLine, rhs: KRCLine) -> Bool {
        lhs.start == rhs.start && lhs.end == rhs.end && lhs.words == rhs.words
    }
}

/// 解析歌词文本：自动识别 KRC（含 `<起始ms,持续ms>` 逐字时间戳）与标准 LRC。
/// - KRC：以毫秒级逐字时间戳驱动卡拉OK式逐字高亮（每字独立 start/end）。
/// - LRC：整句退化为一个字（start=行时间，end 由下一行决定）。
/// 元信息行（[offset:]/[ti:]/[ar:]/[al:]/[by:]）自动跳过。
/// 注：UI 采用逐字卡拉OK填充（每个字在自身 start/end 区间内从左到右填充绘制），
/// 逐字时间戳按原始解析结果使用。

/// 行时间戳正则：`[mm:ss]` / `[mm:ss.ff]` / `[mm:ss:fff]` 及 KRC 每字时间戳
private let rowRegex = try! NSRegularExpression(pattern: "\\[(\\d+):(\\d+)(?:[.:](\\d+))?(?:,(\\d+))?\\]")
/// KRC 逐字时间戳正则：`<起始ms,持续ms>文本`
private let wordRegex = try! NSRegularExpression(pattern: "<(\\d+),(\\d+)>([^<]*)")

func parseLyrics(_ text: String) -> [KRCLine] {
    guard !text.isEmpty else { return [] }
    // 正则创建开销大：顶层静态缓存，只创建一次

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

/// 平滑滚动过渡 + 逐字卡拉OK填充全部由 `TimelineView(.animation)` 帧驱动，单一时间源：
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
/// **逐字卡拉OK填充（还原原始效果）**
/// 已唱完的字全白；正在唱的字在它自己的 [start, end] 区间内从左到右填充绘制；
/// 未到的字灰色。整行单 mask 裁剪 + 预测量字宽，视觉效果与逐字 mask 一致且更轻量。
///
/// 性能：行视图 Equatable 局部刷新；二分定位当前行；每帧仅一次 AVPlayer 时间查询。
struct LyricPreview: View {
    let lines: [KRCLine]
    /// 外部进度（秒）：播放页传入，包含拖动条 scrub 预览位置
    let progress: Double
    let tint: Color
    /// 歌词字号（默认 20 播放页预览；全屏歌词传大字号 30+，行高/间距随之缩放）
    var fontSize: CGFloat = 20

    // 排版尺寸随字号缩放（20 号时：行高约 26、间距 8，与系统行高一致）
    private var rowHeight: CGFloat { fontSize * 1.3 }
    private var rowGap: CGFloat { fontSize * 0.4 }
    private var step: CGFloat { rowHeight + rowGap }        // 单次滚动步长
    // 视口只露两行：当前句 + 下一句。第三行（预备行）在 frame 外被 clipped，
    // 在页面上自然被点赞/评论/分享按钮挡住，滚动时从下方滑上来接替下一句。
    private var viewHeight: CGFloat { rowHeight * 2 + rowGap }
    /// 切句滚动时长（秒）：滚动进度 = 距当前行 start 的时间 / 该值
    private static let scrollDuration: Double = 0.28

    /// 滚动单调化追踪器：记录已到达的最大滚动进度与当前行，
    /// class 引用属性不触发 SwiftUI 重绘，可安全在 TimelineView 每帧更新。
    private final class ScrollTracker {
        var maxT: Double = 0
        var lastC: Int = -2
    }
    @State private var tracker = ScrollTracker()

    /// 播放跟随：每帧直接实时查询 AVPlayer 当前时间（毫秒级），逐字高亮逐帧推进。
    /// 引擎音效模式（3D 立体等）：AVPlayer 无 currentItem 时间恒 0，
    /// 直接以外部进度为准（0.1s 阶梯更新），避免开头 0.6s 误判冻结。
    private func displayTime() -> Double {
        if PlayerManager.shared.usingEngine { return progress }
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
        // 播放中：TimelineView(.animation) 60fps 逐帧推进（切句滚动 + 逐字卡拉OK）。
        // 暂停时：歌词时间不再前进，继续 60fps 重绘纯属空转（耗电/发热）。
        // 改为静态渲染——displayTime() 只求值一次，SwiftUI 仅在其他依赖变化
        // （如拖动条 scrub 预览 progress）时才重建本视图，暂停功耗几乎归零。
        Group {
            if PlayerManager.shared.isPlaying {
                TimelineView(.animation) { _ in
                    content(display: displayTime())
                }
            } else {
                content(display: displayTime())
            }
        }
        .frame(height: viewHeight, alignment: .top)
        .clipped()
    }

    /// 歌词三行渲染（当前句 / 旧句 / 预备句），由 body 决定用 60fps 时间轴
    /// 还是暂停时的单次静态渲染驱动。
    private func content(display: Double) -> some View {
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
        let offsetY = scrolling ? -step * eased : 0

        return VStack(spacing: rowGap) {
                ForEach(0..<3, id: \.self) { idx in
                    let li = base + idx
                    if lines.indices.contains(li) {
                        let line = lines[li]
                        // 当前行：随滚动放大到满字号 + 逐字填充；
                        // 旧行（仅滚动期间）：已唱完全白，同步淡出缩小；
                        // 预备行：恒灰小字。
                        let isCurrent = li == c
                        let isOld = li == c - 1
                        let scale: Double = isCurrent
                            ? (scrolling ? 0.8 + 0.2 * eased : 1.0)
                            : (isOld ? 1.0 - 0.15 * eased : 0.8)
                        let opacity = isOld ? 1 - eased : 1.0
                        LyricRowView(
                            line: line,
                            currentTime: isCurrent ? display : (isOld ? display : -1),
                            scale: scale,
                            opacity: opacity,
                            tint: tint,
                            fontSize: fontSize
                        )
                    }
                }
            }
            .offset(y: offsetY)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 单行歌词（卡拉OK式逐字填充）

/// 逐字卡拉OK填充：已唱完的字全白；正在唱的字从左到右填充绘制（每个字到它的
/// 开始/结束时间区间内从左扫到右）；未到的字灰色。
/// 白色整行文字用**一个**左对齐矩形 mask 裁剪，mask 宽度 = 已唱完字宽之和 +
/// 正在唱的字宽 × 字内进度，视觉效果与逐字 mask 完全一致，但每帧只更新一个
/// CGFloat 宽度（无 GeometryReader）；每个字的渲染宽度在行出现时用 UIFont
/// 一次性测量缓存，零布局开销。
struct LyricRowView: View, Equatable {
    let line: KRCLine
    /// 当前播放秒数；-1 = 非高亮行（全灰），旧行传 display（已唱完 → 全白淡出）
    let currentTime: Double
    let scale: Double       // 当前句固定 1.0；下一句固定 0.8 小字
    let opacity: Double     // 旧句滚动淡出
    let tint: Color
    /// 歌词字号（与 LyricPreview.fontSize 保持一致；字宽测量用同款字号）
    var fontSize: CGFloat = 20
    /// 字重（全屏 3D 歌词用 .semibold 更清晰；竖屏预览默认 .medium）
    var fontWeight: Font.Weight = .medium

    /// 逐字渲染宽度缓存（onAppear 一次性测量）
    @State private var charWidths: [CGFloat] = []

    /// 手动实现 Equatable：排除 @State 缓存属性（自动合成会被 State 包装器阻断）。
    /// 未变化的行（如预备行）由 SwiftUI 跳过重建，当前行/旧行因 currentTime 每帧变化而重建。
    static func == (lhs: LyricRowView, rhs: LyricRowView) -> Bool {
        lhs.line == rhs.line &&
        lhs.currentTime == rhs.currentTime &&
        lhs.scale == rhs.scale &&
        lhs.opacity == rhs.opacity &&
        lhs.tint == rhs.tint &&
        lhs.fontSize == rhs.fontSize &&
        lhs.fontWeight == rhs.fontWeight
    }

    /// 逐字填充的"空洞压缩"阈值（秒）：字间间隔超过该值视为句内停顿（不承载唱词），
    /// 后续字的时间戳整体前移、压缩到 gapKeep，避免卡拉OK填充在长停顿处长时间静止
    /// ——这是"逐字歌词有时走不完一整句"的根因（线上 KRC 数据 35.9% 行存在 >300ms 空洞，
    /// 最大 40.9s）。压缩只影响填充进度节奏，不改变字序与唱词，停顿本就没有字在唱。
    private static let gapThreshold: Double = 0.6
    /// 压缩后保留的停顿（秒），保持一点换气/间奏感
    private static let gapKeep: Double = 0.15

    /// 已唱区间宽度 = 已唱完字宽之和 + 正在唱的字宽 × 字内进度
    /// （字时间戳经空洞压缩；字宽缺失时用字号估算兜底，保证 mask 永远能走到句尾）
    private var filledWidth: CGFloat {
        guard currentTime >= 0 else { return 0 }
        let words = line.words
        // LRC 整句行（无逐字时间戳，words 只有 1 个）：句开始即整行一次性亮起，
        // 不做"按整句时长线性填充"——没有逐字时间时线性填充必然和真实演唱错位
        // （快唱的字被拖慢、拖长的字提前），整句高亮才是 LRC 的正确显示方式。
        if words.count <= 1 {
            if let w = words.first, currentTime >= w.start {
                return charWidths.reduce(0, +)
            }
            return 0
        }
        var w: CGFloat = 0
        var carry: Double = 0          // 已压缩掉的累计空洞（秒）
        var prevEnd: Double = words[0].start   // 上一字压缩后的结束时间
        for (i, word) in words.enumerated() {
            // 空洞压缩：字 start 与上一字 end 的间隔超过阈值，该字及后续整体前移
            let gap = word.start - prevEnd
            if gap > Self.gapThreshold { carry += gap - Self.gapKeep }
            let s = word.start - carry
            let e = word.end - carry
            // 字宽兜底：缓存缺失/过期时用字号×1.0 估算中文字宽，
            // 后半句不会因缓存长度不足而宽度=0、mask 封顶半句
            let cw = charWidths.indices.contains(i) ? charWidths[i] : max(fontSize * 1.0, 8)
            if currentTime >= e {
                w += cw
            } else if currentTime >= s {
                let span = max(e - s, 0.001)
                let p = min(max((currentTime - s) / span, 0), 1)
                w += cw * p
                break
            } else {
                break
            }
            prevEnd = e
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
        .font(.system(size: fontSize, weight: fontWeight))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .scaleEffect(CGFloat(scale), anchor: .leading)
        .opacity(opacity)
        .onAppear { measure() }
        // 行内容切换（切歌/下一句替换本行）时字宽缓存过期，必须重测；
        // 否则新行字数 > 缓存字数时后半部分字宽=0，mask 停在前半句——歌词只走到一半就卡住
        .onChange(of: line) { _ in measure() }
        // 字号变化（多模式歌词里同一行会从小字号变为当前句大字号）也必须重测，
        // 否则卡拉OK填充宽度用的是旧字号字宽，逐字高亮错位
        .onChange(of: fontSize) { _ in measure() }
    }

    private var baseOpacity: Double {
        let t = (scale - 0.8) / 0.2
        return 0.4 + 0.1 * min(max(t, 0), 1)
    }

    /// 用与 SwiftUI 同款字体一次性测量每个字的渲染宽度
    private func measure() {
        let font = UIFont.systemFont(ofSize: fontSize, weight: uiWeight(fontWeight))
        charWidths = line.words.map { w in
            (w.text as NSString).size(withAttributes: [.font: font]).width
        }
    }

    /// Font.Weight → UIFont.Weight（measure 与渲染必须同款字体，否则 mask 宽度错位）
    private func uiWeight(_ w: Font.Weight) -> UIFont.Weight {
        switch w {
        case .bold: return .bold
        case .semibold: return .semibold
        case .regular: return .regular
        case .light: return .light
        default: return .medium
        }
    }
}
