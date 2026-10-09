import SwiftUI

// MARK: - 清新浅色系主题

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
    static let background = Color(hex: 0xFAF8F5)     // 米白主背景
    static let card = Color.white                      // 卡片
    static let cardBorder = Color(hex: 0xEFEAE4)      // 卡片描边

    // 主色：薄荷绿
    static let accent = Color(hex: 0x55C9A2)
    static let accentSoft = Color(hex: 0xE2F5EE)      // 薄荷浅底
    // 辅助色
    static let lilac = Color(hex: 0xB9A7E8)           // 淡紫
    static let peach = Color(hex: 0xF6B7A8)           // 蜜桃
    static let sky = Color(hex: 0x9ECBF5)             // 淡蓝

    // 文字
    static let textPrimary = Color(hex: 0x2E2A33)     // 主文字
    static let textSecondary = Color(hex: 0x8A8794)   // 次文字
    static let textTertiary = Color(hex: 0xB9B6C0)    // 弱文字

    // 通用渐变
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

    // 柔和阴影
    static let softShadow = Color.black.opacity(0.07)
    static let cardShadow = Color.black.opacity(0.05)

    /// 占位封面用的柔和渐变组
    static let placeholderPalettes: [(Color, Color)] = [
        (accentSoft, accent.opacity(0.55)),
        (Color(hex: 0xF0EAFB), lilac.opacity(0.7)),
        (Color(hex: 0xFDEBEA), peach.opacity(0.7)),
        (Color(hex: 0xE8F2FC), sky.opacity(0.7)),
        (Color(hex: 0xE2F5EE), accent.opacity(0.6)),
        (Color(hex: 0xFBEEDD), Color(hex: 0xF6C39E)),
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
                    .shadow(color: Theme.cardShadow, radius: 10, x: 0, y: 4)
            )
    }
}

extension View {
    func softCard(radius: CGFloat = 20, padding: CGFloat = 0) -> some View {
        modifier(SoftCardModifier(radius: radius, padding: padding))
    }
}
