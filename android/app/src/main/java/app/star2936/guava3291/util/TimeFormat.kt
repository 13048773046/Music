package app.star2936.guava3291.util

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.abs

// 对应 iOS Components.formatTime / MineView 日期格式化 / NotificationsView 相对时间

fun formatTime(seconds: Double): String {
    if (seconds.isNaN() || seconds < 0) return "0:00"
    val total = seconds.toInt()
    return "${total / 60}:${String.format(Locale.US, "%02d", total % 60)}"
}

private val dateFormatter = SimpleDateFormat("yyyy-MM-dd", Locale.US)

fun dateString(ts: Double): String {
    if (ts <= 0) return "--"
    return dateFormatter.format(Date((ts * 1000).toLong()))
}

/** 相对时间（对应 RelativeDateTimeFormatter .short，中文简写） */
fun relativeTime(ts: Double): String {
    if (ts <= 0) return ""
    val now = System.currentTimeMillis() / 1000.0
    val diff = now - ts
    val seconds = diff.toInt()
    return when {
        seconds < 60 -> "刚刚"
        seconds < 3600 -> "${seconds / 60}分钟前"
        seconds < 86400 -> "${seconds / 3600}小时前"
        seconds < 172800 -> "昨天"
        seconds < 604800 -> "${seconds / 86400}天前"
        seconds < 2592000 -> "${seconds / 604800}周前"
        else -> dateString(ts)
    }
}

/** 听歌时长格式化（对应 MineView listenText）：不足 1 小时显示分钟，否则显示小时 */
fun listenText(seconds: Int): String {
    if (seconds <= 0) return "0 分钟"
    val hours = seconds / 3600.0
    return if (hours < 1) "${seconds / 60} 分钟"
    else String.format(Locale.US, "%.1f 小时", hours)
}

fun absDiff(a: Double, b: Double): Double = abs(a - b)
