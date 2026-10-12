import SwiftUI
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

    // 听歌时长（秒）
    @State private var listenSeconds: Int = 0

    // 三个分页列表：我的作品 / 我的喜欢 / 我的评论
    @State private var works = MinePager<Track>()
    @State private var likes = MinePager<Track>()
    @State private var comments = MinePager<API.MyComment>()

    /// 滑动窗体当前页：0=作品 1=点赞 2=评论
    @State private var selectedTab = 0
    @Namespace private var tabIndicatorNS

    @State private var showImporter = false
    @State private var pickedFileURL: URL?
    @State private var showUploadSheet = false
    @State private var showProfileEdit = false

    private static let pageSize = 20

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    // 用户信息区（含听歌时长，不用卡片）
                    userHeader
                    // 指示器：作品 | 点赞 | 评论
                    tabIndicator
                    // 滑动窗体：三个列表页
                    tabPages
                    // 底部：关于 + 退出
                    bottomBar
                }
            }
            .navigationBarHidden(true)
            .task { await initialLoad() }
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
                    await loadWorks(reset: true)
                }
                .environmentObject(auth)
            }
        }
        .sheet(isPresented: $showProfileEdit) {
            NavigationStack {
                ProfileEditView()
                    .environmentObject(auth)
            }
        }
        .tint(Theme.accent)
    }

    // MARK: - 用户信息区（头像 + 昵称/签名 + 上传/编辑 + 听歌时长）

    private var userHeader: some View {
        let u = auth.currentUser
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                // 头像
                ZStack {
                    CachedCoverImage(
                        url: u?.avatarURL ?? URL(string: "about:blank")!,
                        title: u?.name ?? "",
                        placeholder:
                            Circle().fill(Theme.accentSoft)
                                .overlay(Image(systemName: "person.fill")
                                    .font(.system(size: 26))
                                    .foregroundColor(Theme.accent))
                    )
                }
                .frame(width: 58, height: 58)
                .clipShape(Circle())
                .overlay(Circle().stroke(Theme.cardBorder, lineWidth: 1.5))

                VStack(alignment: .leading, spacing: 5) {
                    Text(u?.name ?? "未登录")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundColor(.white)
                    HStack(spacing: 8) {
                        if let gender = u?.gender, !gender.isEmpty, gender != "保密" {
                            tag(gender)
                        }
                        if let age = u?.age, age > 0 {
                            tag("\(age) 岁")
                        }
                    }
                }

                Spacer()

                // 上传按钮
                Button {
                    showImporter = true
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Theme.card)
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Theme.accent)
                    }
                    .frame(width: 42, height: 42)
                }
                .buttonStyle(.plain)

                // 编辑资料按钮
                Button {
                    showProfileEdit = true
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Theme.card)
                        Image(systemName: "pencil")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .frame(width: 42, height: 42)
                }
                .buttonStyle(.plain)
            }

            // 签名（有则显示）
            if let sig = u?.signature, !sig.isEmpty {
                Text(sig)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }

            // 听歌时长：整合在用户信息区内（非卡片，一行数据）
            HStack(spacing: 8) {
                Image(systemName: "clock.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.sky)
                Text("累计听歌")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                Text(listenText)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.accent)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    // MARK: - 指示器（作品 | 点赞 | 评论，下划线滑块跟随）

    private var tabIndicator: some View {
        HStack(spacing: 0) {
            indicatorItem(title: "作品", count: works.total, index: 0)
            indicatorItem(title: "点赞", count: likes.total, index: 1)
            indicatorItem(title: "评论", count: comments.total, index: 2)
        }
        .padding(.horizontal, 20)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.cardBorder)
                .frame(height: 1)
        }
        .padding(.bottom, 8)
    }

    private func indicatorItem(title: String, count: Int, index: Int) -> some View {
        let selected = selectedTab == index
        return Button {
            withAnimation(.easeInOut(duration: 0.25)) { selectedTab = index }
        } label: {
            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: selected ? .bold : .medium))
                        .foregroundColor(selected ? .white : Theme.textSecondary)
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(selected ? Theme.accent : Theme.textTertiary)
                }
                .padding(.horizontal, 8)

                // 选中滑块（matchedGeometryEffect 实现跨 tab 滑动动画）
                ZStack(alignment: .leading) {
                    if selected {
                        Rectangle()
                            .fill(Theme.accent)
                            .frame(height: 2.5)
                            .matchedGeometryEffect(id: "tab-slider", in: tabIndicatorNS)
                    } else {
                        Rectangle()
                            .fill(.clear)
                            .frame(height: 2.5)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 滑动窗体（TabView 三页：作品 / 点赞 / 评论）

    private var tabPages: some View {
        TabView(selection: $selectedTab) {
            worksPage
                .tag(0)
            likesPage
                .tag(1)
            commentsPage
                .tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 作品页（分页加载）

    private var worksPage: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if works.failed {
                    loadFailedHint
                } else if works.isEmpty {
                    emptyHint("还没有上传歌曲")
                } else {
                    ForEach(works.items, id: \.id) { t in
                        trackRow(t, queue: works.items)
                    }
                    loadMoreFooter(pager: works) { await loadWorks(reset: false) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
        .refreshable { await refreshWorks() }
    }

    // MARK: - 点赞页（分页加载）

    private var likesPage: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if likes.failed {
                    loadFailedHint
                } else if likes.isEmpty {
                    emptyHint("还没有点赞过歌曲")
                } else {
                    ForEach(likes.items, id: \.id) { t in
                        trackRow(t, queue: likes.items)
                    }
                    loadMoreFooter(pager: likes) { await loadLikes(reset: false) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
        .refreshable { await refreshLikes() }
    }

    // MARK: - 评论页（分页加载）

    private var commentsPage: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
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
        .refreshable { await refreshComments() }
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
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)
        }
    }

    // MARK: - 列表行（作品 / 点赞共用）

    private func trackRow(_ t: Track, queue: [Track]) -> some View {
        Button {
            player.play(t, in: queue)
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
            .overlay(alignment: .bottom) {
                Divider().background(Theme.cardBorder)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 评论行

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
            .overlay(alignment: .bottom) {
                Divider().background(Theme.cardBorder)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 通用小组件

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.45), in: Capsule())
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

    private static func dateString(_ ts: Double) -> String {
        guard ts > 0 else { return "--" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: ts))
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
        let need = !works.loadedOnce || !likes.loadedOnce || !comments.loadedOnce
        if need { await refreshAll() }
    }

    @MainActor
    private func refreshAll() async {
        async let s: Void = loadStats()
        async let w: Void = loadWorks(reset: true)
        async let l: Void = loadLikes(reset: true)
        async let c: Void = loadComments(reset: true)
        _ = await (s, w, l, c)
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
        guard let token = auth.authToken else { return }
        var req = URLRequest(url: API.base.appendingPathComponent("my-stats"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        listenSeconds = (obj["totalSeconds"] as? Int) ?? 0
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
    /// 加载期间防重入；失败时保留已加载数据，仅标记 failed（首屏空列表时展示重试提示）。
    @MainActor
    private func loadPage<T: Equatable>(_ pager: Binding<MinePager<T>>, reset: Bool,
                                        fetch: (Int, Int) async throws -> API.PageResult<T>) async {
        guard !pager.wrappedValue.isLoading else { return }
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
            var np = pager.wrappedValue
            np.isLoading = false
            np.loadedOnce = true
            np.failed = np.items.isEmpty
            pager.wrappedValue = np
        }
    }

    // MARK: - 评论点击播放（构建最小 Track，cover 置 "1" 复用封面路由）

    private func playComment(_ c: API.MyComment) {
        let track = Track(id: c.trackId, title: c.title ?? "未知歌曲",
                          artist: c.artist, album: nil, cover: "1", size: nil,
                          dur: nil, durText: nil, created: c.created,
                          playCount: nil, likeCount: nil, shareCount: nil,
                          commentCount: nil, userId: nil, userName: nil,
                          hasLyric: nil, isLiked: nil)
        player.play(track, in: [track])
    }
}
