import SwiftUI

/// 我的歌单列表页
struct PlaylistsView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var player: PlayerManager
    @State private var playlists: [Playlist] = []
    @State private var isLoading = false
    @State private var showCreateSheet = false
    @State private var newName = ""
    @State private var newDesc = ""

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if playlists.isEmpty && isLoading {
                    ProgressView().padding(.top, 60)
                } else if playlists.isEmpty {
                    emptyState
                        .padding(.top, 80)
                } else {
                    ForEach(playlists) { pl in
                        NavigationLink {
                            PlaylistDetailView(playlist: pl)
                                .environmentObject(player)
                        } label: {
                            playlistRow(pl)
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("我的歌单")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showCreateSheet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22))
                }
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            createSheet
        }
        .onAppear { Task { await reload() } }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.card)
                    .frame(width: 80, height: 80)
                Image(systemName: "music.note.list")
                    .font(.system(size: 32))
                    .foregroundColor(Theme.textTertiary)
            }
            Text("还没有歌单")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Text("点击右上角 + 创建你的第一个歌单")
                .font(.system(size: 13))
                .foregroundColor(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func playlistRow(_ pl: Playlist) -> some View {
        HStack(spacing: 14) {
            // 歌单封面：用最新歌曲封面
            if !pl.cover.isEmpty, let url = URL(string: pl.cover) {
                AsyncImage(url: url) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(Theme.card).overlay(
                        Image(systemName: "music.note").foregroundColor(Theme.textTertiary)
                    )
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.card)
                    .frame(width: 56, height: 56)
                    .overlay(
                        Image(systemName: "music.note")
                            .foregroundColor(Theme.textTertiary)
                    )
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(pl.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text("\(pl.trackCount) 首歌曲")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                if !pl.description.isEmpty {
                    Text(pl.description)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private var createSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("歌单名称", text: $newName)
                } header: {
                    Text("名称")
                }
                Section {
                    TextField("描述（可选）", text: $newDesc)
                } header: {
                    Text("描述")
                }
            }
            .navigationTitle("新建歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showCreateSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") { Task { await createPlaylist() } }
                        .disabled(newName.isEmpty)
                }
            }
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            playlists = try await API.fetchPlaylists()
        } catch {}
    }

    private func createPlaylist() async {
        do {
            let _ = try await API.createPlaylist(name: newName, description: newDesc)
            showCreateSheet = false
            newName = ""
            newDesc = ""
            await reload()
        } catch {}
    }
}

/// 歌单详情页
struct PlaylistDetailView: View {
    let playlist: Playlist
    @EnvironmentObject private var player: PlayerManager
    @State private var tracks: [HistoryTrack] = []
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // 头部：歌单封面 + 信息
                VStack(spacing: 14) {
                    if !playlist.cover.isEmpty, let url = URL(string: playlist.cover) {
                        AsyncImage(url: url) { img in
                            img.resizable().scaledToFill()
                        } placeholder: {
                            Rectangle().fill(Theme.card)
                        }
                        .frame(width: 140, height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 6)
                    } else {
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Theme.card)
                            .frame(width: 140, height: 140)
                            .overlay(
                                Image(systemName: "music.note")
                                    .font(.system(size: 50))
                                    .foregroundColor(Theme.textTertiary)
                            )
                    }

                    Text(playlist.name)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(Theme.textPrimary)

                    Text("\(playlist.trackCount) 首歌曲")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(.vertical, 28)

                // 歌曲列表
                if tracks.isEmpty && isLoading {
                    ProgressView().padding(.top, 40)
                } else if tracks.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "music.note.badge.plus")
                            .font(.system(size: 28))
                            .foregroundColor(Theme.textTertiary)
                        Text("歌单是空的")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.textSecondary)
                        Text("去歌曲详情页添加喜欢的歌曲吧")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .padding(.top, 40)
                } else {
                    ForEach(tracks) { t in
                        trackRow(t)
                            .padding(.horizontal, 16)
                    }
                }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Task { await load() } }
    }

    private func trackRow(_ t: HistoryTrack) -> some View {
        HStack(spacing: 12) {
            AlbumArt(size: 44, title: t.title, coverURL: URL(string: t.cover), radius: 9)
            VStack(alignment: .leading, spacing: 4) {
                Text(t.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text(t.artist)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                Task { await removeTrack(t) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15))
                    .foregroundColor(.red.opacity(0.6))
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            let track = Track(id: t.trackId, title: t.title, artist: t.artist,
                              album: nil, cover: t.cover, size: nil,
                              dur: nil, durText: nil, created: t.created,
                              playCount: nil, likeCount: nil, shareCount: nil,
                              commentCount: nil, userId: nil, userName: nil,
                              hasLyric: nil, isLiked: nil, reason: nil)
            let queue = tracks.map { Track(id: $0.trackId, title: $0.title, artist: $0.artist,
                                            album: nil, cover: $0.cover, size: nil,
                                            dur: nil, durText: nil, created: $0.created,
                                            playCount: nil, likeCount: nil, shareCount: nil,
                                            commentCount: nil, userId: nil, userName: nil,
                                            hasLyric: nil, isLiked: nil, reason: nil) }
            player.play(track, in: queue)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let (_, list) = try await API.fetchPlaylistTracks(playlist.id)
            tracks = list
        } catch {}
    }

    private func removeTrack(_ t: HistoryTrack) async {
        await API.removeFromPlaylist(playlistId: playlist.id, trackId: t.trackId)
        await load()
    }
}
