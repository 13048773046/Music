import SwiftUI
import UIKit

// MARK: - 可靠导航返回

/// 在 NavigationStack 多层 push（navigationDestination + NavigationLink 混合）下，
/// @Environment(\.dismiss) 偶发失效，导致自定义返回按钮点击无响应或返回异常。
/// 统一改为：优先通过 UIKit 导航栈 popViewController（100% 可靠），
/// 找不到导航栈（如 sheet 场景）时回退 dismiss()。
/// 同时提供恢复系统边缘滑动返回手势的能力（navigationBarHidden 后偶发失效）。
enum NavBack {
    /// 当前活跃的 UINavigationController（SwiftUI NavigationStack 内部即 UINavigationController）
    static func currentNavigationController() -> UINavigationController? {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let window = scene.windows.first(where: { $0.isKeyWindow }),
              let root = window.rootViewController else { return nil }
        var vc: UIViewController? = root
        while let presented = vc?.presentedViewController { vc = presented }
        if let nav = vc as? UINavigationController { return nav }
        return vc?.navigationController
    }

    /// 可靠返回：导航栈存在且有上级页面时 pop，否则回退 dismiss
    static func goBack(_ dismiss: DismissAction) {
        if let nav = currentNavigationController(),
           nav.viewControllers.count > 1 {
            nav.popViewController(animated: true)
        } else {
            dismiss()
        }
    }

    /// 恢复系统边缘滑动返回手势（navigationBarHidden 后偶发失效）
    static func enableSwipeBack() {
        if let nav = currentNavigationController() {
            nav.interactivePopGestureRecognizer?.isEnabled = true
        }
    }
}
