import SwiftUI
import AVFoundation
import UIKit

/// 全屏沉浸式歌词（Folia 式 3D 版，横屏）
///
/// 视觉语言对齐 Folia 的 3D 歌词模式：
/// - 行间透视：歌词按「距当前句的句差」做 X 轴旋转 + 缩放 + 透明度衰减，
///   当前句正面居中，前后句向后上方/下方翻折，形成空间纵深；
/// - 视角转动（相机）：整个歌词场景随时间做缓慢的 Y/X 轴正弦微旋转（perspective），
///   背景粒子层以不同速度漂移形成视差，模拟镜头缓移；
/// - 逐字卡拉OK高亮保留：当前句按毫秒级字时间戳从左到右填充。
///
/// 说明：WebGL 粒子/滤镜级效果无法在 SwiftUI 像素级复刻，
/// 这里用 SwiftUI 3D 变换 + Canvas 粒子实现同款视觉语言，细节可继续迭代。
struct FullScreenLyricView: View {
    let track: Track
    let lines: [KRCLine]

    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss

    /// 横屏安全区：刘海在左右两侧，顶部/底部为 0；所有控件避开刘海。
    /// 与播放页一致从 keyWindow 读取真实 inset（Environment safeAreaInsets 在部分
    /// Xcode/SDK 组合下 keyPath 推断失败，改用 UIKit 直读，iOS 16 全兼容）。
    private var safeArea: EdgeInsets {
        let i = (UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene)?
            .windows.first(where: { $0.isKeyWindow })?
            .safeAreaInsets ?? .zero
        return EdgeInsets(top: i.top, leading: i.left, bottom: i.bottom, trailing: i.right)
    }

    /// 背景：封面主色压暗（横屏深底白字沉浸）
    private var baseColor: Color {
        if let d = player.playerCardDominant {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            d.getRed(&r, green: &g, blue: &b, alpha: &a)
            return Color(red: r * 0.28, green: g * 0.28, blue: b * 0.28, opacity: a)
        }
        return Color(hex: 0x121214)
    }

