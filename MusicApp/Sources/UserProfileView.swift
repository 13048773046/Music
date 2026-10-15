import SwiftUI

/// 用户主页页面
struct UserProfileView: View {
    let userId: String
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss
    @State private var profile: UserProfile?
    @State private var userTracks: [Track] = []
    @State private var isLoading = true
    @State private var isFollowing = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                if isLoading {
                    ProgressView().tint(Theme.accent)
                } else if let p = profile {
                    ScrollView {
                        VStack(spacing: 20) {
                            // 头部：头像 + 基本信息
                            VStack(spacing: 12) {
                                // 头像
                                if !p.avatar.isEmpty {
                                    AsyncImage(url: API.avatarURL(p.userId)) { img in
                                        img.resizable().scaledToFill()
                                    } placeholder: {
                                        Circle().fill(Theme.accentSoft).overlay(
                                            Image(systemName: "person.fill")
                                                .foregroundColor(Theme.accent)
                                        )
                                    }
                                    .frame(width: 80, height: 80)
                                    .clipShape(Circle())
                                } else {
                                    Circle()
                                        .fill(Theme.accentSoft)
                                        .frame(width: 80, height: 80)
                                        .overlay(
                                            Image(systemName: "person.fill")
                                                .font(.system(size: 32))
                                                .foregroundColor(Theme.accent)
                                        )
                                }

                                Text(p.name.isEmpty ? "用户" : p.name)
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundColor(Theme.textPrimary)

                                Text("账号：\(p.account)")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.textSecondary)

                                if !p.signature.isEmpty {
                                    Text(p.signature)
                                        .font(.system(size: 14))
                                        .foregroundColor(Theme.textSecondary)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, 32)
                                }
                            }
                            .padding(.top, 20)

                            // 关注按钮（不是自己才显示）
                            if p.userId != AuthManager.shared.currentUser?.id {
                                Button {
                                    Task { await toggleFollow() }
                                } label: {
                                    Text(isFollowing ? "已关注" : "关注")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(isFollowing ? Theme.textSecondary : .white)
                                        .frame(width: 120, height: 38)
                                        .background(isFollowing ? Theme.card : Theme.accent, in: Capsule())
                                }
                                .buttonStyle(PressableButtonStyle())
                            }

                            // 数据统计卡片
                            HStack(spacing: 0) {
                                statItem(value: "\(p.trackCount)", label: "上传歌曲")
                                Divider().frame(height: 40)
                                statItem(value: "\(p.followerCount)", label: "粉丝")
                                Divider().frame(height: 40)
                                statItem(value: "\(p.followingCount)", label: "关注")
                            }
                            .padding(16)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                            .padding(.horizontal, 16)

                            // 用户上传的歌曲
                            if !userTracks.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("TA 上传的歌曲")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(Theme.textPrimary)
                                        .padding(.horizontal, 16)

                                    ForEach(userTracks) { t in
                                        Button {
                                            player.play(t, in: userTracks)
                                        } label: {
                                            HStack(spacing: 12) {
                                                AlbumArt(size: 44, title: t.title, coverURL: t.coverURL, radius: 9)
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(t.title)
                                                        .font(.system(size: 14, weight: .medium))
                                                        .foregroundColor(Theme.textPrimary)
                                                        .lineLimit(1)
                                                    Text(t.artist ?? "")
                                                        .font(.system(size: 12))
                                                        .foregroundColor(Theme.textSecondary)
                                                        .lineLimit(1)
                                                }
                                                Spacer()
                                                Image(systemName: "play.fill")
                                                    .font(.system(size: 13))
                                                    .foregroundColor(Theme.textTertiary)
                                            }
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 6)
                                        }
                                        .buttonStyle(PressableButtonStyle())
                                    }
                                }
                                .padding(.top, 8)
                            }
                        }
                    }
                }
            }
            .navigationTitle("用户主页")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 6) {
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(Theme.textPrimary)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let p = try await API.fetchUserProfile(userId)
            profile = p
            isFollowing = p.isFollowing
            userTracks = try await API.fetchUserTracks(userId)
        } catch {
            // 加载失败
        }
    }

    private func toggleFollow() async {
        do {
            let newState = try await API.toggleFollow(userId)
            isFollowing = newState
            // 刷新数据
            if let p = profile {
                profile = UserProfile(
                    userId: p.userId, account: p.account, name: p.name, avatar: p.avatar,
                    signature: p.signature, created: p.created, gender: p.gender, age: p.age,
                    trackCount: p.trackCount, likeCount: p.likeCount,
                    followerCount: p.followerCount + (newState ? 1 : -1),
                    followingCount: p.followingCount, mutualCount: p.mutualCount,
                    isFollowing: newState
                )
            }
        } catch {}
    }
}

// String 作为 sheet item 需要 Identifiable 扩展
extension String: Identifiable {
    public var id: String { self }
}
