import SwiftUI

/// 官方通知聊天记录样式：像微信聊天一样，官方消息靠右/左对齐展示，只读不可回复
struct OfficialMessagesView: View {
    @EnvironmentObject private var auth: AuthManager

    @State private var messages: [API.OfficialMessage] = []
    @State private var isLoading = false
    @State private var loadFailed = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                // 顶部时间提示
                Text("以下是流萤音乐官方通知")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.top, 8)

                if isLoading && messages.isEmpty {
                    ProgressView()
                        .tint(Theme.accent)
                        .padding(.top, 40)
                } else if loadFailed && messages.isEmpty {
                    Text("加载失败，下拉重试")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textTertiary)
                        .padding(.top, 40)
                } else if messages.isEmpty {
                    Text("暂无官方通知")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textTertiary)
                        .padding(.top, 40)
                } else {
                    ForEach(messages) { msg in
                        messageBubble(msg)
                    }
                }

                // 底部提示
                Text("— 以上为全部官方通知 —")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
            }
            .padding(.horizontal, 16)
        }
        .refreshable { await loadMessages() }
        .task { await loadMessages() }
    }

    // MARK: - 消息气泡

    private func messageBubble(_ msg: API.OfficialMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 发送者头像+名字
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Theme.accent.opacity(0.2))
                        .frame(width: 32, height: 32)
                    Image("AppLogo")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(msg.sender ?? "流萤音乐官方")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                    Text(timeString(msg.created))
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                }
                Spacer()
            }

            // 消息气泡
            Text(msg.content)
                .font(.system(size: 14))
                .foregroundColor(Theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Theme.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Theme.cardBorder, lineWidth: 0.5)
                )
        }
    }

    // MARK: - 辅助

    private func timeString(_ ts: Double) -> String {
        guard ts > 0 else { return "" }
        let date = Date(timeIntervalSince1970: ts)
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    @MainActor
    private func loadMessages() async {
        isLoading = true
        loadFailed = false
        do {
            messages = try await API.officialMessages()
        } catch {
            loadFailed = true
        }
        isLoading = false
    }
}