    var body: some View {
        ZStack {
            // 背景：主色渐变 + 视差粒子光斑（相机缓移感）
            background

            VStack(spacing: 0) {
                // 顶部：歌名/歌手（左）+ 关闭（右）
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(track.artist.flatMap { $0.isEmpty ? nil : $0 } ?? "未知歌手")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button {
                        // 退出全屏：先复位全局方向授权 + 强制转回竖屏，再关闭。
                        // 不能只靠 dismiss 后主界面 OrientationVC 的 viewWillAppear——
                        // 它作为 child controller 不会被触发，设备会停在横屏。
                        FullScreenOrientation.shared.isFullScreen = false
                        UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, max(safeArea.leading, 0) + 24)
                .padding(.trailing, max(safeArea.trailing, 0) + 20)
                .padding(.top, safeArea.top + 8)

                Spacer(minLength: 6)

                // 中央：3D 透视歌词（相机微转）
                ZStack {
                    if lines.isEmpty {
                        VStack(spacing: 12) {
                            Text(track.artist.flatMap { $0.isEmpty ? nil : $0 } ?? "未知歌手")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.white.opacity(0.55))
                            Text("该歌曲暂无歌词")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(.white.opacity(0.45))
                        }
                    } else {
                        FullScreen3DLyricView(lines: lines, fontSize: 32)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.leading, max(safeArea.leading, 0) + 12)
                .padding(.trailing, max(safeArea.trailing, 0) + 12)
                .modifier(CameraMotion())   // 视角转动（相机缓移）

                // 底部：时间 + 进度
                VStack(spacing: 8) {
                    HStack {
                        Text(fmt(player.progress * player.duration))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                            .monospacedDigit()
                        Spacer()
                        Text(fmt(player.duration))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                            .monospacedDigit()
                    }
                    // 细进度条
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.16))
                            Capsule().fill(Color.white.opacity(0.85))
                                .frame(width: max(4, g.size.width * min(max(player.progress, 0), 1)))
                        }
                    }
                    .frame(height: 3)
                }
                .padding(.leading, max(safeArea.leading, 0) + 26)
                .padding(.trailing, max(safeArea.trailing, 0) + 26)
                .padding(.bottom, max(safeArea.bottom, 0) + 16)
            }
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        .background(Color.black)
        // 兜底：无论以何种方式退出全屏，都复位全局横屏授权（AppDelegate 恢复竖屏）
        .onDisappear {
            FullScreenOrientation.shared.isFullScreen = false
        }
    }

    // MARK: - 背景层：主色渐变 + 双层视差粒子

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [baseColor, baseColor.opacity(0.8), Color.black.opacity(0.6)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // 两层粒子：大而慢（远） + 小而快（近），漂移速度差 = 视差
            ParticleLayer(count: 14, sizeRange: 26...64, drift: 5.0, opacity: 0.10)
            ParticleLayer(count: 22, sizeRange: 6...16, drift: 16.0, opacity: 0.16)
        }
        .ignoresSafeArea()
    }

    private func fmt(_ s: Double) -> String {
        let t = max(Int(s), 0)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - 3D 透视歌词（旋转木马式行间翻折 + 逐字卡拉OK）

/// 当前句正面居中；按句差做 X 轴旋转/缩放/透明衰减，形成纵深。
/// 切句平滑滚动沿用 LyricPreview 的单调滚动模型（无回弹）。
struct FullScreen3DLyricView: View {
    let lines: [KRCLine]
    var fontSize: CGFloat = 32

    @EnvironmentObject private var player: PlayerManager

    // 行间距（随字号）：当前句与下一句的垂直间隔
    private var rowGap: CGFloat { fontSize * 1.42 }
    // 每句差的旋转角（度）：距当前句每远一句多转 24°，向纵深翻折
    private let anglePerLine: Double = 24
    // 距当前句越远，缩放越小（纵深衰减）
    private var farScale: Double { 0.55 }
    // 切句滚动时长
    private static let scrollDuration: Double = 0.28

    private final class Tracker { var maxT: Double = 0; var lastC: Int = -2 }
    @State private var tracker = Tracker()

    private func displayTime() -> Double {
        if PlayerManager.shared.usingEngine { return player.progress * player.duration }
        let now = CMTimeGetSeconds(PlayerManager.shared.player.currentTime())
        let safe = now.isFinite ? now : 0
        let ext = player.progress * player.duration
        return abs(ext - safe) < 0.6 ? safe : ext
    }

    private func currentIndex(_ display: Double) -> Int {
        guard !lines.isEmpty else { return -1 }
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].start <= display { lo = mid + 1 } else { hi = mid }
        }
        return lo - 1
    }

    private func advanceTracker(c: Int, display: Double) {
        if c != tracker.lastC {
            tracker.lastC = c
            tracker.maxT = 0
        }
        let tRaw = c > 0 ? min(max((display - lines[c].start) / Self.scrollDuration, 0), 1) : 1
        if tRaw > tracker.maxT { tracker.maxT = tRaw }
    }

    var body: some View {
        TimelineView(.animation) { _ in
            let display = displayTime()
            let c = currentIndex(display)
            let _ = advanceTracker(c: c, display: display)
            let t = max(c > 0 ? min(max((display - lines[c].start) / Self.scrollDuration, 0), 1) : 1,
                        tracker.maxT)
            let eased = c > 0 ? 1 - (1 - t) * (1 - t) * (1 - t) : 0
            let scrolling = c > 0 && t < 1
            let base = scrolling ? c - 1 : c
            // 滚动期间整体上移一步，新句从下方滑入
            let offsetY = scrolling ? -rowGap * eased : 0

            ZStack(alignment: .center) {
                // 显示窗口：当前句 ±2 句（滚动期间再多带一句旧行）
                ForEach((base - 1)..<(base + 4), id: \.self) { li in
                    if lines.indices.contains(li) {
                        lyricRow(li: li, c: c, display: display, eased: eased)
                    }
                }
            }
            .offset(y: offsetY)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 单行 3D 呈现：句差 → 旋转角 / 缩放 / 透明度 / 垂直错位
    @ViewBuilder
    private func lyricRow(li: Int, c: Int, display: Double, eased: Double) -> some View {
        let line = lines[li]
        let d = Double(li - c)              // 句差：0=当前句，正=下一句方向
        let isCurrent = li == c
        let isOld = li == c - 1

        // 切句滚动期间：新句（原下一句）从远到近推进，旧句同步退远淡出
        let scrollIn = isCurrent && eased > 0 ? (1 - eased) : 0.0
        let scrollOut = isOld && eased > 0 ? eased : 0.0
        let effD = d + scrollIn - scrollOut  // 平滑推进/退后

        let angle = effD * anglePerLine
        let scale = isCurrent
            ? (0.78 + 0.22 * (1 - scrollIn))          // 新句从 0.78 放大到 1.0
            : max(farScale, 1.0 - abs(effD) * 0.22)
        let opacity = isCurrent
            ? (0.35 + 0.65 * (1 - scrollIn))
            : max(0.10, 1.0 - abs(effD) * 0.30)
        let yOff = effD * rowGap

        LyricRowView(
            line: line,
            currentTime: li <= c ? display : -1,       // 当前句/已唱句：逐字/全白；预备句：灰
            scale: scale,
            opacity: opacity,
            tint: .white,
            fontSize: fontSize
        )
        .rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0), perspective: 0.35)
        .offset(y: yOff)
        .zIndex(Double(-abs(li - c)))                  // 近句在上层
    }
}

