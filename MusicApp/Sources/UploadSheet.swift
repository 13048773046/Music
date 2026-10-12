import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct UploadSheet: View {
    let fileURL: URL
    var onUploaded: () async -> Void
    @EnvironmentObject private var auth: AuthManager

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var detecting = true
    @State private var coverImage: UIImage?
    @State private var coverData: Data?
    @State private var pickerItem: PhotosPickerItem?
    @State private var uploading = false
    @State private var error: String?
    /// 选图请求序号：快速连续选两次封面时，旧加载结果迟到直接丢弃，防止旧图覆盖新图
    @State private var pickerLoadToken = 0

    private var canUpload: Bool {
        !uploading
            && !title.trimmingCharacters(in: .whitespaces).isEmpty
            && coverImage != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("歌曲信息") {
                    if detecting {
                        HStack(spacing: 10) {
                            ProgressView()
                                .tint(Theme.accent)
                            Text("正在识别音频信息…")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Label("已识别音频信息，可修改", systemImage: "checkmark.seal")
                            .font(.footnote)
                            .foregroundColor(Theme.accent)
                    }
                    TextField("标题", text: $title)
                    TextField("歌手", text: $artist)
                    TextField("专辑", text: $album)
                }

                Section("歌曲封面") {
                    HStack(spacing: 16) {
                        if let image = coverImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 84, height: 84)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(.systemGray5))
                                Image(systemName: "photo")
                                    .font(.system(size: 26))
                                    .foregroundColor(.secondary)
                            }
                            .frame(width: 84, height: 84)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            PhotosPicker(selection: $pickerItem, matching: .images) {
                                Text(coverImage == nil ? "选择封面" : "更换封面")
                                    .fontWeight(.semibold)
                            }
                            .buttonStyle(.bordered)
                            if coverImage != nil {
                                Button("移除封面", role: .destructive) {
                                    coverImage = nil
                                    coverData = nil
                                    pickerItem = nil
                                }
                                .font(.footnote)
                            }
                        }
                    }
                    if coverImage == nil {
                        Text("该音频未识别到内置封面，必须选择封面后才能上传")
                            .font(.footnote)
                            .foregroundColor(.orange)
                    }
                }

                Section {
                    Label(fileURL.lastPathComponent, systemImage: "music.note")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                if let error {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }

                Section {
                    Button {
                        Task { await upload() }
                    } label: {
                        HStack(spacing: 8) {
                            Spacer()
                            if uploading {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text("上传")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                        .foregroundColor(.white)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(!canUpload)
                }
            }
            .navigationTitle("上传歌曲")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .task {
            await detectMetadata()
        }
        .onChange(of: pickerItem) { _ in
            loadPickerImage()
        }
    }

    // MARK: - 识别音频内嵌信息

    private func detectMetadata() async {
        let meta = await AudioInfo.detect(fileURL: fileURL)
        if let t = meta.title, !t.isEmpty {
            title = t
        }
        if let a = meta.artist, !a.isEmpty {
            artist = a
        }
        if let al = meta.album, !al.isEmpty {
            album = al
        }
        if let data = meta.artworkData {
            coverData = data
            coverImage = meta.artworkImage
        }
        detecting = false
    }

    // MARK: - 相册选封面

    private func loadPickerImage() {
        guard let item = pickerItem else { return }
        pickerLoadToken += 1
        let token = pickerLoadToken
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                // 旧选择的结果迟到：丢弃，不覆盖用户最新选择的封面
                guard token == pickerLoadToken else { return }
                coverImage = image
                coverData = data
            }
        }
    }

    // MARK: - 上传

    private func upload() async {
        uploading = true
        error = nil
        defer { uploading = false }
        do {
            // 与后端一致的单曲大小上限：超过直接拦截，避免大文件白传失败
            let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            if size > 100 * 1024 * 1024 {
                error = "文件超过 100MB 上限，无法上传"
                return
            }
            // 大文件读取放到后台线程（最高 100MB），避免阻塞主线程 UI：
            // Task 继承主线程隔离，直接 Data(contentsOf:) 会卡住界面
            let data: Data = try await Task.detached(priority: .userInitiated) {
                let accessing = fileURL.startAccessingSecurityScopedResource()
                defer {
                    if accessing {
                        fileURL.stopAccessingSecurityScopedResource()
                    }
                }
                return try Data(contentsOf: fileURL)
            }.value
            try await API.upload(
                data: data,
                filename: fileURL.lastPathComponent,
                title: title.trimmingCharacters(in: .whitespaces),
                artist: artist.trimmingCharacters(in: .whitespaces),
                album: album.trimmingCharacters(in: .whitespaces),
                userId: auth.currentUser?.id ?? "",
                coverData: coverData,
                coverFilename: "cover.jpg"
            )
            await onUploaded()
            dismiss()
        } catch {
            self.error = "上传失败：\(error.localizedDescription)"
        }
    }
}
