import SwiftUI
import PhotosUI

/// 登录 / 注册页：未登录用户启动后看到。
/// 注册：密码 + 昵称 + 头像 + 性别 + 年龄 + 签名 + 背景图；账号由后端自动生成 6 位数字；
/// 成功后自动写入 Keychain 直接进首页，并在首页弹窗提示记住账号。
struct LoginView: View {
    @EnvironmentObject private var auth: AuthManager

    @State private var isRegister = false
    @State private var account = ""
    @State private var password = ""
    @State private var name = ""
    @State private var gender = "保密"
    @State private var ageText = ""
    @State private var signature = ""
    @State private var avatarData: Data?
    @State private var avatarImage: UIImage?
    @State private var pickerItem: PhotosPickerItem?
    @State private var bgData: Data?
    @State private var bgImage: UIImage?
    @State private var bgPickerItem: PhotosPickerItem?
    @State private var busy = false
    @State private var error: String?

    private let genders = ["男", "女", "保密"]

    private var canSubmit: Bool {
        !busy
            && !password.isEmpty
            && (isRegister
                ? !name.trimmingCharacters(in: .whitespaces).isEmpty
                : !account.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 76, height: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    Text("流萤音乐")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(Theme.textPrimary)

                    if isRegister {
                        bgPicker
                        avatarPicker
                        field("昵称", text: $name)
                        genderRow
                        field("年龄", text: $ageText)
                            .keyboardType(.numberPad)
                        field("签名（一句话介绍自己）", text: $signature)
                        Text("账号将由系统自动生成 6 位数字，注册成功后请牢记")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                    }

                    if !isRegister {
                        field("账号", text: $account)
                    }
                    SecureFieldCustom("密码", text: $password)

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
                .padding(.top, 36)
            }
        }
        .onChange(of: pickerItem) { _ in
            Task { await loadAvatar() }
        }
        .onChange(of: bgPickerItem) { _ in
            Task { await loadBackground() }
        }
    }

    // MARK: - 性别选择

    private var genderRow: some View {
        HStack(spacing: 10) {
            ForEach(genders, id: \.self) { g in
                Button {
                    gender = g
                } label: {
                    Text(g)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(gender == g ? .white : Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(gender == g ? Theme.accent : Theme.card,
                                    in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
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
                    Circle().fill(Theme.card)
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 22))
                        .foregroundColor(Theme.accent)
                }
            }
            .frame(width: 76, height: 76)
            .clipShape(Circle())
            .overlay(Circle().stroke(Theme.cardBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var bgPicker: some View {
        PhotosPicker(selection: $bgPickerItem, matching: .images) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let bgImage {
                        Image(uiImage: bgImage)
                            .resizable()
                            .scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Theme.card)
                            .overlay(
                                Image(systemName: "photo.on.rectangle")
                                    .font(.system(size: 20))
                                    .foregroundColor(Theme.accent)
                            )
                    }
                }
                .frame(height: 90)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text(bgImage == nil ? "选择个人页背景图" : "更换背景图")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.45),
                                in: RoundedRectangle(cornerRadius: 6))
                    .padding(10)
            }
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.cardBorder, lineWidth: 1))
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

    private func loadBackground() async {
        guard let item = bgPickerItem else { return }
        if let data = try? await item.loadTransferable(type: Data.self),
           let image = UIImage(data: data) {
            bgData = data
            bgImage = image
        }
    }

    // MARK: - 提交

    private func submit() async {
        busy = true
        error = nil
        do {
            if isRegister {
                try await auth.register(
                    password: password,
                    name: name.trimmingCharacters(in: .whitespaces),
                    avatarData: avatarData,
                    gender: gender,
                    age: Int(ageText) ?? 0,
                    signature: signature.trimmingCharacters(in: .whitespaces),
                    backgroundData: bgData)
            } else {
                try await auth.login(account: account.trimmingCharacters(in: .whitespaces),
                                     password: password)
            }
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
