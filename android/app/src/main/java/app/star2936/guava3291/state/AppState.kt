package app.star2936.guava3291.state

import android.content.Context
import androidx.compose.ui.graphics.Color
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import app.star2936.guava3291.data.Api
import app.star2936.guava3291.data.Track
import app.star2936.guava3291.util.ColorPalette
import app.star2936.guava3291.util.parseLyrics
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

// 对应 iOS PlayerManager 会话持久化（杀 App 重开：短时间接着上次的下一首）
object PlayerSession {
    private const val SessionKey = "PlayerManager.savedSession.v1"
    private const val ResumeWindowMs = 300_000L  // 5 分钟
    private const val KeepBefore = 30
    private const val KeepAfter = 90

    private lateinit var prefs: android.content.SharedPreferences

    @Serializable
    private data class SavedSession(
        val queue: List<Track>,
        val currentIndex: Int,
        val listenMode: String,
        val playModeIndex: Int,
        val savedNormalModeIndex: Int,
        val searchContext: String?,
        val wasPlaying: Boolean,
        val savedAt: Long,
    )

    fun init(context: Context) {
        val masterKey = MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
        prefs = EncryptedSharedPreferences.create(
            context, "player_session", masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }

    /** 只在进入后台时保存一次（切歌后杀 App 必经后台回调） */
    fun saveToDisk() {
        val q = PlayerManager.queue.value
        val idx = PlayerManager.currentIndex.value
        if (q.isEmpty() || idx !in q.indices) return
        val start = maxOf(0, idx - KeepBefore)
        val end = minOf(q.size, idx + KeepAfter + 1)
        val saved = q.subList(start, end)
        val playIdx = PlayMode.entries.indexOf(PlayerManager.playMode.value).coerceAtLeast(0)
        val normalIdx = PlayMode.entries.indexOf(PlayerManager.savedNormalMode).coerceAtLeast(0)
        val s = SavedSession(
            queue = saved, currentIndex = idx - start,
            listenMode = PlayerManager.listenMode.value.name,
            playModeIndex = playIdx, savedNormalModeIndex = normalIdx,
            searchContext = Library.searchContext.value,
            wasPlaying = PlayerManager.isPlaying.value,
            savedAt = System.currentTimeMillis(),
        )
        try {
            prefs.edit().putString(SessionKey, Api.json.encodeToString(s)).apply()
        } catch (_: Exception) { }
    }

    fun restoreIfNeeded(): Boolean {
        if (PlayerManager.queue.value.isNotEmpty()) return false
        val raw = prefs.getString(SessionKey, null) ?: return false
        val s = try { Api.json.decodeFromString<SavedSession>(raw) } catch (_: Exception) { null }
        if (s == null || s.queue.isEmpty() || s.currentIndex !in s.queue.indices) {
            prefs.edit().remove(SessionKey).apply()
            return false
        }
        // 长时间重开（>5 分钟）：不接着上次，重新进带随机性的新鲜推荐流
        val age = System.currentTimeMillis() - s.savedAt
        if (age > ResumeWindowMs) {
            prefs.edit().remove(SessionKey).apply()
            return false
        }
        val mode = try { ListenMode.valueOf(s.listenMode) } catch (_: Exception) { ListenMode.Normal }
        PlayerManager.listenMode.value = mode
        if (s.playModeIndex in PlayMode.entries.indices) PlayerManager.playMode.value = PlayMode.entries[s.playModeIndex]
        if (s.savedNormalModeIndex in PlayMode.entries.indices) PlayerManager.savedNormalMode = PlayMode.entries[s.savedNormalModeIndex]
        if (mode == ListenMode.Normal) Library.searchContext.value = s.searchContext else Library.searchContext.value = null
        PlayerManager.queue.value = s.queue
        // 恢复队列里的歌加入推荐去重集合
        PlayerManager.noteRecommended(s.queue.map { it.id })
        val resume = if (s.currentIndex + 1 in s.queue.indices) s.currentIndex + 1 else 0
        PlayerManager.currentIndex.value = resume
        PlayerManager.playCurrent(autoResume = s.wasPlaying)
        return true
    }
}

// 对应 iOS AppPreloader.swift：启动页期间并行预加载发现页/我的页数据
object AppPreloader {
    val recommended = MutableStateFlow<List<Track>>(emptyList())
    val discoverRecommendedReady = MutableStateFlow(false)
    val mineStatsSeconds = MutableStateFlow(0)
    val works = MutableStateFlow<List<Track>>(emptyList())
    val worksTotal = MutableStateFlow(0)
    val likes = MutableStateFlow<List<Track>>(emptyList())
    val likesTotal = MutableStateFlow(0)
    val comments = MutableStateFlow<List<app.star2936.guava3291.data.MyComment>>(emptyList())
    val commentsTotal = MutableStateFlow(0)
    val mineLoaded = MutableStateFlow(false)

    /** 切换账号后失效我的页预加载数据 */
    fun invalidateMine() {
        mineLoaded.value = false
        works.value = emptyList()
        worksTotal.value = 0
        likes.value = emptyList()
        likesTotal.value = 0
        comments.value = emptyList()
        commentsTotal.value = 0
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    fun preload() {
        scope.launch {
            coroutineScopeLoadRecommended()
            coroutineScopeLoadMine()
        }
    }

    private suspend fun coroutineScopeLoadRecommended() {
        try {
            val list = Api.recommend(source = "discover")
            recommended.value = list.take(10)
        } catch (_: Exception) { }
        discoverRecommendedReady.value = true
    }

    private suspend fun coroutineScopeLoadMine() {
        if (AuthManager.currentUserValue?.token.isNullOrEmpty()) {
            mineLoaded.value = true
            return
        }
        kotlinx.coroutines.coroutineScope {
            launch { loadStats() }
            launch { loadWorks() }
            launch { loadLikes() }
            launch { loadComments() }
            launch { loadUnread() }
        }
        mineLoaded.value = true
    }

    private suspend fun loadStats() {
        try { mineStatsSeconds.value = Api.myStats() } catch (_: Exception) { }
    }
    private suspend fun loadWorks() {
        try { val r = Api.myTracks(1, 20); works.value = r.list; worksTotal.value = r.total } catch (_: Exception) { }
    }
    private suspend fun loadLikes() {
        try { val r = Api.myLikes(1, 20); likes.value = r.list; likesTotal.value = r.total } catch (_: Exception) { }
    }
    private suspend fun loadComments() {
        try { val r = Api.myComments(1, 20); comments.value = r.list; commentsTotal.value = r.total } catch (_: Exception) { }
    }
    private suspend fun loadUnread() {
        try {
            val r = Api.notifications()
            NotificationBus.setUnread(r.unread)
        } catch (_: Exception) { }
    }
}

// 对应 iOS AppRouter.swift：全局路由（跨页跳转与评论弹窗）
object AppRouter {
    val selectedTab = MutableStateFlow(1)   // 0=发现 1=首页 2=我的
    val showCommentSheet = MutableStateFlow(false)
    val pendingCommentTrack = MutableStateFlow<Track?>(null)
    val highlightCommentId = MutableStateFlow<String?>(null)
    val myTracksRefreshTick = MutableStateFlow(0)  // 上传成功后触发"我的"作品刷新

    fun jumpToHome(play: Track, openComment: Boolean = false, commentId: String? = null) {
        pendingCommentTrack.value = play
        highlightCommentId.value = commentId
        selectedTab.value = 1
        PlayerManager.playNotificationTrack(play)
        if (openComment) showCommentSheet.value = true
    }
}


