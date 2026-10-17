import Foundation
import Network

/// 网络状态感知（弱网播放优化的依据）。
/// 基于 NWPathMonitor（iOS 12+）监测：是否离线 / 是否蜂窝网络。
/// 全局单例；状态变化在主线程发布，PlayerManager 据此动态调整
/// 缓冲超时、预取窗口与同曲重载策略（弱网降级，音频带宽优先）。
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    /// 当前无网络（断网 / 飞行模式 / 无蜂窝与 Wi-Fi）
    @Published private(set) var isOffline: Bool = false
    /// 当前走蜂窝数据（弱网降级的保守依据：蜂窝网常弱于 Wi-Fi）
    @Published private(set) var isCellular: Bool = false

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.liuying.netmonitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            let cellular = path.usesInterfaceType(.cellular)
            DispatchQueue.main.async {
                guard let self else { return }
                if self.isOffline != offline {
                    self.isOffline = offline
                }
                if self.isCellular != cellular {
                    self.isCellular = cellular
                }
            }
        }
        monitor.start(queue: monitorQueue)
    }
}
