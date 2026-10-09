import SwiftUI

struct UploadSheet: View {
    let fileURL: URL
    var onUploaded: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var uploading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("歌曲信息") {
                    TextField("标题", text: $title)
                    TextField("歌手", text: $artist)
                    TextField("专辑", text: $album)
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
                    .disabled(uploading || title.trimmingCharacters(in: .whitespaces).isEmpty)
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
        .presentationDetents([.medium, .large])
    }

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
                album: album.trimmingCharacters(in: .whitespaces)
            )
            await onUploaded()
            dismiss()
        } catch {
            self.error = "上传失败：\(error.localizedDescription)"
        }
    }
}
