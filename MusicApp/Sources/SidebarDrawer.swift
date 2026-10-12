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

    func finishDrag(translationX dx: CGFloat, velocityX rawVelocity: CGFloat) {
        guard isDragging else { return }
        isDragging = false
        // 归一化瞬时速度（单位 progress/秒）：区分「快速甩动 fling」与「慢速拖拽」
        let v = rawVelocity / width
        // fling 阈值：每秒 progress 变化超过 0.5（约 175px/s）视为快速甩动，
        // 直接按速度方向落位，不再纠结手指当前拖了多少距离——甩一下就走
        let flingThreshold: CGFloat = 0.5
        let shouldOpen: Bool
        if v > flingThreshold {
            shouldOpen = true          // 向右快甩 → 打开
        } else if v < -flingThreshold {
            shouldOpen = false         // 向左快甩 → 关闭
        } else {
            // 慢速拖拽：按当前位置是否过半决定落位（跟手拖到 49% 松手就关，51% 就开）
            shouldOpen = progress > 0.5
        }
        animate(to: shouldOpen ? 1 : 0, velocity: v)
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
        // 速度钳制在 ±2.0 以内：避免快速甩动时弹簧「嗖」地飞出去，整体节奏保持舒缓
        let clamped = max(-2.0, min(2.0, velocity))
        let timing = UISpringTimingParameters(dampingRatio: 0.82,
                                              initialVelocity: CGVector(dx: clamped, dy: 0))
        animator = UIViewPropertyAnimator(duration: 0.65, timingParameters: timing)
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
        // UIViewAnimatingState 仅 .inactive/.active/.stopped：
        // 动画自然完成后回到 .inactive，手动 stop 为 .stopped；无 .ended case
        if animator.state == .inactive || animator.state == .stopped {
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
