import Foundation

struct Track: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String?
    let album: String?
    let cover: String?
    let size: Int?
    let dur: Double?
    let durText: String?
    let created: Double?
    let playCount: Int?
    let likeCount: Int?
    let shareCount: Int?
    let commentCount: Int?
    let userId: String?
    let userName: String?
    var isLiked: Bool?

    var coverURL: URL? {
        guard let cover, !cover.isEmpty else { return nil }
        return API.coverURL(id)
    }

    /// 作者名：优先用上传者昵称，其次 artist 字段
    var displayAuthor: String {
        if let userName, !userName.isEmpty { return userName }
        if let artist, !artist.isEmpty { return artist }
        return "未知歌手"
    }
}
