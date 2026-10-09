import Foundation

struct Track: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String?
    let album: String?
    let size: Int?
    let dur: Double?
    let durText: String?
    let created: Double?
}
