import SwiftUI
import UIKit

// MARK: - 播放页左侧抽屉侧边栏（参照汽水音乐风格）

/// 播放页右滑 / 点左上角音符打开的侧边栏：
/// 顶部「听歌模式」标题 + 三个模式大按钮 + 3 列功能入口网格。
/// 深色极简，无阴影渐变，与 App 整体主题一致。
struct SidebarView: View {
    @EnvironmentObject private var player: PlayerManager
    /// 点遮罩 / 左滑关闭
    var onClose: () -> Void

    /// 侧边栏宽度（约屏宽 85%）
    private let panelWidth = UIScreen.main.bounds.width * 0.85

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                modeButtons
                grid
                Spacer(minLength: 0)
            }
            .frame(width: panelWidth)
            .background(panelBackground)

            // 右侧填充，把遮罩露出来
            Color.clear
        }
        .ignoresSafeArea()
        // 侧边栏打开时，左滑关闭
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { v in
                    if v.translation.width < -50 { onClose() }
                }
        )
    }

    // MARK: - 背景色：跟随当前歌曲封面主色（比播放页再暗一档）

    /// 播放页背景 = 封面主色×0.4；侧边栏再压暗到 0.3，更沉浸。
    /// 封面加载中/无封面时回退到固定深灰。
    private var panelBackground: Color {
        if let ui = player.playerCardDominant {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ui.getRed(&r, green: &g, blue: &b, alpha: &a)
            let factor: CGFloat = 0.3
            return Color(red: r * factor, green: g * factor, blue: b * factor)
        }
        return Color(red: 0.11, green: 0.11, blue: 0.12)
    }

    // MARK: - 顶部标题

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("听歌模式")
                .font(.system(size: 28, weight: .heavy))
                .foregroundColor(.white)
            Text("登录后推荐更精准 ›")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 54)
        .padding(.bottom, 24)
    }

    // MARK: - 三个模式大按钮

    private var modeButtons: some View {
        VStack(spacing: 12) {
            ForEach(ListenMode.allCases, id: \.self) { mode in
                SidebarModeButton(
                    title: mode.rawValue,
                    icon: mode.icon,
                    selected: player.listenMode == mode
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        player.applyListenMode(mode)
                    }
                    onClose()
                }
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - 3 列功能入口网格

    private var grid: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 0),
                    GridItem(.flexible(), spacing: 0),
                    GridItem(.flexible(), spacing: 0)
                ],
                spacing: 26
            ) {
                // 第一行
                gridItem(icon: "crown", title: "会员专区") {}
                gridItem(icon: "play.rectangle", title: "音乐视频") {}
                gridItem(icon: "waveform", title: "超清全景声") {}
                // 第二行
                gridItem(icon: "bus", title: "通勤必听") {}
                gridItem(icon: "car", title: "驾车") {}
                gridItem(icon: "sun.max", title: "起床") {}
                // 第三行
                gridItem(icon: "moon.zzz", title: "深夜 EMO") {}
                gridItem(icon: "hifispeaker", title: "DJ 模式") {}
                gridItem(icon: "moon.stars", title: "助眠模式") {}
                // 第四行
                gridItem(icon: "figure.run", title: "动感健身") {}
                gridItem(icon: "music.note", title: "抖音漫游") {}
                gridItem(icon: "drop.fill", title: "洗澡") {}

                // 第五行
                gridItem(icon: "leaf", title: "Chill 放松") {}
                gridItem(icon: "face.smiling", title: "快乐时光") {}
                gridItem(icon: "music.mic", title: "电音") {}
            }
            .padding(.horizontal, 16)
            .padding(.top, 30)
        }
    }

    private func gridItem(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundColor(.white.opacity(0.9))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 模式大按钮

private struct SidebarModeButton: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundColor(selected ? .black : .white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(selected ? Color.white : Color.white.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
