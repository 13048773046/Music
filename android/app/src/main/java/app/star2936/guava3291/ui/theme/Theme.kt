package app.star2936.guava3291.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import kotlin.math.abs

// 深黑灰主题（与 iOS Theme.swift 一一对应）

val Background = Color(0xFF121214)      // 深黑底
val Card = Color(0xFF1C1C1F)            // 深灰卡片
val CardBorder = Color(0xFF2A2A2E)      // 卡片描边
val Accent = Color(0xFF4CD9A5)          // 薄荷绿主色
val AccentSoft = Color(0xFF1C3A30)      // 深薄荷底
val Lilac = Color(0xFF8F84C7)           // 暗紫
val Peach = Color(0xFFC98870)           // 暗蜜桃
val Sky = Color(0xFF6FA3C9)             // 暗蓝
val TextPrimary = Color(0xFFECECEC)     // 近白
val TextSecondary = Color(0xFF9C9CA0)   // 灰
val TextTertiary = Color(0xFF626266)    // 暗灰
val DangerRed = Color(0xFFFF6B6B)       // 退出登录/错误红
val UpdateGreen = Color(0xFF5CD68A)     // 更新弹窗版本色

// 占位封面暗色渐变组（与 iOS placeholderPalettes 一致）
data class PalettePair(val first: Color, val second: Color)

val PlaceholderPalettes = listOf(
    PalettePair(AccentSoft, Accent.copy(alpha = 0.45f)),
    PalettePair(Color(0xFF2A2440), Lilac.copy(alpha = 0.55f)),
    PalettePair(Color(0xFF33201C), Peach.copy(alpha = 0.55f)),
    PalettePair(Color(0xFF1D2B3A), Sky.copy(alpha = 0.55f)),
    PalettePair(Color(0xFF1C3A30), Accent.copy(alpha = 0.5f)),
    PalettePair(Color(0xFF33291D), Color(0xFF8A6A4D)),
)

// 按文字 hash 选渐变（与 iOS paletteFrom 一致）
fun placeholderPalette(title: String): PalettePair {
    var hash = 0
    for (ch in title) {
        hash = (hash * 31 + ch.code) and 0x7fffffff
    }
    return PlaceholderPalettes[hash % PlaceholderPalettes.size]
}

// 亮度：与 iOS luminance 一致（0.299R + 0.587G + 0.114B）
fun luminance(color: Color): Float {
    return 0.299f * color.red + 0.587f * color.green + 0.114f * color.blue
}

/** 把主色压暗到 factor 比例（播放页 0.4 / 侧边栏 0.3） */
fun darkened(color: Color, factor: Float): Color {
    return Color(color.red * factor, color.green * factor, color.blue * factor, color.alpha)
}

// 取封面平均色（等价 CIAreaAverage：整图缩放 1x1 取像素）
fun averageColor(r: Float, g: Float, b: Float): Color = Color(r, g, b)

fun Color.isLightish(threshold: Float = 0.55f): Boolean = luminance(this) > threshold

fun lerpColor(a: Color, b: Color, t: Float): Color = lerp(a, b, t.coerceIn(0f, 1f))

fun clamp01(v: Float): Float = if (v.isNaN()) 0f else v.coerceIn(0f, 1f)

fun absf(v: Double): Double = abs(v)
