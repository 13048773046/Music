import SwiftUI

/// 视图方向锁定：全屏歌词强制横屏、主界面锁定竖屏。
///
/// Info.plist 已声明 Portrait + LandscapeLeft/Right；本控制器按所在视图返回
/// 允许的方向，并在出现时用 UIDevice KVC 强制旋转到目标方向（dismiss 时由
/// 下层控制器的 supportedInterfaceOrientations 自动转回竖屏）。
struct OrientationLock: UIViewControllerRepresentable {
    /// 本视图允许的方向
    var mask: UIInterfaceOrientationMask
    /// 出现时强制旋转到的方向（nil = 只声明不强制）
    var force: UIInterfaceOrientation?

    func makeUIViewController(context: Context) -> UIViewController {
        OrientationVC(mask: mask, force: force)
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    private final class OrientationVC: UIViewController {
        let mask: UIInterfaceOrientationMask
        let force: UIInterfaceOrientation?

        init(mask: UIInterfaceOrientationMask, force: UIInterfaceOrientation?) {
            self.mask = mask
            self.force = force
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var supportedInterfaceOrientations: UIInterfaceOrientationMask { mask }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            forceOrientation()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            forceOrientation()
        }

        /// 强制旋转：呈现动画前后各触发一次 + 延迟再触发一次，规避系统方向重算时机问题；
        /// 配合 supportedInterfaceOrientations，dismiss 后由下层竖屏控制器自动转回。
        private func forceOrientation() {
            guard let force else { return }
            setNeedsUpdateOfSupportedInterfaceOrientations()
            DispatchQueue.main.async {
                UIDevice.current.setValue(force.rawValue, forKey: "orientation")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                UIDevice.current.setValue(force.rawValue, forKey: "orientation")
                self.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }
}

extension View {
    /// 包裹为强制横屏视图（全屏沉浸式歌词）
    func landscapeFullScreen() -> some View {
        OrientationLock(mask: .landscape, force: .landscapeRight)
            .overlay(self)
            .ignoresSafeArea()
    }

    /// 锁定竖屏（主界面 / 登录页，防止系统横屏授权被主界面接管）
    func portraitLocked() -> some View {
        OrientationLock(mask: .portrait, force: .portrait)
            .overlay(self)
            .ignoresSafeArea()
    }
}
