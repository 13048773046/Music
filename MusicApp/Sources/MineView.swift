import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 分页加载状态容器：管理某个列表的「已加载项 + 当前页 + 总数 + 是否还有更多」
struct MinePager<T: Equatable> {
    var items: [T] = []
    var page: Int = 1
    var total: Int = 0
    var hasMore: Bool = false
    var isLoading: Bool = false
    var loadedOnce: Bool = false
    var failed: Bool = false

    var isEmpty: Bool { loadedOnce && items.isEmpty }
}

struct MineView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var router: AppRouter

    // 听歌时长（秒）
    @State private var listenSeconds: Int = 0

    // 三个分页列表：我的作品 / 我的喜欢 / 我的评论
    @State private var works = MinePager<Track>()
    @State private var likes = MinePager<Track>()
    @State private var comments = MinePager<API.MyComment>()

    /// 滑动窗体当前页：0=作品 1=点赞 2=评论
    @State private var selectedTab = 0
    /// 上一次所在页：用于左右切换时的过渡动画方向
    @State private var lastTab = 0
    @Namespace private var sliderNS

    @State private var showImporter = false
    @State private var pickedFileURL: URL?
    @State private var showUploadSheet = false
    @State private var showSettings = false
    @State private var showNotifications = false
    @State private var unreadNotifCount: Int = 0

    private static let pageSize = 20

    /// 状态栏高度：背景图延伸到状态栏后面需要用它铺满顶部
    private static var statusBarHeight: CGFloat {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene,
                  let window = ws.keyWindow else { continue }
            let top = window.safeAreaInsets.top
            if top > 0 { return top }
        }
        return 44
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                // 整页滚动（与首页一致沉浸式）：头部/指示器/列表全部在同一个 ScrollView 里，
                // 上下滑动时整个页面（背景图、用户信息、指示器）一起滚动，而不是只有列表滚。
                ScrollView {
                    LazyVStack(spacing: 0) {
                        userHeader(topInset: Self.statusBarHeight)
                        tabIndicator
                        currentPage
                        bottomBar
                    }
                }
                .ignoresSafeArea(edges: .top)
                .refreshable { await refreshAll() }
                .simultaneousGesture(horizontalSwipe)
            }
            // 设置页（独立页面，非弹窗）——navigationDestination 必须在 NavigationStack 内部
            .navigationDestination(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(auth)
            }
            .navigationDestination(isPresented: $showNotifications) {
                NotificationsView()
                    .environmentObject(player)
                    .environmentObject(auth)
                    .environmentObject(router)
            }
            .navigationBarHidden(true)
            .task { await initialLoad() }
            // WebSocket 实时推送驱动铃铛红点
            .onReceive(NotificationBus.shared.$unreadCount) { n in
                unreadNotifCount = n
            }
            // 实时数据事件：听歌时长统计 / 我的作品列表变化
            .onReceive(NotificationBus.shared.$lastDataEvent) { ev in
                guard let ev else { return }
                switch ev.event {
                case "stats":
                    if let t = ev.totalSeconds {
                        listenSeconds = t
                    }
                    Task { await loadStats() }
                case "my_tracks":
                    Task { await refreshWorks() }
                default:
                    break
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.audio, .mp3, .wav, .mpeg4Audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    pickedFileURL = url
                    showUploadSheet = true
                }
            case .failure:
                break
            }
        }
        .sheet(isPresented: $showUploadSheet) {
            if let url = pickedFileURL {
                UploadSheet(fileURL: url) {
                    // 刷新「我的作品」列表 + 强制刷新全局曲库：
                    // 否则首页竖滑/发现页看不到新上传的歌（只有重启 App 才会出现）
                    async let w: Void = loadWorks(reset: true)
                    async let lib: Void = Library.shared.load(force: true)
                    _ = await (w, lib)
                }
                .environmentObject(auth)
            }
        }
        .tint(Theme.accent)
    }

    // MARK: - 用户信息区（背景图横幅 + 头像压边 + 昵称 + 签名 + 听歌时长）

    private func userHeader(topInset: CGFloat) -> some View {
        let u = auth.currentUser
        return VStack(spacing: 0) {
            // 背景图延伸至状态栏（沉浸式），底部两角圆角；右上角按钮 + 头像行
            ZStack(alignment: .topLeading) {
                // 背景图（无图时深色占位）：高 160 + 顶部安全区
                Group {
                    if let bgURL = u?.backgroundURL {
                        CachedCoverImage(url: bgURL, title: u?.name ?? "",
                                         placeholder: Rectangle().fill(Theme.card))
                            .frame(height: 160 + topInset)
                            .clipped()
                    } else {
                        // 无背景图：深薄荷→暗紫渐变，和整体设计语言统一
                        LinearGradient(
                            colors: [Theme.accentSoft, Color(hex: 0x2A2440)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .frame(height: 160 + topInset)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .clipShape(BottomRoundedShape(radius: 24))

                // 右上角：上传 + 消息 + 设置按钮（圆形半透明白底，和渐变背景融合）
                HStack(spacing: 10) {
                    Button {
                        showImporter = true
                    } label: {
                        ZStack {
                            Circle().fill(.white.opacity(0.18))
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .frame(width: 38, height: 38)
                    }
                    .buttonStyle(PressableButtonStyle())

                    // 消息通知入口
                    Button {
                        showNotifications = true
                    } label: {
                        ZStack {
                            Circle().fill(.white.opacity(0.18))
                            Image(systemName: "bell.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                            // 未读红点
                            if unreadNotifCount > 0 {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 16, height: 16)
                                    .overlay(
                                        Text("\(unreadNotifCount > 99 ? "99+" : "\(unreadNotifCount)")")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(.white)
                                    )
                                    .offset(x: 11, y: -11)
                            }
                        }
                        .frame(width: 38, height: 38)
                    }
                    .buttonStyle(PressableButtonStyle())

                    // 设置入口：跳转设置页（修改信息/修改密码/缓存/更新/退出登录）
                    Button {
                        showSettings = true
                    } label: {
                        ZStack {
                            Circle().fill(.white.opacity(0.18))
                            Image(systemName: "gearshape")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .frame(width: 38, height: 38)
                    }
                    .buttonStyle(PressableButtonStyle())
                }
                .padding(.top, topInset + 8)
                .padding(.trailing, 20)
                .frame(maxWidth: .infinity, alignment: .topTrailing)

                // 头像 + 昵称 + 账号（背景图下部左侧，头像压背景图下沿）
                HStack(spacing: 16) {
                    CachedCoverImage(
                        url: u?.avatarURL ?? URL(string: "about:blank")!,
                        title: u?.name ?? "",
                        placeholder:
                            Circle().fill(Theme.accentSoft)
                                .overlay(Image(systemName: "person.fill")
                                    .font(.system(size: 28))
                                    .foregroundColor(Theme.accent))
                    )
                    .frame(width: 76, height: 76)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 3))

                    VStack(alignment: .leading, spacing: 7) {
                        Text(u?.name ?? "未登录")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            if let acc = u?.account, !acc.isEmpty {
                                Text("ID \(acc)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.white.opacity(0.9))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(.white.opacity(0.18)))
                            }
                            if let gender = u?.gender, !gender.isEmpty, gender != "保密" {
                                tag(gender)
                            }
                            if let age = u?.age, age > 0 {
                                tag("\(age)")
                            }
                        }
                    }

                    Spacer()
                }
                .padding(.leading, 20)
                .padding(.trailing, 20)
                .padding(.top, topInset + 160 - 38)   // 头像中心压在背景图下沿
            }
            .frame(height: topInset + 160 + 36)       // 背景 + 头像露出下半部

            // 签名 + 听歌时长（软卡片，和首页卡片风统一）
            VStack(alignment: .leading, spacing: 12) {
                if let sig = u?.signature, !sig.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "quote.bubble.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textTertiary)
                        Text(sig)
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(2)
                    }
                }

                // 听歌时长：软卡片数据行
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(Theme.accentSoft).frame(width: 30, height: 30)
                        Image(systemName: "clock.fill")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.accent)
                    }
                    Text("累计听歌")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                    Spacer()
                    Text(listenText)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Theme.accent)
                }
                .padding(12)
                .softCard(radius: 14)
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 14)
        }
    }

    // MARK: - 指示器（左对齐：作品 | 点赞 | 评论，选中项绿色加粗 + 滑块平滑过渡）

    private var tabIndicator: some View {
        HStack(spacing: 26) {
            segItem(title: "作品", count: works.total, index: 0)
            segItem(title: "点赞", count: likes.total, index: 1)
            segItem(title: "评论", count: comments.total, index: 2)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func segItem(title: String, count: Int, index: Int) -> some View {
        let selected = selectedTab == index
        return Button {
            switchTab(index)
        } label: {
            VStack(spacing: 5) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: selected ? .bold : .medium))
                        .foregroundColor(selected ? Theme.accent : Theme.textSecondary)
                    Text("\(count)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(selected ? Theme.accent : Theme.textTertiary)
                }
                // 滑块：选中项显示，切换时平滑滑动到新位置（matchedGeometryEffect 过渡）
                Group {
                    if selected {
                        Capsule()
                            .fill(Theme.accent)
                            .frame(width: 30, height: 3)
                            .matchedGeometryEffect(id: "tab-slider", in: sliderNS)
                    } else {
                        Capsule()
                            .fill(Color.clear)
                            .frame(width: 30, height: 3)
                    }
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 当前页内容（整页滚动：只渲染选中页，左右滑动切换带过渡动画）

    /// 切换页：记录上一页用于过渡方向，并带动画切换（指示器滑块同步平滑移动）
    private func switchTab(_ new: Int) {
        guard new >= 0, new <= 2, new != selectedTab else { return }
        lastTab = selectedTab
        withAnimation(.easeInOut(duration: 0.28)) { selectedTab = new }
    }

    /// 左右滑动手势：横向主导时切换上一页/下一页（纵向仍交给整页滚动）
    private var horizontalSwipe: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy), abs(dx) > 50 else { return }
                let newTab = dx < 0 ? min(selectedTab + 1, 2) : max(selectedTab - 1, 0)
                switchTab(newTab)
            }
    }

    @ViewBuilder
    private var currentPage: some View {
        // 过渡方向：向右切（新页从右滑入、旧页向左滑出）；向左切反之
        let dir: Edge = selectedTab > lastTab ? .trailing : .leading
        let rev: Edge = dir == .trailing ? .leading : .trailing
        ZStack {
            if selectedTab == 0 {
                worksList
                    .transition(.asymmetric(insertion: .move(edge: dir),
                                            removal: .move(edge: rev)))
            } else if selectedTab == 1 {
                likesList
                    .transition(.asymmetric(insertion: .move(edge: dir),
                                            removal: .move(edge: rev)))
            } else {
                commentsList
                    .transition(.asymmetric(insertion: .move(edge: dir),
                                            removal: .move(edge: rev)))
            }
        }
    }

    // MARK: - 作品页（分页加载，直接在外层整页 ScrollView 中惰性渲染）

    private var worksList: some View {
        LazyVStack(spacing: 10) {
            if works.failed {
                loadFailedHint
            } else if works.isEmpty {
                emptyHint("还没有上传歌曲")
            } else {
                ForEach(works.items, id: \.id) { t in
                    trackRow(t, queue: works.items, kind: .works)
                }
                loadMoreFooter(pager: works) { await loadWorks(reset: false) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    // MARK: - 点赞页（分页加载）

    private var likesList: some View {
        LazyVStack(spacing: 10) {
            if likes.failed {
                loadFailedHint
            } else if likes.isEmpty {
                emptyHint("还没有点赞过歌曲")
            } else {
                ForEach(likes.items, id: \.id) { t in
                    trackRow(t, queue: likes.items, kind: .liked)
                }
                loadMoreFooter(pager: likes) { await loadLikes(reset: false) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    // MARK: - 评论页（分页加载）

    private var commentsList: some View {
        LazyVStack(spacing: 10) {
            if comments.failed {
                loadFailedHint
            } else if comments.isEmpty {
                emptyHint("还没有发表过评论")
            } else {
                ForEach(comments.items, id: \.id) { c in
                    commentRow(c)
                }
                loadMoreFooter(pager: comments) { await loadComments(reset: false) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    // MARK: - 底部（关于 + 退出登录）

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider().background(Theme.cardBorder)
            HStack {
                Text("流萤音乐 v\(appVersion)")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textTertiary)
                Spacer()
                Text("www.dbmt999.asia")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            Button {
                auth.logout()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                    Text("退出登录")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundColor(.red.opacity(0.9))
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .softCard(radius: 14)
            }
            .buttonStyle(PressableButtonStyle())
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
        }
    }

    // MARK: - 列表行（作品 / 点赞共用）

    /// 列表行点击来源：作品 / 喜欢（决定点击后进入哪个听歌模式）
    private enum MineRowKind { case works, liked }

    private func trackRow(_ t: Track, queue: [Track], kind: MineRowKind) -> some View {
        Button {
            switch kind {
            case .works:
                // 点击我的作品：播放页切换「我的作品」模式，作品列表循环（到最后一个回第一个），从该歌开始
                player.playWorksTrack(t, known: queue)
            case .liked:
                // 点击我的喜欢：播放页切换「我的喜欢」模式，点赞列表循环，从该歌开始
                player.playLikedTrack(t, known: queue)
            }
        } label: {
            HStack(spacing: 12) {
                AlbumArt(size: 44, title: t.title, coverURL: t.coverURL, radius: 9)
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Text(t.displayAuthor)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                if player.current?.id == t.id {
                    if player.isPlaying {
                        EqualizerBars(color: Theme.accent)
                    } else {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Theme.accent)
                    }
                }
                if let dur = t.durText, !dur.isEmpty {
                    Text(dur)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .softCard(radius: 14)
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func commentRow(_ c: API.MyComment) -> some View {
        Button {
            playComment(c)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.lilac)
                    Text(c.title ?? "未知歌曲")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    if let created = c.created, created > 0 {
                        Text(Self.dateString(created))
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textTertiary)
                    }
                }
                Text("「\(c.content)」")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .softCard(radius: 14)
        }
        .buttonStyle(PressableButtonStyle())
    }

    // MARK: - 通用小组件

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white.opacity(0.9))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1)
            )
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(Theme.textTertiary)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var loadFailedHint: some View {
        Text("加载失败，下拉刷新重试")
            .font(.system(size: 13))
            .foregroundColor(Theme.textTertiary)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// 底部加载更多指示：滚动到列表末尾时自动加载下一页
    @ViewBuilder
    private func loadMoreFooter<T: Equatable>(pager: MinePager<T>,
                                              load: @escaping () async -> Void) -> some View {
        if pager.hasMore {
            ProgressView()
                .tint(Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .onAppear { Task { await load() } }
        }
    }

    /// 日期格式化：DateFormatter 创建开销大，列表多行复用同一实例。
    /// 仅在主线程（视图渲染上下文）使用。
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func dateString(_ ts: Double) -> String {
        guard ts > 0 else { return "--" }
        return dateFormatter.string(from: Date(timeIntervalSince1970: ts))
    }

    /// 听歌时长格式化：不足 1 小时显示分钟，否则显示小时
    private var listenText: String {
        guard listenSeconds > 0 else { return "0 分钟" }
        let hours = Double(listenSeconds) / 3600.0
        if hours < 1 {
            return "\(Int(listenSeconds / 60)) 分钟"
        }
        return String(format: "%.1f 小时", hours)
    }

    // MARK: - 数据加载（分页）

    @MainActor
    private func initialLoad() async {
        // 启动页已预加载我的页数据：直接采用，不再重复请求（秒开）
        if AppPreloader.shared.mineLoaded {
            adoptPreload()
            return
        }
        // 预加载未完成/失败（如启动时未登录）：自行加载兜底
        let need = !works.loadedOnce || !likes.loadedOnce || !comments.loadedOnce
        if need { await refreshAll() }
    }

    /// 采用启动页预加载的数据初始化三个列表与听歌时长（第一页，后续滚动续拉）
    @MainActor
    private func adoptPreload() {
        let pre = AppPreloader.shared
        listenSeconds = pre.mineStatsSeconds

        func pager<T: Equatable>(items: [T], total: Int) -> MinePager<T> {
            var p = MinePager<T>()
            p.items = items
            p.total = total
            p.page = 2
            p.hasMore = total > items.count
            p.loadedOnce = true
            p.isLoading = false
            p.failed = false
            return p
        }
        works = pager(items: pre.works, total: pre.worksTotal)
        likes = pager(items: pre.likes, total: pre.likesTotal)
        comments = pager(items: pre.comments, total: pre.commentsTotal)
    }

    @MainActor
    private func refreshAll() async {
        async let s: Void = loadStats()
        async let w: Void = loadWorks(reset: true)
        async let l: Void = loadLikes(reset: true)
        async let c: Void = loadComments(reset: true)
        async let n: Void = loadUnreadCount()
        _ = await (s, w, l, c, n)
    }

    /// 加载未读通知数（铃铛红点）
    @MainActor
    private func loadUnreadCount() async {
        guard auth.currentUser != nil else {
            unreadNotifCount = 0
            NotificationBus.shared.setUnread(0)
            return
        }
        if let r = try? await API.notifications() {
            unreadNotifCount = r.unread
            NotificationBus.shared.setUnread(r.unread)
        }
    }

    @MainActor
    private func refreshWorks() async {
        async let s: Void = loadStats()
        async let w: Void = loadWorks(reset: true)
        _ = await (s, w)
    }

    @MainActor
    private func refreshLikes() async {
        async let s: Void = loadStats()
        async let l: Void = loadLikes(reset: true)
        _ = await (s, l)
    }

    @MainActor
    private func refreshComments() async {
        async let s: Void = loadStats()
        async let c: Void = loadComments(reset: true)
        _ = await (s, c)
    }

    @MainActor
    private func loadStats() async {
        if let seconds = try? await API.myStats() {
            listenSeconds = seconds
        }
    }

    @MainActor
    private func loadWorks(reset: Bool) async {
        await loadPage($works, reset: reset) { page, size in
            try await API.myTracks(page: page, pageSize: size)
        }
    }

    @MainActor
    private func loadLikes(reset: Bool) async {
        await loadPage($likes, reset: reset) { page, size in
            try await API.myLikes(page: page, pageSize: size)
        }
    }

    @MainActor
    private func loadComments(reset: Bool) async {
        await loadPage($comments, reset: reset) { page, size in
            try await API.myComments(page: page, pageSize: size)
        }
    }

    /// 通用分页加载：reset=true 回到第一页并替换数据；否则追加下一页。
    /// - 加载期间防重入；
    /// - 请求成功后才替换/清空列表；
    /// - 请求失败或被系统打断（如重复下拉刷新取消上一次任务）时**回滚旧数据**，
    ///   只有完全没有任何数据时才展示"加载失败"，避免刷新时列表闪空/误报失败。
    @MainActor
    private func loadPage<T: Equatable>(_ pager: Binding<MinePager<T>>, reset: Bool,
                                        fetch: (Int, Int) async throws -> API.PageResult<T>) async {
        guard !pager.wrappedValue.isLoading else { return }
        // 记录旧快照：失败时回滚
        let old = pager.wrappedValue
        if reset {
            pager.wrappedValue = MinePager()
        }
        var p = pager.wrappedValue
        p.isLoading = true
        p.failed = false
        pager.wrappedValue = p
        do {
            let r = try await fetch(p.page, Self.pageSize)
            var np = pager.wrappedValue
            np.items = reset ? r.list : np.items + r.list
            np.total = r.total
            np.hasMore = r.hasMore
            np.page = p.page + 1
            np.loadedOnce = true
            np.isLoading = false
            np.failed = false
            pager.wrappedValue = np
        } catch {
            // 有旧数据：回滚（列表保持不变，不打断浏览、不误报失败）
            if !old.items.isEmpty {
                var np = old
                np.isLoading = false
                np.failed = false
                pager.wrappedValue = np
            } else {
                // 无旧数据（首次加载失败）：展示失败提示
                var np = pager.wrappedValue
                np.isLoading = false
                np.loadedOnce = true
                np.failed = np.items.isEmpty
                pager.wrappedValue = np
            }
        }
    }

    // MARK: - 评论点击播放（构建最小 Track，cover 置 "1" 复用封面路由）

    private func playComment(_ c: API.MyComment) {
        let track = Track(id: c.trackId, title: c.title ?? "未知歌曲",
                          artist: c.artist, album: nil, cover: "1", size: nil,
                          dur: nil, durText: nil, created: c.created,
                          playCount: nil, likeCount: nil, shareCount: nil,
                          commentCount: nil, userId: nil, userName: nil,
                          hasLyric: nil, isLiked: nil, reason: nil)
        player.play(track, in: [track])
    }
}

/// 只圆底部两角的形状：用户背景图与下方信息区衔接处的圆角
struct BottomRoundedShape: Shape {
    var radius: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                       control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                       control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
