import SwiftUI

/// 消息通知主页：混合列表，官方通知固定在最顶部，下面是互动通知
struct NotificationsView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthManager

    @State private var notifications: [API.Notification] = []
    @State private var officialMsg: API.OfficialMessage?
    @State private var unreadCount: Int = 0
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var showOfficialChat = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: 0) {
                    // 官方通知（固定第一条）
                    if let msg = officialMsg {
                        officialRow(msg)
                        Divider().background(Theme.cardBorder).padding(.leading, 76)
                    }

                    // 互动通知列表
                    if isLoading && notifications.isEmpty && officialMsg == nil {
                        ProgressView()
                            .tint(Theme.accent)
                            .padding(.top, 60)
                    } else if loadFailed && notifications.isEmpty {
                        emptyHint("加载失败，下拉重试")
                    } else if notifications.isEmpty && officialMsg != nil {
                        // 只有官方通知，没有互动通知
                    } else if notifications.isEmpty {
                        emptyHint("暂无互动通知\n有人赞你、评论你时会出现在这里")
                    } else {
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
        .navigationDestination(isPresented: $showOfficialChat) {
            OfficialMessagesView()
                .environmentObject(player)
                .environmentObject(auth)
        }
        .task { await loadAll() }
    }

    // MARK: - 官方通知行（列表第一项）

    private func officialRow(_ msg: API.OfficialMessage) -> some View {
        Button {
            showOfficialChat = true
        } label: {
            HStack(spacing: 12) {
                // APP Logo（音符图标，圆角方形）
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.card)
                        .frame(width: 48, height: 48)
                    Image(systemName: "music.note")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(Theme.accent)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.cardBorder, lineWidth: 0.5)
                )

                // 名称 + 最新内容预览
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("流萤音乐官方")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                        Text(timeString(msg.created))
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textTertiary)
                    }
                    Text(msg.content)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }

                // 右箭头
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 互动通知行（头像 + 封面 + 文字）

    private func interactionRow(_ n: API.Notification) -> some View {
        Button {
            if let trackId = n.trackId, !trackId.isEmpty {
                Task { await playTrack(trackId) }
            }
        } label: {
            HStack(spacing: 12) {
                // 点赞者头像
                avatarView(for: n)

                // 歌曲封面
                albumCover(for: n)

                // 文字内容
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(n.fromUser ?? "有人")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                        if n.unread {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                        }
                    }
                    Text(notificationText(for: n))
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                    Text(timeString(n.created))
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Theme.cardBorder)
                    .frame(height: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 组件

    @ViewBuilder
    private func avatarView(for n: API.Notification) -> some View {
        ZStack {
            Circle()
                .fill(Theme.accentSoft)
                .frame(width: 44, height: 44)
            Image(systemName: "person.fill")
                .font(.system(size: 18))
                .foregroundColor(Theme.accent)
        }
        .overlay(Circle().stroke(Theme.cardBorder, lineWidth: 0.5))
    }

    @ViewBuilder
    private func albumCover(for n: API.Notification) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.card)
                .frame(width: 48, height: 48)
            Image(systemName: "music.note")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Theme.textTertiary)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.cardBorder, lineWidth: 0.5)
        )
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
            Task { await API.markNotificationsRead() }
        } catch {
            loadFailed = true
        }
    }

    @MainActor
    private func playTrack(_ trackId: String) async {
        do {
            let allTracks = try await API.tracks()
            if let t = allTracks.first(where: { $0.id == trackId }) {
                player.play(t, in: [t])
            }
        } catch {}
    }
}
