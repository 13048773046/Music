import SwiftUI

@main
struct MusicApp: App {
    @StateObject private var player = PlayerManager.shared
    @StateObject private var auth = AuthManager.shared
    @StateObject private var library = Library.shared
    @State private var showSplash = true
    @State private var announcement: Announcement?
    @State private var updateNotice: UpdateNotice?

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
                Task { await Library.shared.load() }
                // 启动页期间并行预加载发现页/我的页数据：进入主界面后切页不再等待
                Task { await AppPreloader.shared.preload() }
                Task { await fetchAnnouncement() }
                Task { await fetchUpdate() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    withAnimation(.easeInOut(duration: 0.45)) {
                        showSplash = false
                    }
                }
            }
            // 公告弹窗（半屏）
            .sheet(item: $announcement) { ann in
                AnnouncementSheet(announcement: ann)
                    .presentationDetents([.medium])
            }
            // 更新弹窗（半屏）
            .sheet(item: $updateNotice) { upd in
                UpdateSheet(update: upd)
                    .presentationDetents([.medium])
            }
            .preferredColorScheme(.dark)
        }
    }

    private func fetchAnnouncement() async {
        let url = API.base.appendingPathComponent("announcement")
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let title = obj?["title"] as? String, !title.isEmpty,
                  let annId = obj?["id"] as? String, !annId.isEmpty else { return }
            let showOnce = (obj?["showOnce"] as? Int) ?? 0
            if showOnce == 1 {
                let shown = UserDefaults.standard.string(forKey: "shown_announcement_id") ?? ""
                if shown == annId { return }
            }
            await MainActor.run {
                announcement = Announcement(
                    id: annId, title: title,
                    content: obj?["content"] as? String ?? "",
                    version: obj?["version"] as? String ?? "",
                    showOnce: showOnce
                )
            }
        } catch {}
    }

    private func fetchUpdate() async {
        let url = API.base.appendingPathComponent("check-update")
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let hasUpdate = obj?["hasUpdate"] as? Bool, hasUpdate else { return }
            await MainActor.run {
                updateNotice = UpdateNotice(
                    id: obj?["id"] as? String ?? "",
                    title: obj?["title"] as? String ?? "",
                    content: obj?["content"] as? String ?? "",
                    version: obj?["version"] as? String ?? "",
                    forceUpdate: (obj?["forceUpdate"] as? Int) ?? 0,
                    downloadUrl: obj?["downloadUrl"] as? String ?? ""
                )
            }
        } catch {}
    }
}

/// 公告模型
struct Announcement: Identifiable {
    let id: String
    let title: String
    let content: String
    let version: String
    let showOnce: Int
}

/// 更新通知模型
struct UpdateNotice: Identifiable {
    let id: String
    let title: String
    let content: String
    let version: String
    let forceUpdate: Int
    let downloadUrl: String
}

/// 公告弹窗（半屏）
struct AnnouncementSheet: View {
    let announcement: Announcement
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(announcement.title)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
            ScrollView {
                Text(announcement.content)
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.85))
                    .lineSpacing(6)
            }
            if !announcement.version.isEmpty {
                Text("版本：\(announcement.version)")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.5))
            }
            Spacer()
            Button(action: {
                if announcement.showOnce == 1 {
                    UserDefaults.standard.set(announcement.id, forKey: "shown_announcement_id")
                }
                dismiss()
            }) {
                Text("我知道了")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accent)
                    .cornerRadius(12)
            }
        }
        .padding(24)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
    }
}

/// 更新弹窗（半屏）
struct UpdateSheet: View {
    let update: UpdateNotice
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(update.title)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
            if !update.version.isEmpty {
                Text("新版本：\(update.version)")
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: 0x5cd68a))
            }
            ScrollView {
                Text(update.content)
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.85))
                    .lineSpacing(6)
            }
            Spacer()
            // 去更新按钮（始终显示）
            Button(action: {
                if let url = URL(string: update.downloadUrl) {
                    UIApplication.shared.open(url)
                }
                if update.forceUpdate != 1 {
                    dismiss()
                }
            }) {
                Text("去更新")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accent)
                    .cornerRadius(12)
            }
            // 非强制更新才显示取消按钮
            if update.forceUpdate != 1 {
                Button(action: {
                    dismiss()
                }) {
                    Text("以后再说")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
        }
        .padding(24)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
    }
}

