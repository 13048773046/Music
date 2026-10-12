import SwiftUI

// MARK: - 设置页

/// 设置页：从「我的」右上角齿轮进入。
/// 分组：账号（修改用户信息 / 修改密码）、通用（清理缓存 / 检查更新）、
/// 关于（版本 / 官网）、退出登录。
struct SettingsView: View {
    @EnvironmentObject private var auth: AuthManager

    @State private var showClearAlert = false
    @State private var showNoUpdate = false
    @State private var showUpdateSheet = false
    @State private var showLogoutConfirm = false
    @State private var checkBusy = false
    @State private var updateCheck: API.UpdateCheck?

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 12) {
                    accountSection
                    generalSection
                    aboutSection
                    logoutButton
                }
                .padding(20)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .alert("缓存已清理", isPresented: $showClearAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("封面图片缓存已释放，下次加载会自动重新缓存。")
        }
        .alert("已是最新版本", isPresented: $showNoUpdate) {
            Button("好", role: .cancel) {}
        } message: {
            Text("当前已是最新版本 v\(appVersion)。")
        }
        .alert("确认退出登录？", isPresented: $showLogoutConfirm) {
            Button("取消", role: .cancel) {}
            Button("退出", role: .destructive) {
                auth.logout()
            }
        } message: {
            Text("退出后本地登录状态将被清除，需要重新登录才能使用。")
        }
        .sheet(isPresented: $showUpdateSheet) {
            if let u = updateCheck {
                UpdateSheet(update: UpdateNotice(
                    id: u.id ?? "",
                    title: u.title ?? "发现新版本",
                    content: u.content ?? "",
                    version: u.version ?? "",
                    forceUpdate: u.forceUpdate ?? 0,
                    downloadUrl: u.downloadUrl ?? ""
                ))
                .presentationDetents([.medium])
            }
        }
    }

    // MARK: - 账号

    private var accountSection: some View {
        VStack(spacing: 8) {
            NavigationLink {
                ProfileEditView()
                    .environmentObject(auth)
            } label: {
                rowContent(icon: "person.crop.circle", tint: Theme.accent,
                           title: "修改用户信息", value: nil)
            }
            .buttonStyle(.plain)

            NavigationLink {
                ChangePasswordView()
                    .environmentObject(auth)
            } label: {
                rowContent(icon: "lock", tint: Theme.accent,
                           title: "修改密码", value: nil)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 通用

    private var generalSection: some View {
        VStack(spacing: 8) {
            Button {
                clearCache()
            } label: {
                rowContent(icon: "trash", tint: .orange,
                           title: "清理缓存", value: nil)
            }
            .buttonStyle(.plain)

            Button {
                Task { await checkUpdate() }
            } label: {
                rowContent(icon: "arrow.clockwise.circle", tint: Theme.sky,
                           title: "检查更新",
                           value: checkBusy ? "检查中…" : "v\(appVersion)")
            }
            .buttonStyle(.plain)
            .disabled(checkBusy)
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        VStack(spacing: 8) {
            rowContent(icon: "info.circle", tint: Theme.textTertiary,
                       title: "版本", value: "v\(appVersion)")
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            rowContent(icon: "globe", tint: Theme.textTertiary,
                       title: "官网", value: "www.dbmt999.asia")
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: - 退出登录

    private var logoutButton: some View {
        Button {
            showLogoutConfirm = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 15, weight: .semibold))
                Text("退出登录")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundColor(.red)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
    }

    // MARK: - 通用行

    private func rowContent(icon: String, tint: Color, title: String,
                            value: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(title)
                .font(.system(size: 15))
                .foregroundColor(Theme.textPrimary)

            Spacer()

            if let value {
                Text(value)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textTertiary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textTertiary.opacity(0.6))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - 逻辑

    /// 清理缓存：封面内存缓存 + URL 会话缓存
    private func clearCache() {
        CoverImageCache.shared.clear()
        URLCache.shared.removeAllCachedResponses()
        showClearAlert = true
    }

    /// 手动检查版本更新：有新版弹更新提示，无新版提示已是最新
    private func checkUpdate() async {
        checkBusy = true
        let result = await API.checkUpdate()
        checkBusy = false
        if let result, result.hasUpdate {
            updateCheck = result
            showUpdateSheet = true
        } else {
            showNoUpdate = true
        }
    }
}

// MARK: - 修改密码页

/// 修改密码：输入旧密码 + 新密码（6-64 位）+ 确认，调后端 change-password
struct ChangePasswordView: View {
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss

    @State private var oldPwd = ""
    @State private var newPwd = ""
    @State private var confirmPwd = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showDone = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    secureField("当前密码", text: $oldPwd)

                    secureField("新密码（6-64 位）", text: $newPwd)

                    secureField("确认新密码", text: $confirmPwd)

                    if let error {
                        Text(error)
                            .font(.footnote)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        Task { await save() }
                    } label: {
                        HStack(spacing: 8) {
                            if busy {
                                ProgressView().tint(.white)
                            } else {
                                Text("确认修改").fontWeight(.semibold)
                            }
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(busy)
                    .buttonStyle(.plain)
                }
                .padding(20)
            }
        }
        .navigationTitle("修改密码")
        .navigationBarTitleDisplayMode(.inline)
        .alert("密码已修改", isPresented: $showDone) {
            Button("好", role: .cancel) { dismiss() }
        } message: {
            Text("下次登录请使用新密码。")
        }
    }

    private func secureField(_ title: String, text: Binding<String>) -> some View {
        SecureField(title, text: text)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundColor(Theme.textPrimary)
    }

    private func save() async {
        let new = newPwd.trimmingCharacters(in: .whitespaces)
        // 本地校验
        if oldPwd.isEmpty {
            error = "请输入当前密码"
            return
        }
        if new.count < 6 || new.count > 64 {
            error = "新密码长度需 6-64 位"
            return
        }
        if new != confirmPwd {
            error = "两次输入的新密码不一致"
            return
        }
        busy = true
        error = nil
        do {
            try await auth.changePassword(old: oldPwd, new: new)
            showDone = true
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }
}
