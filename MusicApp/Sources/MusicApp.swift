import SwiftUI
import UIKit

/// 全屏沉浸歌词横屏状态：AppDelegate 按此返回全局允许的方向。
/// 比 per-View supportedInterfaceOrientations + KVC 更可靠：
/// 系统旋转决策时直接询问 AppDelegate，进入全屏即授权横屏、退出即锁回竖屏。
final class FullScreenOrientation: ObservableObject {
    static let shared = FullScreenOrientation()
    @Published var isFullScreen = false
}

/// 全局方向策略：全屏歌词=横屏，其余一律竖屏
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        FullScreenOrientation.shared.isFullScreen ? .landscape : .portrait
    }
}

@main
struct MusicApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
                        .portraitLocked()
                } else if auth.currentUser == nil {
                    LoginView()
                        .environmentObject(auth)
                        .environmentObject(player)
                        .environmentObject(library)
                        .portraitLocked()
                } else {
                    MainTabView()
                        .environmentObject(player)
                        .environmentObject(auth)
                        .environmentObject(library)
                        .portraitLocked()
                }
            }
            .onAppear {
                Task { await Library.shared.load() }
                // 启动页期间并行预加载发现页/我的页数据：进入主界面后切页不再等待
                Task { await AppPreloader.shared.preload() }
                Task { await fetchAnnouncement() }
                Task { await fetchUpdate() }
                // 已登录（启动自动登录）：直接建立通知 WebSocket
                if auth.currentUser != nil {
                    NotificationBus.shared.startIfNeeded()
                }
                // 启动即拉取未读数：首页（播放页）直接显示红点，无需先打开通知页
                Task { await NotificationBus.shared.refreshUnread() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    withAnimation(.easeInOut(duration: 0.45)) {
                        showSplash = false
                    }
                }
            }
            // 登录态切换：登录后建立实时通知长连接，退出登录断开
            .onChange(of: auth.currentUser != nil) { loggedIn in
                if loggedIn {
                    NotificationBus.shared.resetAndReconnect()
                    // 登录后同步一次未读数（红点立即可见）
                    Task { await NotificationBus.shared.refreshUnread() }
                } else {
                    NotificationBus.shared.stop()
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

    /// 本地 App 版本号（Info.plist CFBundleShortVersionString）
    private var localVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    /// 版本号逐段数字比较：latest > current 返回 true。
    /// 支持 1 / 1.0 / 1.0.0 等格式，段数不同按缺位补 0（如 1.10 > 1.9.9）；相等返回 false。
    private func isNewerVersion(_ latest: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "_" })
                .map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let lp = parts(latest), cp = parts(current)
        let n = max(lp.count, cp.count)
        for i in 0..<n {
            let a = i < lp.count ? lp[i] : 0
            let b = i < cp.count ? cp[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    private func fetchUpdate() async {
        // 携带本地版本号：后端对比后返回 hasUpdate；前端再做一次本地兜底对比
        var comps = URLComponents(string: API.base.appendingPathComponent("check-update").absoluteString)
        comps?.queryItems = [URLQueryItem(name: "v", value: localVersion)]
        let url = comps?.url ?? API.base.appendingPathComponent("check-update")
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let hasUpdate = obj?["hasUpdate"] as? Bool, hasUpdate else { return }
            let latestV = obj?["version"] as? String ?? ""
            // 本地兜底：后端返回的新版本不高于本地版本时不弹窗
            if !latestV.isEmpty && !isNewerVersion(latestV, than: localVersion) { return }
            await MainActor.run {
                updateNotice = UpdateNotice(
                    id: obj?["id"] as? String ?? "",
                    title: obj?["title"] as? String ?? "",
                    content: obj?["content"] as? String ?? "",
                    version: latestV,
                    forceUpdate: (obj?["forceUpdate"] as? Int) ?? 0,
                    downloadUrl: obj?["downloadUrl"] as? String ?? "",
                    downloadUrlIos: obj?["downloadUrlIos"] as? String ?? ""
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
    let downloadUrlIos: String
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
            // 去更新按钮（始终显示）；iOS 优先用 downloadUrlIos（后台分开配置），兜底 downloadUrl
            Button(action: {
                let target = update.downloadUrlIos.isEmpty ? update.downloadUrl : update.downloadUrlIos
                if let url = URL(string: target) {
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
    /// 全局路由：跨页跳转与评论弹窗（通知点击跳转走这里）
    @StateObject private var router = AppRouter.shared
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

    /// 搜索页 push 绑定（首页顶栏放大镜触发，独立页面非弹窗）
    private var searchPageBinding: Binding<Bool> {
        Binding(
            get: { router.showSearchPage },
            set: { if !$0 { router.showSearchPage = false } }
        )
    }

    /// 用户主页 push 绑定（通知头像 / 播放页发布者名称触发，独立页面非弹窗）
    private var userProfileBinding: Binding<Bool> {
        Binding(
            get: { router.pendingUserProfileId != nil },
            set: { if !$0 { router.pendingUserProfileId = nil } }
        )
    }

    var body: some View {
        NavigationStack {
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
                            .environmentObject(router)
                            .opacity(router.selectedTab == 0 ? 1 : 0)
                            .allowsHitTesting(router.selectedTab == 0)
                        HomeView()
                            .ignoresSafeArea()
                            .environmentObject(router)
                            .opacity(router.selectedTab == 1 ? 1 : 0)
                            .allowsHitTesting(router.selectedTab == 1)
                        MineView()
                            .environmentObject(router)
                            .opacity(router.selectedTab == 2 ? 1 : 0)
                            .allowsHitTesting(router.selectedTab == 2)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 顶部栏只在首页（播放页）展示：切到发现/我的后隐藏，
                // 内容区完全沉浸，不残留全局顶部栏。
                // portraitLocked 已保持安全区完整（不再清空），顶栏自然落在状态栏下方
                if router.selectedTab == 1 {
                    GlobalTopBar(onOpenSidebar: handlers.onOpen)
                        .environmentObject(router)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .alignmentGuide(.top) { d in d[.top] }
                        .frame(maxHeight: .infinity, alignment: .top)
                }

                AppTabBar(selection: $router.selectedTab)
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
        // 实时数据事件：全局歌曲列表变化 → 刷新 Library（首页/发现页自动更新）；资料更新 → 多端同步
        .onReceive(NotificationBus.shared.$lastDataEvent) { ev in
            guard let ev else { return }
            switch ev.event {
            case "track_list":
                Task { await Library.shared.load(force: true) }
            case "profile":
                if let u = ev.user,
                   let data = try? JSONSerialization.data(withJSONObject: u),
                   let user = try? JSONDecoder().decode(User.self, from: data) {
                    AuthManager.shared.applyRemoteProfile(user)
                }
            default:
                break
            }
        }
        // 评论定位弹窗：通知点击评论类 → 回首页并打开评论弹窗定位到那条评论
        .sheet(isPresented: $router.showCommentSheet) {
            if let t = router.pendingCommentTrack {
                CommentSheet(track: t, highlightCommentId: router.highlightCommentId)
                    .environmentObject(player)
                    .environmentObject(AuthManager.shared)
            }
        }
        .onAppear {
            // 只绑定一次：之后拖动导致父视图重算时，闭包引用保持同一实例，子视图不再重建
            handlers.onClose = { drawer.animate(to: 0) }
            handlers.onOpen = { drawer.animate(to: 1) }
        }
        // 搜索页：独立页面 push（非弹窗），首页顶栏放大镜触发
        .navigationDestination(isPresented: searchPageBinding) {
            SearchView()
                .environmentObject(player)
                .environmentObject(Library.shared)
                .environmentObject(AuthManager.shared)
        }
        // 用户主页：独立页面 push（非弹窗），通知头像 / 播放页发布者名称触发
        .navigationDestination(isPresented: userProfileBinding) {
            if let uid = router.pendingUserProfileId {
                UserProfileView(userId: uid)
                    .environmentObject(player)
                    .environmentObject(AuthManager.shared)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        }
    }

    /// 跟手拖拽手势：onChanged 实时更新抽屉进度；onEnded 交给官方
    /// UISpringTimingParameters(initialVelocity:) 落位（继承手指速度，无停顿）
    private var dragGesture: some Gesture {        DragGesture(minimumDistance: 10)
            .onChanged { v in
                // 侧滑抽屉只在首页（播放页）生效：发现页/我的页不响应，
                // 避免在"我的"页面左滑误触侧边栏（那里有自己的左右滑动切页）
                guard router.selectedTab == 1 else { return }
                let dx = v.translation.width
                let dy = v.translation.height
                // 区分水平/垂直滑动：水平位移远大于垂直才是侧滑（竖滑切歌不受影响）
                guard abs(dx) > abs(dy) * 1.5 else { return }
                drawer.beginDrag()
                drawer.updateDrag(translationX: dx)
            }
            .onEnded { v in
                guard router.selectedTab == 1 else { return }
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
    @EnvironmentObject private var router: AppRouter
    /// 点击汉堡菜单打开侧边栏（统一走 MainTabView 的动画开合入口）
    let onOpenSidebar: () -> Void

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
                // 搜索页：独立页面 push（非弹窗），由 MainTabView 外层 NavigationStack 承接
                router.showSearchPage = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(10)
            }
            .buttonStyle(.plain)
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
// MARK: - 底部安全区统一度量

/// 底部安全区度量：动态计算「App 内部底部导航栏高度 + 系统底部安全区」，
/// 让所有页面内容不被悬浮的底部导航栏遮挡（不同机型 Home 指示条高度不同，动态取值）。
enum TabBarMetrics {
    /// App 内部底部导航栏内容高度（图标 + 文字 + 上下内边距，不含系统安全区）
    static let contentHeight: CGFloat = 64

    /// 当前设备系统底部安全区高度（Home 指示条，因机型动态变化）
    static var systemBottomInset: CGFloat {
        (UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene)?
            .windows.first(where: { $0.isKeyWindow })?
            .safeAreaInsets.bottom ?? 0
    }

    /// 完整安全区 = App 内部 TabBar 高度 + 系统底部安全区
    static var total: CGFloat { contentHeight + systemBottomInset }
}

/// 为普通滚动页面补上底部导航栏安全区：
/// 系统底部安全区由 ScrollView 自带（未 ignoresSafeArea 时），这里只补 App 内部 TabBar 高度；
/// 全屏沉浸页面（播放页等）请用 `TabBarMetrics.total` 手动计算。
extension View {
    func appBottomTabSpacing() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: TabBarMetrics.contentHeight)
        }
    }
}

// MARK: - 底部导航栏

struct AppTabBar: View {
    @EnvironmentObject private var player: PlayerManager
    /// 订阅通知总线：未读数变化（启动拉取 / WebSocket 实时推送）立即驱动红点刷新
    @ObservedObject private var notifBus = NotificationBus.shared
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
                // "我的"Tab：右上角挂未读通知红点（App 全局消息小红点）
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 21))
                    if index == 2 && notifBus.unreadCount > 0 {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 9, height: 9)
                            .offset(x: 3, y: -2)
                    }
                }
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