/// 侧边栏开合回调的稳定容器：父视图因拖动每帧重算时，闭包引用保持不变，
/// 避免 SidebarView / GlobalTopBar 因「新闭包 ≠ 旧闭包」而整棵视图树反复重建——
/// 这是快速拖动时掉帧卡顿的根源。
final class SidebarHandlers {
    var onClose: () -> Void = {}
    var onOpen: () -> Void = {}
}

/// 页面索引：0=发现音乐 1=首页播放页 2=我的
struct MainTabView: View {
    @EnvironmentObject private var player: PlayerManager
    @State private var selection = 1
    /// 侧边栏抽屉驱动（官方交互式动画：跟手 + UISpringTimingParameters 速度继承落位）
    @StateObject private var drawer: SidebarDrawerController
    /// 稳定闭包容器（见 SidebarHandlers 注释）
    @State private var handlers = SidebarHandlers()

    /// 侧边栏宽度（约屏宽 85%）
    private let panelWidth = UIScreen.main.bounds.width * 0.85

    init() {
        let width = UIScreen.main.bounds.width * 0.85
        _drawer = StateObject(wrappedValue: SidebarDrawerController(width: width))
    }

    var body: some View {
        ZStack {
            // 侧边栏：常驻渲染，offset 跟随抽屉进度实时滑动（关闭时完全移出屏幕左侧）
            SidebarView(
                onClose: handlers.onClose
            )
            .offset(x: drawer.progress * panelWidth - panelWidth)
            .zIndex(1)
            .allowsHitTesting(drawer.progress > 0.01)

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
                    GlobalTopBar(onOpenSidebar: handlers.onOpen)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .alignmentGuide(.top) { d in d[.top] }
                        .frame(maxHeight: .infinity, alignment: .top)
                }

                AppTabBar(selection: $selection)
            }
            .offset(x: drawer.progress * panelWidth)
            // 遮罩常驻：透明度随进度渐显；进度为 0 时不可点击，自动穿透到主界面
            .overlay {
                Color.black.opacity(0.4 * drawer.progress)
                    .allowsHitTesting(drawer.progress > 0.01)
                    .onTapGesture { handlers.onClose() }
            }
        }
        // 全局手势：整个屏幕左右拖动实时跟手；松手由官方弹簧时序按速度继承落位
        .gesture(dragGesture)
        .onAppear {
            // 只绑定一次：之后拖动导致父视图重算时，闭包引用保持同一实例，子视图不再重建
            handlers.onClose = { drawer.animate(to: 0) }
            handlers.onOpen = { drawer.animate(to: 1) }
        }
    }

    /// 跟手拖拽手势：onChanged 实时更新抽屉进度；onEnded 交给官方
    /// UISpringTimingParameters(initialVelocity:) 落位（继承手指速度，无停顿）
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { v in
                // 侧滑抽屉只在首页（播放页）生效：发现页/我的页不响应，
                // 避免在"我的"页面左滑误触侧边栏（那里有自己的左右滑动切页）
                guard selection == 1 else { return }
                let dx = v.translation.width
                let dy = v.translation.height
                // 区分水平/垂直滑动：水平位移远大于垂直才是侧滑（竖滑切歌不受影响）
                guard abs(dx) > abs(dy) * 1.5 else { return }
                drawer.beginDrag()
                drawer.updateDrag(translationX: dx)
            }
            .onEnded { v in
                guard selection == 1 else { return }
                drawer.finishDrag(translationX: v.translation.width,
                                 velocityX: v.velocity.width)
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
                HStack(spacing: 8) {
                    // 三横线菜单：圆润线条 + 纯白色，视觉饱满
                    Image(systemName: "line.horizontal.3")
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundColor(.white)
                    Text("流萤音乐")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                showSearch = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
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
