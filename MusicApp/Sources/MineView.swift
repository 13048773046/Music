import SwiftUI
import UniformTypeIdentifiers

struct MineView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthManager
    @State private var trackCount: Int?
    @State private var showImporter = false
    @State private var pickedFileURL: URL?
    @State private var showUploadSheet = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    LazyVStack(spacing: 18) {
                        // 用户卡片
                        userCard
                        // 统计卡片
                        statsRow
                        // 功能入口
                        actionCard
                        // 关于
                        aboutCard
                        // 退出登录
                        logoutCard
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 120)
                }
            }
            .navigationBarHidden(true)
            .task {
                if trackCount == nil {
                    await loadCount()
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.audio, .mp3, .wav, .mpeg4Audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    pickedFileURL = url
                    showUploadSheet = true
                }
            case .failure:
                break
            }
        }
        .sheet(isPresented: $showUploadSheet) {
            if let url = pickedFileURL {
                UploadSheet(fileURL: url) {
                    await loadCount()
                }
            }
        }
        .tint(Theme.accent)
    }

    // MARK: - 用户资料卡（背景图 + 昵称 + 性别/年龄 + 签名 + IP，不显示头像）

    private var userCard: some View {
        let u = auth.currentUser
        return VStack(alignment: .leading, spacing: 0) {
            // 背景图横幅
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let bgURL = u?.backgroundURL {
                        CachedCoverImage(url: bgURL, title: u?.name ?? "",
                                         placeholder: Rectangle().fill(Theme.card))
                            .frame(height: 150)
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(Theme.card)
                            .frame(height: 150)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(u?.name ?? "未登录")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                    HStack(spacing: 8) {
                        if let gender = u?.gender, !gender.isEmpty, gender != "保密" {
                            tag(gender)
                        }
                        if let age = u?.age, age > 0 {
                            tag("\(age) 岁")
                        }
                    }
                }
                .padding(16)
            }

            VStack(alignment: .leading, spacing: 10) {
                if let sig = u?.signature, !sig.isEmpty {
                    Text(sig)
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textSecondary)
                }
                infoRow(icon: "at", label: "账号", value: u?.account ?? "--")
                infoRow(icon: "network", label: "登录 IP", value: u?.ip?.isEmpty == false ? u!.ip! : "--")
                infoRow(icon: "calendar", label: "注册时间",
                        value: Self.dateString(u?.created ?? 0))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(Theme.cardBorder, lineWidth: 1))
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.45), in: Capsule())
    }

    private func infoRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(Theme.textTertiary)
                .frame(width: 20)
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(Theme.textTertiary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
        }
    }

    private static func dateString(_ ts: Double) -> String {
        guard ts > 0 else { return "--" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }

    // MARK: - 退出登录

    private var logoutCard: some View {
        Button {
            auth.logout()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 17, weight: .semibold))
                Text("退出登录")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .foregroundColor(.red)
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Theme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Theme.cardBorder, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 统计卡片

    private var statsRow: some View {
        HStack(spacing: 14) {
            statCard(
                icon: "music.note.list",
                value: trackCount.map(String.init) ?? "--",
                label: "歌曲总数",
                iconColor: Theme.accent
            )
            statCard(
                icon: "speaker.wave.2.fill",
                value: player.current?.title ?? "无",
                label: "正在播放",
                iconColor: Theme.lilac
            )
        }
    }

    private func statCard(icon: String, value: String, label: String, iconColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(iconColor.opacity(0.16))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(iconColor)
            }
            Text(value)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .softCard(radius: 20, padding: 16)
    }

    // MARK: - 功能入口

    private var actionCard: some View {
        Button {
            showImporter = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.accentSoft)
                        .frame(width: 46, height: 46)
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(Theme.accent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("上传歌曲")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text("从本机选择音频，自动识别歌曲信息")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textTertiary)
            }
            .softCard(radius: 20, padding: 16)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 关于

    private var aboutCard: some View {
        VStack(spacing: 0) {
            aboutRow(icon: "server.rack", label: "服务器", value: "www.dbmt999.asia")
            Divider().padding(.leading, 56)
            aboutRow(icon: "info.circle", label: "版本", value: "v\(appVersion)")
        }
        .softCard(radius: 20, padding: 6)
    }

    private func aboutRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(Theme.accent)
                .frame(width: 30)
            Text(label)
                .font(.system(size: 14))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            Text(value)
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 12)
    }

    private func loadCount() async {
        do {
            let list = try await API.tracks()
            trackCount = list.count
        } catch {
            trackCount = 0
        }
    }
}
