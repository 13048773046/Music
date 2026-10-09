import SwiftUI
import UniformTypeIdentifiers

/// 首页：抖音 / 汽水音乐风格，上下滑动切换歌曲的沉浸式播放页
struct HomeView: View {
    @EnvironmentObject private var player: PlayerManager
    @State private var tracks: [Track] = []
    @State private var state: LoadState = .loading
    @State private var currentIndex = 0
    @State private var showImporter = false
    @State private var pickedFileURL: URL?
    @State private var showUploadSheet = false

    var body: some View {
        ZStack {
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
                    Image(systemName: "music.note.list")
                        .font(.system(size: 46))
                        .foregroundColor(.secondary)
                    Text("还没有歌曲")
                        .font(.headline)
                    Text("点击右上角 + 上传你的第一首歌")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Button {
                        showImporter = true
                    } label: {
                        Text("上传歌曲")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .loaded:
                if tracks.isEmpty {
                    EmptyView()
                } else {
                    VerticalPager(
                        currentIndex: $currentIndex,
                        tracks: tracks,
                        onPageChanged: { index in
                            guard tracks.indices.contains(index) else { return }
                            player.play(tracks[index], in: tracks)
                        }
                    )
                    .ignoresSafeArea()
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                showImporter = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(12)
                    .background(.black.opacity(0.28), in: Circle())
            }
            .padding(.top, 8)
            .padding(.trailing, 16)
            .accessibilityLabel("上传歌曲")
        }
        .task {
            if case .loaded = state {} else {
                await load()
            }
        }
        .onChange(of: tracks) { newTracks in
            if player.queue.isEmpty, !newTracks.isEmpty {
                currentIndex = 0
                player.play(newTracks[0], in: newTracks)
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