// MARK: - 相机运动：整个歌词场景缓慢视角转动

/// 随时间做 Y/X 轴正弦微旋转（perspective 透视），模拟镜头缓移；
/// 旋转幅度小（±2.5°/±1.5°），不干扰阅读。
private struct CameraMotion: ViewModifier {
    func body(content: Content) -> some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let camY = sin(t * 0.11) * 2.4        // 左右缓转
            let camX = sin(t * 0.083 + 1.3) * 1.5 // 俯仰缓转
            content
                .rotation3DEffect(.degrees(camY), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
                .rotation3DEffect(.degrees(camX), axis: (x: 1, y: 0, z: 0), perspective: 0.45)
        }
    }
}

// MARK: - 视差粒子光斑层

/// Canvas 绘制确定性伪随机光斑：位置由 sin-hash 决定（不跳动），
/// 随时间缓慢漂移（drift 越大越"近"、视差越明显），双层叠加出镜头移动感。
private struct ParticleLayer: View {
    let count: Int
    let sizeRange: ClosedRange<CGFloat>
    let drift: CGFloat
    let opacity: Double

    var body: some View {
        TimelineView(.animation) { ctx in
            Canvas { out, size in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let w = size.width, h = size.height
                for i in 0..<count {
                    // 确定性伪随机（sin-hash），每帧位置稳定
                    let r1 = fract(sin(Double(i) * 12.9898) * 43758.5453)
                    let r2 = fract(sin(Double(i) * 78.233) * 12543.123)
                    let r3 = fract(sin(Double(i) * 39.19) * 2999.991)
                    let baseX = r1 * w
                    let baseY = r2 * h
                    // 漂移：横向缓慢往复 + 纵向极缓下落，伪"镜头移动"
                    let dx = drift * (sin(t * 0.14 + r1 * 6.28))
                    let dy = drift * 0.35 * sin(t * 0.09 + r2 * 6.28)
                    let px = baseX + dx
                    let py = baseY + dy
                    let d = sizeRange.lowerBound + r3 * (sizeRange.upperBound - sizeRange.lowerBound)
                    let path = Path(ellipseIn: CGRect(x: px - d / 2, y: py - d / 2, width: d, height: d))
                    out.fill(path, with: .color(.white.opacity(opacity)))
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func fract(_ x: Double) -> Double { x - floor(x) }
}
