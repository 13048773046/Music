import SwiftUI
import UIKit

/// 侧边栏抽屉驱动（官方交互式动画方案）。
///
/// 跟手阶段：SwiftUI DragGesture 直接更新 progress，实时跟随手指；
/// 落位阶段：使用官方 `UIViewPropertyAnimator` + `UISpringTimingParameters(initialVelocity:)`
/// 完成剩余动画——该弹簧时序支持「初始速度」，松手动画从手指当前速度继续，
/// 不会像 `withAnimation` 那样从零初速起步产生停顿（系统控制中心 / Apple Music
/// 抽屉即此类实现）。动画期间用 CADisplayLink 按官方弹簧曲线每帧采样 progress，
/// 驱动 SwiftUI 视图偏移。
final class SidebarDrawerController: NSObject, ObservableObject {
    /// 0 = 完全关闭，1 = 完全打开
    @Published var progress: CGFloat = 0
    let width: CGFloat

    private var animator: UIViewPropertyAnimator?
    private var displayLink: CADisplayLink?
    private var startProgress: CGFloat = 0
    private var endProgress: CGFloat = 0
    /// 本次拖动手势开始时的开合状态（跟手基准，手势期间保持不变）
    private var dragStartOpen = false
    private var isDragging = false

    var isOpen: Bool { progress > 0.5 }

    init(width: CGFloat) {
        self.width = width
        super.init()
    }

    // MARK: - 跟手阶段（由 SwiftUI DragGesture 调用）

    func beginDrag() {
        guard !isDragging else { return }
        isDragging = true
        stopAnimation()
        dragStartOpen = isOpen
    }

    func updateDrag(translationX dx: CGFloat) {
        guard isDragging else { return }
        let base: CGFloat = dragStartOpen ? width : 0
        progress = min(1, max(0, (base + dx) / width))
    }

    func finishDrag(translationX dx: CGFloat, velocityX predicted: CGFloat) {
        guard isDragging else { return }
        isDragging = false
        // 方向判定：拖过 1/4 宽度或预测位移超 30% 宽度（快速甩动）→ 打开/关闭，否则回弹
        let shouldOpen: Bool
        if dragStartOpen {
            shouldOpen = !(dx < -width * 0.25 || predicted < -width * 0.3)
        } else {
            shouldOpen = (dx > width * 0.25 || predicted > width * 0.3)
        }
        animate(to: shouldOpen ? 1 : 0, velocity: predicted / width)
    }

    /// 按钮 / 遮罩点击触发的落位动画（无初始速度）
    func animate(to target: CGFloat) {
        animate(to: target, velocity: 0)
    }

    // MARK: - 落位动画（官方弹簧时序 + 速度继承）

    private func animate(to target: CGFloat, velocity: CGFloat) {
        stopAnimation()
        startProgress = progress
        endProgress = target
        guard abs(target - progress) > 0.001 else {
            progress = target
            return
        }
        // 官方交互式弹簧时序：initialVelocity 继承手指当前速度，落位无「零初速停顿」
        let timing = UISpringTimingParameters(dampingRatio: 0.86,
                                              initialVelocity: CGVector(dx: velocity, dy: 0))
        animator = UIViewPropertyAnimator(duration: 0.6, timingParameters: timing)
        animator?.addAnimations { [weak self] in
            // 动画结束时确保精确到位（fractionComplete 采样已接近目标）
            self?.progress = self?.endProgress ?? 0
        }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        animator?.startAnimation()
    }

    /// 每帧按官方弹簧曲线插值 progress，动画结束即停
    @objc private func tick() {
        guard let animator else {
            stopAnimation()
            return
        }
        let fraction = animator.fractionComplete
        progress = startProgress + (endProgress - startProgress) * fraction
        if animator.state == .ended || animator.state == .stopped {
            progress = endProgress
            stopAnimation()
        }
    }

    private func stopAnimation() {
        displayLink?.invalidate()
        displayLink = nil
        animator?.stopAnimation(false)
        animator = nil
    }
}
