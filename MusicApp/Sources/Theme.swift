import SwiftUI

// MARK: - 深黑灰主题（克制光污染）

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

enum Theme {
    // 背景
    static let background = Color(hex: 0x121214)     // 深黑底
    static let card = Color(hex: 0x1C1C1F)            // 深灰卡片
    static let cardBorder = Color(hex: 0x2A2A2E)      // 卡片描边

    // 主色：低饱和薄荷绿（深底上醒目但不刺眼）
    static let accent = Color(hex: 0x4CD9A5)
    static let accentSoft = Color(hex: 0x1C3A30)      // 深薄荷底
    // 辅助色：暗调
    static let lilac = Color(hex: 0x8F84C7)           // 暗紫
    static let peach = Color(hex: 0xC98870)           // 暗蜜桃
    static let sky = Color(hex: 0x6FA3C9)             // 暗蓝

    // 文字
    static let textPrimary = Color(hex: 0xECECEC)     // 近白
    static let textSecondary = Color(hex: 0x9C9CA0)   // 灰
    static let textTertiary = Color(hex: 0x626266)    // 暗灰

    // 渐变（深色主题下克制使用）
    static let heroGradient = LinearGradient(
        colors: [accent, lilac],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let peachGradient = LinearGradient(
        colors: [peach, accent],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let skyGradient = LinearGradient(
        colors: [sky, lilac],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // 轻阴影（弱化光污染）
    static let softShadow = Color.clear
    static let cardShadow = Color.clear

    /// 占位封面用的暗色渐变组
    static let placeholderPalettes: [(Color, Color)] = [
        (accentSoft, accent.opacity(0.45)),
        (Color(hex: 0x2A2440), lilac.opacity(0.55)),
        (Color(hex: 0x33201C), peach.opacity(0.55)),
        (Color(hex: 0x1D2B3A), sky.opacity(0.55)),
        (Color(hex: 0x1C3A30), accent.opacity(0.5)),
        (Color(hex: 0x33291D), Color(hex: 0x8A6A4D)),
    ]
}

// MARK: - 通用卡片样式

struct SoftCardModifier: ViewModifier {
    var radius: CGFloat = 20
    var padding: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .stroke(Theme.cardBorder, lineWidth: 1)
                    )
            )
    }
}

extension View {
    func softCard(radius: CGFloat = 20, padding: CGFloat = 0) -> some View {
        modifier(SoftCardModifier(radius: radius, padding: padding))
    }
}
