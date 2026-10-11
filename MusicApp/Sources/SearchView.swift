import SwiftUI

// MARK: - 搜索页面

/// 顶部搜索框 + 搜索结果列表。
/// 深色极简风格，点击结果加入播放队列并播放。
struct SearchView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss

    @State private var keyword = ""
    @State private var results: [Track] = []
    @State private var searching = false
    @State private var hasSearched = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    searchBar
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                    if searching {
                        ProgressView()
                            .tint(.white)
                            .frame(maxHeight: .infinity)
                    } else if results.isEmpty && hasSearched {
                        emptyState
                            .frame(maxHeight: .infinity)
                    } else if results.isEmpty {
                        // 初始状态：推荐提示
                        VStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 40))
                                .foregroundColor(.white.opacity(0.3))
                            Text("搜索歌曲、歌手")
                                .font(.system(size: 15))
                                .foregroundColor(.white.opacity(0.5))
                        }
                        .frame(maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(results) { track in
                                    SearchRow(track: track) {
                                        play(track: track)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 16)
                        }
                    }
                }
            }
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    // MARK: - 搜索框

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.5))
            TextField("输入歌名或歌手", text: $keyword)
                .textFieldStyle(.plain)
                .foregroundColor(.white)
                .submitLabel(.search)
                .onSubmit { doSearch() }
            if !keyword.isEmpty {
                Button {
                    keyword = ""
                    results = []
                    hasSearched = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.3))
            Text("没找到「\(keyword)」相关歌曲")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.5))
        }
    }

    // MARK: - 操作

    private func doSearch() {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        hasSearched = true
        searching = true
        // 搜索关键词上报（个性化推荐信号：搜过什么 → 推相关歌曲）
        let ev = API.BehaviorEvent(trackId: "", event: "search", value: 0,
                                   meta: API.BehaviorEvent.metaJSON(["kw": kw]))
        Task { await API.reportBehavior([ev]) }
        Task {
            do {
                let found = try await API.search(kw)
                results = found
            } catch {
                results = []
            }
            searching = false
        }
    }

    private func play(track: Track) {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        if kw.isEmpty {
            // 无关键词（例如点击默认结果）：切回普通流，并入全局曲库播放
            library.searchContext = nil
            if !library.tracks.contains(where: { $0.id == track.id }) {
                library.tracks.append(track)
            }
            player.playInNormalMode(track, in: library.tracks)
        } else {
            // 建立搜索相关流：以当前歌曲立即播放，后台拉取第一批相关歌曲
            // （每次 10 首随机，歌名/歌手/专辑/上传者相关优先，不足补全随机），
            // 首页上下滑动即可在相关歌曲间切换，滑到末尾自动续拉下一批
            library.startSearchStream(keyword: kw, first: track)
        }
        // 播放后关闭搜索页，回到首页播放页查看同步的歌曲信息
        dismiss()
    }
}

// MARK: - 搜索结果行

private struct SearchRow: View {
    @EnvironmentObject private var player: PlayerManager
    let track: Track
    let onTap: () -> Void

    private var isCurrent: Bool {
        player.current?.id == track.id
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                AlbumArt(size: 48, title: track.title, coverURL: track.coverURL, radius: 8)

                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(track.artist.flatMap { $0.isEmpty ? nil : $0 } ?? "未知歌手")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }

                Spacer()

                if isCurrent && player.isPlaying {
                    EqualizerBars(color: .white)
                } else {
                    Text(track.durText ?? "")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .padding(10)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
