import SwiftUI

/// 我的歌单列表页
struct PlaylistsView: View {
    @EnvironmentObject private var auth: AuthManager
    @State private var playlists: [Playlist] = []
    @State private var isLoading = false
    @State private var showCreateSheet = false
    @State private var newName = ""
    @State private var newDesc = ""

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if playlists.isEmpty && isLoading {
                    ProgressView().padding(.top, 60)
                } else if playlists.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 40))
                            .foregroundColor(Theme.textTertiary)
                        Text("暂无歌单")
                            .font(.system(size: 15))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .padding(.top, 80)
                } else {
                    ForEach(playlists) { pl in
                        NavigationLink {
                            PlaylistDetailView(playlist: pl)
                        } label: {
                            playlistRow(pl)
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                }
            }
        }
        .navigationTitle("我的歌单")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            createSheet
        }
        .onAppear { Task { await reload() } }
    }

    private func playlistRow(_ pl: Playlist) -> some View {
        HStack(spacing: 12) {
            // 歌单封面：用歌曲封面，没有则用占位图
            if !pl.cover.isEmpty, let url = URL(string: pl.cover) {
                AsyncImage(url: url) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(Theme.card).overlay(
                        Image(systemName: "music.note").foregroundColor(Theme.textTertiary)
                    )
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.card)
                    .frame(width: 52, height: 52)
                    .overlay(
                        Image(systemName: "music.note")
                            .foregroundColor(Theme.textTertiary)
                    )
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(pl.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text("\(pl.trackCount) 首")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var createSheet: some View {
        NavigationStack {
            Form {
                TextField("歌单名称", text: $newName)
                TextField("描述（可选）", text: $newDesc)
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
            LazyVStack(spacing: 0) {
                // 头部：歌单封面 + 信息
                VStack(spacing: 12) {
                    if !playlist.cover.isEmpty, let url = URL(string: playlist.cover) {
                        AsyncImage(url: url) { img in
                            img.resizable().scaledToFill()
                        } placeholder: {
                            Rectangle().fill(Theme.card)
                        }
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    } else {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Theme.card)
                            .frame(width: 120, height: 120)
                            .overlay(
                                Image(systemName: "music.note")
                                    .font(.system(size: 40))
                                    .foregroundColor(Theme.textTertiary)
                            )
                    }
                    Text(playlist.name)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(Theme.textPrimary)
                    Text("\(playlist.trackCount) 首歌曲")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(.vertical, 24)

                if tracks.isEmpty && isLoading {
                    ProgressView().padding(.top, 40)
                } else if tracks.isEmpty {
                    Text("歌单是空的，去添加喜欢的歌曲吧")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textTertiary)
                        .padding(.top, 40)
                } else {
                    ForEach(tracks) { t in
                        trackRow(t)
                    }
                }
            }
        }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Task { await load() } }
    }

    private func trackRow(_ t: HistoryTrack) -> some View {
        Button {
            let track = Track(id: t.trackId, title: t.title, artist: t.artist, cover: t.cover)
            player.play(track, in: tracks.map { Track(id: $0.trackId, title: $0.title, artist: $0.artist, cover: $0.cover) })
        } label: {
            HStack(spacing: 12) {
                AlbumArt(size: 44, title: t.title, coverURL: URL(string: t.cover), radius: 9)
                VStack(alignment: .leading, spacing: 3) {
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
                        .font(.system(size: 14))
                        .foregroundColor(.red.opacity(0.7))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .buttonStyle(PressableButtonStyle())
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
