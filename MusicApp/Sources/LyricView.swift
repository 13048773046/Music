import SwiftUI

// MARK: - LRC 歌词模型

struct LyricLine: Identifiable {
    let id = UUID()
    let time: Double  // 秒
    let text: String
}

/// 解析 LRC 格式歌词文本
func parseLRC(_ lrcText: String) -> [LyricLine] {
    var lines: [LyricLine] = []
    let regex = try? NSRegularExpression(pattern: "\\[(\\d+):(\\d+)(?:[.:](\\d+))?\\]")
    for raw in lrcText.components(separatedBy: .newlines) {
        guard let regex else { break }
        let nsRange = NSRange(raw.startIndex..., in: raw)
        var lastEnd = raw.startIndex
        var times: [Double] = []
        regex.enumerateMatches(in: raw, range: nsRange) { m, _, _ in
            guard let m = m else { return }
            let mm = (raw as NSString).substring(with: m.range(at: 1))
            let ss = (raw as NSString).substring(with: m.range(at: 2))
            let ff = m.range(at: 3).location != NSNotFound
                ? Double((raw as NSString).substring(with: m.range(at: 3))) ?? 0
                : 0
            let sec = (Double(mm) ?? 0) * 60 + (Double(ss) ?? 0) + ff / (ff >= 10 ? 100 : 1000)
            times.append(sec)
            if let r = Range(m.range, in: raw) { lastEnd = r.upperBound }
        }
        let text = String(raw[lastEnd...]).trimmingCharacters(in: .whitespaces)
        for t in times {
            lines.append(LyricLine(time: t, text: text))
        }
    }
    return lines.sorted { $0.time < $1.time }
}

// MARK: - 歌词视图

struct LyricView: View {
    let lines: [LyricLine]
    let progress: Double  // 当前播放进度（秒）
    let tint: Color

    /// 当前应该高亮的歌词行索引
    private var currentIndex: Int {
        guard !lines.isEmpty else { return -1 }
        var idx = 0
        for (i, line) in lines.enumerated() where line.time <= progress {
            idx = i
        }
        return idx
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 16) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: i == currentIndex ? 17 : 14,
                                          weight: i == currentIndex ? .bold : .medium))
                            .foregroundColor(i == currentIndex ? tint : tint.opacity(0.4))
                            .multilineTextAlignment(.center)
                            .id(i)
                    }
                }
                .padding(.vertical, 120)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: currentIndex) { _, newIdx in
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(newIdx, anchor: .center)
                }
            }
        }
    }
}
