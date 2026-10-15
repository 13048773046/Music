import SwiftUI

/// 评论页：展示歌曲评论列表，登录用户可发表评论。
/// 传入 highlightCommentId 时，加载完成后自动滚动定位并高亮该评论（通知点击定位用）。
struct CommentSheet: View {
    let track: Track
    var highlightCommentId: String? = nil
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss

    @State private var comments: [API.Comment] = []
    @State private var loading = true
    @State private var text = ""
    @State private var sending = false
    /// 评论点赞状态：commentId -> (liked: Bool, count: Int)
    @State private var likeState: [String: (liked: Bool, count: Int)] = [:]

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
                    ScrollViewReader { proxy in
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

                                        Spacer()

                                        // 点赞按钮
                                        Button {
                                            Task { await toggleLike(c) }
                                        } label: {
                                            VStack(spacing: 2) {
                                                Image(systemName: isCommentLiked(c.id) ? "heart.fill" : "heart")
                                                    .font(.system(size: 14))
                                                    .foregroundColor(isCommentLiked(c.id) ? .red : Theme.textTertiary)
                                                Text("\(commentLikeCount(c.id))")
                                                    .font(.system(size: 10))
                                                    .foregroundColor(Theme.textTertiary)
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    // 目标评论高亮（通知点击定位）
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(highlightCommentId == c.id
                                                  ? Theme.accent.opacity(0.14)
                                                  : Color.clear)
                                    )
                                    .id(c.id)
                                }
                            }
                            .padding(16)
                        }
                        // 评论加载完成后滚动到目标评论
                        .onChange(of: comments) { list in
                            guard let target = highlightCommentId,
                                  list.contains(where: { $0.id == target }) else { return }
                            DispatchQueue.main.async {
                                withAnimation(.easeInOut(duration: 0.35)) {
                                    proxy.scrollTo(target, anchor: .center)
                                }
                            }
                        }
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
        .task {
            // 打开评论弹窗即记录行为（即使没评论也记：comment_open，个性化推荐弱信号）
            if auth.currentUser != nil {
                let ev = API.BehaviorEvent(trackId: track.id, event: "comment_open", value: 1)
                await API.reportBehavior([ev])
            }
            await load()
        }
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
            // 行为上报：发表评论
            let ev = API.BehaviorEvent(trackId: track.id, event: "comment", value: 1)
            Task { await API.reportBehavior([ev]) }
        } catch {
        }
        sending = false
    }

    // MARK: - 评论点赞
    private func isCommentLiked(_ commentId: String) -> Bool {
        likeState[commentId]?.liked ?? false
    }

    private func commentLikeCount(_ commentId: String) -> Int {
        likeState[commentId]?.count ?? 0
    }

    private func toggleLike(_ c: API.Comment) async {
        do {
            let result = try await API.toggleCommentLike(c.id)
            likeState[c.id] = (liked: result.liked, count: result.count)
        } catch {}
    }
}
