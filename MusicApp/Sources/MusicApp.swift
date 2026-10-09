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
        }
    }
}

struct MainTabView: View {
    @State private var selection = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.background.ignoresSafeArea()

            // 内容区：首页为全屏播放页，其余页面保留系统列表
            Group {
                switch selection {
                case 0:
                    HomeView()
                        .ignoresSafeArea()
                case 1:
                    DiscoverView()
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            Color.clear.frame(height: 62)
                        }
                default:
                    MineView()
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            Color.clear.frame(height: 62)
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 清新浅色悬浮 TabBar
            AppTabBar(selection: $selection)
        }
    }
}

/// 悬浮 TabBar：首页（全屏播放页）上更透明，其余页面浅色毛玻璃
struct AppTabBar: View {
    @Binding var selection: Int

    private let items: [(Int, String, String)] = [
        (0, "首页", "house.fill"),
        (1, "发现音乐", "sparkles"),
        (2, "我的", "person.crop.circle.fill"),
    ]

    private func foreground(for item: Int) -> Color {
        if selection == 0 {
            return selection == item ? Theme.accent : Theme.textTertiary
        }
        return selection == item ? Theme.accent : Theme.textSecondary
    }

    var body: some View {
        HStack {
            ForEach(items, id: \.0) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selection = item.0
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.2)
                            .font(.system(size: 21))
                        Text(item.1)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(foreground(for: item.0))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background {
            if selection == 0 {
                // 播放页上：半透明白，柔和
                Rectangle().fill(.ultraThinMaterial)
            } else {
                Rectangle().fill(.ultraThinMaterial)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Theme.cardBorder).frame(height: 0.5)
                    }
            }
        }
    }
}
