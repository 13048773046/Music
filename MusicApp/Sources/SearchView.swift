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
    /// 请求序号：快速连续搜索时旧响应后到直接丢弃，防止旧结果覆盖新结果
    @State private var searchToken = 0
    /// 搜索历史
    @State private var searchHistory: [SearchHistoryItem] = []

    var body: some View {
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
                    // 初始状态：显示搜索历史
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("搜索历史")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white.opacity(0.7))
                                Spacer()
                                if !searchHistory.isEmpty {
                                    Button {
                                        Task {
                                            await API.clearSearchHistory()
                                            searchHistory = []
                                        }
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 13))
                                            .foregroundColor(.white.opacity(0.5))
                                    }
                                }
                            }
                            if searchHistory.isEmpty {
                                VStack(spacing: 12) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 40))
                                        .foregroundColor(.white.opacity(0.3))
                                    Text("搜索歌曲、歌手")
                                        .font(.system(size: 15))
                                        .foregroundColor(.white.opacity(0.5))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                            } else {
                                ForEach(searchHistory) { item in
                                    Button {
                                        keyword = item.keyword
                                        doSearch()
                                    } label: {
                                        Text(item.keyword)
                                            .font(.system(size: 14))
                                            .foregroundColor(.white.opacity(0.8))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.vertical, 8)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                    }
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
        // 搜索页作为独立页面 push 时，明确显示导航栏（含返回按钮）
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            Task {
                searchHistory = (try? await API.fetchSearchHistory()) ?? []
            }
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
        // 递增请求序号：本次请求的响应只有仍是最新序号时才生效
        searchToken += 1
        let token = searchToken
        // 搜索关键词上报（个性化推荐信号：搜过什么 → 推相关歌曲）
        let ev = API.BehaviorEvent(trackId: "", event: "search", value: 0,
                                   meta: API.BehaviorEvent.metaJSON(["kw": kw]))
        Task { await API.reportBehavior([ev]) }
        // 记录搜索历史
        Task { await API.recordSearch(keyword: kw) }
        Task {
            let found = try? await API.search(kw)
            // 旧请求的迟到响应：丢弃，不覆盖最新搜索结果
            guard token == searchToken else { return }
            results = found ?? []
            searching = false
        }
    }

    private func play(track: Track) {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        if kw.isEmpty {
            // 无关键词（例如点击默认结果）：进入个性化推荐流（汽水式），以该歌为当前曲；
            // 推荐不可用时回退全库流，保证点歌必有声音
            library.searchContext = nil
            if !library.tracks.contains(where: { $0.id == track.id }) {
                library.tracks.append(track)
            }
            player.startRecommendedStream(startingAt: track, fallback: library.tracks)
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
