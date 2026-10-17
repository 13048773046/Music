import Foundation

/// 播放历史本地存储（MRU：最近播放置顶）。
/// 同一首歌重复播放 → 移除旧记录并置顶（排到第一）。
/// UserDefaults 持久化（JSON，上限 100 条），设备级、无需登录/网络。
/// 播放历史展示数据源已从前端 API（后端 play_history）迁到本地。
struct LocalPlayHistory {
    private static let key = "local_play_history_v1"
    private static let limit = 100

    struct Item: Codable, Identifiable, Equatable {
        let id: String          // trackId 作为去重键
        var title: String
        var artist: String
        var cover: String
        var created: Double
    }

    /// 记录一次播放：已存在 → 移除旧记录置顶；不存在 → 插入头部；裁剪到上限
    static func record(track: Track) {
        var list = load()
        list.removeAll { $0.id == track.id }
        list.insert(Item(id: track.id,
                         title: track.title,
                         artist: track.artist ?? "",
                         cover: track.coverURL?.absoluteString ?? "",
                         created: Date().timeIntervalSince1970),
                    at: 0)
        if list.count > limit {
            list = Array(list.prefix(limit))
        }
        save(list)
    }

    static func load() -> [Item] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        return list
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func save(_ list: [Item]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
