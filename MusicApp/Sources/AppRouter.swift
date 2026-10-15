import SwiftUI
import UIKit

/// 全局导航路由：跨页面跳转（通知点击 → 回首页播放歌曲 / 打开评论弹窗定位评论）
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    /// 0=发现音乐 1=首页播放页 2=我的
    @Published var selectedTab = 1

    /// 待打开评论弹窗的歌曲与要定位的评论 id
    @Published var pendingCommentTrack: Track?
    @Published var highlightCommentId: String?
    @Published var showCommentSheet = false

    /// 待打开的用户主页（独立页面 push，非弹窗）
    @Published var pendingUserProfileId: String?
    /// 搜索页（独立页面 push，首页顶栏触发）
    @Published var showSearchPage = false

    private init() {}

    /// 打开用户主页（独立页面 push）：通知头像 / 播放页发布者名称点击走这里
    func openUserProfile(_ uid: String) {
        guard !uid.isEmpty else { return }
        pendingUserProfileId = uid
    }

    /// 从通知跳转：回首页 + 播放歌曲；评论类通知打开评论弹窗（可选定位到该评论）
    func jumpToHome(play track: Track, openComment: Bool = false, commentId: String? = nil) {
        pendingCommentTrack = track
        highlightCommentId = commentId
        selectedTab = 1
        if openComment {
            showCommentSheet = true
        }
    }
}

/// WebSocket 推送载荷（与 /api/notifications 单条结构一致）
struct WSPayload {
    let id: String?
    let type: String?        // like / comment / share / official
    let title: String?
    let content: String?
    let fromUser: String?
    let fromUserId: String?
    let commentId: String?
    let trackId: String?
    let trackTitle: String?
    let isRead: Int
    let created: Double

    init(dict: [String: Any]) {
        id = dict["id"] as? String
        type = dict["type"] as? String
        title = dict["title"] as? String
        content = dict["content"] as? String
        fromUser = dict["fromUser"] as? String
        fromUserId = dict["fromUserId"] as? String
        commentId = dict["commentId"] as? String
        trackId = dict["trackId"] as? String
        trackTitle = dict["trackTitle"] as? String
        isRead = dict["isRead"] as? Int ?? 0
        created = dict["created"] as? Double ?? 0
    }

    var asNotification: API.Notification {
        API.Notification(id: id ?? "", type: type ?? "like", title: title,
                         content: content, fromUser: fromUser,
                         fromUserId: fromUserId, commentId: commentId,
                         trackId: trackId, trackTitle: trackTitle,
                         isRead: isRead, created: created)
    }
}

/// 实时数据事件（服务器数据变化 → 前端对应页面刷新）
/// event: stats（听歌统计）/ profile（资料更新）/ my_tracks（我的作品变化）
///        track_list（全局歌曲列表变化）/ recommend（个性化推荐更新）
struct WSDataEvent {
    let event: String
    let totalSeconds: Int?
    let trackCount: Int?
    let user: [String: Any]?
    let action: String?
    let reason: String?

    init(dict: [String: Any]) {
        event = dict["event"] as? String ?? ""
        totalSeconds = dict["totalSeconds"] as? Int
        trackCount = dict["trackCount"] as? Int
        user = dict["user"] as? [String: Any]
        action = dict["action"] as? String
        reason = dict["reason"] as? String
    }
}

/// App 全局通知总线：WebSocket 长连接实时接收新通知，驱动未读红点与通知列表刷新
final class NotificationBus: ObservableObject {
    static let shared = NotificationBus()

    /// 当前未读通知总数（驱动铃铛红点 / TabBar 红点）
    @Published var unreadCount = 0
    /// 最近一次实时推送的通知（通知页监听此值刷新列表）
    @Published private(set) var lastEvent: WSPayload?
    /// 最近一次实时数据事件（各页面监听此值刷新对应数据）
    @Published private(set) var lastDataEvent: WSDataEvent?

    private var task: URLSessionWebSocketTask?
    private var heartbeat: Timer?
    private var reconnectAttempt = 0
    private var manualStop = false

