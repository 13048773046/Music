import SwiftUI
import UIKit

/// 用户主页页面（v2 重做版：背景更紧凑、单返回键、信息更精致）
struct UserProfileView: View {
    let userId: String
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss
    @State private var profile: UserProfile?
    @State private var userTracks: [Track] = []
    @State private var isLoading = true
    @State private var isFollowing = false
    @State private var page = 1
    @State private var hasMore = true

    /// 状态栏高度：背景图延伸到状态栏后面需要用它铺满顶部
    private static var statusBarHeight: CGFloat {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene,
                  let window = ws.keyWindow else { continue }
            let top = window.safeAreaInsets.top
            if top > 0 { return top }
        }
        return 44
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    // 背景图区域：延伸到状态栏，高度紧凑（150 + 状态栏），底部渐变与内容衔接
                    headerBackground
                        .frame(height: 150 + Self.statusBarHeight)

                    // 头像 + 基本信息（向上重叠，与背景衔接）
                    profileInfoSection
                        .offset(y: -38)
                        .padding(.bottom, -38)

                    // 关注按钮
                    if let p = profile, p.userId != AuthManager.shared.currentUser?.id {
                        followButton
                            .padding(.top, 12)
                            .padding(.bottom, 16)
                    }

                    // 数据统计（5 项）
                    if let p = profile {
                        statsCard(p: p)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 20)
                    }

                    // 歌曲列表
                    tracksSection
                        .padding(.bottom, 90)
                }
            }
        }
        // 独立页面 push：隐藏系统返回，仅保留自定义返回（避免双返回键）
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss() } label: {
                    Circle()
                        .fill(.black.opacity(0.3))
                        .frame(width: 32, height: 32)
                        .overlay(
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                        )
                }
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await load() }
    }

    // MARK: - 背景图

    private var headerBackground: some View {
        ZStack(alignment: .bottom) {
            // 用户背景图（有图用图，无图用渐变，与"我的"页面一致）
            Group {
                if let p = profile, !p.backgroundImage.isEmpty {
                    CachedCoverImage(url: API.backgroundURL(p.userId), title: p.name,
                                     placeholder: Rectangle().fill(Theme.card))
                } else {
                    LinearGradient(
                        colors: [Theme.accent.opacity(0.24), Theme.accent.opacity(0.06)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }

            // 顶部轻微压暗：让返回按钮始终清晰
            LinearGradient(
                colors: [Color.black.opacity(0.18), Color.clear],
                startPoint: .top,
                endPoint: .center
            )

            // 底部渐变遮罩：与下方内容自然融合
            LinearGradient(
                colors: [Color.clear, Theme.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 90)
        }
        .frame(maxWidth: .infinity)
        .clipped()
    }

    // MARK: - 个人信息

    private var profileInfoSection: some View {
        HStack(spacing: 14) {
            // 头像
            if let p = profile, !p.avatar.isEmpty {
                AsyncImage(url: API.avatarURL(p.userId)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(Theme.accentSoft).overlay(
                        Image(systemName: "person.fill").foregroundColor(Theme.accent)
                    )
                }
                .frame(width: 76, height: 76)
                .clipShape(Circle())
                .overlay(Circle().stroke(Theme.background, lineWidth: 3))
            } else {
                Circle()
                    .fill(Theme.accentSoft)
                    .frame(width: 76, height: 76)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 30))
                            .foregroundColor(Theme.accent)
                    )
                    .overlay(Circle().stroke(Theme.background, lineWidth: 3))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(profile?.name.isEmpty ?? true ? "用户" : profile!.name)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)

                // 性别 · 年龄 · 城市（大致地址，有值才显示）
                if let p = profile {
                    let meta = [p.gender.isEmpty ? nil : p.gender,
                                p.age > 0 ? "\(p.age) 岁" : nil,
                                p.city.isEmpty ? nil : p.city]
                        .compactMap { $0 }
                    if !meta.isEmpty {
                        Text(meta.joined(separator: " · "))
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                    }
                }

                if let sig = profile?.signature, !sig.isEmpty {
                    Text(sig)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
    }

    // MARK: - 关注按钮

    private var followButton: some View {
        Button {
            Task { await toggleFollow() }
        } label: {
            Text(isFollowing ? "已关注" : "关注")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(isFollowing ? Theme.textSecondary : .white)
                .frame(width: 104, height: 34)
                .background(
                    Capsule()
                        .fill(isFollowing ? Theme.card : Theme.accent)
                )
        }
        .buttonStyle(PressableButtonStyle())
    }

    // MARK: - 统计卡片（歌曲/粉丝/关注/互关/获赞）

    private func statsCard(p: UserProfile) -> some View {
        HStack(spacing: 0) {
            statItem(value: "\(p.trackCount)", label: "歌曲")
            Divider().frame(height: 22)
            statItem(value: "\(p.followerCount)", label: "粉丝")
            Divider().frame(height: 22)
            statItem(value: "\(p.followingCount)", label: "关注")
            Divider().frame(height: 22)
            statItem(value: "\(p.mutualCount)", label: "互关")
            Divider().frame(height: 22)
            statItem(value: "\(p.likeCount)", label: "获赞")
        }
        .padding(.vertical, 12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 歌曲列表

    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TA 的歌曲")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .padding(.horizontal, 18)

            if userTracks.isEmpty && isLoading {
                ProgressView()
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else if userTracks.isEmpty {
                Text("还没有上传歌曲")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else {
                ForEach(userTracks) { t in
                    Button {
                        player.play(t, in: userTracks)
                    } label: {
                        trackRow(t)
                    }
                    .buttonStyle(PressableButtonStyle())
                }

                // 加载更多
                if hasMore {
                    Button {
                        Task { await loadMoreTracks() }
                    } label: {
                        Text("加载更多")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
            }
        }
    }

    private func trackRow(_ t: Track) -> some View {
        HStack(spacing: 12) {
            AlbumArt(size: 46, title: t.title, coverURL: t.coverURL, radius: 8)

            VStack(alignment: .leading, spacing: 4) {
                Text(t.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text(t.artist ?? "")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "play.fill")
                .font(.system(size: 14))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    // MARK: - 数据加载

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let p = try await API.fetchUserProfile(userId)
            profile = p
            isFollowing = p.isFollowing
            page = 1
            let tracks = try await API.fetchUserTracks(userId)
            userTracks = tracks
            hasMore = tracks.count >= 20
        } catch {}
    }

    private func loadMoreTracks() async {
        do {
            page += 1
            let tracks = try await API.fetchUserTracks(userId)
            userTracks.append(contentsOf: tracks)
            hasMore = tracks.count >= 20
        } catch {
            page -= 1
        }
    }

    private func toggleFollow() async {
        do {
            let newState = try await API.toggleFollow(userId)
            isFollowing = newState
            if let p = profile {
                profile = UserProfile(
                    userId: p.userId, account: p.account, name: p.name, avatar: p.avatar,
                    signature: p.signature, created: p.created, gender: p.gender, age: p.age,
                    trackCount: p.trackCount, likeCount: p.likeCount,
                    followerCount: p.followerCount + (newState ? 1 : -1),
                    followingCount: p.followingCount, mutualCount: p.mutualCount,
                    isFollowing: newState,
                    backgroundImage: p.backgroundImage, city: p.city
                )
            }
        } catch {}
    }
}

extension String: Identifiable {
    public var id: String { self }
}
