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

                ScrollView {
                    LazyVStack(spacing: 18) {
                        userCard
                        listenBanner
                        worksSection
                        likesSection
                        commentsSection
                        actionCard
                        aboutCard
                        logoutCard
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 120)
                }
            }
            .navigationBarHidden(true)
            .task { await initialLoad() }
            .refreshable { await refreshAll() }
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

    // MARK: - 用户资料卡（背景图 + 头像 + 昵称 + 性别/年龄 + 签名，点击进编辑页）

    private var userCard: some View {
        let u = auth.currentUser
        return VStack(alignment: .leading, spacing: 0) {
            // 头部：背景图 140 + 头像压边区 36
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Theme.card)

                Group {
                    if let bgURL = u?.backgroundURL {
                        CachedCoverImage(url: bgURL, title: u?.name ?? "",
                                         placeholder: Rectangle().fill(Theme.card))
                            .frame(height: 140)
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(Theme.card)
                            .frame(height: 140)
                    }
                }

                HStack(alignment: .center, spacing: 14) {
                    ZStack {
                        CachedCoverImage(
                            url: u?.avatarURL ?? URL(string: "about:blank")!,
                            title: u?.name ?? "",
                            placeholder:
                                Circle().fill(Theme.accentSoft)
                                    .overlay(Image(systemName: "person.fill")
                                        .font(.system(size: 28))
                                        .foregroundColor(Theme.accent))
                        )
                    }
                    .frame(width: 74, height: 74)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Theme.card, lineWidth: 3))

                    VStack(alignment: .leading, spacing: 5) {
                        Text(u?.name ?? "未登录")
                            .font(.system(size: 20, weight: .bold))
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
                    .padding(.trailing, 12)
                }
                .padding(.leading, 16)
                .padding(.top, 104)   // 头像中心压在背景图下沿（140 - 36）
            }
            .frame(height: 176)
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 10) {
                if let sig = u?.signature, !sig.isEmpty {
                    Text(sig)
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textSecondary)
                } else {
                    Text("点击编辑个人资料")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textTertiary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(Theme.cardBorder, lineWidth: 1))
        .onTapGesture { showProfileEdit = true }
    }

    // MARK: - 听歌时长横幅（独立卡片，突出展示累计数据）

    private var listenBanner: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.sky.opacity(0.16))
                    .frame(width: 46, height: 46)
                Image(systemName: "clock.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(Theme.sky)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("累计听歌时长")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                Text(listenText)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
            }
            Spacer()
            Image(systemName: "headphones")
                .font(.system(size: 15))
                .foregroundColor(Theme.sky.opacity(0.55))
        }
        .softCard(radius: 20, padding: 16)
    }

    // MARK: - 我的上传作品（分页加载）

    private var worksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(icon: "music.note.list", title: "我的作品",
                          count: works.total, unit: "首", color: Theme.accent)
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
        .softCard(radius: 20, padding: 16)
    }

    // MARK: - 我点赞的歌（分页加载）

    private var likesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(icon: "heart.fill", title: "我的喜欢",
                          count: likes.total, unit: "首", color: Theme.peach)
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
        .softCard(radius: 20, padding: 16)
    }

    // MARK: - 我评论过的歌（分页加载）

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(icon: "quote.bubble.fill", title: "我的评论",
                          count: comments.total, unit: "条", color: Theme.lilac)
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
        .softCard(radius: 20, padding: 16)
    }

    // MARK: - 通用区块组件

    private func sectionHeader(icon: String, title: String, count: Int,
                               unit: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(color)
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            Text("\(count) \(unit)")
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(Theme.textTertiary)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var loadFailedHint: some View {
        Text("加载失败，下拉刷新重试")
            .font(.system(size: 13))
            .foregroundColor(Theme.textTertiary)
            .padding(.vertical, 24)
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
                .padding(.vertical, 10)
                .onAppear { Task { await load() } }
        }
    }

    // MARK: - 歌曲行（作品 / 喜欢共用，带封面 + 播放指示）

    private func trackRow(_ t: Track, queue: [Track]) -> some View {
        Button {
            player.play(t, in: queue)
        } label: {
            HStack(spacing: 12) {
                AlbumArt(size: 46, title: t.title, coverURL: t.coverURL, radius: 10)
                VStack(alignment: .leading, spacing: 4) {
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
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 评论行（歌曲信息 + 评论内容，点击播放对应歌曲）

    private func commentRow(_ c: API.MyComment) -> some View {
        Button {
            playComment(c)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
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
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.45), in: Capsule())
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

    // MARK: - 功能入口 / 关于 / 退出登录

    private var actionCard: some View {
        Button {
            showImporter = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.accentSoft)
                        .frame(width: 46, height: 46)
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(Theme.accent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("上传歌曲")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text("从本机选择音频，自动识别歌曲信息")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textTertiary)
            }
            .softCard(radius: 20, padding: 16)
        }
        .buttonStyle(.plain)
    }

    private var aboutCard: some View {
        VStack(spacing: 0) {
            aboutRow(icon: "server.rack", label: "服务器", value: "www.dbmt999.asia")
            Divider().padding(.leading, 56)
            aboutRow(icon: "info.circle", label: "版本", value: "v\(appVersion)")
        }
        .softCard(radius: 20, padding: 6)
    }

    private func aboutRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(Theme.accent)
                .frame(width: 30)
            Text(label)
                .font(.system(size: 14))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            Text(value)
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 12)
    }

    private var logoutCard: some View {
        Button {
            auth.logout()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 17, weight: .semibold))
                Text("退出登录")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .foregroundColor(.red)
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Theme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Theme.cardBorder, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
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
