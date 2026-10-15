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

    /// 当前歌词展示模式（Folia 多模式，持久化记忆）
    @State private var selectedMode: LyricDisplayMode = LyricModeStore.current
    /// 模式选择面板
    @State private var showModePicker = false

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
                    // 歌词展示模式切换（Folia 多模式）
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { showModePicker = true }
                    } label: {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(.plain)
                    Button {
                        // 退出全屏：只复位方向授权并关闭；竖屏转回由 fullScreenCover
                        // onDismiss 兜底执行（避免 setValue 与 dismiss 同帧竞态导致按钮无响应）。
                        FullScreenOrientation.shared.isFullScreen = false
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
                // 确保顶栏永远在最上层、按钮命中区域明确
                .zIndex(10)
                .allowsHitTesting(true)

                Spacer(minLength: 6)

                // 中央：按歌词展示模式渲染（8 种 Folia 风格，见 LyricModes.swift）
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
                        switch selectedMode {
                        case .tilt:
                            TiltLyricView(lines: lines,
                                          progress: player.progress * player.duration)
                        case .diorama:
                            DioramaLyricView(lines: lines,
                                             progress: player.progress * player.duration,
                                             seed: track.id)
                        case .partita:
                            PartitaLyricView(lines: lines,
                                             progress: player.progress * player.duration)
                        case .lumiere:
                            LumiereLyricView(lines: lines,
                                             progress: player.progress * player.duration)
                        case .pendolo:
                            PendoloLyricView(lines: lines,
                                             progress: player.progress * player.duration)
                        case .cadenza:
                            CadenzaLyricView(lines: lines,
                                             progress: player.progress * player.duration)
                        case .monet:
                            MonetLyricView(lines: lines,
                                           progress: player.progress * player.duration)
                        case .cappella:
                            CappellaLyricView(lines: lines,
                                              progress: player.progress * player.duration)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.leading, max(safeArea.leading, 0) + 20)
                .padding(.trailing, max(safeArea.trailing, 0) + 20)
                // 裁剪保护：任何模式下歌词都不会溢出屏幕外
                .clipped()
                // 相机运镜仅由镜台（Diorama）模式内部承载，其余模式保持平正排版

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
        // 沿用播放页的沉浸式状态栏方式：不隐藏状态栏，背景铺满、内容在安全区内
        .preferredColorScheme(.dark)
        .background(Color.black)
        // 歌词展示模式切换浮层（页面内 overlay，不依赖 sheet）
        .overlay {
            if showModePicker {
                LyricModePickerOverlay(selection: $selectedMode, isPresented: $showModePicker)
            }
        }
        .animation(.easeOut(duration: 0.18), value: showModePicker)
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

            // 中央径向光晕：歌词区一束柔光（Folia 光感层次）
            RadialGradient(
                colors: [Color.white.opacity(0.13), Color.white.opacity(0.035), .clear],
                center: .init(x: 0.5, y: 0.44),
                startRadius: 0, endRadius: 460
            )
            .ignoresSafeArea()

            // 三层粒子（远/中/近，漂移速度差 = 视差，越近越大越快越亮）
            ParticleLayer(count: 12, sizeRange: 30...72, drift: 4.5, opacity: 0.07)  // 远：大而慢
            ParticleLayer(count: 18, sizeRange: 12...26, drift: 10.0, opacity: 0.11) // 中
            ParticleLayer(count: 26, sizeRange: 4...12, drift: 22.0, opacity: 0.15)  // 近：小而快
        }
        .ignoresSafeArea()
    }

    private func fmt(_ s: Double) -> String {
        let t = max(Int(s), 0)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - 相机运动：整个歌词场景缓慢视角转动 + 镜头推拉平移

/// 模拟"运镜对准歌词"（Folia diorama CameraRig 概念）：Y/X 双频正弦微旋转（扫视）
/// + 镜头推拉呼吸（接近/退后）+ 横向纵向游移（平移），三种运动叠加出相机缓缓
/// 运动过去、最终正对当前句的沉浸感。幅度克制，不干扰阅读。
/// 目前仅镜台（Diorama）模式承载。
struct CameraMotion: ViewModifier {
    func body(content: Content) -> some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            // 扫视（旋转）：主频大弧度 + 次频小抖动
            let camY = sin(t * 0.11) * 3.2 + sin(t * 0.23 + 1.7) * 0.8   // 左右缓转 + 微抖
            let camX = sin(t * 0.083 + 1.3) * 2.0 + sin(t * 0.17) * 0.5  // 俯仰缓转 + 微抖
            // 推拉（zoom 呼吸）：镜头缓慢接近再退回，当前句始终正对屏幕
            let zoom = 1.0 + 0.015 * sin(t * 0.13 + 0.6)
            // 平移（游移）：横向纵向轻微位移，镜头"走过去"的体感
            let panX = CGFloat(sin(t * 0.09 + 2.1) * 10.0)
            let panY = CGFloat(sin(t * 0.07 + 0.4) * 6.0)
            content
                .scaleEffect(zoom)
                .rotation3DEffect(.degrees(camY), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                .rotation3DEffect(.degrees(camX), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
                .offset(x: panX, y: panY)
        }
    }
}

// MARK: - 视差粒子光斑层

/// Canvas 绘制确定性伪随机光斑：位置由 sin-hash 决定（不跳动），
/// 随时间缓慢漂移（drift 越大越"近"、视差越明显）+ 每颗粒子独立呼吸（透明度正弦微变），
/// 多层叠加出镜头移动感与灵动光感。
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
                    // 呼吸：每颗粒子亮度独立缓慢起伏（不同相位）
                    let breathe = 0.7 + 0.3 * sin(t * 0.6 + r3 * 6.28)
                    let d = sizeRange.lowerBound + r3 * (sizeRange.upperBound - sizeRange.lowerBound)
                    let path = Path(ellipseIn: CGRect(x: px - d / 2, y: py - d / 2, width: d, height: d))
                    out.fill(path, with: .color(.white.opacity(opacity * breathe)))
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func fract(_ x: Double) -> Double { x - floor(x) }
}
