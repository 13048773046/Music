package app.star2936.guava3291.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// 对应 iOS Track.swift
@Serializable
data class Track(
    val id: String,
    val title: String,
    val artist: String? = null,
    val album: String? = null,
    val cover: String? = null,
    val size: Long? = null,
    val dur: Double? = null,
    @SerialName("durText") val durText: String? = null,
    val created: Double? = null,
    @SerialName("playCount") val playCount: Int? = null,
    @SerialName("likeCount") val likeCount: Int? = null,
    @SerialName("shareCount") val shareCount: Int? = null,
    @SerialName("commentCount") val commentCount: Int? = null,
    @SerialName("userId") val userId: String? = null,
    @SerialName("userName") val userName: String? = null,
    @SerialName("hasLyric") val hasLyric: Boolean? = null,
    @SerialName("isLiked") val isLiked: Boolean? = null,
    val reason: String? = null,
) {
    val coverURL: String?
        get() = if (cover.isNullOrEmpty()) null else Api.coverUrl(id)

    val displayAuthor: String
        get() = when {
            !userName.isNullOrEmpty() -> userName
            !artist.isNullOrEmpty() -> artist
            else -> "未知歌手"
        }
}

// 对应 iOS Auth.swift User
@Serializable
data class User(
    val id: String,
    val account: String,
    val name: String,
    val avatar: String? = null,
    val gender: String? = null,
    val age: Int? = null,
    val background: String? = null,
    val signature: String? = null,
    val ip: String? = null,
    val created: Double? = null,
    val token: String? = null,
) {
    val avatarURL: String get() = Api.avatarUrl(id)
    val backgroundURL: String?
        get() = if (background.isNullOrEmpty()) null else Api.backgroundUrl(id)
}

// 对应 API.Comment
@Serializable
data class Comment(
    val id: String,
    @SerialName("userId") val userId: String,
    @SerialName("userName") val userName: String,
    val content: String,
    val created: Double,
    @SerialName("commentImageURL") val commentImageURL: String? = null,
    @SerialName("isLiked") val isLiked: Boolean = false,
    @SerialName("likeCount") val likeCount: Int = 0,
)

// 对应 API.MyComment
@Serializable
data class MyComment(
    @SerialName("trackId") val trackId: String,
    val content: String,
    val created: Double? = null,
    val title: String? = null,
    val artist: String? = null,
)

// 对应 API.PageResult
@Serializable
data class PageResult<T>(
    val list: List<T>,
    val total: Int,
    val hasMore: Boolean,
)

// 对应 API.Notification
@Serializable
data class Notification(
    val id: String,
    val type: String,
    @SerialName("trackId") val trackId: String? = null,
    @SerialName("trackTitle") val trackTitle: String? = null,
    @SerialName("fromUserId") val fromUserId: String? = null,
    @SerialName("fromUser") val fromUser: String? = null,
    val content: String? = null,
    @SerialName("commentId") val commentId: String? = null,
    val created: Double,
    val unread: Boolean = false,
    val mutual: Boolean = false,
)

@Serializable
data class NotificationsResult(
    val list: List<Notification>,
    val unread: Int,
    val hasMore: Boolean = false,
)

// 对应 API.OfficialMessage
@Serializable
data class OfficialMessage(
    val id: String,
    val sender: String? = null,
    val content: String,
    val created: Double = 0.0,
)

// 对应 MusicApp.swift Announcement
@Serializable
data class Announcement(
    val id: String,
    val title: String,
    val content: String,
    val version: String,
    @SerialName("showOnce") val showOnce: Int,
)

// 对应 MusicApp.swift UpdateNotice / API.UpdateCheck
@Serializable
data class UpdateCheck(
    val hasUpdate: Boolean = false,
    val id: String? = null,
    val title: String? = null,
    val content: String? = null,
    val version: String? = null,
    @SerialName("forceUpdate") val forceUpdate: Int? = null,
    @SerialName("downloadUrl") val downloadUrl: String? = null,
    @SerialName("downloadUrlIos") val downloadUrlIos: String? = null,
)

// 行为事件（对应 API.BehaviorEvent）
data class BehaviorEvent(
    @SerialName("trackId") val trackId: String,
    val event: String,
    val value: Double = 0.0,
    val meta: String? = null,
) {
    companion object {
        fun metaJSON(map: Map<String, Any>): String? {
            return try {
                val entries = map.map { (k, v) ->
                    k to when (v) {
                        is Double -> v
                        is Float -> v.toDouble()
                        is Int -> v.toDouble()
                        is Long -> v.toDouble()
                        is Boolean -> if (v) 1.0 else 0.0
                        else -> v.toString()
                    }
                }.toMap()
                kotlinx.serialization.json.JsonObject(
                    entries.map { (k, v) -> k to kotlinx.serialization.json.JsonPrimitive(v.toString()) }.toMap()
                ).toString()
            } catch (_: Exception) { null }
        }
    }
}

// ---------- 新增数据模型（歌单/历史/用户主页） ----------

// 对应 iOS Playlist
@Serializable
data class Playlist(
    val id: String,
    val name: String,
    val description: String? = null,
    @SerialName("userId") val userId: String? = null,
    @SerialName("trackCount") val trackCount: Int = 0,
    val cover: String? = null,
    val created: Double? = null,
)

// 对应 iOS HistoryTrack
@Serializable
data class HistoryTrack(
    val id: String,
    @SerialName("trackId") val trackId: String,
    val title: String,
    val artist: String? = null,
    val cover: String? = null,
    val created: Double? = null,
) {
    val coverURL: String?
        get() = if (cover.isNullOrEmpty()) null else Api.coverUrl(trackId)
}

// 对应 iOS UserProfile
@Serializable
data class UserProfile(
    val id: String,
    val name: String,
    val avatar: String? = null,
    val signature: String? = null,
    val gender: String? = null,
    val age: Int? = null,
    val background: String? = null,
    @SerialName("city") val city: String = "",
    @SerialName("workCount") val workCount: Int = 0,
    @SerialName("followerCount") val followerCount: Int = 0,
    @SerialName("followingCount") val followingCount: Int = 0,
    @SerialName("mutualCount") val mutualCount: Int = 0,
    @SerialName("likeCount") val likeCount: Int = 0,
    @SerialName("isFollowing") val isFollowing: Boolean = false,
) {
    val avatarURL: String get() = Api.avatarUrl(id)
    val backgroundURL: String?
        get() = if (background.isNullOrEmpty()) null else Api.backgroundUrl(id)
}

@Serializable
data class AppNotification(
    val id: String = "",
    val type: String = "",
    val content: String? = null,
    val fromUser: String? = null,
    val fromUserId: String? = null,
    val trackId: String? = null,
    val trackTitle: String? = null,
    val commentId: String? = null,
    val created: Double = 0.0,
    val unread: Boolean = false
)
