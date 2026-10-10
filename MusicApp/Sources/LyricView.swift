import SwiftUI

// MARK: - KRC / LRC 歌词模型（毫秒级逐字时间戳）

struct KRWord: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let start: Double  // 秒
    let end: Double    // 秒
}

struct KRCLine: Equatable, Identifiable {
    let id = UUID()
    let words: [KRWord]
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

// MARK: - 逐字高亮歌词视图（性能优化版）

/// KRC 卡拉OK式逐字高亮歌词视图。
///
/// 性能设计（针对高刷新率逐字高亮场景）：
/// 1. **二分定位**：每帧只做一次行级二分（O(log n)）+ 当前行内线性扫字，不做全量扫描；
/// 2. **局部刷新**：行视图为 `Equatable` 值类型，仅当 `isCurrent / activeWordIndex` 变化时 SwiftUI 才重建该行，
///    非当前行完全不依赖进度，零重算；
/// 3. **懒加载**：`LazyVStack` 只实例化可见行，长歌词不常驻全部视图；
/// 4. **单 Text 渲染**：每行用 `AttributedString` 逐字着色，一行只有一个 Text 节点，避免每字一个视图；
/// 5. **独立轻量时钟**：歌词页激活时才启动 0.1s Timer 驱动本地 `liveProgress`，
///    不触碰 PlayerManager 的全局 0.5s 观察者，避免锁屏/进度条等无关视图被连带刷新。
struct LyricView: View {
    let lines: [KRCLine]
    /// 外部进度（秒）：播放页传入，包含拖动条 scrub 预览位置
    let progress: Double
    let tint: Color

    @State private var liveProgress: Double = 0
    @State private var timer: Timer?

    /// 播放跟随：外部进度与本地时钟相差 <0.6s 视为正常播放，用 0.1s 粒度本地值平滑逐字高亮；
    /// 差异大（拖动 scrub 预览）则优先外部值。
    private var displayProgress: Double {
        abs(progress - liveProgress) < 0.6 ? liveProgress : progress
    }

    /// 当前行索引（-1 = 尚未到第一行歌词）
    private var currentLineIndex: Int {
        guard !lines.isEmpty else { return -1 }
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].start <= displayProgress { lo = mid + 1 } else { hi = mid }
        }
        return lo - 1
    }

    /// 当前行内正在唱的字索引；-1 = 该行已唱完（间隙）或无活动字
    private var activeWordIndex: Int {
        let lineIdx = currentLineIndex
        guard lineIdx >= 0 else { return -1 }
        let ws = lines[lineIdx].words
        guard !ws.isEmpty else { return -1 }
        for i in ws.indices where ws[i].start <= displayProgress && displayProgress < ws[i].end {
            return i
        }
        // 未命中：已唱完（进度越过行尾）→ -1 表示整行已唱；否则兜底第一字
        return displayProgress >= (ws.last?.end ?? 0) ? -1 : 0
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 14) {
                    ForEach(lines.indices, id: \.self) { i in
                        KRCWordLineView(
                            line: lines[i],
                            isCurrent: i == currentLineIndex,
                            activeWordIndex: i == currentLineIndex ? activeWordIndex : -1,
                            tint: tint
                        )
                        .equatable()
                        .id(i)
                    }
                }
                .padding(.vertical, 110)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: currentLineIndex) { idx in
                guard idx >= 0 else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
        }
        .onAppear(perform: startTimer)
        .onDisappear(perform: stopTimer)
    }

    // MARK: - 0.1s 轻量进度时钟（仅歌词页激活期间运行）

    private func startTimer() {
        guard timer == nil else { return }
        liveProgress = PlayerManager.shared.currentTime
        let t = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.liveProgress = PlayerManager.shared.currentTime
        }
        // .common 模式：拖动歌词/滚动时不暂停，保证逐字高亮连续
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - 单行歌词（逐字着色，Equatable 局部刷新）

private struct KRCWordLineView: View, Equatable {
    let line: KRCLine
    let isCurrent: Bool
    let activeWordIndex: Int
    let tint: Color

    var body: some View {
        Text(attributedText)
            .font(.system(size: 16))
            .multilineTextAlignment(.center)
            .lineLimit(nil)
            .frame(maxWidth: .infinity)
    }

    /// 逐字 AttributedString：每字独立前景色，一行仅一个 Text 节点
    private var attributedText: AttributedString {
        var out = AttributedString()
        for (i, w) in line.words.enumerated() {
            var run = AttributedString(w.text)
            run.foregroundColor = wordColor(i)
            out += run
        }
        if out.isEmpty { out = AttributedString(" ") }
        return out
    }

    private func wordColor(_ i: Int) -> Color {
        guard isCurrent else { return tint.opacity(0.4) }   // 非当前行：统一弱化
        if activeWordIndex < 0 { return tint.opacity(0.85) } // 当前行已唱完（间隙）
        if i < activeWordIndex { return tint.opacity(0.85) } // 已唱
        if i == activeWordIndex { return .white }            // 正在唱：纯白高亮
        return tint.opacity(0.4)                             // 未唱
    }
}
