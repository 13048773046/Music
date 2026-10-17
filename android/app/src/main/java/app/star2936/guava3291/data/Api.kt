package app.star2936.guava3291.data

import app.star2936.guava3291.state.AuthManager
import app.star2936.guava3291.state.WeatherInfo
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.booleanOrNull
import okhttp3.FormBody
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.net.URLEncoder
import java.util.concurrent.TimeUnit

// 对应 iOS API.swift
object Api {
    const val BASE = "https://www.dbmt999.asia/music/api"

    val json = Json { ignoreUnknownKeys = true; coerceInputValues = true }
    private val jsonMedia = "application/json; charset=utf-8".toMediaType()
    private val formMedia = "multipart/form-data".toMediaType()

    // 全局复用 OkHttp 客户端（连接池 + 超时，与 URLSession 行为对齐）
    val http: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(60, TimeUnit.SECONDS)
            .followRedirects(true)
            .build()
    }

    val httpLong: OkHttpClient by lazy {
        http.newBuilder().writeTimeout(180, TimeUnit.SECONDS).build()
    }

    fun coverUrl(id: String) = "$BASE/cover/$id"
    fun lyricUrl(id: String) = "$BASE/lyric/$id"
    fun avatarUrl(id: String) = "$BASE/avatar/$id"
    fun backgroundUrl(id: String) = "$BASE/background/$id"
    fun streamUrl(id: String, low: Boolean = false): String =
        "$BASE/stream/$id" + if (low) "?br=96" else ""
    fun wsUrl(token: String) = "wss://www.dbmt999.asia/music/api/ws?token=${URLEncoder.encode(token, "UTF-8")}"

    class ApiException(val msg: String) : Exception(msg)

    // ---------- 基础请求 ----------

    private fun authHeader(builder: Request.Builder) {
        AuthManager.currentUser.value?.token?.let { builder.header("Authorization", "Bearer $it") }
    }

    private fun checkAuth(code: Int) {
        if (code == 401) {
            AuthManager.handleUnauthorized()
            throw ApiException("登录已过期，请重新登录")
        }
    }

    private fun errBody(body: String): String? {
        return try {
            val obj = json.decodeFromString<Map<String, String>>(body)
            obj["err"]
        } catch (_: Exception) { null }
    }

    /** GET 请求，返回 200 body；非 2xx 抛 ApiException */
    private suspend fun get(path: String, authed: Boolean = false, timeoutMs: Long = 15000): String {
        return withContext(Dispatchers.IO) {
            val url = if (path.startsWith("http")) path else "$BASE/$path"
            val b = Request.Builder().url(url)
            if (authed) authHeader(b)
            val client = if (timeoutMs > 15000) httpLong else http
            val call = client.newCall(b.build())
            call.execute().use { resp ->
                val code = resp.code
                val body = resp.body?.string().orEmpty()
                if (authed) checkAuth(code)
                if (code in 200..299) body
                else throw ApiException(errBody(body) ?: "请求失败($code)")
            }
        }
    }

    /** POST 表单请求 */
    private suspend fun postForm(path: String, form: FormBody, authed: Boolean = false,
                                 timeoutMs: Long = 15000): String {
        return withContext(Dispatchers.IO) {
            val b = Request.Builder().url("$BASE/$path").post(form)
            if (authed) authHeader(b)
            val client = if (timeoutMs > 15000) httpLong else http
            val call = client.newCall(b.build())
            call.execute().use { resp ->
                val code = resp.code
                val body = resp.body?.string().orEmpty()
                if (authed) checkAuth(code)
                if (code in 200..299) body
                else throw ApiException(errBody(body) ?: "请求失败($code)")
            }
        }
    }

    // ---------- 歌曲列表 / 搜索 ----------

    suspend fun tracks(userId: String? = null, keyword: String? = null): List<Track> {
        val q = mutableListOf<String>()
        if (!userId.isNullOrEmpty()) q += "userId=${URLEncoder.encode(userId, "UTF-8")}"
        if (!keyword.isNullOrEmpty()) q += "q=${URLEncoder.encode(keyword, "UTF-8")}"
        val path = if (q.isEmpty()) "tracks" else "tracks?${q.joinToString("&")}"
        return json.decodeFromString(get(path))
    }

    suspend fun track(id: String): Track =
        json.decodeFromString(get("track/$id"))

    suspend fun search(keyword: String): List<Track> {
        val q = URLEncoder.encode(keyword, "UTF-8")
        return json.decodeFromString(get("search?q=$q", authed = true))
    }

    // ---------- 签名播放 URL ----------

    /**
     * 签名流 URL（对齐 iOS API.signedStreamURL for:bitrate:）。
     * @param low 低码率档（br=96，蜂窝弱网秒开）；后端签名只校验 tid:exp，br 参数不影响验签。
     */
    suspend fun signedStreamUrl(id: String, low: Boolean = false): String {
        val signUrl = "$BASE/stream-url/$id"
        val streamBase = streamUrl(id, low)
        return withContext(Dispatchers.IO) {
            val req = Request.Builder().url(signUrl).build()
            try {
                val call = http.newCall(req)
                call.execute().use { resp ->
                    if (resp.code in 200..299) {
                        val body = resp.body?.string().orEmpty()
                        val obj = kotlinx.serialization.json.Json.parseToJsonElement(body).jsonObject
                        val exp = obj["exp"]?.jsonPrimitive?.contentOrNull ?: ""
                        val sig = obj["sig"]?.jsonPrimitive?.contentOrNull ?: ""
                        if (exp.isNotEmpty() && sig.isNotEmpty()) {
                            // 分隔符：low 时 streamBase 已含 ?br=96 → 追加用 &；非 low 时首参用 ?
                            val sep = if (low) "&" else "?"
                            return@withContext "$streamBase$sep" +
                                "exp=$exp&sig=${URLEncoder.encode(sig, "UTF-8")}"
                        }
                    }
                }
            } catch (_: Exception) { }
            streamBase   // 失败回退普通 URL（低码率回退 br=96，与 iOS 一致）
        }
    }

    /** 预生成低码率签名 URL（对齐 iOS API.prepareLowBitrate：预取阶段预热 low 档） */
    suspend fun prepareLowBitrate(id: String) {
        try { signedStreamUrl(id, low = true) } catch (_: Exception) { }
    }

    // ---------- 互动 ----------

    suspend fun reportPlay(trackId: String) {
        try {
            withContext(Dispatchers.IO) {
                val b = Request.Builder().url("$BASE/play/$trackId").post(FormBody.Builder().build())
                authHeader(b)
                http.newCall(b.build()).execute().close()
            }
        } catch (_: Exception) { }
    }

    suspend fun toggleLike(trackId: String, userId: String): Pair<Boolean, Int> {
        val form = FormBody.Builder().add("userId", userId).build()
        val body = postForm("like/$trackId", form, authed = true)
        val obj = kotlinx.serialization.json.Json.parseToJsonElement(body).jsonObject
        val liked = obj["liked"]?.jsonPrimitive?.booleanOrNull ?: false
        val count = obj["likeCount"]?.jsonPrimitive?.intOrNull ?: 0
        return liked to count
    }

    suspend fun reportShare(trackId: String): Int {
        return withContext(Dispatchers.IO) {
            try {
                val b = Request.Builder().url("$BASE/share/$trackId").post(FormBody.Builder().build())
                authHeader(b)
                val resp = http.newCall(b.build()).execute()
                val body = resp.body?.string().orEmpty()
                resp.close()
                if (resp.code == 401) AuthManager.handleUnauthorized()
                val obj = kotlinx.serialization.json.Json.parseToJsonElement(body).jsonObject
                obj["shareCount"]?.jsonPrimitive?.intOrNull ?: 0
            } catch (_: Exception) { 0 }
        }
    }

    suspend fun shareLink(id: String): String? {
        return withContext(Dispatchers.IO) {
            try {
                val req = Request.Builder().url("$BASE/share-url/$id").build()
                val resp = http.newCall(req).execute()
                val body = resp.body?.string().orEmpty()
                resp.close()
                val obj = kotlinx.serialization.json.Json.parseToJsonElement(body).jsonObject
                val code = obj["code"]?.jsonPrimitive?.contentOrNull ?: ""
                if (code.isNotEmpty()) "https://www.dbmt999.asia/s/$code/" else null
            } catch (_: Exception) { null }
        }
    }

    // ---------- 行为上报 ----------

    suspend fun reportBehavior(events: List<BehaviorEvent>) {
        if (events.isEmpty()) return
        // 优先走 WebSocket（NotificationBus.sendBehavior 内部判断连接）
        if (NotificationBusRef.sendBehavior(events)) return
        try {
            withContext(Dispatchers.IO) {
                val payload = Json.encodeToString(mapOf("events" to events))
                val b = Request.Builder()
                    .url("$BASE/behavior")
                    .post(payload.toRequestBody(jsonMedia))
                authHeader(b)
                http.newCall(b.build()).execute().close()
            }
        } catch (_: Exception) { }
    }

    // ---------- 推荐 / 喜欢 ----------

    suspend fun recommend(userId: String? = null, excluding: List<String> = emptyList(),
                          fresh: Boolean = false, source: String? = null,
                          lat: Double? = null, lng: Double? = null, hour: Int? = null): List<Track> {
        val q = mutableListOf<String>()
        val uid = userId ?: AuthManager.currentUser.value?.id
        if (!uid.isNullOrEmpty()) q += "userId=${URLEncoder.encode(uid, "UTF-8")}"
        if (excluding.isNotEmpty()) q += "exclude=${URLEncoder.encode(excluding.joinToString(","), "UTF-8")}"
        if (fresh) q += "fresh=1"
        if (!source.isNullOrEmpty()) q += "source=${URLEncoder.encode(source, "UTF-8")}"
        lat?.let { q += "lat=%.4f".format(it) }
        lng?.let { q += "lng=%.4f".format(it) }
        hour?.let { q += "hour=$it" }
        val path = "recommend" + (if (q.isEmpty()) "" else "?${q.joinToString("&")}")
        return json.decodeFromString(get(path, authed = false))
    }

    suspend fun fetchWeather(lat: Double, lng: Double, hour: Int? = null): WeatherInfo? {
        return try {
            var path = "weather?lat=%.4f&lng=%.4f".format(lat, lng)
            hour?.let { path += "&hour=$it" }
            json.decodeFromString<WeatherInfo>(get(path, authed = false))
        } catch (_: Exception) { null }
    }

    suspend fun likedTracks(userId: String? = null): List<Track> {
        val uid = userId ?: AuthManager.currentUser.value?.id
        val path = if (uid.isNullOrEmpty()) "likes" else "likes?userId=${URLEncoder.encode(uid, "UTF-8")}"
        return json.decodeFromString(get(path, authed = true))
    }

    // ---------- 我的页分页 ----------

    suspend fun myTracks(page: Int, pageSize: Int = 20): PageResult<Track> {
        val body = get("my-tracks?page=$page&pageSize=$pageSize", authed = true)
        return json.decodeFromString(body)
    }

    suspend fun myLikes(page: Int, pageSize: Int = 20): PageResult<Track> {
        val body = get("my-likes?page=$page&pageSize=$pageSize", authed = true)
        return json.decodeFromString(body)
    }

    suspend fun myComments(page: Int, pageSize: Int = 20): PageResult<MyComment> {
        val body = get("my-comments?page=$page&pageSize=$pageSize", authed = true)
        return json.decodeFromString(body)
    }

    suspend fun myStats(): Int {
        val body = get("my-stats", authed = true)
        val obj = kotlinx.serialization.json.Json.parseToJsonElement(body).jsonObject
        return obj["totalSeconds"]?.jsonPrimitive?.intOrNull ?: 0
    }

    // ---------- 评论 ----------

    suspend fun fetchComments(trackId: String): List<Comment> {
        return withContext(Dispatchers.IO) {
            val req = Request.Builder().url("$BASE/comments/$trackId").build()
            http.newCall(req).execute().use { resp ->
                json.decodeFromString(resp.body?.string().orEmpty())
            }
        }
    }

    suspend fun postComment(trackId: String, userId: String, userName: String, content: String, images: List<String> = emptyList()) {
        val arr = images.joinToString(prefix = "[", postfix = "]") { "\"$it\"" }
        val contentJson = kotlinx.serialization.json.JsonPrimitive(content).toString()
        val json = """{"userId":"$userId","userName":"$userName","content":$contentJson,"images":$arr}"""
        withContext(Dispatchers.IO) {
            val b = Request.Builder().url("$BASE/comment/$trackId")
                .post(json.toRequestBody(jsonMedia))
            authHeader(b)
            http.newCall(b.build()).execute().use { resp ->
                if (!resp.isSuccessful) throw ApiException("评论失败(${resp.code})")
            }
        }
    }

    // ---------- 歌词（内存缓存 300 上限，与 iOS 一致） ----------

    @Volatile private var lyricCache: MutableMap<String, String> = mutableMapOf()
    private const val LyricCacheMax = 300

    suspend fun fetchLyric(id: String): String {
        lyricCache[id]?.let { return it }
        val text = withContext(Dispatchers.IO) {
            val req = Request.Builder().url(lyricUrl(id)).build()
            http.newCall(req).execute().use { resp ->
                if (resp.code in 200..299) resp.body?.string().orEmpty() else ""
            }
        }
        synchronized(lyricCache) {
            if (lyricCache.size >= LyricCacheMax) lyricCache = mutableMapOf()
            lyricCache[id] = text
        }
        return text
    }

    fun clearLyricCache() { synchronized(lyricCache) { lyricCache = mutableMapOf() } }

    // ---------- 用户（multipart，对应 multipart/form-data） ----------

    private fun multipart(path: String, fields: Map<String, String>,
                          files: List<Triple<String, String, ByteArray>>,
                          authed: Boolean = false): String {
        val builder = MultipartBody.Builder().setType(MultipartBody.FORM)
        fields.forEach { (k, v) -> builder.addFormDataPart(k, v) }
        files.forEach { (name, filename, data) ->
            builder.addFormDataPart(name, filename, data.toRequestBody("image/jpeg".toMediaType()))
        }
        val body = builder.build()
        val b = Request.Builder().url("$BASE/$path").post(body)
        if (authed) authHeader(b)
        val resp = httpLong.newCall(b.build()).execute()
        val code = resp.code
        val bodyStr = resp.body?.string().orEmpty()
        resp.close()
        if (authed) checkAuth(code)
        if (code !in 200..299) throw ApiException(errBody(bodyStr) ?: "请求失败($code)")
        return bodyStr
    }

    suspend fun register(password: String, name: String, avatarData: ByteArray?,
                         gender: String, age: Int, signature: String,
                         backgroundData: ByteArray?): User {
        val files = mutableListOf<Triple<String, String, ByteArray>>()
        avatarData?.let { files += Triple("avatar", "avatar.jpg", it) }
        backgroundData?.let { files += Triple("background", "background.jpg", it) }
        val body = withContext(Dispatchers.IO) {
            multipart("register", mapOf(
                "password" to password, "name" to name, "gender" to gender,
                "age" to age.toString(), "signature" to signature
            ), files)
        }
        return json.decodeFromString(body)
    }

    suspend fun login(account: String, password: String): User {
        val body = withContext(Dispatchers.IO) {
            multipart("login", mapOf("account" to account, "password" to password), emptyList())
        }
        return json.decodeFromString(body)
    }

    suspend fun updateProfile(account: String, name: String, gender: String, age: Int,
                              signature: String, avatarData: ByteArray?, backgroundData: ByteArray?): User {
        val files = mutableListOf<Triple<String, String, ByteArray>>()
        avatarData?.let { files += Triple("avatar", "avatar.jpg", it) }
        backgroundData?.let { files += Triple("background", "background.jpg", it) }
        val body = withContext(Dispatchers.IO) {
            multipart("profile/update", mapOf(
                "account" to account, "name" to name, "gender" to gender,
                "age" to age.toString(), "signature" to signature
            ), files, authed = true)
        }
        return json.decodeFromString(body)
    }

    suspend fun changePassword(old: String, new: String) {
        val form = FormBody.Builder()
            .add("old_password", old).add("new_password", new).build()
        postForm("change-password", form, authed = true)
    }

    // ---------- 上传 ----------

    suspend fun upload(data: ByteArray, filename: String, title: String, artist: String,
                       album: String, userId: String, coverData: ByteArray?) {
        withContext(Dispatchers.IO) {
            val builder = MultipartBody.Builder().setType(MultipartBody.FORM)
            builder.addFormDataPart("title", title)
            builder.addFormDataPart("artist", artist)
            builder.addFormDataPart("album", album)
            builder.addFormDataPart("userId", userId)
            builder.addFormDataPart("file", filename, data.toRequestBody("audio/mpeg".toMediaType()))
            coverData?.let { builder.addFormDataPart("cover", "cover.jpg", it.toRequestBody("image/jpeg".toMediaType())) }
            val b = Request.Builder().url("$BASE/upload").post(builder.build())
            authHeader(b)
            httpLong.newCall(b.build()).execute().use { resp ->
                if (resp.code == 401) AuthManager.handleUnauthorized()
                val body = resp.body?.string().orEmpty()
                if (resp.code !in 200..299) throw ApiException(errBody(body) ?: "上传失败(${resp.code})")
            }
        }
    }

    // ---------- 更新 / 公告 ----------

    suspend fun checkUpdate(): UpdateCheck? {
        return try { json.decodeFromString(get("check-update")) } catch (_: Exception) { null }
    }

    suspend fun fetchAnnouncement(): Announcement? {
        return try { json.decodeFromString(get("announcement")) } catch (_: Exception) { null }
    }

    // ---------- 通知 ----------

    suspend fun officialMessages(): List<OfficialMessage> {
        return withContext(Dispatchers.IO) {
            val b = Request.Builder().url("$BASE/official-messages")
            authHeader(b)
            http.newCall(b.build()).execute().use { resp ->
                if (resp.code in 200..299) {
                    val raw = resp.body?.string().orEmpty()
                    // 后端返回 {"list":[...]} 包装，提取 list 字段
                    val obj = kotlinx.serialization.json.Json.parseToJsonElement(raw)
                    val arr = if (obj is kotlinx.serialization.json.JsonObject) obj["list"].toString() else raw
                    runCatching { json.decodeFromString<List<OfficialMessage>>(arr) }.getOrDefault(emptyList())
                } else emptyList()
            }
        }
    }

    suspend fun notifications(page: Int = 1, size: Int = 30): NotificationsResult {
        return withContext(Dispatchers.IO) {
            val b = Request.Builder().url("$BASE/notifications?page=$page&size=$size")
            authHeader(b)
            http.newCall(b.build()).execute().use { resp ->
                if (resp.code in 200..299) json.decodeFromString(resp.body?.string().orEmpty())
                else NotificationsResult(emptyList(), 0, false)
            }
        }
    }

    suspend fun markNotificationsRead() {
        try {
            withContext(Dispatchers.IO) {
                val b = Request.Builder().url("$BASE/notifications/read").post(FormBody.Builder().build())
                authHeader(b)
                http.newCall(b.build()).execute().close()
            }
        } catch (_: Exception) { }
    }

    suspend fun deleteNotification(id: String) {
        try {
            withContext(Dispatchers.IO) {
                val b = Request.Builder().url("$BASE/notifications/$id").delete()
                authHeader(b)
                http.newCall(b.build()).execute().close()
            }
        } catch (_: Exception) { }
    }

    // ---------- 歌单 ----------

    suspend fun fetchPlaylists(): List<Playlist> {
        return try { json.decodeFromString(get("playlists", authed = true)) } catch (_: Exception) { emptyList() }
    }

    suspend fun createPlaylist(name: String, description: String = ""): Playlist {
        val form = FormBody.Builder().add("name", name).add("description", description).build()
        val body = postForm("playlists", form, authed = true)
        return try { json.decodeFromString(body) } catch (_: Exception) { Playlist(id = "", name = name, cover = null, trackCount = 0) }
    }

    suspend fun fetchPlaylistTracks(playlistId: String): List<Track> {
        return try { json.decodeFromString(get("playlists/$playlistId/tracks", authed = true)) } catch (_: Exception) { emptyList() }
    }

    suspend fun addToPlaylist(playlistId: String, trackId: String, title: String,
                              artist: String, cover: String?) {
        val formBuilder = FormBody.Builder()
            .add("trackId", trackId).add("title", title).add("artist", artist)
        if (!cover.isNullOrEmpty()) formBuilder.add("cover", cover)
        postForm("playlists/$playlistId/tracks", formBuilder.build(), authed = true)
    }

    suspend fun removeFromPlaylist(playlistId: String, trackId: String) {
        withContext(Dispatchers.IO) {
            val b = Request.Builder().url("$BASE/playlists/$playlistId/tracks/$trackId").delete()
            authHeader(b)
            http.newCall(b.build()).execute().close()
        }
    }

    // ---------- 播放历史 ----------

    suspend fun recordHistory(trackId: String, title: String, artist: String, cover: String?) {
        try {
            val form = FormBody.Builder()
                .add("trackId", trackId).add("title", title).add("artist", artist)
            if (!cover.isNullOrEmpty()) form.add("cover", cover)
            postForm("history", form.build(), authed = true)
        } catch (_: Exception) { }
    }

    suspend fun fetchHistory(page: Int = 1, pageSize: Int = 50): PageResult<HistoryTrack> {
        val body = get("history?page=$page&pageSize=$pageSize", authed = true)
        return json.decodeFromString(body)
    }

    // ---------- 搜索历史 ----------

    suspend fun recordSearch(keyword: String) {
        try {
            val form = FormBody.Builder().add("keyword", keyword).build()
            postForm("search/history", form, authed = true)
        } catch (_: Exception) { }
    }

    suspend fun fetchSearchHistory(): List<String> {
        return try {
            val body = get("search/history", authed = true)
            val obj = kotlinx.serialization.json.Json.parseToJsonElement(body).jsonObject
            obj["history"]?.jsonArray?.map { it.jsonPrimitive.contentOrNull ?: "" }?.filter { it.isNotEmpty() } ?: emptyList()
        } catch (_: Exception) { emptyList() }
    }

    suspend fun clearSearchHistory() {
        try {
            val b = Request.Builder().url("$BASE/search/history").delete()
            authHeader(b)
            http.newCall(b.build()).execute().close()
        } catch (_: Exception) { }
    }

    // ---------- 用户主页 ----------

    suspend fun fetchUserProfile(userId: String): UserProfile {
        val body = get("user/$userId/profile", authed = true)
        return json.decodeFromString(body)
    }

    suspend fun toggleFollow(userId: String): Boolean {
        val form = FormBody.Builder().build()
        val body = postForm("user/$userId/follow", form, authed = true)
        val obj = kotlinx.serialization.json.Json.parseToJsonElement(body).jsonObject
        return obj["isFollowing"]?.jsonPrimitive?.booleanOrNull ?: false
    }

    suspend fun fetchUserTracks(userId: String): List<Track> {
        return try { json.decodeFromString(get("user/$userId/tracks", authed = true)) } catch (_: Exception) { emptyList() }
    }

    // ---------- 评论扩展（图片/点赞） ----------

    suspend fun uploadCommentImage(data: ByteArray, filename: String): String {
        val body = multipart("upload-comment-image", emptyMap(),
            listOf(Triple("image", filename, data)), authed = true)
        val obj = kotlinx.serialization.json.Json.parseToJsonElement(body).jsonObject
        return obj["url"]?.jsonPrimitive?.contentOrNull ?: ""
    }

    suspend fun toggleCommentLike(commentId: String): Pair<Boolean, Int> {
        val form = FormBody.Builder().build()
        val body = postForm("comments/$commentId/like", form, authed = true)
        val obj = kotlinx.serialization.json.Json.parseToJsonElement(body).jsonObject
        val liked = obj["liked"]?.jsonPrimitive?.booleanOrNull ?: false
        val count = obj["likeCount"]?.jsonPrimitive?.intOrNull ?: 0
        return liked to count
    }

}

// 供 Api.reportBehavior 引用（在 state 包中定义实现，避免循环依赖编译问题）
object NotificationBusRef {
    var sendBehavior: (List<BehaviorEvent>) -> Boolean = { false }
}
