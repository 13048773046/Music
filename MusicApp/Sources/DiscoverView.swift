import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var player: PlayerManager
    @State private var tracks: [Track] = []
    @State private var state: LoadState = .loading
    @State private var latest: [Track] = []
    @State private var recommended: [Track] = []

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                Group {
                    switch state {
                    case .loading:
                        VStack(spacing: 14) {
                            ProgressView()
                                .tint(Theme.accent)
                            Text("加载中…")
                                .font(.footnote)
                                .foregroundColor(Theme.textSecondary)
                        }

                    case .failed(let message):
                        StatusPlaceholder(
                            icon: "wifi.exclamationmark",
                            title: "加载失败",
                            message: message
                        ) {
                            Task { await load() }
                        }

                    case .empty:
                        StatusPlaceholder(
                            icon: "sparkles",
                            title: "暂时没有可发现的内容",
                            message: "去首页上传歌曲后，这里会有推荐"
                        )

                    case .loaded:
                        content
                    }
                }
            }
            .navigationBarHidden(true)
            .task {
                if case .loaded = state {} else {
                    await load()
                }
            }
        }
        .tint(Theme.accent)
    }

    // MARK: - 内容

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                // 头部
                header

                if !recommended.isEmpty {
                    sectionTitle("为你推荐", subtitle: "根据你的喜好精选")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(recommended) { track in
                                RecommendCard(track: track) {
                                    player.play(track, in: tracks)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }

                if !latest.isEmpty {
                    sectionTitle("最新上架", subtitle: "刚刚入库的新鲜音乐")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(latest) { track in
                                LatestCard(track: track) {
                                    player.play(track, in: tracks)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }

                sectionTitle("全部歌曲", subtitle: "共 \(tracks.count) 首")
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 14),
                              GridItem(.flexible(), spacing: 14)],
                    spacing: 16
                ) {
                    ForEach(tracks) { track in
                        GridCard(track: track) {
                            player.play(track, in: tracks)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.vertical, 12)
        }
        .refreshable {
            await load()
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("发现音乐")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Text("好听的不止一首")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Theme.accent, Theme.sky],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 42, height: 42)
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 19, weight: .bold))
                .foregroundColor(Theme.textPrimary)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - 加载

    func load() async {
        state = .loading
        do {
            let list = try await API.tracks()
            tracks = list
            if list.isEmpty {
                state = .empty
            } else {
                buildSections(from: list)
                state = .loaded
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// 最新 = 按入库时间倒序前 6；推荐 = 其余歌曲随机 6 首
    private func buildSections(from list: [Track]) {
        let sorted = list.sorted { ($0.created ?? 0) > ($1.created ?? 0) }
        latest = Array(sorted.prefix(6))
        let rest = list.filter { !latest.contains($0) }
        recommended = Array(rest.shuffled().prefix(6))
    }
}

// MARK: - 推荐大卡片

private struct RecommendCard: View {
    let track: Track
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    AlbumArt(size: 190, title: track.title, coverURL: track.coverURL, radius: 18)
                    Text("推荐")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            LinearGradient(
                                colors: [Theme.accent, Theme.lilac],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: Capsule()
                        )
                        .padding(8)
                }

                Text(track.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .foregroundColor(Theme.textPrimary)
                Text(track.artist ?? "未知歌手")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: 190, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 最新上架卡片

private struct LatestCard: View {
    let track: Track
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                AlbumArt(size: 150, title: track.title, coverURL: track.coverURL, radius: 16)
                Text(track.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .foregroundColor(Theme.textPrimary)
                Text(track.artist ?? "未知歌手")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
            .softCard(radius: 18, padding: 12)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 全部歌曲网格卡片

private struct GridCard: View {
    @EnvironmentObject private var player: PlayerManager
    let track: Track
    let onTap: () -> Void

    private var isCurrent: Bool {
        player.current?.id == track.id
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    AlbumArt(size: 158, title: track.title, coverURL: track.coverURL, radius: 16)
                        .frame(maxWidth: .infinity)
                    if isCurrent {
                        HStack(spacing: 3) {
                            if player.isPlaying {
                                EqualizerBars(color: .white)
                            } else {
                                Image(systemName: "pause.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        .padding(7)
                        .background(Theme.accent, in: Circle())
                        .padding(8)
                    }
                }

                Text(track.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .foregroundColor(Theme.textPrimary)
                HStack(spacing: 4) {
                    Text(track.artist ?? "未知歌手")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                    if let durText = track.durText, durText != "--:--" {
                        Text("· \(durText)")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textTertiary)
                    }
                }
            }
            .softCard(radius: 20, padding: 10)
        }
        .buttonStyle(.plain)
    }
}
