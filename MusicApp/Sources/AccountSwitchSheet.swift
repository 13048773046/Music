import SwiftUI

// MARK: - 切换账号弹窗

/// 切换账号：列出本地保存的历史账号（头像 / 名称 / 账号），
/// 右侧圆圈标记当前登录账号（勾），点击其他账号即一键切换。
struct AccountSwitchSheet: View {
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    header

                    if auth.savedAccounts.isEmpty {
                        emptyState
                    } else {
                        accountList
                    }
                }
            }
            .navigationBarHidden(true)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("切换账号")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Text("选择本地保存的账号快速登录")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                ZStack {
                    Circle().fill(Theme.card)
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                }
                .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    // MARK: - 账号列表

    private var accountList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(auth.savedAccounts.enumerated()), id: \.element.id) { idx, u in
                    Button {
                        switchTo(u)
                    } label: {
                        row(u)
                    }
                    .buttonStyle(.plain)
                    if idx < auth.savedAccounts.count - 1 {
                        divider
                    }
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.cardBorder, lineWidth: 1))
            .padding(.horizontal, 20)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 40))
                .foregroundColor(Theme.textTertiary)
            Text("暂无历史账号")
                .font(.system(size: 14))
                .foregroundColor(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - 账号行

    private func row(_ u: User) -> some View {
        HStack(spacing: 14) {
            CachedCoverImage(
                url: u.avatarURL,
                title: u.name,
                placeholder: Circle().fill(Theme.accentSoft)
                    .overlay(Image(systemName: "person.fill")
                        .font(.system(size: 20))
                        .foregroundColor(Theme.accent))
            )
            .frame(width: 48, height: 48)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(u.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text("账号 \(u.account)")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }

            Spacer()

            // 右侧选中圆圈：当前登录显示勾，否则透明圆圈
            ZStack {
                Circle()
                    .stroke(u.id == auth.currentUser?.id
                                ? Theme.accent
                                : Theme.textTertiary.opacity(0.5),
                            lineWidth: 1.5)
                    .frame(width: 22, height: 22)
                if u.id == auth.currentUser?.id {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 22, height: 22)
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.cardBorder)
            .frame(height: 0.5)
            .frame(maxWidth: .infinity)
            .padding(.leading, 78)
    }

    // MARK: - 切换

    private func switchTo(_ u: User) {
        auth.switchAccount(to: u)
        dismiss()
    }
}
