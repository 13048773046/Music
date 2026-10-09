import SwiftUI
import PhotosUI

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
    @State private var avatarPickerItem: PhotosPickerItem?
    @State private var bgData: Data?
    @State private var bgImage: UIImage?
    @State private var bgPickerItem: PhotosPickerItem?
    @State private var busy = false
    @State private var error: String?
    @State private var showSaved = false

    private let genders = ["男", "女", "保密"]

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    header

                    inputCard

                    Button {
                        Task { await save() }
                    } label: {
                        HStack(spacing: 8) {
                            if busy {
                                ProgressView().tint(.white)
                            } else {
                                Text("保存修改").fontWeight(.semibold)
                            }
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(busy)
                    .buttonStyle(.plain)

                    if let error {
                        Text(error).font(.footnote).foregroundColor(.red)
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("编辑资料")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { seed() }
        .onChange(of: avatarPickerItem) { _ in Task { await loadAvatar() } }
        .onChange(of: bgPickerItem) { _ in Task { await loadBg() } }
        .alert("已保存", isPresented: $showSaved) {
            Button("好", role: .cancel) { dismiss() }
        }
    }

    // MARK: - 头部：背景图 + 头像

    private var header: some View {
        ZStack(alignment: .topLeading) {
            // 底层 card 色，撑满整个卡片（160 图区 + 40 头像区）
            Rectangle().fill(Theme.card)

            // 背景图：顶部 160 高
            PhotosPicker(selection: $bgPickerItem, matching: .images) {
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
            PhotosPicker(selection: $avatarPickerItem, matching: .images) {
                ZStack {
                    if let avatarImage {
                        Image(uiImage: avatarImage).resizable().scaledToFill()
                    } else if let avURL = auth.currentUser?.avatarURL {
                        CachedCoverImage(url: avURL, title: auth.currentUser?.name ?? "",
                                         placeholder: Circle().fill(Theme.accentSoft))
                    } else {
                        Circle().fill(Theme.accentSoft)
                        Image(systemName: "person.fill")
                            .font(.system(size: 26))
                            .foregroundColor(Theme.accent)
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

    private func loadAvatar() async {
        guard let item = avatarPickerItem else { return }
        if let data = try? await item.loadTransferable(type: Data.self),
           let img = UIImage(data: data) {
            avatarData = data; avatarImage = img
        }
    }

    private func loadBg() async {
        guard let item = bgPickerItem else { return }
        if let data = try? await item.loadTransferable(type: Data.self),
           let img = UIImage(data: data) {
            bgData = data; bgImage = img
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
