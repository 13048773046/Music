import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: Library
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
                                    library.playFromDiscover(track)
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
                                    library.playFromDiscover(track)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }

                sectionTitle("全部歌曲", subtitle: "共 \(library.tracks.count) 首")
                LazyVStack(spacing: 10) {
                    ForEach(library.tracks) { track in
                        TrackRow(track: track) {
                            library.playFromDiscover(track)
                        }
                        .softCard(radius: 14, padding: 8)
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 12)
            .padding(.bottom, 120)
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
                    .fill(Theme.accent)
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

    // MARK: - 加载（复用启动页预加载的 Library 数据）

    func load() async {
        if library.isLoaded {
            applySections()
            return
        }
        state = .loading
        await library.load()
        applySections()
    }

    private func applySections() {
        if library.tracks.isEmpty {
            state = .empty
        } else {
            buildSections(from: library.tracks)
            state = .loaded
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
                        .background(Theme.accent, in: Capsule())
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
