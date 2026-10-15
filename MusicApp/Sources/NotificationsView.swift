import SwiftUI

/// 消息通知主页：混合列表，官方通知固定在最顶部，下面是互动通知
struct NotificationsView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss

    @State private var notifications: [API.Notification] = []
    @State private var officialMsg: API.OfficialMessage?
    @State private var unreadCount: Int = 0
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var showOfficialChat = false
    @State private var showUserProfile: String?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: 0) {
                    // 官方通知（固定第一分区）
                    if officialMsg != nil {
                        sectionHeader("官方通知")
                        officialRow(msg: officialMsg!)
                    }

                    // 互动通知分区
                    if isLoading && notifications.isEmpty && officialMsg == nil {
                        ProgressView()
                            .tint(Theme.accent)
                            .padding(.top, 60)
                    } else if loadFailed && notifications.isEmpty {
                        emptyHint("加载失败，下拉重试")
                    } else if notifications.isEmpty && officialMsg != nil {
                        sectionHeader("互动通知")
                    } else if notifications.isEmpty {
                        emptyHint("暂无互动通知\n有人赞你、评论你时会出现在这里")
                    } else {
                        sectionHeader("互动通知")
                        ForEach(notifications) { n in
                            interactionRow(n)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            .refreshable { await loadAll() }
        }
        .navigationTitle("消息通知")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                }
            }
        }
        .navigationDestination(isPresented: $showOfficialChat) {
            OfficialMessagesView()
                .environmentObject(player)
                .environmentObject(auth)
        }
        // 用户主页：独立页面 push（非弹窗）——点击通知头像跳转用户主页
        .navigationDestination(isPresented: Binding(
            get: { showUserProfile != nil },
            set: { if !$0 { showUserProfile = nil } }
        )) {
            if let uid = showUserProfile {
                UserProfileView(userId: uid)
                    .environmentObject(player)
                    .environmentObject(auth)
            }
        }
        // WebSocket 实时推送：收到新通知自动刷新列表与红点
        .onReceive(NotificationBus.shared.$lastEvent) { _ in
            guard auth.currentUser != nil else { return }
            Task { await loadAll() }
        }
        .task { await loadAll() }
    }

    // MARK: - 分区小标题

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(Theme.textTertiary)
            .padding(.top, 18)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 官方通知行（列表第一项）

    private func officialRow(msg: API.OfficialMessage) -> some View {
        Button {
            showOfficialChat = true
        } label: {
            HStack(spacing: 12) {
                // APP Logo（圆形头像，更克制）
                ZStack {
                    Circle()
                        .fill(Theme.card)
                        .frame(width: 40, height: 40)
                    Image("AppLogo")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 40, height: 40)
                        .clipShape(Circle())
                }

                // 名称 + 最新内容预览
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("流萤音乐官方")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                        Text(timeString(msg.created))
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textTertiary)
                        Spacer()
                    }
                    Text(msg.content)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }

                // 右箭头（轻量化）
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textTertiary.opacity(0.6))
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 互动通知行（头像 + 文字 + 封面）

    private func interactionRow(_ n: API.Notification) -> some View {
        HStack(spacing: 12) {
            // 头像：点击跳转用户主页
            Button {
                if let uid = n.fromUserId, !uid.isEmpty {
                    showUserProfile = uid
                }
            } label: {
                avatarView(for: n)
                    .overlay(alignment: .topTrailing) {
                        if n.unread {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 7, height: 7)
                                .overlay(
                                    Circle().stroke(Theme.background, lineWidth: 1.5)
                                )
                        }
                    }
            }
            .buttonStyle(.plain)

            // 文字内容（主体）：点击跳转该歌曲，与原来一致——
            // 评论类通知回首页播放并打开评论弹窗定位到那条评论，其余直接播放该歌曲
            Button {
                Task { await handleTap(n) }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(n.fromUser ?? "有人")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                    }
                    Text(notificationText(for: n))
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                    Text(timeString(n.created))
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            // 右侧：关注类型显示回关按钮，其他显示歌曲封面
            if n.type == "follow" {
                Button {
                    Task {
                        if let uid = n.fromUserId {
                            _ = try? await API.toggleFollow(uid)
                        }
                    }
                } label: {
                    Text("回关")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(PressableButtonStyle())
            } else {
                // 歌曲封面：点击同样跳转该歌曲
                Button {
                    Task { await handleTap(n) }
                } label: {
                    albumCover(for: n)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.cardBorder.opacity(0.6))
                .frame(height: 0.5)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                Task { await deleteNotification(n) }
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func deleteNotification(_ n: API.Notification) async {
        await API.deleteNotification(n.id)
        notifications.removeAll { $0.id == n.id }
    }

    // MARK: - 组件

    @ViewBuilder
    private func avatarView(for n: API.Notification) -> some View {
        if let uid = n.fromUserId, !uid.isEmpty {
            // 触发用户真实头像（从触发用户 id 加载）
            CachedCoverImage(
                url: API.avatarURL(uid),
                title: n.fromUser ?? "",
                placeholder: Circle().fill(Theme.accentSoft)
                    .overlay(Image(systemName: "person.fill")
                        .font(.system(size: 16))
                        .foregroundColor(Theme.accent))
            )
            .frame(width: 40, height: 40)
            .clipShape(Circle())
        } else {
            ZStack {
                Circle()
                    .fill(Theme.accentSoft)
                    .frame(width: 40, height: 40)
                Image(systemName: "person.fill")
                    .font(.system(size: 16))
                    .foregroundColor(Theme.accent)
            }
        }
    }

    @ViewBuilder
    private func albumCover(for n: API.Notification) -> some View {
        // 真实歌曲封面（/api/cover/{trackId}：上传歌返回本地封面，采集歌由后端 302 到第三方）
        CachedCoverImage(
            url: API.coverURL(n.trackId ?? ""),
            title: n.trackTitle ?? "",
            placeholder: ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.card.opacity(0.7))
                    .frame(width: 40, height: 40)
                Image(systemName: "music.note")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(Theme.textTertiary)
            }
        )
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func notificationText(for n: API.Notification) -> String {
        let trackName = n.trackTitle ?? "未知歌曲"
        switch n.type {
        case "like": return "赞了你的《\(trackName)》"
        case "comment": return "评论了你的《\(trackName)》"
        case "share": return "分享了你的《\(trackName)》"
        default: return n.content ?? ""
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(Theme.textTertiary)
            .multilineTextAlignment(.center)
            .padding(.top, 60)
            .frame(maxWidth: .infinity)
    }

    private func timeString(_ ts: Double) -> String {
        guard ts > 0 else { return "" }
        let date = Date(timeIntervalSince1970: ts)
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - 数据加载

    @MainActor
    private func loadAll() async {
        isLoading = true
        loadFailed = false
        async let msgs: () = loadOfficial()
        async let notifs: () = loadNotifications()
        _ = await (msgs, notifs)
        isLoading = false
    }

    @MainActor
    private func loadOfficial() async {
        if let list = try? await API.officialMessages() {
            officialMsg = list.first
        }
    }

    @MainActor
    private func loadNotifications() async {
        guard auth.currentUser != nil else {
            notifications = []
            unreadCount = 0
            return
        }
        do {
            let r = try await API.notifications()
            // 过滤掉official类型（官方通知单独显示在顶部）
            notifications = r.list.filter { $0.type != "official" }
            unreadCount = r.unread
            // 同步全局未读数（TabBar/铃铛红点）
            NotificationBus.shared.setUnread(r.unread)
            Task { await API.markNotificationsRead() }
        } catch {
            loadFailed = true
        }
    }

    /// 点击互动通知：播放歌曲 → 关闭通知页回首页；评论类通知额外打开评论弹窗定位到那条评论
    @MainActor
    private func handleTap(_ n: API.Notification) async {
        guard let trackId = n.trackId, !trackId.isEmpty else { return }
        do {
            // 单曲精确查询（tracks/collected 都覆盖；tracks() 只随机返回 10 首，无法保证命中）
            let t = try await API.track(id: trackId)
            // 延续用户当前听歌模式与音乐流（播完接回原队列），不是单曲孤立播放
            player.playNotificationTrack(t)
            dismiss()
            if n.type == "comment" {
                router.jumpToHome(play: t, openComment: true, commentId: n.commentId)
            } else {
                router.jumpToHome(play: t)
            }
        } catch {}
    }
}
