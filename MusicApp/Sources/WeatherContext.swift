import Foundation
import CoreLocation

/// M2 天气×时段场景上下文（全局单例）
///
/// 职责：单次定位 → 反查城市 → 调 /api/weather 取"天气×时段"心情场景快照，
/// 供发现页「今日心情卡片」展示，并为推荐接口提供场景参数（lat/lng/hour）。
///
/// 降级策略（任一环节失败都不阻塞主流程）：
///   定位失败/用户拒绝/超时 → 不传位置，仅靠后端"时段兜底"出场景（推荐照常）；
///   天气接口不可用 → 卡片隐藏、推荐不带场景参数。
/// 会话节流：同一次会话 30 分钟内复用上次结果，不重复定位/请求。
final class WeatherContext: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WeatherContext()

    @Published private(set) var scene: String?
    @Published private(set) var sceneLabel: String?
    @Published private(set) var temperature: Double?
    @Published private(set) var city: String?
    @Published private(set) var isAvailable = false

    /// 推荐接口场景参数（定位未就绪时为 nil → 后端按时段兜底）
    var lat: Double?
    var lng: Double?
    /// 当前本地小时（0-23），天气接口/推荐接口共用
    var hour: Int? { Calendar.current.component(.hour, from: Date()) }

    private var lastSuccessAt: Date = .distantPast
    private let manager = CLLocationManager()
    private var pendingAuth: (() -> Void)?
    private var pendingLocation: ((CLLocation?) -> Void)?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// 刷新场景（App 启动 / 切前台超 30 分钟时调用）。返回是否拿到天气场景。
    /// - Parameter force: 强制刷新（"换一批"按钮用）；默认走 30 分钟节流。
    @discardableResult
    func refresh(force: Bool = false) async -> Bool {
        if !force && Date().timeIntervalSince(lastSuccessAt) < 30 * 60 {
            return isAvailable
        }
        let status = manager.authorizationStatus
        if status == .notDetermined {
            // 首次进入：请求授权后再继续（用户拒绝 → 走仅时段降级）。
            // ⚠ 授权等待带 3s 超时兜底：系统授权弹窗可能被吞/用户迟迟不响应，
            //   任何调用方（启动预加载、发现页 .task、切前台）都绝不允许被授权未决永久挂起
            //   ——否则会阻塞发现页内容加载（「加载中…」卡死）。
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let timer = Timer(timeInterval: 3.0, repeats: false) { _ in
                    self.pendingAuth = nil
                    cont.resume()
                }
                RunLoop.main.add(timer, forMode: .common)
                pendingAuth = {
                    timer.invalidate()
                    cont.resume()
                }
                manager.requestWhenInUseAuthorization()
            }
        }
        guard manager.authorizationStatus == .authorizedWhenInUse
                || manager.authorizationStatus == .authorizedAlways else {
            return false
        }
        // 定位等待同样带 3s 超时（requestLocation 偶发无回调，防挂起 → 按无定位降级）
        let location: CLLocation? = await withCheckedContinuation { (cont: CheckedContinuation<CLLocation?, Never>) in
            let timer = Timer(timeInterval: 3.0, repeats: false) { _ in
                self.pendingLocation = nil
                cont.resume(returning: nil)
            }
            RunLoop.main.add(timer, forMode: .common)
            pendingLocation = { loc in
                timer.invalidate()
                cont.resume(returning: loc)
            }
            manager.requestLocation()
        }
        guard let loc = location else { return false }
        lat = loc.coordinate.latitude
        lng = loc.coordinate.longitude
        // 反查城市（失败不阻塞天气；只用于卡片文案）
        if let place = try? await CLGeocoder().reverseGeocodeLocation(loc).first {
            city = place.locality ?? place.subLocality ?? ""
        }
        // 天气×场景快照（失败静默 → 卡片隐藏，推荐仍按时段兜底）
        guard let wx = await API.fetchWeather(lat: loc.coordinate.latitude,
                                              lng: loc.coordinate.longitude,
                                              hour: hour), wx.ok else { return false }
        scene = wx.scene
        sceneLabel = wx.sceneLabel
        temperature = wx.temp
        lastSuccessAt = Date()
        isAvailable = true
        return true
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        pendingAuth?()
        pendingAuth = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        pendingLocation?(locations.first)
        pendingLocation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        pendingLocation?(nil)
        pendingLocation = nil
    }
}
