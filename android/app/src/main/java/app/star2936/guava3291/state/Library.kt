package app.star2936.guava3291.state

import app.star2936.guava3291.data.Api
import app.star2936.guava3291.data.Track
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

// 对应 iOS Library.swift：歌曲库全局单例（普通全随机流 + 搜索相关流）

object Library {
    val tracks = MutableStateFlow<List<Track>>(emptyList())
    val isLoaded = MutableStateFlow(false)
    val searchContext = MutableStateFlow<String?>(null)
    private var isLoadingMore = false
    private var inFlightLoad: Job? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    fun load(force: Boolean = false) {
        if (!force && isLoaded.value) return
        if (inFlightLoad?.isActive == true) return
        searchContext.value = null
        inFlightLoad = scope.launch {
            try {
                val list = Api.tracks(userId = AuthManager.currentUserValue?.id)
                tracks.value = list
                isLoaded.value = true
                // 首次拿到列表且播放器还没有队列：先尝试恢复上次播放会话，
                // 无可恢复会话 → 进入带随机性的新鲜个性化推荐流
                if (PlayerManager.queue.value.isEmpty()) {
                    if (!PlayerSession.restoreIfNeeded()) {
                        PlayerManager.startRecommendedStream(fallback = list, fresh = true)
                    }
                }
            } catch (_: Exception) {
                // 失败静默：保持未加载状态，下次进入自动重试
            }
        }
    }

    fun playFromDiscover(track: Track) {
        searchContext.value = null
        PlayerManager.startRecommendedStream(startingAt = track, fallback = tracks.value)
    }

    fun startSearchStream(keyword: String, first: Track) {
        searchContext.value = keyword
        PlayerManager.playInNormalMode(first, listOf(first))
        loadMore()
    }

    fun loadMore() {
        if (PlayerManager.listenMode.value != ListenMode.Normal) return
        if (isLoadingMore) return
        isLoadingMore = true
        scope.launch {
            try {
                val list = Api.tracks(userId = AuthManager.currentUserValue?.id, keyword = searchContext.value)
                val queue = PlayerManager.queue.value
                val existing = queue.map { it.id }.toSet()
                val fresh = list.filter { it.id !in existing }
                if (fresh.isNotEmpty()) {
                    PlayerManager.queue.update { it + fresh }
                    PlayerManager.trimQueueIfNeeded()
                }
            } catch (_: Exception) { }
            isLoadingMore = false
        }
    }
}
