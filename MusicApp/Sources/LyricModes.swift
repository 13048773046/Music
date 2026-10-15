import SwiftUI
import AVFoundation

// MARK: - 歌词显示模式（对标 Folia 多模式歌词）

/// 全屏歌词 8 种展示模式，切换后全局记忆（下次打开保持）。
/// 每种模式共用同一时间/索引驱动，仅呈现方式不同。
enum LyricDisplayMode: String, CaseIterable, Identifiable {
    case tilt3D = "浮名"      // 3D 行间翻折（旋转木马纵深）
    case classic = "云阶"     // 经典居中滚动
    case lumiere = "流光"     // 逐字白→金渐变流光
    case cadenza = "倾诉"     // 聚焦大字 + 呼吸浮动
    case partita = "群唱"     // 多行合唱平铺
    case specchio = "镜台"    // 歌词倒影
    case pendolo = "时计"     // 逐字点亮 + 扫光条
    case monet = "心象"       // 柔和光晕呼吸

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .tilt3D: return "cube"
        case .classic: return "list.number"
        case .lumiere: return "sparkles"
        case .cadenza: return "textformat.size"
        case .partita: return "person.3.fill"
        case .specchio: return "rectangle.on.rectangle"
        case .pendolo: return "clock.fill"
        case .monet: return "circle.hexagongrid.fill"
        }
    }
}

/// 模式记忆：UserDefaults 持久化
enum LyricModeStore {
    private static let key = "lyric_display_mode"
    static var current: LyricDisplayMode {
        get {
            let raw = UserDefaults.standard.string(forKey: key) ?? ""
            return LyricDisplayMode(rawValue: raw) ?? .tilt3D
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}

// MARK: - 公共时间驱动（全屏歌词各模式共用）

/// 播放跟随时间：引擎音效模式（AVPlayer 无 currentItem 时间恒 0）直接取外部进度
func lyricDisplayTime(_ progress: Double) -> Double {
    let pm = PlayerManager.shared
    if pm.usingEngine { return progress }
    let now = CMTimeGetSeconds(pm.player.currentTime())
    let safe = now.isFinite ? now : 0
    return abs(progress - safe) < 0.6 ? safe : progress
}

/// 二分定位当前歌词行索引（-1 = 尚未到第一行）
func lyricCurrentIndex(_ display: Double, lines: [KRCLine]) -> Int {
    guard !lines.isEmpty else { return -1 }
    var lo = 0, hi = lines.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if lines[mid].start <= display { lo = mid + 1 } else { hi = mid }
    }
    return lo - 1
}

// MARK: - 云阶：经典居中滚动

/// 当前句居中白色大字，上下句灰色小字；切句整组平滑上滚（Folia 经典样式）。
struct ClassicLyricView: View {
    let lines: [KRCLine]
    let progress: Double
    var fontSize: CGFloat = 30

    private var rowHeight: CGFloat { fontSize * 1.25 }
    private var rowGap: CGFloat { fontSize * 0.55 }
    private var viewRows: Int { 5 }                 // 显示窗口行数
    private var step: CGFloat { rowHeight + rowGap }
    private static let scrollDuration: Double = 0.3

    private final class Tracker { var maxT: Double = 0; var lastC: Int = -2 }
    @State private var tracker = Tracker()

