package app.star2936.guava3291.state

import android.content.Context
import app.star2936.guava3291.data.Api
import app.star2936.guava3291.data.Track
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString

/**
 * 播放历史本地存储（对应 iOS LocalPlayHistory.swift）。
 * MRU：最近播放置顶。同一首歌重复播放 → 移除旧记录并置顶（排到第一）。
 * SharedPreferences 持久化（JSON，上限 100 条），设备级、无需登录/网络。
 * 只存音乐元数据（title/artist/cover/created），不存音频。
 */
object LocalPlayHistory {
    private const val prefsName = "local_play_history"
    private const val key = "local_play_history_v1"
    private const val limit = 100

    private lateinit var prefs: android.content.SharedPreferences

    @Serializable
    data class Item(
        val id: String,          // trackId 作为去重键
        val title: String,
        val artist: String,
        val cover: String,       // 封面 URL 字符串
        val created: Double,
    )

    fun init(context: Context) {
        prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
    }

    /** 记录一次播放：已存在 → 移除旧记录置顶；不存在 → 插入头部；裁剪到上限 */
    fun record(track: Track) {
        if (track.id.isEmpty()) return
        val list = load().toMutableList()
        list.removeAll { it.id == track.id }
        list.add(0, Item(
            id = track.id,
            title = track.title,
            artist = track.artist ?: "",
            cover = track.cover ?: "",
            created = System.currentTimeMillis() / 1000.0,
        ))
        if (list.size > limit) {
            list.subList(limit, list.size).clear()
        }
        save(list)
    }

    fun load(): List<Item> {
        val raw = prefs.getString(key, null) ?: return emptyList()
        return try {
            Api.json.decodeFromString<List<Item>>(raw)
        } catch (_: Exception) { emptyList() }
    }

    fun clear() {
        prefs.edit().remove(key).apply()
    }

    private fun save(list: List<Item>) {
        try {
            prefs.edit().putString(key, Api.json.encodeToString(list)).apply()
        } catch (_: Exception) { }
    }
}
