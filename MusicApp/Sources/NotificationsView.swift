import SwiftUI

/// 消息通知主页：顶部两个Tab（互动通知 / 官方通知）
struct NotificationsView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthManager

    @State private var selectedTab = 0
    @State private var notifications: [API.Notification] = []
    @State private var unreadCount: Int = 0
    @State private var isLoading = false
    @State private var loadFailed = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // 顶部Tab切换
                tabBar

                // 内容区
                if selectedTab == 0 {
                    interactionList
                } else {
                    OfficialMessagesView()
                        .environmentObject(player)
                        .environmentObject(auth)
                }
            }
        }
        .navigationTitle("消息通知")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadNotifications() }
    }

    // MARK: - Tab栏

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabItem(title: "互动通知", index: 0, badge: unreadCount)
            tabItem(title: "官方通知", index: 1, badge: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private func tabItem(title: String, index: Int, badge: Int) -> some View {
        let selected = selectedTab == index
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { selectedTab = index }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 14, weight: selected ? .bold : .medium))
                    .foregroundColor(selected ? Theme.accent : Theme.textSecondary)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Circle().fill(Color.red))
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) {
                if selected {
                    Capsule()
                        .fill(Theme.accent)
                        .frame(height: 2.5)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 互动通知列表

    private var interactionList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if isLoading && notifications.isEmpty {
                    ProgressView()
                        .tint(Theme.accent)
                        .padding(.top, 60)
                } else if loadFailed && notifications.isEmpty {
                    emptyState("加载失败，下拉重试")
                } else if notifications.isEmpty {
                    emptyState("暂无互动通知\n有人赞你、评论你时会出现在这里")
                } else {
                    ForEach(notifications) { n in
                        notifRow(n)
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        .refreshable { await loadNotifications() }
    }

    private func notifRow(_ n: API.Notification) -> some View {
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

    // MARK: - 头像/封面/文字组件

    /// 点赞者头像（圆形，带默认占位）
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

    /// 歌曲封面（方形圆角）
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

    /// 根据通知类型生成描述文字
    private func notificationText(for n: API.Notification) -> String {
        let trackName = n.trackTitle ?? "未知歌曲"
        switch n.type {
        case "like":
            return "赞了你的《\(trackName)》"
        case "comment":
            return "评论了你的《\(trackName)》"
        case "share":
            return "分享了你的《\(trackName)》"
        case "official":
            return n.content ?? ""
        default:
            return n.content ?? ""
        }
    }

    // MARK: - 辅助

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(Theme.textTertiary)
            .multilineTextAlignment(.center)
            .padding(.top, 80)
            .frame(maxWidth: .infinity)
    }

    private func iconName(for type: String) -> String {
        switch type {
        case "like": return "heart.fill"
        case "comment": return "text.bubble.fill"
        case "share": return "square.and.arrow.up.fill"
        case "official": return "bell.badge.fill"
        default: return "bell.fill"
        }
    }

    private func iconBgColor(for type: String) -> Color {
        switch type {
        case "like": return Color(red: 0.9, green: 0.3, blue: 0.4).opacity(0.15)
        case "comment": return Color(red: 0.3, green: 0.5, blue: 0.9).opacity(0.15)
        case "share": return Color(red: 0.4, green: 0.7, blue: 0.4).opacity(0.15)
        default: return Theme.accentSoft
        }
    }

    private func iconFgColor(for type: String) -> Color {
        switch type {
        case "like": return Color(red: 0.9, green: 0.3, blue: 0.4)
        case "comment": return Color(red: 0.3, green: 0.5, blue: 0.9)
        case "share": return Color(red: 0.4, green: 0.7, blue: 0.4)
        default: return Theme.accent
        }
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
    private func loadNotifications() async {
        isLoading = true
        loadFailed = false
        do {
            let r = try await API.notifications()
            notifications = r.list
            unreadCount = r.unread
            // 加载后标记已读
            Task { await API.markNotificationsRead() }
        } catch {
            loadFailed = true
        }
        isLoading = false
    }

    @MainActor
    private func playTrack(_ trackId: String) async {
        // 通过API获取歌曲信息然后播放
        do {
            let allTracks = try await API.tracks()
            if let t = allTracks.first(where: { $0.id == trackId }) {
                player.play(t, in: [t])
            }
        } catch {
            // 静默失败
        }
    }
}
