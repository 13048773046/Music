import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var player: PlayerManager
    @State private var tracks: [Track] = []
    @State private var state: LoadState = .loading

    private var latest: [Track] {
        Array(tracks.prefix(6))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .loading:
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("加载中…")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .failed(let message):
                    VStack(spacing: 16) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 44))
                            .foregroundColor(.secondary)
                        Text("加载失败")
                            .font(.headline)
                        Text(message)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button {
                            Task { await load() }
                        } label: {
                            Text("重试")
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .empty:
                    VStack(spacing: 16) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 46))
                            .foregroundColor(.secondary)
                        Text("暂时没有可发现的内容")
                            .font(.headline)
                        Text("去首页上传歌曲后，这里会有推荐")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .loaded:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if !latest.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("最新上架")
                                        .font(.title3.bold())
                                        .padding(.horizontal)
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 14) {
                                            ForEach(latest) { track in
                                                DiscoverCard(track: track) {
                                                    player.play(track, in: tracks)
                                                }
                                            }
                                        }
                                        .padding(.horizontal)
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 12) {
                                Text("全部歌曲")
                                    .font(.title3.bold())
                                    .padding(.horizontal)
                                LazyVGrid(
                                    columns: [GridItem(.flexible(), spacing: 14),
                                              GridItem(.flexible(), spacing: 14)],
                                    spacing: 18
                                ) {
                                    ForEach(tracks) { track in
                                        GridCard(track: track) {
                                            player.play(track, in: tracks)
                                        }
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                        .padding(.vertical)
                    }
                    .refreshable {
                        await load()
                    }
                }
            }
            .navigationTitle("发现音乐")
            .task {
                if case .loaded = state {} else {
                    await load()
                }
            }
        }
    }

    func load() async {
        state = .loading
        do {
            let list = try await API.tracks()
            tracks = list
            state = list.isEmpty ? .empty : .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

// 横向大卡片
private struct DiscoverCard: View {
    @EnvironmentObject private var player: PlayerManager
    let track: Track
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                AlbumArt(size: 150, title: track.title, coverURL: track.coverURL)
                Text(track.title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundColor(.primary)
                Text(track.artist ?? "未知歌手")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 150)
        }
        .buttonStyle(.plain)
    }
}

// 网格卡片
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
                    AlbumArt(size: 160, title: track.title, coverURL: track.coverURL)
                        .frame(maxWidth: .infinity)
                    if isCurrent {
                        Image(systemName: "waveform")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(.black.opacity(0.5), in: Circle())
                            .padding(8)
                    }
                }
                Text(track.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .foregroundColor(.primary)
                HStack(spacing: 4) {
                    Text(track.artist ?? "未知歌手")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    if let durText = track.durText, durText != "--:--" {
                        Text("· \(durText)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}
