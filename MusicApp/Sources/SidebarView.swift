import SwiftUI
import UIKit

// MARK: - 播放页左侧抽屉侧边栏（参照汽水音乐风格）

/// 播放页右滑 / 点左上角音符打开的侧边栏：
/// 顶部品牌区（Logo + 登录态）→「听歌模式」三个模式大按钮 →「场景音乐」网格 → 底部版本。
/// 背景跟随当前歌曲封面主色（比播放页更暗一档），深色极简，无阴影渐变，与 App 整体主题一致。
struct SidebarView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthManager
    /// 预加载器：启动页阶段已并行拉取「我的作品」总数（worksTotal），侧滑栏据此显示/隐藏"我的作品"模式
    @ObservedObject private var preloader = AppPreloader.shared
    /// 点遮罩 / 左滑关闭
    var onClose: () -> Void

    /// 侧边栏宽度（约屏宽 85%）
    private let panelWidth = UIScreen.main.bounds.width * 0.85

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                brandHeader
                sectionTitle("听歌模式")
                modeButtons
                sectionTitle("场景音乐")
                grid
                Spacer(minLength: 0)
                footer
            }
            .frame(width: panelWidth)
            .background(panelBackground)

            // 右侧填充，把遮罩露出来
            Color.clear
        }
        .ignoresSafeArea()
        // 开合手势统一由 MainTabView 的全局跟手手势控制（拖动侧边栏区域同样跟手），
        // 这里不再挂独立手势，避免与全局手势冲突导致卡顿
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

    // MARK: - 顶部品牌区

    private var brandHeader: some View {
        HStack(spacing: 12) {
            Image("AppLogo")
                .resizable()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("流萤音乐")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 54)
        .padding(.bottom, 26)
    }

    private var subtitle: String {
        if let u = auth.currentUser {
            if let sig = u.signature, !sig.isEmpty { return sig }
            return u.name.isEmpty ? "已登录" : u.name
        }
        return "登录后推荐更精准"
    }

    // MARK: - 分区小标题

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white.opacity(0.45))
            .padding(.horizontal, 22)
            .padding(.bottom, 10)
    }

    // MARK: - 三个模式大按钮

    private var modeButtons: some View {
        VStack(spacing: 10) {
            // 无上传作品的用户不显示「我的作品」模式（预加载阶段 worksTotal 已就绪；上传后 MineView 同步刷新实时出现）
            ForEach(ListenMode.allCases.filter { $0 != .works || preloader.worksTotal > 0 }, id: \.self) { mode in
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

    // MARK: - 场景音乐网格

    private var grid: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                spacing: 22
            ) {
                gridItem(icon: "bus", title: "通勤必听") {}
                gridItem(icon: "car", title: "驾车") {}
                gridItem(icon: "sun.max", title: "起床") {}
                gridItem(icon: "moon.zzz", title: "深夜 EMO") {}
                gridItem(icon: "hifispeaker", title: "DJ 模式") {}
                gridItem(icon: "moon.stars", title: "助眠模式") {}
                gridItem(icon: "figure.run", title: "动感健身") {}
                gridItem(icon: "music.note", title: "抖音漫游") {}
                gridItem(icon: "drop.fill", title: "洗澡") {}
                gridItem(icon: "leaf", title: "Chill 放松") {}
                gridItem(icon: "face.smiling", title: "快乐时光") {}
                gridItem(icon: "music.mic", title: "电音") {}
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 8)
        }
    }

    private func gridItem(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
                    .frame(width: 46, height: 46)
                    .background(
                        Color.white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 底部版本信息

    private var footer: some View {
        HStack(spacing: 6) {
            Text("流萤音乐")
            Text("·")
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
        }
        .font(.system(size: 11))
        .foregroundColor(.white.opacity(0.35))
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
    }
}

// MARK: - 模式大按钮

/// 选中态：薄荷绿图标底 + 整行淡绿底 + 右侧对勾；未选中：半透明白图标底 + 弱化整行底
private struct SidebarModeButton: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(selected ? Color(hex: 0x121214) : .white.opacity(0.85))
                    .frame(width: 38, height: 38)
                    .background(
                        selected ? Theme.accent : Color.white.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )

                Text(title)
                    .font(.system(size: 16, weight: selected ? .bold : .semibold))
                    .foregroundColor(.white)

                Spacer(minLength: 0)

                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Theme.accent)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 58)
            .background(
                selected ? Theme.accent.opacity(0.16) : Color.white.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}
