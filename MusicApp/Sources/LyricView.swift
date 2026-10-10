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

/// 只显示「当前播放的一句 + 下一句」的滚动歌词，支持 KRC 逐字从左到右平滑填充。
///
/// 性能设计（高刷新率逐字填充场景）：
/// 1. **二分定位**：每次刷新只做行级二分（O(log n)）+ 当前行内线性扫字；
/// 2. **局部刷新**：行视图为 `Equatable` 值类型，仅当前句（及填充进度）变化才重建，
///    下一句是静态 Text，零重算；
/// 3. **独立轻量时钟**：仅本组件激活时运行 0.05s 进度循环（`.task` 自动管理生命周期），
///    不触碰 PlayerManager 全局 0.5s 观察者；
/// 4. **平滑填充**：正唱字颜色按字内进度线性插值（暗→亮），配合 0.05s linear 动画补间，
///    视觉上从左到右连续填满；换字时以短动画平滑过渡，无跳变。
struct LyricPreview: View {
    let lines: [KRCLine]
    /// 外部进度（秒）：播放页传入，包含拖动条 scrub 预览位置
    let progress: Double
    let tint: Color

    @State private var liveProgress: Double = 0

    /// 播放跟随：外部进度与本地时钟相差 <0.6s 视为正常播放，用 0.05s 粒度本地值平滑填充；
    /// 差异大（拖动 scrub 预览）则优先外部值。
    private var displayProgress: Double {
        abs(progress - liveProgress) < 0.6 ? liveProgress : progress
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

    private var currentLine: KRCLine? {
        let idx = currentIndex
        guard idx >= 0, idx < lines.count else { return nil }
        return lines[idx]
    }

    private var nextLine: KRCLine? {
        let idx = currentIndex
        guard idx >= 0, idx + 1 < lines.count else { return nil }
        return lines[idx + 1]
    }

    /// 切换动画锚点：未到第一句时锚定第 0 句，保证滚动区稳定
    private var anchorIndex: Int { currentIndex >= 0 ? currentIndex : 0 }

    /// 当前行内正在唱的字索引；-1 = 已唱完（间隙）
    private var activeWordIndex: Int {
        guard let line = currentLine, !line.words.isEmpty else { return -1 }
        for i in line.words.indices where line.words[i].start <= displayProgress && displayProgress < line.words[i].end {
            return i
        }
        return displayProgress >= (line.words.last?.end ?? 0) ? -1 : 0
    }

    /// 正唱字的填充进度 0...1（字内时间占比）
    private var wordProgress: Double {
        guard let line = currentLine else { return 0 }
        for w in line.words where w.start <= displayProgress && displayProgress < w.end {
            let t = (displayProgress - w.start) / max(w.end - w.start, 0.001)
            return min(max(t, 0), 1)
        }
        // 无正唱字：已唱完视为填充完成，未开始视为 0
        return displayProgress >= (line.words.last?.end ?? 0) ? 1 : 0
    }

    var body: some View {
        VStack(spacing: 9) {
            // 当前句：逐字填充高亮
            Group {
                if let line = currentLine {
                    KRCWordLineView(line: line,
                                    isCurrent: true,
                                    activeWordIndex: activeWordIndex,
                                    wordProgress: wordProgress,
                                    tint: tint)
                } else if !lines.isEmpty {
                    // 未到第一句：显示第一句（未开始状态）
                    KRCWordLineView(line: lines[0],
                                    isCurrent: true,
                                    activeWordIndex: -1,
                                    wordProgress: 0,
                                    tint: tint)
                }
            }
            .id("cur-\(anchorIndex)")
            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .move(edge: .top).combined(with: .opacity)))

            // 下一句：静态弱化
            Group {
                if let line = nextLine {
                    Text(line.text)
                        .font(.system(size: 13))
                        .foregroundColor(tint.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                } else if lines.count > 1, currentIndex < 0 {
                    Text(lines[1].text)
                        .font(.system(size: 13))
                        .foregroundColor(tint.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
            }
            .id("next-\(anchorIndex)")
            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .move(edge: .top).combined(with: .opacity)))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 54, alignment: .center)
        .clipped()
        .animation(.easeInOut(duration: 0.3), value: anchorIndex)
        // 0.05s 轻量进度时钟：视图出现时启动、消失时由 SwiftUI 自动取消
        .task {
            liveProgress = PlayerManager.shared.currentTime
            while !Task.isCancelled {
                liveProgress = PlayerManager.shared.currentTime
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }
}

// MARK: - 单行歌词（逐字从左到右平滑填充）

private struct KRCWordLineView: View, Equatable {
    let line: KRCLine
    let isCurrent: Bool
    let activeWordIndex: Int
    let wordProgress: Double   // 0...1：正唱字填充进度
    let tint: Color

    var body: some View {
        HStack(spacing: 0) {
            ForEach(line.words.indices, id: \.self) { i in
                Text(line.words[i].text)
                    .foregroundColor(wordColor(i))
                    // 字内填充：随 wordProgress 平滑补间（从左到右连续填满）
                    .animation(.linear(duration: 0.05), value: wordProgress)
                    // 换字瞬间：颜色平滑过渡，无跳变
                    .animation(.linear(duration: 0.08), value: activeWordIndex)
            }
        }
        .font(.system(size: 17, weight: .medium))
        .multilineTextAlignment(.center)
        .lineLimit(1)
        .frame(maxWidth: .infinity)
    }

    private func wordColor(_ i: Int) -> Color {
        guard isCurrent else { return tint.opacity(0.4) }   // 非当前行：统一弱化
        if activeWordIndex < 0 { return tint.opacity(0.85) } // 已唱完（间隙）：整行已唱
        if i < activeWordIndex { return tint.opacity(0.85) } // 已唱
        if i == activeWordIndex {                            // 正在唱：暗→亮平滑填充
            return lerpColor(tint.opacity(0.4), .white, wordProgress)
        }
        return tint.opacity(0.4)                             // 未唱
    }

    /// 颜色线性插值（UIColor 分量），用于逐字填充动画
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
