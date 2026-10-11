import SwiftUI

@main
struct MusicApp: App {
    @StateObject private var player = PlayerManager.shared
    @StateObject private var auth = AuthManager.shared
    @StateObject private var library = Library.shared
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                if showSplash {
                    SplashView()
                        .transition(.opacity)
                } else if auth.currentUser == nil {
                    LoginView()
                        .environmentObject(auth)
                        .environmentObject(player)
                        .environmentObject(library)
                } else {
                    MainTabView()
                        .environmentObject(player)
                        .environmentObject(auth)
                        .environmentObject(library)
                }
            }
            .onAppear {
                // 启动页期间就并发拉取歌曲列表，进首页即播，减少等待
                Task { await Library.shared.load() }
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
    @EnvironmentObject private var player: PlayerManager
    @State private var selection = 1
    /// 侧边栏实时露出宽度（0 = 完全关闭，panelWidth = 完全打开），由跟手手势实时驱动
    @State private var sidebarDrag: CGFloat = 0

    /// 侧边栏宽度（约屏宽 85%）
    private let panelWidth = UIScreen.main.bounds.width * 0.85

    /// 遮罩透明度进度 0...1
    private var progress: CGFloat { panelWidth > 0 ? sidebarDrag / panelWidth : 0 }

    var body: some View {
        ZStack {
            // 侧边栏：常驻渲染，offset 跟随手势实时滑动（关闭时完全移出屏幕左侧）
            SidebarView(
                onClose: closeSidebar
            )
            .offset(x: sidebarDrag - panelWidth)
            .zIndex(1)
            .allowsHitTesting(sidebarDrag > 0)

            // 主界面（内容区 + 顶部栏 + TabBar），打开侧边栏时整体向右推
            ZStack(alignment: .bottom) {
                Theme.background.ignoresSafeArea()

                // 内容区：三个页面常驻
                Group {
                    ZStack {
                        DiscoverView()
                            .opacity(selection == 0 ? 1 : 0)
                            .allowsHitTesting(selection == 0)
                        HomeView()
                            .ignoresSafeArea()
                            .opacity(selection == 1 ? 1 : 0)
                            .allowsHitTesting(selection == 1)
                        MineView()
                            .opacity(selection == 2 ? 1 : 0)
                            .allowsHitTesting(selection == 2)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 顶部栏只在首页（播放页）展示：切到发现/我的后隐藏，
                // 内容区完全沉浸，不残留全局顶部栏
                if selection == 1 {
                    GlobalTopBar(onOpenSidebar: openSidebar)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .alignmentGuide(.top) { d in d[.top] }
                        .frame(maxHeight: .infinity, alignment: .top)
                }

                AppTabBar(selection: $selection)
            }
            .offset(x: sidebarDrag)
            // 遮罩随侧边栏进度渐显，点击关闭
            .overlay {
                if sidebarDrag > 0 {
                    Color.black.opacity(0.4 * progress)
                        .onTapGesture { closeSidebar() }
                }
            }
        }
        // 全局手势：整个屏幕左右拖动，侧边栏实时跟手；松手按位移/速度落位或回弹
        .gesture(dragGesture)
    }

    // MARK: - 侧边栏开合（唯一入口：动画同步 sidebarOpen 语义状态与 sidebarDrag 视觉进度）

    private func openSidebar() {
        withAnimation(.easeInOut(duration: 0.3)) {
            player.sidebarOpen = true
            sidebarDrag = panelWidth
        }
    }

    private func closeSidebar() {
        withAnimation(.easeInOut(duration: 0.3)) {
            player.sidebarOpen = false
            sidebarDrag = 0
        }
    }

    /// 跟手拖拽手势：onChanged 实时更新露出宽度；onEnded 超过阈值（位移/速度）落位，否则回弹
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { v in
                let dx = v.translation.width
                let dy = v.translation.height
                // 区分水平/垂直滑动：水平位移远大于垂直才是侧滑
                guard abs(dx) > abs(dy) * 1.5 else { return }
                // 以「当前开合状态 + 本次拖动位移」计算目标露出宽度，钳制在 0...panelWidth
                let base = player.sidebarOpen ? panelWidth : 0
                sidebarDrag = min(panelWidth, max(0, base + dx))
            }
            .onEnded { v in
                let dx = v.translation.width
                let vel = v.predictedEndTranslation.width
                if player.sidebarOpen {
                    // 展开状态：向左拖超 1/4 宽度或快速左滑 → 关闭，否则回弹到全开
                    if dx < -panelWidth * 0.25 || vel < -80 {
                        closeSidebar()
                    } else {
                        withAnimation(.easeInOut(duration: 0.25)) { sidebarDrag = panelWidth }
                    }
                } else {
                    // 收起状态：向右拖超 1/4 宽度或快速右滑 → 打开，否则回弹到全关
                    if dx > panelWidth * 0.25 || vel > 80 {
                        openSidebar()
                    } else {
                        withAnimation(.easeInOut(duration: 0.25)) { sidebarDrag = 0 }
                    }
                }
            }
    }
}

// MARK: - 全局顶部栏（与底部 TabBar 平级，悬浮在内容区上方）

/// 顶部栏：左侧汉堡菜单（打开侧边栏）+ 右侧搜索图标。
/// 首页时颜色随封面主色亮度动态变化；其他页面固定深色。
struct GlobalTopBar: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: Library
    /// 点击汉堡菜单打开侧边栏（统一走 MainTabView 的动画开合入口）
    let onOpenSidebar: () -> Void
    @State private var showSearch = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                onOpenSidebar()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "line.horizontal.3")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(textPrimary.opacity(0.9))
                    Text("流萤音乐")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(textPrimary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                showSearch = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(textPrimary)
                    .padding(10)
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showSearch) {
            SearchView()
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(AuthManager.shared)
        }
    }

    // 首页时根据封面亮度切色；其他页固定白色
    private var textPrimary: Color {
        player.playerCardBackgroundLight ? Color(red: 0.93, green: 0.93, blue: 0.93) : .white
    }
    private var textSecondary: Color {
        .white.opacity(0.78)
    }
}

/// 悬浮 TabBar：播放控制居中（首页时显示播放/暂停按钮，其他页面显示当前歌曲封面，点击回首页）
struct AppTabBar: View {
    @EnvironmentObject private var player: PlayerManager
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 0) {
            tabButton(icon: "sparkles", label: "发现", index: 0)

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
                    // 当前歌曲封面 + 暗色透明遮罩 + 播放状态小竖条
                    ZStack {
                        AlbumArt(
                            size: 44,
                            title: player.current?.title ?? "音乐",
                            coverURL: player.current?.coverURL,
                            radius: 12
                        )
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.black.opacity(0.35))
                        if player.isPlaying {
                            EqualizerBars(color: .white)
                        } else {
                            Image(systemName: "pause.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(width: 44, height: 44)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}
