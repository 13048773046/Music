import SwiftUI

@main
struct MusicApp: App {
    @StateObject private var player = PlayerManager.shared
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                if showSplash {
                    SplashView()
                        .transition(.opacity)
                } else {
                    MainTabView()
                        .environmentObject(player)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    withAnimation(.easeInOut(duration: 0.45)) {
                        showSplash = false
                    }
                }
            }
            // 全局深色外观：状态栏白色文字（浅色封面背景的播放页会局部覆盖为浅色）
            .preferredColorScheme(.dark)
        }
    }
}

/// 页面索引：0=发现音乐 1=首页播放页 2=我的
struct MainTabView: View {
    @State private var selection = 1

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.background.ignoresSafeArea()

            // 内容区：首页为全屏播放页，其余页面内容可从底部导航栏后滑过
            Group {
                switch selection {
                case 0:
                    DiscoverView()
                case 1:
                    HomeView()
                        .ignoresSafeArea()
                default:
                    MineView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 清新浅色悬浮 TabBar：发现音乐 | 播放控制 | 我的
            AppTabBar(selection: $selection)
        }
    }
}

/// 悬浮 TabBar：播放控制居中（首页时显示播放/暂停按钮，其他页面显示当前歌曲封面，点击回首页）
struct AppTabBar: View {
    @EnvironmentObject private var player: PlayerManager
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 0) {
            tabButton(icon: "sparkles", label: "发现音乐", index: 0)

            playControl

            tabButton(icon: "person.crop.circle.fill", label: "我的", index: 2)
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background {
            if selection == 1 {
                // 首页：透明导航栏，悬浮覆盖在播放页之上（播放页背景透出）
                Rectangle().fill(.clear)
            } else {
                // 其他页：深色不透明导航栏，延伸到屏幕最底部，悬浮覆盖在内容之上
                Rectangle()
                    .fill(Theme.card.opacity(0.98))
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Theme.cardBorder).frame(height: 0.5)
                    }
            }
        }
    }

    /// 图标文字颜色：首页时按播放页背景亮度动态（浅背景深字/深背景白字）
    private func tabForeground(selected: Bool) -> Color {
        if selection == 1 {
            if selected { return Theme.accent }
            return player.playerCardBackgroundLight ? Theme.textSecondary : .white.opacity(0.72)
        }
        return selected ? Theme.accent : Theme.textSecondary
    }

    private func tabButton(icon: String, label: String, index: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selection = index
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 21))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(tabForeground(selected: selection == index))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
    }

    /// 播放控制格：首页显示播放/暂停大按钮；其他页面显示当前歌曲封面
    private var playControl: some View {
        Button {
            if selection == 1 {
                player.toggle()
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selection = 1
                }
            }
        } label: {
            Group {
                if selection == 1 {
                    ZStack {
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 46, height: 46)
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                            .offset(x: player.isPlaying ? 0 : 1.5)
                    }
                } else {
                    AlbumArt(
                        size: 44,
                        title: player.current?.title ?? "音乐",
                        coverURL: player.current?.coverURL,
                        radius: 12
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}
