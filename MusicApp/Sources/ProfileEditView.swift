import SwiftUI

/// 用户主页 / 编辑资料页：从「我的」资料卡点进来，可改昵称、性别、年龄、签名、头像、背景图。
struct ProfileEditView: View {
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var gender = "保密"
    @State private var ageText = ""
    @State private var signature = ""
    @State private var avatarData: Data?
    @State private var avatarImage: UIImage?
    @State private var bgData: Data?
    @State private var bgImage: UIImage?
    @State private var showAvatarPicker = false
    @State private var showBgPicker = false
    @State private var busy = false
    @State private var error: String?
    @State private var showSaved = false

    private let genders = ["男", "女", "保密"]

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // 固定头部：返回 + 标题 + 保存按钮。
                // 独立于下方 ScrollView 内容层，与背景图/头像 PhotosPicker 完全隔离，
                // 避免内容层的点击区域干扰返回按钮的触摸命中。
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                ScrollView {
                    VStack(spacing: 18) {
                        profileCard

                        inputCard

                        if let error {
                            Text(error)
                                .font(.footnote)
                                .foregroundColor(Color(hex: 0xFF6B6B))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            seed()
            NavBack.enableSwipeBack()
        }
        .sheet(isPresented: $showAvatarPicker) {
            ImagePicker(onPicked: pickedAvatar)
        }
        .sheet(isPresented: $showBgPicker) {
            ImagePicker(onPicked: pickedBg)
        }
        .alert("已保存", isPresented: $showSaved) {
            Button("好", role: .cancel) { NavBack.goBack(dismiss) }
        }
    }

    // MARK: - 头部（返回 + 大标题，与设置页一致）

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                NavBack.goBack(dismiss)
            } label: {
                ZStack {
                    Circle().fill(Theme.card)
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                }
                .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text("编辑资料")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Text("完善你的个人主页")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()

            // 保存按钮：右上角，与返回按钮同一行
            Button {
                Task { await save() }
            } label: {
                Group {
                    if busy {
                        ProgressView().tint(Theme.accent)
                    } else {
                        Text("保存")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Theme.accent)
                    }
                }
                .frame(minWidth: 52, minHeight: 38)
                .contentShape(Rectangle())
            }
            .disabled(busy)
            .buttonStyle(.plain)
        }
    }

    // MARK: - 资料卡：背景图 + 头像（点击更换）

    private var profileCard: some View {
        ZStack(alignment: .topLeading) {
            // 底层 card 色，撑满整个卡片（160 图区 + 40 头像区）
            Rectangle().fill(Theme.card)

            // 背景图：顶部 160 高（普通 Button 触发显式照片选择器，命中区域精确）
            Button {
                showBgPicker = true
            } label: {
                Group {
                    if let bgImage {
                        Image(uiImage: bgImage).resizable().scaledToFill()
                    } else if let bgURL = auth.currentUser?.backgroundURL {
                        CachedCoverImage(url: bgURL, title: auth.currentUser?.name ?? "",
                                         placeholder: Rectangle().fill(Theme.card))
                    } else {
                        Rectangle().fill(Theme.card)
                    }
                }
                .frame(height: 160)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "photo")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Color.black.opacity(0.45), in: Circle())
                        .padding(12)
                }
            }
            .buttonStyle(.plain)

            // 头像：压在背景图下沿（top = 160 - 38 = 122，leading = 16）
            Button {
                showAvatarPicker = true
            } label: {
                ZStack {
                    if let avatarImage {
                        Image(uiImage: avatarImage).resizable().scaledToFill()
                    } else {
                        CachedCoverImage(
                            url: auth.currentUser?.avatarURL ?? URL(string: "about:blank")!,
                            title: auth.currentUser?.name ?? "",
                            placeholder:
                                Circle().fill(Theme.accentSoft)
                                    .overlay(Image(systemName: "person.fill")
                                        .font(.system(size: 26))
                                        .foregroundColor(Theme.accent))
                        )
                    }
                }
                .frame(width: 76, height: 76)
                .clipShape(Circle())
                .overlay(Circle().stroke(Theme.background, lineWidth: 3))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(Theme.accent)
                        .background(Circle().fill(Theme.background))
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)
            .padding(.top, 122)
        }
        .frame(height: 200)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(Theme.cardBorder, lineWidth: 1))
        .padding(.bottom, 16)
    }

    // MARK: - 输入区

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("昵称").font(.system(size: 12, weight: .medium)).foregroundColor(Theme.textTertiary)
            field("输入昵称", text: $name)

            Text("性别").font(.system(size: 12, weight: .medium)).foregroundColor(Theme.textTertiary)
            HStack(spacing: 10) {
                ForEach(genders, id: \.self) { g in
                    Button { gender = g } label: {
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

            Text("年龄").font(.system(size: 12, weight: .medium)).foregroundColor(Theme.textTertiary)
            field("输入年龄", text: $ageText).keyboardType(.numberPad)

            Text("签名").font(.system(size: 12, weight: .medium)).foregroundColor(Theme.textTertiary)
            field("一句话介绍自己", text: $signature)
        }
        .padding(18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 10))
            .foregroundColor(Theme.textPrimary)
    }

    // MARK: - 逻辑

    private func seed() {
        guard let u = auth.currentUser else { return }
        name = u.name
        gender = u.gender ?? "保密"
        ageText = (u.age ?? 0) > 0 ? String(u.age ?? 0) : ""
        signature = u.signature ?? ""
    }

    private func pickedAvatar(_ data: Data) {
        if let img = UIImage(data: data) {
            avatarData = data
            avatarImage = img
        }
    }

    private func pickedBg(_ data: Data) {
        if let img = UIImage(data: data) {
            bgData = data
            bgImage = img
        }
    }

    private func save() async {
        busy = true
        error = nil
        do {
            try await auth.updateProfile(
                name: name.trimmingCharacters(in: .whitespaces),
                gender: gender,
                age: Int(ageText) ?? 0,
                signature: signature.trimmingCharacters(in: .whitespaces),
                avatarData: avatarData,
                backgroundData: bgData)
            showSaved = true
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }
}
