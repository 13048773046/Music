import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject private var player: PlayerManager
    @State private var tracks: [Track] = []
    @State private var state: LoadState = .loading
    @State private var showImporter = false
    @State private var pickedFileURL: URL?
    @State private var showUploadSheet = false

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "早上好"
        case 12..<14: return "中午好"
        case 14..<19: return "下午好"
        default: return "晚上好"
        }
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
                    List {
                        ForEach(tracks) { track in
                            TrackRow(track: track) {
                                player.play(track, in: tracks)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .refreshable {
                        await load()
                    }
                }
            }
            .navigationTitle(greeting)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("上传歌曲")
                }
            }
            .task {
                if case .loaded = state {} else {
                    await load()
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
