import SwiftUI

/// 侧边栏抽屉驱动（SwiftUI 原生手势 + 官方弹簧动画）。
///
/// 跟手阶段：DragGesture.onChanged 直接写 progress，视图实时跟随手指；
/// 落位阶段：onEnded 按速度判定 fling / 按位置过半判定慢速，
/// 然后用 `withAnimation(.spring)` 驱动系统官方弹簧完成开合。
final class SidebarDrawerController: ObservableObject {
    /// 0 = 完全关闭，1 = 完全打开
    @Published var progress: CGFloat = 0
    let width: CGFloat

    /// 官方弹簧参数：response 是动画时长量级，dampingFraction 越接近 1 越干脆、越小回弹越多
    private let springResponse: Double = 0.45
    private let springDamping: Double = 0.82

    private var isDragging = false
    private var dragStartOpen = false

    init(width: CGFloat) {
        self.width = width
    }

    var isOpen: Bool { progress > 0.5 }

    // MARK: - 跟手阶段（由 SwiftUI DragGesture 调用）

    func beginDrag() {
        guard !isDragging else { return }
        isDragging = true
        dragStartOpen = isOpen
    }

    func updateDrag(translationX dx: CGFloat) {
        guard isDragging else { return }
        let base: CGFloat = dragStartOpen ? 1 : 0
        progress = min(1, max(0, base + dx / width))
    }

    func finishDrag(translationX dx: CGFloat, velocityX rawVelocity: CGFloat) {
        guard isDragging else { return }
        isDragging = false
        // 归一化瞬时速度（progress/秒）
        let v = rawVelocity / width
        // 快速甩动 fling：速度够大直接按方向自动开合，不纠结拖了多远
        let flingThreshold: CGFloat = 0.5
        let shouldOpen: Bool
        if v > flingThreshold {
            shouldOpen = true
        } else if v < -flingThreshold {
            shouldOpen = false
        } else {
            // 慢速拖拽：按当前位置是否过半决定落位
            shouldOpen = progress > 0.5
        }
        withAnimation(.spring(response: springResponse, dampingFraction: springDamping)) {
            progress = shouldOpen ? 1 : 0
        }
    }

    /// 按钮 / 遮罩点击触发的开合动画
    func animate(to target: CGFloat) {
        withAnimation(.spring(response: springResponse, dampingFraction: springDamping)) {
            progress = target
        }
    }
}
