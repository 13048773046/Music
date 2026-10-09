import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct UploadSheet: View {
    let fileURL: URL
    var onUploaded: () async -> Void

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
                            Text("正在识别音频信息…")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Label("已识别音频信息，可修改", systemImage: "checkmark.seal")
                            .font(.footnote)
                            .foregroundColor(.green)
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
                            } else {
                                Text("上传")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
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
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
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
            let accessing = fileURL.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }
            let data = try Data(contentsOf: fileURL)
            try await API.upload(
                data: data,
                filename: fileURL.lastPathComponent,
                title: title.trimmingCharacters(in: .whitespaces),
                artist: artist.trimmingCharacters(in: .whitespaces),
                album: album.trimmingCharacters(in: .whitespaces),
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
