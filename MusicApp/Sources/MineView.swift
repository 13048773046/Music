import SwiftUI
import UniformTypeIdentifiers

struct MineView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthManager
    @State private var trackCount: Int?
    @State private var listenSeconds: Int = 0
    @State private var myTracks: [[String: Any]] = []
    @State private var myLikes: [[String: Any]] = []
    @State private var myComments: [[String: Any]] = []
    @State private var showImporter = false
    @State private var pickedFileURL: URL?
    @State private var showUploadSheet = false
    @State private var showProfileEdit = false

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
                        // 我的上传作品
                        myTracksSection
                        // 我点赞的歌
                        myLikesSection
                        // 我评论过的歌
                        myCommentsSection
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
                await loadListenStats()
                await loadMyData()
            }
            .refreshable {
                await loadListenStats()
                await loadMyData()
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
                .environmentObject(auth)
            }
        }
        .sheet(isPresented: $showProfileEdit) {
            NavigationStack {
                ProfileEditView()
                    .environmentObject(auth)
            }
        }
        .tint(Theme.accent)
    }

    // MARK: - 用户资料卡（背景图 + 头像 + 昵称 + 性别/年龄 + 签名 + IP，点击进编辑页）

    private var userCard: some View {
        let u = auth.currentUser
        return VStack(alignment: .leading, spacing: 0) {
            // 头部：背景图 150 + 头像压边区 38
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Theme.card)

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

                HStack(alignment: .center, spacing: 14) {
                    // 头像：按 id 请求，后端无图时自动占位
                    ZStack {
                        CachedCoverImage(
                            url: u?.avatarURL ?? URL(string: "about:blank")!,
                            title: u?.name ?? "",
                            placeholder:
                                Circle().fill(Theme.accentSoft)
                                    .overlay(Image(systemName: "person.fill")
                                        .font(.system(size: 28))
                                        .foregroundColor(Theme.accent))
                        )
                    }
                    .frame(width: 76, height: 76)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Theme.card, lineWidth: 3))

                    VStack(alignment: .leading, spacing: 5) {
                        Text(u?.name ?? "未登录")
                            .font(.system(size: 20, weight: .bold))
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
                    .padding(.trailing, 12)
                }
                .padding(.leading, 16)
                .padding(.top, 112)   // 头像中心压在背景图下沿（150 - 38）
            }
            .frame(height: 188)
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 10) {
                if let sig = u?.signature, !sig.isEmpty {
                    Text(sig)
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(Theme.cardBorder, lineWidth: 1))
        .onTapGesture { showProfileEdit = true }
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
                icon: "clock.fill",
                value: listenHoursText,
                label: "听歌时长",
                iconColor: Theme.sky
            )
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

    // MARK: - 我的上传作品
    private var myTracksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("我的作品")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text("\(myTracks.count) 首")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textTertiary)
            }
            if myTracks.isEmpty {
                Text("还没有上传歌曲")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ForEach(myTracks.indices, id: \.self) { i in
                    let t = myTracks[i]
                    Button {
                        if let tid = t["id"] as? String,
                           let track = Library.shared.tracks.first(where: { $0.id == tid }) {
                            player.play(track, in: Library.shared.tracks)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Theme.accent.opacity(0.2))
                                .frame(width: 40, height: 40)
                                .overlay(Image(systemName: "music.note").font(.system(size: 14)).foregroundColor(Theme.accent))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(t["title"] as? String ?? "")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(Theme.textPrimary)
                                    .lineLimit(1)
                                Text(t["artist"] as? String ?? "")
                                    .font(.system(size: 12))
                                    .foregroundColor(Theme.textTertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text("\(t["playCount"] as? Int ?? 0) 播放")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textTertiary)
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
        .softCard(radius: 20, padding: 16)
    }

    // MARK: - 我点赞的歌
    private var myLikesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("我的喜欢")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text("\(myLikes.count) 首")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textTertiary)
            }
            if myLikes.isEmpty {
                Text("还没有点赞过歌曲")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ForEach(myLikes.indices, id: \.self) { i in
                    let t = myLikes[i]
                    Button {
                        if let tid = t["id"] as? String,
                           let track = Library.shared.tracks.first(where: { $0.id == tid }) {
                            player.play(track, in: Library.shared.tracks)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Theme.peach.opacity(0.2))
                                .frame(width: 40, height: 40)
                                .overlay(Image(systemName: "heart.fill").font(.system(size: 14)).foregroundColor(Theme.peach))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(t["title"] as? String ?? "")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(Theme.textPrimary)
                                    .lineLimit(1)
                                Text(t["artist"] as? String ?? "")
                                    .font(.system(size: 12))
                                    .foregroundColor(Theme.textTertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
        .softCard(radius: 20, padding: 16)
    }

    // MARK: - 我评论过的歌
    private var myCommentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("我的评论")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text("\(myComments.count) 条")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textTertiary)
            }
            if myComments.isEmpty {
                Text("还没有发表过评论")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ForEach(myComments.indices, id: \.self) { i in
                    let c = myComments[i]
                    VStack(alignment: .leading, spacing: 6) {
                        Text(c["title"] as? String ?? "")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                        Text("「\(c["content"] as? String ?? "")」")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .softCard(radius: 20, padding: 16)
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

    private func loadListenStats() async {
        guard let token = auth.authToken else { return }
        guard let url = URL(string: "https://www.dbmt999.asia/music/api/my-stats") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            listenSeconds = (obj?["totalSeconds"] as? Int) ?? 0
        } catch {}
    }

    private func loadMyData() async {
        guard let token = auth.authToken else { return }
        let endpoints = [
            ("my-tracks", \Self.myTracks),
            ("my-likes", \Self.myLikes),
            ("my-comments", \Self.myComments)
        ]
        for (path, _) in endpoints {
            guard let url = URL(string: "https://www.dbmt999.asia/music/api/\(path)") else { continue }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                if let list = obj?["list"] as? [[String: Any]] {
                    await MainActor.run {
                        if path == "my-tracks" { myTracks = list }
                        else if path == "my-likes" { myLikes = list }
                        else { myComments = list }
                    }
                }
            } catch {}
        }
    }

    /// 听歌时长格式化：不足1小时显示分钟，否则显示小时
    private var listenHoursText: String {
        guard listenSeconds > 0 else { return "0" }
        let hours = Double(listenSeconds) / 3600.0
        if hours < 1 {
            let mins = Int(listenSeconds / 60)
            return "\(mins)分"
        }
        return String(format: "%.1f", hours)
    }
}
