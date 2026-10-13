import SwiftUI

/// 官方通知聊天记录样式：像微信聊天一样，官方消息靠右/左对齐展示，只读不可回复
struct OfficialMessagesView: View {
    @EnvironmentObject private var auth: AuthManager

    @State private var messages: [API.OfficialMessage] = []
    @State private var isLoading = false
    @State private var loadFailed = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                // 顶部时间提示
                Text("仅流萤音乐官方可发送，无法回复")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary.opacity(0.8))
                    .padding(.top, 10)
                    .padding(.bottom, 6)

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
                    // 相邻同发送者消息只展示一次头像/名称（标准 IM 样式，更克制）
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, msg in
                        messageBubble(msg, showHeader: shouldShowHeader(at: index))
                    }
                }

                Text("— 已显示全部官方通知 —")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary.opacity(0.7))
                    .padding(.top, 14)
                    .padding(.bottom, 20)
            }
            .padding(.horizontal, 16)
        }
        .refreshable { await loadMessages() }
        .task { await loadMessages() }
    }

    /// 是否显示消息头部（头像+名称）：仅当上一条来自不同发送者时显示
    private func shouldShowHeader(at index: Int) -> Bool {
        guard index > 0 else { return true }
        return messages[index - 1].sender != messages[index].sender
    }

    // MARK: - 消息气泡

    private func messageBubble(_ msg: API.OfficialMessage, showHeader: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if showHeader {
                // 发送者头像 + 名称
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(Theme.accent.opacity(0.15))
                            .frame(width: 28, height: 28)
                        Image("AppLogo")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 28, height: 28)
                            .clipShape(Circle())
                    }
                    Text(msg.sender ?? "流萤音乐官方")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textTertiary)
                }
                .padding(.top, 6)
            }

            // 消息气泡（无描边、圆角左小右大，更贴近原生 IM）
            Text(msg.content)
                .font(.system(size: 14))
                .foregroundColor(Theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(ChatBubbleShape().fill(Theme.card))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 辅助

    /// IM 聊天气泡圆角形状：左小右大（iOS 16 兼容，不用 UnevenRoundedRectangle）
    private struct ChatBubbleShape: Shape {
        func path(in rect: CGRect) -> Path {
            let rSmall: CGFloat = 4
            let rBig: CGFloat = 16
            var p = Path()
            p.move(to: CGPoint(x: rect.minX + rSmall, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - rBig, y: rect.minY))
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + rBig),
                           control: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - rBig))
            p.addQuadCurve(to: CGPoint(x: rect.maxX - rBig, y: rect.maxY),
                           control: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX + rSmall, y: rect.maxY))
            p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - rSmall),
                           control: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
            return p
        }
    }

    @MainActor
    private func loadMessages() async {
        isLoading = true
        loadFailed = false
        do {
            // 接口按时间倒序返回，聊天页正序渲染（最早在上、最新在下）
            messages = Array((try await API.officialMessages()).reversed())
        } catch {
            loadFailed = true
        }
        isLoading = false
    }
}
