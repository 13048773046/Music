import SwiftUI

/// 评论页：展示歌曲评论列表，登录用户可发表评论。
struct CommentSheet: View {
    let track: Track
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss

    @State private var comments: [API.Comment] = []
    @State private var loading = true
    @State private var text = ""
    @State private var sending = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("评论 \(comments.count)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                            .padding(8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if loading {
                    ProgressView().tint(Theme.accent).frame(maxHeight: .infinity)
                } else if comments.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "bubble.left")
                            .font(.system(size: 30))
                            .foregroundColor(Theme.textTertiary)
                        Text("还没有评论，来抢沙发")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(comments) { c in
                                HStack(alignment: .top, spacing: 10) {
                                    // 用户头像（无头像时显示默认占位）
                                    CachedCoverImage(
                                        url: API.avatarURL(c.userId),
                                        title: c.userName,
                                        placeholder: Circle().fill(Theme.accentSoft)
                                            .overlay(Image(systemName: "person.fill")
                                                .font(.system(size: 15))
                                                .foregroundColor(Theme.accent))
                                    )
                                    .frame(width: 36, height: 36)
                                    .clipShape(Circle())

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(c.userName.isEmpty ? "用户" : c.userName)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(Theme.accent)
                                        Text(c.content)
                                            .font(.system(size: 14))
                                            .foregroundColor(Theme.textPrimary)
                                    }
                                }
                            }
                        }
                        .padding(16)
                    }
                }

                // 输入栏
                HStack(spacing: 10) {
                    TextField("发条友善的评论…", text: $text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
                        .foregroundColor(Theme.textPrimary)
                    Button {
                        Task { await send() }
                    } label: {
                        if sending {
                            ProgressView().tint(.white)
                        } else {
                            Text("发送").fontWeight(.semibold)
                        }
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Theme.accent, in: Capsule())
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || sending)
                }
                .padding(16)
                .background(Theme.background)
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        comments = (try? await API.fetchComments(trackId: track.id)) ?? []
        loading = false
    }

    private func send() async {
        guard let u = auth.currentUser else { return }
        sending = true
        do {
            try await API.postComment(trackId: track.id,
                                      userId: u.id, userName: u.name,
                                      content: text.trimmingCharacters(in: .whitespaces))
            text = ""
            await load()
        } catch {
        }
        sending = false
    }
}
