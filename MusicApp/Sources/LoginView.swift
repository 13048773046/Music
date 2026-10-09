import SwiftUI
import PhotosUI

/// 登录 / 注册页：未登录用户启动后看到。
/// 注册只需 账号 + 密码 + 昵称 + 头像，成功后自动写入 Keychain 直接进首页；
/// 登录态持久化，杀后台重进无需再次登录。
struct LoginView: View {
    @EnvironmentObject private var auth: AuthManager

    @State private var isRegister = false
    @State private var account = ""
    @State private var password = ""
    @State private var name = ""
    @State private var avatarData: Data?
    @State private var avatarImage: UIImage?
    @State private var pickerItem: PhotosPickerItem?
    @State private var busy = false
    @State private var error: String?

    private var canSubmit: Bool {
        !busy
            && !account.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && (!isRegister || !name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    Text("流萤音乐")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(Theme.textPrimary)

                    if isRegister {
                        avatarPicker
                    }

                    field("账号", text: $account)
                    SecureFieldCustom("密码", text: $password)
                    if isRegister {
                        field("昵称", text: $name)
                    }

                    Button {
                        Task { await submit() }
                    } label: {
                        HStack(spacing: 8) {
                            if busy {
                                ProgressView().tint(.white)
                            } else {
                                Text(isRegister ? "注册并进入" : "登录")
                                    .fontWeight(.semibold)
                            }
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(!canSubmit)
                    .buttonStyle(.plain)

                    Button {
                        withAnimation {
                            isRegister.toggle()
                            error = nil
                        }
                    } label: {
                        Text(isRegister ? "已有账号？去登录" : "没有账号？注册新账号")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)

                    if let error {
                        Text(error)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }
                .padding(24)
                .padding(.top, 40)
            }
        }
        .onChange(of: pickerItem) { _ in
            Task { await loadAvatar() }
        }
    }

    // MARK: - 头像选择

    private var avatarPicker: some View {
        PhotosPicker(selection: $pickerItem, matching: .images) {
            ZStack {
                if let avatarImage {
                    Image(uiImage: avatarImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    Circle()
                        .fill(Theme.card)
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 22))
                        .foregroundColor(Theme.accent)
                }
            }
            .frame(width: 84, height: 84)
            .clipShape(Circle())
            .overlay(Circle().stroke(Theme.cardBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func loadAvatar() async {
        guard let item = pickerItem else { return }
        if let data = try? await item.loadTransferable(type: Data.self),
           let image = UIImage(data: data) {
            avatarData = data
            avatarImage = image
        }
    }

    // MARK: - 提交

    private func submit() async {
        busy = true
        error = nil
        do {
            if isRegister {
                try await auth.register(account: account.trimmingCharacters(in: .whitespaces),
                                        password: password,
                                        name: name.trimmingCharacters(in: .whitespaces),
                                        avatarData: avatarData)
            } else {
                try await auth.login(account: account.trimmingCharacters(in: .whitespaces),
                                     password: password)
            }
            // 成功后 currentUser 变化，根视图自动切到 MainTabView
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .foregroundColor(Theme.textPrimary)
    }

    private func SecureFieldCustom(_ title: String, text: Binding<String>) -> some View {
        SecureField(title, text: text)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .foregroundColor(Theme.textPrimary)
    }
}
