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
            // 全局浅色外观：状态栏深色文字（深色封面背景的页面会局部覆盖）
            .preferredColorScheme(.light)
        }
    }
}

/// 页面索引：0=发现音乐 1=首页播放页 2=我的
struct MainTabView: View {
    @State private var selection = 1

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.background.ignoresSafeArea()

            // 内容区：首页为全屏播放页，其余页面保留系统列表
            Group {
                switch selection {
                case 0:
                    DiscoverView()
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            Color.clear.frame(height: 62)
                        }
                case 1:
                    HomeView()
                        .ignoresSafeArea()
                default:
                    MineView()
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            Color.clear.frame(height: 62)
                        }
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
            // 沉浸式透明导航条
            Rectangle().fill(.clear)
        }
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
            .foregroundColor(selection == index ? Theme.accent : Theme.textSecondary)
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
                            .shadow(color: Theme.accent.opacity(0.35), radius: 8, x: 0, y: 3)
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
