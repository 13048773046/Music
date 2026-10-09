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
            // 内容区：首页为全屏播放页，其余页面保留系统列表
            Group {
                switch selection {
                case 0:
                    HomeView()
                        .ignoresSafeArea()
                case 1:
                    DiscoverView()
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            Color.clear.frame(height: 64)
                        }
                default:
                    MineView()
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            Color.clear.frame(height: 64)
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 透明 Tab 覆盖层
            AppTabBar(selection: $selection)
        }
    }
}

/// 悬浮透明 TabBar：首页（全屏播放页）上完全透明，其余页面半透明毛玻璃
struct AppTabBar: View {
    @Binding var selection: Int

    private let items: [(Int, String, String)] = [
        (0, "首页", "house.fill"),
        (1, "发现音乐", "sparkles"),
        (2, "我的", "person.crop.circle.fill"),
    ]

    private func foreground(for item: Int) -> Color {
        if selection == 0 {
            return selection == item ? .white : .white.opacity(0.55)
        }
        return selection == item ? .purple : .secondary
    }

    var body: some View {
        HStack {
            ForEach(items, id: \.0) { item in
                Button {
                    selection = item.0
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.2)
                            .font(.system(size: 22))
                        Text(item.1)
                            .font(.system(size: 11))
                    }
                    .foregroundColor(foreground(for: item.0))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background {
            if selection == 0 {
                Color.clear
            } else {
                Rectangle().fill(.ultraThinMaterial)
                    .overlay(alignment: .top) {
                        Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5)
                    }
            }
        }
    }
}
