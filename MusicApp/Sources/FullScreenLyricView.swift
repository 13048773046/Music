import SwiftUI

/// 全屏沉浸式歌词（Folia 式）：封面主色深色渐变背景 + 大字号卡拉OK逐字歌词 + 歌名/歌手 + 进度。
/// 入口：播放页「⋮ → 全屏播放」。复用 LyricPreview 的帧驱动滚动 + 逐字填充（大字号参数）。
struct FullScreenLyricView: View {
    let track: Track
    /// 歌词行（播放页已解析并缓存，直接传入）
    let lines: [KRCLine]

    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss

    /// 背景：播放页已提取的封面主色压暗到 35%（深底白字沉浸）；无主色时深色渐变兜底
    private var baseColor: Color {
        if let d = player.playerCardDominant {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            d.getRed(&r, green: &g, blue: &b, alpha: &a)
            return Color(red: r * 0.35, green: g * 0.35, blue: b * 0.35, opacity: a)
        }
        return Color(hex: 0x141416)
    }

    var body: some View {
        ZStack {
            // 背景：主色 → 更暗的纵向渐变，顶部略亮、底部沉入黑色，歌词区域更聚焦
            LinearGradient(
                colors: [baseColor, baseColor.opacity(0.78), Color.black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // 顶部：歌名/歌手（左）+ 关闭（右）
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(track.artist.flatMap { $0.isEmpty ? nil : $0 } ?? "未知歌手")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                            .frame(width: 40, height: 40)
                            .background(Color.white.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.top, 10)

                // 中央：全屏大字号逐字歌词（垂直居中，留出上下呼吸空间）
                Spacer(minLength: 24)
                if lines.isEmpty {
                    // 无歌词：歌手名 + 提示（与播放页占位风格一致）
                    VStack(spacing: 14) {
                        Text(track.artist.flatMap { $0.isEmpty ? nil : $0 } ?? "未知歌手")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                        Text("该歌曲暂无歌词")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    LyricPreview(
                        lines: lines,
                        progress: player.progress * player.duration,
                        tint: .white,
                        fontSize: 30
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)
                }
                Spacer(minLength: 24)

                // 底部：当前时间 / 总时长
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
                .padding(.horizontal, 28)
                .padding(.bottom, 40)
            }
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
    }

    private func fmt(_ s: Double) -> String {
        let t = max(Int(s), 0)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
