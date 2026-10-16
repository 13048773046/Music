import SwiftUI

// MARK: - 切换账号弹窗

/// 切换账号：列出本地保存的历史账号（头像 / 名称 / 账号），
/// 右侧圆圈标记当前登录账号（勾），点击其他账号即一键切换；
/// 列表末尾提供「添加账号」入口，全屏登录新账号，取消返回不影响当前登录。
struct AccountSwitchSheet: View {
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss

    /// 打开弹窗时的当前账号 id：登录态变化（切换/新增）后自动关闭弹窗
    @State private var openingUserID = AuthManager.shared.currentUser?.id
    @State private var showLoginCover = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                    accountList
                }
            }
            .navigationBarHidden(true)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // 登录了新账号（或切换了账号）：关闭弹窗
        .onChange(of: auth.currentUser?.id) { newID in
            if newID != openingUserID {
                dismiss()
            }
        }
        .fullScreenCover(isPresented: $showLoginCover) {
            LoginCover()
                .environmentObject(auth)
        }
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

    // MARK: - 账号列表（历史账号 + 添加账号入口）

    private var accountList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // 历史账号
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

                // 历史账号与「添加账号」之间用分隔线隔开
                if !auth.savedAccounts.isEmpty {
                    divider
                }

                // 添加账号（大头像加号）
                Button {
                    showLoginCover = true
                } label: {
                    addAccountRow
                }
                .buttonStyle(.plain)
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.cardBorder, lineWidth: 1))
            .padding(.horizontal, 20)
        }
    }

    // MARK: - 添加账号行

    private var addAccountRow: some View {
        HStack(spacing: 14) {
            // 大头像：虚线圆圈 + 大加号
            ZStack {
                Circle()
                    .stroke(Theme.cardBorder, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .frame(width: 48, height: 48)
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Theme.accent)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("添加账号")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("登录新的账号")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
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

// MARK: - 添加账号全屏登录

/// 「添加账号」全屏登录：登录新账号成功后自动关闭并重建通知连接；
/// 直接取消/返回不影响当前登录账号。
struct LoginCover: View {
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss

    /// 打开登录页时的当前账号（判断是否登录了其他账号）
    @State private var openingID = AuthManager.shared.currentUser?.id
    @State private var openingToken = AuthManager.shared.currentUser?.token
    @State private var handled = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            LoginView()
                .environmentObject(auth)

            // 取消：返回切换账号弹窗，当前登录不受影响
            Button {
                dismiss()
            } label: {
                ZStack {
                    Circle().fill(Theme.card.opacity(0.92))
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                }
                .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 10)
        }
        // 登录了新账号（id 变化）或刷新了同账号 token：视为添加账号成功
        .onChange(of: auth.currentUser?.id) { newID in
            if newID != openingID {
                onLoggedIn()
            }
        }
        .onChange(of: auth.currentUser?.token) { newToken in
            if newToken != openingToken {
                onLoggedIn()
            }
        }
    }

    private func onLoggedIn() {
        guard !handled else { return }
        handled = true
        // 换 token 重建 WebSocket 连接 + 刷新未读数（登录态布尔值不变，不走 MusicApp 的 onChange）
        NotificationBus.shared.resetAndReconnect()
        Task { await NotificationBus.shared.refreshUnread() }
        dismiss()
    }
}
