import AVFoundation
import UIKit

struct AudioMetadata: Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var artworkData: Data?
    var artworkImage: UIImage? {
        artworkData.flatMap(UIImage.init(data:))
    }
}

enum AudioInfo {
    /// 解析音频文件内嵌的标题 / 歌手 / 专辑 / 封面图（异步）
    static func detect(fileURL: URL) async -> AudioMetadata {
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        var meta = AudioMetadata()
        let asset = AVURLAsset(url: fileURL)
        do {
            let items = try await asset.load(.commonMetadata)
            for item in items {
                guard let key = item.commonKey else { continue }
                do {
                    switch key {
                    case .commonKeyTitle:
                        if meta.title == nil,
                           let value = try await item.load(.stringValue) {
                            meta.title = value
                        }
                    case .commonKeyArtist:
                        if meta.artist == nil,
                           let value = try await item.load(.stringValue) {
                            meta.artist = value
                        }
                    case .commonKeyAlbumName:
                        if meta.album == nil,
                           let value = try await item.load(.stringValue) {
                            meta.album = value
                        }
                    case .commonKeyArtwork:
                        if meta.artworkData == nil,
                           let value = try await item.load(.dataValue) {
                            meta.artworkData = value
                        }
                    default:
                        break
                    }
                } catch {
                    continue
                }
            }
        } catch {
            // 读取失败则返回空信息，由用户手动填写
        }
        return meta
    }
}
