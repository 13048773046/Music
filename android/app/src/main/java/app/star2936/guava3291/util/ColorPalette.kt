package app.star2936.guava3291.util

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import app.star2936.guava3291.ui.theme.darkened
import androidx.compose.ui.graphics.Color
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.concurrent.ConcurrentHashMap

// 对应 iOS CoverPalette.swift：从封面提取平均主色（等价 CIAreaAverage，带缓存）

object ColorPalette {
    // 与 iOS NSCache 语义近似：ConcurrentHashMap 上限 + 内存压力时清空
    private val cache = ConcurrentHashMap<String, Color>()
    private const val CacheMax = 600

    fun colorFor(id: String, fromUrl: String): Color? = cache[id]

    suspend fun load(id: String, url: String): Color? {
        cache[id]?.let { return it }
        val color = withContext(Dispatchers.IO) {
            try {
                val conn = java.net.URL(url).openConnection()
                conn.connectTimeout = 8000
                conn.readTimeout = 8000
                val input = conn.getInputStream()
                val bitmap = BitmapFactory.decodeStream(input)
                input.close()
                extractAverage(bitmap)
            } catch (_: Exception) { null }
        }
        if (color != null) {
            if (cache.size >= CacheMax) cache.clear()
            cache[id] = color
        }
        return color
    }

    /** 缩放到 1x1 取平均色（等价 CIAreaAverage），提升饱和度让主色更鲜亮 */
    fun extractAverage(bitmap: Bitmap): Color? {
        val scaled = Bitmap.createScaledBitmap(bitmap, 1, 1, true)
        val px = scaled.getPixel(0, 0)
        if (scaled != bitmap) scaled.recycle()
        val r = ((px shr 16) and 0xFF) / 255f
        val g = ((px shr 8) and 0xFF) / 255f
        val b = (px and 0xFF) / 255f
        // 提升饱和度：向色相方向拉，减少灰度感
        val avg = (r + g + b) / 3f
        val satBoost = 1.35f
        return Color(
            (avg + (r - avg) * satBoost).coerceIn(0f, 1f),
            (avg + (g - avg) * satBoost).coerceIn(0f, 1f),
            (avg + (b - avg) * satBoost).coerceIn(0f, 1f),
            1f
        )
    }

    /** 播放页背景 = 主色×0.4；侧边栏背景 = 主色×0.3（由调用方传 factor） */
    // darkened 已迁移到 ui/theme/Theme.kt，这里不再重复定义

    fun clear() { cache.clear() }
}
