import SwiftUI

/// 用户主页页面
struct UserProfileView: View {
    let userId: String
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss
    @State private var profile: UserProfile?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                if isLoading {
                    ProgressView().tint(Theme.accent)
                } else if let p = profile {
                    ScrollView {
                        VStack(spacing: 24) {
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

                            // 数据统计卡片
                            HStack(spacing: 0) {
                                statItem(value: "\(p.trackCount)", label: "上传歌曲")
                                Divider().frame(height: 40)
                                statItem(value: "\(p.likeCount)", label: "获赞总数")
                            }
                            .padding(16)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                            .padding(.horizontal, 16)

                            // 提示
                            Text("TA 上传的歌曲会在首页推荐中出现")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textTertiary)
                                .padding(.top, 8)
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
                .font(.system(size: 22, weight: .bold))
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
            profile = try await API.fetchUserProfile(userId)
        } catch {
            // 加载失败
        }
    }
}

// String 作为 sheet item 需要 Identifiable 扩展
extension String: Identifiable {
    public var id: String { self }
}
