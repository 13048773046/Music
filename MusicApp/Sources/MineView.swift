import SwiftUI
import UniformTypeIdentifiers

struct MineView: View {
    @EnvironmentObject private var player: PlayerManager
    @State private var trackCount: Int?
    @State private var showImporter = false
    @State private var pickedFileURL: URL?
    @State private var showUploadSheet = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Color(.secondarySystemFill))
                            Image(systemName: "person.fill")
                                .font(.system(size: 30))
                                .foregroundColor(.secondary)
                        }
                        .frame(width: 64, height: 64)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("音乐爱好者")
                                .font(.title3.bold())
                            Text("享受每一段旋律")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section("我的音乐") {
                    HStack {
                        Label("歌曲总数", systemImage: "music.note.list")
                        Spacer()
                        if let count = trackCount {
                            Text("\(count)")
                                .foregroundColor(.secondary)
                        } else {
                            ProgressView()
                        }
                    }
                    HStack {
                        Label("正在播放", systemImage: "speaker.wave.2")
                        Spacer()
                        Text(player.current?.title ?? "无")
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Section("管理") {
                    Button {
                        showImporter = true
                    } label: {
                        Label("上传歌曲", systemImage: "square.and.arrow.up")
                    }
                }

                Section("关于") {
                    HStack {
                        Label("服务器", systemImage: "server.rack")
                        Spacer()
                        Text("www.dbmt999.asia")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Label("版本", systemImage: "info.circle")
                        Spacer()
                        Text("v\(appVersion)")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("我的")
            .task {
                if trackCount == nil {
                    await loadCount()
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
                    await loadCount()
                }
            }
        }
    }

    private func loadCount() async {
        do {
            let list = try await API.tracks()
            trackCount = list.count
        } catch {
            trackCount = 0
        }
    }
}