    var body: some View {
        TimelineView(.animation) { _ in
            let display = lyricDisplayTime(progress)
            let c = lyricCurrentIndex(display, lines: lines)
            // 滚动推进：切句瞬间归零，之后只增不减（防 TimeLineView 乱序回跳）
            let raw = c > 0 ? min(max((display - lines[c].start) / Self.scrollDuration, 0), 1) : 1
            let t = advance(raw, c)
            let eased = 1 - (1 - t) * (1 - t) * (1 - t)
            let base = (c > 0 && t < 1) ? c - 1 : c
            let offsetY = (c > 0 && t < 1) ? -step * eased : 0

            VStack(spacing: rowGap) {
                ForEach(0..<viewRows, id: \.self) { idx in
                    let li = base + idx - (viewRows / 2)
                    if lines.indices.contains(li) {
                        let line = lines[li]
                        let isCurrent = li == c
                        let isOld = li == c - 1
                        LyricRowView(
                            line: line,
                            currentTime: li <= c ? display : -1,
                            scale: isCurrent ? 1.0 : 0.8,
                            opacity: isCurrent ? 1.0 : (isOld ? 1 - eased : 0.55),
                            tint: .white,
                            fontSize: isCurrent ? fontSize : fontSize * 0.66,
                            fontWeight: .medium
                        )
                        .frame(height: rowHeight, alignment: .center)
                    } else {
                        Color.clear.frame(height: rowHeight)
                    }
                }
            }
            .offset(y: offsetY)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 滚动推进跟踪：切句归零、单调递增。放在方法里（TimelineView 闭包是 ViewBuilder，
    /// 不能直接写赋值 if）。
    private func advance(_ raw: Double, _ c: Int) -> Double {
        if c != tracker.lastC { tracker.lastC = c; tracker.maxT = 0 }
        tracker.maxT = max(tracker.maxT, raw)
        return tracker.maxT
    }
}

// MARK: - 流光：逐字白→金渐变

/// 已唱部分按白→暖金横向渐变填充（流光质感），未唱部分淡灰；当前句居中大字。
struct LumiereLyricView: View {
    let lines: [KRCLine]
    let progress: Double
    var fontSize: CGFloat = 32

    private static let scrollDuration: Double = 0.28
    private final class Tracker { var maxT: Double = 0; var lastC: Int = -2 }
    @State private var tracker = Tracker()

    var body: some View {
        TimelineView(.animation) { _ in
            let display = lyricDisplayTime(progress)
            let c = lyricCurrentIndex(display, lines: lines)
            let raw = c > 0 ? min(max((display - lines[c].start) / Self.scrollDuration, 0), 1) : 1
            let t = advance(raw, c)
            let eased = 1 - (1 - t) * (1 - t) * (1 - t)
            let base = (c > 0 && t < 1) ? c - 1 : c
            let offsetY = (c > 0 && t < 1) ? -fontSize * 1.8 * eased : 0

            VStack(spacing: fontSize * 1.5) {
                ForEach((base - 1)...(base + 1), id: \.self) { li in
                    if lines.indices.contains(li) {
                        lumiereRow(line: lines[li], li: li, c: c, display: display)
                    }
                }
            }
            .offset(y: offsetY)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func advance(_ raw: Double, _ c: Int) -> Double {
        if c != tracker.lastC { tracker.lastC = c; tracker.maxT = 0 }
        tracker.maxT = max(tracker.maxT, raw)
        return tracker.maxT
    }

    @ViewBuilder
    private func lumiereRow(line: KRCLine, li: Int, c: Int, display: Double) -> some View {
        let isCurrent = li == c
        let isOld = li == c - 1
        ZStack(alignment: .leading) {
            // 统一底色：未唱部分淡灰（当前句略亮）
            Text(line.text)
                .foregroundColor(.white.opacity(isCurrent ? 0.36 : 0.20))
            if isCurrent {
                // 当前句已唱部分：白→暖金渐变（流光）
                Text(line.text)
                    .mask(alignment: .leading) {
                        LinearGradient(
                            colors: [.white, Color(red: 1.0, green: 0.86, blue: 0.45),
                                     Color(red: 1.0, green: 0.72, blue: 0.35)],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: lumiereFilledWidth(line, display))
                    }
            } else if li < c {
                // 已唱背景句：整行点亮（弱化，不叠字）
                Text(line.text)
                    .foregroundColor(.white.opacity(0.55))
            }
        }
        .font(.system(size: isCurrent ? fontSize : fontSize * 0.62, weight: .medium))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .center)
        .opacity(isOld ? 1.0 : (isCurrent ? 1.0 : 0.4))
        .shadow(color: isCurrent ? Color(red: 1.0, green: 0.75, blue: 0.35).opacity(0.30) : .clear,
                radius: 18)
    }

    /// 已唱宽度（复用 LyricRowView 的逐字推进算法）
    private func lumiereFilledWidth(_ line: KRCLine, _ display: Double) -> CGFloat {
        guard display >= 0 else { return 0 }
        let font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
        var w: CGFloat = 0
        for word in line.words {
            let cw = (word.text as NSString).size(withAttributes: [.font: font]).width
            if display >= word.end {
                w += cw
            } else if display >= word.start {
                let span = max(word.end - word.start, 0.001)
                w += cw * min(max((display - word.start) / span, 0), 1)
                break
            } else {
                break
            }
        }
        return w
    }
}

// MARK: - 倾诉：聚焦大字 + 呼吸浮动

/// 当前句超大居中白色 + 轻微呼吸缩放；前后句小字淡出；整组缓慢上下浮动（倾诉感）。
struct CadenzaLyricView: View {
    let lines: [KRCLine]
    let progress: Double
    var fontSize: CGFloat = 40

    var body: some View {
        TimelineView(.animation) { ctx in
            let display = lyricDisplayTime(progress)
            let c = lyricCurrentIndex(display, lines: lines)
            let t = ctx.date.timeIntervalSinceReferenceDate
            let breathe = 1.0 + 0.018 * sin(t * 0.9)          // 呼吸缩放
            let floatY = 5.0 * sin(t * 0.5)                    // 上下浮动

            VStack(spacing: fontSize * 0.75) {
                ForEach((c - 1)...(c + 1), id: \.self) { li in
                    if lines.indices.contains(li) {
                        let isCurrent = li == c
                        let d = abs(li - c)
                        LyricRowView(
                            line: lines[li],
                            currentTime: li <= c ? display : -1,
                            scale: isCurrent ? breathe : (0.75 - Double(d - 1) * 0.15),
                            opacity: isCurrent ? 1.0 : (0.55 - Double(d - 1) * 0.2),
                            tint: .white,
                            fontSize: isCurrent ? fontSize : fontSize * 0.5,
                            fontWeight: isCurrent ? .semibold : .regular
                        )
                    }
                }
            }
            .offset(y: floatY)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - 群唱：多行合唱平铺

/// 5 行等距平铺，当前行最亮、其余半透明；切句整组平滑上移（合唱齐唱感）。
struct PartitaLyricView: View {
    let lines: [KRCLine]
    let progress: Double
    var fontSize: CGFloat = 26

    private var rowHeight: CGFloat { fontSize * 1.35 }
    private static let scrollDuration: Double = 0.25
    private final class Tracker { var maxT: Double = 0; var lastC: Int = -2 }
    @State private var tracker = Tracker()

    var body: some View {
        TimelineView(.animation) { _ in
            let display = lyricDisplayTime(progress)
            let c = lyricCurrentIndex(display, lines: lines)
            let raw = c > 0 ? min(max((display - lines[c].start) / Self.scrollDuration, 0), 1) : 1
            let t = advance(raw, c)
            let eased = 1 - (1 - t) * (1 - t) * (1 - t)
            let base = (c > 0 && t < 1) ? c - 1 : c
            let offsetY = (c > 0 && t < 1) ? -rowHeight * eased : 0

            VStack(spacing: 6) {
                ForEach(0..<5, id: \.self) { idx in
                    let li = base + idx - 2
                    if lines.indices.contains(li) {
                        let isCurrent = li == c
                        LyricRowView(
                            line: lines[li],
                            currentTime: li <= c ? display : -1,
                            scale: 1.0,
                            opacity: isCurrent ? 1.0 : 0.45,
                            tint: .white,
                            fontSize: isCurrent ? fontSize : fontSize * 0.85,
                            fontWeight: isCurrent ? .semibold : .regular
                        )
                        .frame(height: rowHeight)
                    } else {
                        Color.clear.frame(height: rowHeight)
                    }
                }
            }
            .offset(y: offsetY)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func advance(_ raw: Double, _ c: Int) -> Double {
        if c != tracker.lastC { tracker.lastC = c; tracker.maxT = 0 }
        tracker.maxT = max(tracker.maxT, raw)
        return tracker.maxT
    }
}

// MARK: - 镜台：歌词倒影

/// 当前句居中大字 + 正下方渐变倒影（垂直翻转 + 透明蒙版），镜面沉浸。
struct SpecchioLyricView: View {
    let lines: [KRCLine]
    let progress: Double
    var fontSize: CGFloat = 32

    var body: some View {
        TimelineView(.animation) { _ in
            let display = lyricDisplayTime(progress)
            let c = lyricCurrentIndex(display, lines: lines)
            VStack(spacing: 0) {
                if c >= 0 && c < lines.count {
                    currentRow(lines[c], display, mirrored: false)
                    currentRow(lines[c], display, mirrored: true)
                        .scaleEffect(x: 1, y: -1, anchor: .center)
                        .mask(LinearGradient(
                            colors: [.white.opacity(0.30), .clear],
                            startPoint: .top, endPoint: .bottom
                        ))
                        .padding(.top, 4)
                } else {
                    Text("♪")
                        .font(.system(size: fontSize * 0.8, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func currentRow(_ line: KRCLine, _ display: Double, mirrored: Bool) -> some View {
        LyricRowView(
            line: line,
            currentTime: display,
            scale: 1.0,
            opacity: 1.0,
            tint: .white,
            fontSize: fontSize,
            fontWeight: .semibold
        )
        .shadow(color: .white.opacity(mirrored ? 0 : 0.35), radius: 24)
    }
}

// MARK: - 时计：逐字点亮 + 扫光条

/// 当前句逐字卡拉OK点亮 + 一条纵向扫光随已唱进度横向掠过（秒针感）。
struct PendoloLyricView: View {
    let lines: [KRCLine]
    let progress: Double
    var fontSize: CGFloat = 32

    private final class Tracker { var maxT: Double = 0; var lastC: Int = -2 }
    @State private var tracker = Tracker()

    var body: some View {
        TimelineView(.animation) { _ in
            let display = lyricDisplayTime(progress)
            let c = lyricCurrentIndex(display, lines: lines)
            // 切句归零（tracker 重置），返回单调推进值（本模式仅用于防回跳）
            let raw = c > 0 ? min(max((display - lines[c].start) / 0.25, 0), 1) : 1
            let _ = advance(raw, c)

            ZStack(alignment: .center) {
                if c >= 0 && c < lines.count {
                    let line = lines[c]
                    ZStack(alignment: .leading) {
                        Text(line.text)
                            .foregroundColor(.white.opacity(0.32))
                        Text(line.text)
                            .foregroundColor(.white)
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: filledWidth(line, display))
                            }
                        // 扫光条：已唱边界处一条纵向亮光
                        Text(line.text)
                            .foregroundColor(.clear)
                            .overlay(alignment: .leading) {
                                LinearGradient(
                                    colors: [.clear, .white.opacity(0.85), .clear],
                                    startPoint: .top, endPoint: .bottom
                                )
                                .frame(width: fontSize * 0.55)
                                .offset(x: filledWidth(line, display) - fontSize * 0.27)
                            }
                            .mask(Text(line.text))
                    }
                    .font(.system(size: fontSize, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    Text("♪")
                        .font(.system(size: fontSize * 0.8, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func advance(_ raw: Double, _ c: Int) -> Double {
        if c != tracker.lastC { tracker.lastC = c; tracker.maxT = 0 }
        tracker.maxT = max(tracker.maxT, raw)
        return tracker.maxT
    }

    private func filledWidth(_ line: KRCLine, _ display: Double) -> CGFloat {
        guard display >= 0 else { return 0 }
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        var w: CGFloat = 0
        for word in line.words {
            let cw = (word.text as NSString).size(withAttributes: [.font: font]).width
            if display >= word.end {
                w += cw
            } else if display >= word.start {
                let span = max(word.end - word.start, 0.001)
                w += cw * min(max((display - word.start) / span, 0), 1)
                break
            } else {
                break
            }
        }
        return w
    }
}

// MARK: - 心象：柔和光晕呼吸

/// 当前句大字居中，背景光晕随播放呼吸放大（静谧沉浸）。
/// 歌词行不带 shadow（避免每帧高开销重绘），辉光全部由背景光晕承担。
struct MonetLyricView: View {
    let lines: [KRCLine]
    let progress: Double
    var fontSize: CGFloat = 34

    var body: some View {
        TimelineView(.animation) { ctx in
            let display = lyricDisplayTime(progress)
            let c = lyricCurrentIndex(display, lines: lines)
            let t = ctx.date.timeIntervalSinceReferenceDate
            let glow = 0.5 + 0.5 * sin(t * 0.55)          // 光晕呼吸 0~1

            ZStack(alignment: .center) {
                // 背景光晕（呼吸）
                RadialGradient(
                    colors: [.white.opacity(0.10 + 0.06 * glow), .clear],
                    center: .center, startRadius: 0, endRadius: 360 + 60 * glow
                )
                .frame(width: 700, height: 700)

                VStack(spacing: fontSize * 0.8) {
                    ForEach((c - 1)...(c + 1), id: \.self) { li in
                        if lines.indices.contains(li) {
                            let isCurrent = li == c
                            LyricRowView(
                                line: lines[li],
                                currentTime: li <= c ? display : -1,
                                scale: isCurrent ? 1.0 : 0.7,
                                opacity: isCurrent ? 1.0 : 0.35,
                                tint: .white,
                                fontSize: isCurrent ? fontSize : fontSize * 0.55,
                                fontWeight: isCurrent ? .semibold : .regular
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - 模式选择面板

/// 全屏歌词顶部的模式选择按钮 + 网格面板（2 列 4 行，与音效选择同交互风格）
struct LyricModePickerSheet: View {
    @Binding var selection: LyricDisplayMode
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.flexible(), spacing: 14),
                           GridItem(.flexible(), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("歌词展示")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(Theme.textPrimary)

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(LyricDisplayMode.allCases) { mode in
                    Button {
                        selection = mode
                        LyricModeStore.current = mode
                        dismiss()
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: mode.icon)
                                .font(.system(size: 20))
                                .foregroundColor(selection == mode ? Theme.accent : Theme.textSecondary)
                            Text(mode.rawValue)
                                .font(.system(size: 13, weight: selection == mode ? .semibold : .medium))
                                .foregroundColor(selection == mode ? Theme.accent : Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            (selection == mode ? Theme.accent.opacity(0.14) : Theme.card.opacity(0.6)),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(selection == mode ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .presentationDetents([.height(340)])
        .presentationDragIndicator(.visible)
    }
}