    private init() {
        // 回前台主动恢复：后台时系统可能回收长连接（不触发 failure），回前台检查并重连
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, !self.manualStop, self.task == nil,
                  let token = AuthManager.shared.authToken, !token.isEmpty else { return }
            self.startIfNeeded()
            // 回前台同步一次最新未读数（不打开通知页也能刷新红点）
            Task { await self.refreshUnread() }
        }
    }

    /// 设置未读数（列表接口返回时同步）
    func setUnread(_ n: Int) {
        unreadCount = n
    }

    /// 主动拉取最新未读数（App 启动 / 登录后 / 回前台时调用）。
    /// 修复：不打开消息通知页就看不到红点的问题——红点不再依赖通知页首次加载，
    /// 首页（播放页）直接实时显示。
    func refreshUnread() async {
        guard let token = AuthManager.shared.authToken, !token.isEmpty else { return }
        if let r = try? await API.notifications() {
            unreadCount = r.unread
        }
    }

    /// 通过 WebSocket 实时上报行为事件（即时通讯通道）：行为数据实时入库并触发
    /// 后端 recommend 事件推送，前端「猜你喜欢」随之实时刷新。
    /// 返回是否成功发送（WS 未连接/未登录时返回 false，由调用方回退 HTTP 上报）。
    func sendBehavior(_ events: [API.BehaviorEvent]) -> Bool {
        guard let t = task else { return false }
        let arr = events.map { ev -> [String: Any] in
            var d: [String: Any] = ["trackId": ev.trackId, "event": ev.event, "value": ev.value]
            if let m = ev.meta, !m.isEmpty { d["meta"] = m }
            return d
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["type": "behavior", "events": arr]),
              let str = String(data: data, encoding: .utf8) else { return false }
        t.send(.string(str)) { _ in }
        return true
    }

    /// 登录后启动长连接（已连接则忽略）
    func startIfNeeded() {
        guard task == nil, !manualStop else { return }
        guard let token = AuthManager.shared.authToken, !token.isEmpty,
              let url = API.wsURL(token: token) else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        let t = URLSession.shared.webSocketTask(with: req)
        task = t
        reconnectAttempt = 0
        t.resume()
        receiveLoop(t)
        startHeartbeat()
    }

    /// 退出登录时停止（不再重连）
    func stop() {
        manualStop = true
        heartbeat?.invalidate()
        heartbeat = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        unreadCount = 0
        lastEvent = nil
    }

    /// 登录态变化后重置并重连（如重新登录换 token）
    func resetAndReconnect() {
        manualStop = false
        task?.cancel()
        task = nil
        heartbeat?.invalidate()
        heartbeat = nil
        startIfNeeded()
    }

    // MARK: - 内部

    private func startHeartbeat() {
        heartbeat?.invalidate()
        let timer = Timer(timeInterval: 25, repeats: true) { [weak self] _ in
            guard let self, let t = self.task else { return }
            t.sendPing { _ in }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                switch msg {
                case .string(let s):
                    self.handle(s)
                case .data(let d):
                    if let s = String(data: d, encoding: .utf8) {
                        self.handle(s)
                    }
                @unknown default:
                    break
                }
                // 继续等待下一条
                if self.task === t {
                    self.receiveLoop(t)
                }
            case .failure:
                // 连接断开：清理并退避重连（登录态未退出时）
                if self.task === t {
                    self.task = nil
                    self.heartbeat?.invalidate()
                    self.heartbeat = nil
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handle(_ s: String) {
        guard let d = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        switch obj["kind"] as? String {
        case "notification":
            if let unread = obj["unread"] as? Int {
                unreadCount = unread
            }
            if let n = obj["notification"] as? [String: Any] {
                lastEvent = WSPayload(dict: n)
            }
        case "event":
            lastDataEvent = WSDataEvent(dict: obj)
        default:
            break
        }
    }

    private func scheduleReconnect() {
        guard !manualStop else { return }
        // 指数退避：5s 起、每失败一次近似翻倍，封顶 60s；不设重连上限——
        // 长时间播放时网络可能长时间不稳定，硬上限会导致永久断连、之后通知全丢。
        // 达到封顶后持续每 60s 重试，直到登录态退出（manualStop）或重连成功。
        reconnectAttempt += 1
        let delay = min(5.0 * Double(reconnectAttempt), 60.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.manualStop, self.task == nil else { return }
            self.startIfNeeded()
        }
    }
}
