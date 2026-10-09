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

    var coverURL: URL? {
        guard let cover, !cover.isEmpty else { return nil }
        return API.coverURL(id)
    }
}
