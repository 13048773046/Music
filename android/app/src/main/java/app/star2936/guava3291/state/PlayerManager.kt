package app.star2936.guava3291.state

import android.content.Context
import android.media.AudioManager
import android.media.audiofx.Equalizer
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import app.star2936.guava3291.data.Api
import app.star2936.guava3291.data.BehaviorEvent
import app.star2936.guava3291.data.Track
import app.star2936.guava3291.util.ColorPalette
import app.star2936.guava3291.util.parseLyrics
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.random.Random

// 对应 iOS PlayerManager.swift（AVQueuePlayer → ExoPlayer 移植）

enum class PlayMode(val label: String) {
    ListLoop("列表循环"), SingleLoop("单曲循环"), Shuffle("随机播放")
}

enum class ListenMode(val label: String) {
    Normal("默认模式"), Works("我的作品"), Liked("我的喜欢"), Fresh("新鲜模式")
}

// 内存缓存（对应 CoverImageCache / LyricsCache / CoverPalette.cache）
object CoverCache { val map = java.util.concurrent.ConcurrentHashMap<String, ByteArray>() }
object LyricsLinesCache { val map = java.util.concurrent.ConcurrentHashMap<String, List<app.star2936.guava3291.util.KRCLine>>() }

object PlayerManager {
    lateinit var appContext: Context

    lateinit var player: androidx.media3.common.Player
    private lateinit var exoPlayer: ExoPlayer

    // ---------- 发布状态（对应 @Published） ----------
    val queue = MutableStateFlow<List<Track>>(emptyList())
    val queueRevision = MutableStateFlow(0)
    val currentIndex = MutableStateFlow(-1)
    val isPlaying = MutableStateFlow(false)
    val progress = MutableStateFlow(0.0)
    val currentTime = MutableStateFlow(0.0)
    val duration = MutableStateFlow(0.0)
    val bufferProgress = MutableStateFlow(0.0)
    val isBuffering = MutableStateFlow(false)
    val loadFailed = MutableStateFlow(false)
    val selectedEQ = MutableStateFlow("原音")
    val listenMode = MutableStateFlow(ListenMode.Normal)
    val playMode = MutableStateFlow(PlayMode.ListLoop)
    val playerCardBackgroundLight = MutableStateFlow(false)
    val playerCardDominant = MutableStateFlow<androidx.compose.ui.graphics.Color?>(null)
    val engineSwitchInProgress = MutableStateFlow(false)
    val engineDownloadFraction = MutableStateFlow(0.0)

    val current: Track?
        get() = queue.value.getOrNull(currentIndex.value)

    // ---------- 播放池健壮性 ----------
    private val loadJob = java.util.concurrent.atomic.AtomicReference<Job?>(null)
    private var autoRetriedTrackId: String? = null
    private var bufferingStallStart: Long? = null
    private var stallProgressAtStart = 0.0
    // 卡死超时动态化：离线不设超时（等网络恢复，对齐 iOS isOffline → 无限等待）
    private val stallTimeoutMs: Long
        get() = if (NetworkMonitor.isOffline.value) Long.MAX_VALUE else 15000L
    private var pendingSeekFraction: Double? = null

    // ---------- 码率决策（对齐 iOS activeBitrate/effectiveBitrate/bitrateUpgraded） ----------
    /** 已从低码率升级到原码率重试的曲目（low 失败 → high 兜底，避免同一首反复卡 low） */
    private val bitrateUpgraded = mutableSetOf<String>()
    /** 当前播放曲目实际使用的码率档（true=low 96k） */
    private var activeLow = false

    /** 弱网播放 UI：当前是否离线（失败视图文案区分「网络未连接」与「加载失败」） */
    val networkOffline: Boolean get() = NetworkMonitor.isOffline.value

    /** 当前曲目码率档决策：蜂窝弱网 → 低码率；已升级（low 失败）→ 原码率 */
    private fun effectiveLowFor(trackId: String?): Boolean =
        NetworkMonitor.isCellular.value && trackId != null && trackId !in bitrateUpgraded

    /** 签名 URL 池键：码率绑定（高低码率不互相覆盖） */
    private fun poolKey(id: String, low: Boolean) = "$id::$low"

    // ---------- 预加载 ----------
    private val signedURLPool = mutableMapOf<String, String>()
    private val urlPoolOrder = mutableListOf<String>()
    private val urlPoolLimit = 16
    // 预取窗口动态化：离线暂停预取（省流量，对齐 iOS isOffline → 0）
    private val prefetchAheadCount: Int
        get() = if (NetworkMonitor.isOffline.value) 0 else 4
    private var prefetchJob: Job? = null

    // ---------- 推荐流 ----------
    private val recommendedIds = mutableSetOf<String>()
    private val recommendedExcludeCap = 500

    // ---------- 收听结算 ----------
    private data class ListenState(
        var trackId: String = "",
        var seconds: Double = 0.0,
        var reported: Double = 0.0,
        var completedPlays: Int = 0,
    )
    private var listen = ListenState()
    private var tickerJob: Job? = null

    // ---------- 听歌模式会话 ----------
    private data class ModeSession(
        var queue: List<Track> = emptyList(),
        var currentIndex: Int = -1,
        var wasPlaying: Boolean = false,
        var searchContext: String? = null,
        var mode: ListenMode = ListenMode.Normal,
    )
    private val sessions = mutableMapOf<ListenMode, ModeSession>()
    internal var savedNormalMode = PlayMode.ListLoop

    // ---------- EQ（系统均衡器近似实现） ----------
    private var eq: Equalizer? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    // ---------- 初始化 ----------
    private var simpleCache: androidx.media3.datasource.cache.SimpleCache? = null

    fun init(context: Context) {
        appContext = context.applicationContext

        // 工业级本地音频缓存（对应 iOS AudioCache）：200MB LRU，已缓存歌曲下次秒开+离线可播
        try {
            val cacheDir = java.io.File(appContext.cacheDir, "liuying_audio")
            if (!cacheDir.exists()) cacheDir.mkdirs()
            simpleCache = androidx.media3.datasource.cache.SimpleCache(
                cacheDir,
                androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor(200L * 1024 * 1024),
                androidx.media3.database.StandaloneDatabaseProvider(appContext)
            )
        } catch (_: Exception) {}

        // 对应 iOS preferredForwardBufferDuration=30：向前缓冲更多数据，切歌秒开减少卡顿
        // 弱网工业级缓冲策略：小缓冲快速起播，大缓冲抗抖动
        val loadControl = androidx.media3.exoplayer.DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                5000,    // minBufferMs: 5秒（弱网快速起播）
                45000,   // maxBufferMs: 45秒
                1000,    // bufferForPlaybackMs: 缓冲1秒即起播
                3000     // bufferForPlaybackAfterRebufferMs: 卡顿时缓冲3秒再续
            )
            .setPrioritizeTimeOverSizeThresholds(true)
            .build()
        // 缓存数据源：已缓存歌曲直接本地读，未缓存走网络并写入缓存
        val dataSourceFactory = simpleCache?.let { cache ->
            val httpDataSource = androidx.media3.datasource.DefaultHttpDataSource.Factory()
                .setConnectTimeoutMs(8000)
                .setReadTimeoutMs(15000)
            androidx.media3.datasource.cache.CacheDataSource.Factory()
                .setCache(cache)
                .setUpstreamDataSourceFactory(httpDataSource)
                .setFlags(androidx.media3.datasource.cache.CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
        }

        exoPlayer = ExoPlayer.Builder(appContext)
            .setLoadControl(loadControl)
            .apply { if (dataSourceFactory != null) setMediaSourceFactory(androidx.media3.exoplayer.source.DefaultMediaSourceFactory(dataSourceFactory)) }
            .build()
        // 通知栏上一首/下一首按钮调 seekToPrevious()/seekToNext()，
        // ExoPlayer 默认行为：position>5s 时 seekTo(0) 重播当前歌。
        // override 为 seekToPreviousMediaItem()/seekToNextMediaItem()，总是切到上/下一个 item。
        player = object : androidx.media3.common.ForwardingPlayer(exoPlayer) {
            override fun seekToPrevious() {
                super.seekToPreviousMediaItem()
            }
            override fun seekToNext() {
                super.seekToNextMediaItem()
            }
        }
        player.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
                .build(),
            true  // handleAudioFocus：来电等打断自动暂停
        )
        player.volume = 1.0f
        addPlayerListeners()
        startTicker()
    }

    private fun addPlayerListeners() {
        // 自动切歌：媒体项自动前进 → 同步索引 + 结算上一首（等价 adoptAutoAdvancedTrack）
        player.addListener(object : Player.Listener {
            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                val newId = mediaItem?.mediaId ?: return
                val idx = queue.value.indexOfFirst { it.id == newId }
                if (idx < 0) return
                val prev = currentIndex.value
                if (idx != prev) {
                    currentIndex.value = idx
                    if (listen.trackId != newId) {
                        flushListen(ListenFlushReason.SwitchTrack)
                        listen = ListenState(trackId = newId)
                        autoRetriedTrackId = null
                    }
                    topUpQueue()
                }
            }

            override fun onPlaybackStateChanged(playbackState: Int) {
                isBuffering.value = playbackState == Player.STATE_BUFFERING
                if (playbackState == Player.STATE_ENDED) {
                    // clearMediaItems/stop 后也会触发 STATE_ENDED，此时 player 无 item，不能误调 next()
                    if (player.mediaItemCount == 0) return
                    // 队列已全部播完（无下一项可自动前进）：统一由 next() 驱动
                    if (listen.trackId == current?.id) listen.completedPlays += 1
                    flushListen(ListenFlushReason.Complete)
                    next()
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                // 弱网工业级：网络错误按码率档处理，其他错误跳下一首
                val isNetworkError = when (error.errorCode) {
                    PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
                    PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT,
                    PlaybackException.ERROR_CODE_IO_UNSPECIFIED,
                    PlaybackException.ERROR_CODE_TIMEOUT -> true
                    else -> false
                }
                if (isNetworkError) {
                    // low 码率失败 → 同曲升级原码率重试一次（防反复卡低码率）；
                    // 已升级/非 low → 走延迟重试；断网 → 失败视图（网络恢复后自动续播）
                    val tid = current?.id
                    if (activeLow && tid != null && tid !in bitrateUpgraded) {
                        bitrateUpgraded.add(tid)
                        reloadCurrent()
                    } else {
                        handlePlaybackFailure()
                    }
                } else {
                    // 解码器/格式错误：直接跳下一首，不卡屏
                    scope.launch {
                        delay(500)
                        next()
                    }
                }
            }
        })
    }

    /** 每秒心跳：累计收听秒数 + 30s 自动上报 + 缓冲卡死检测 + 进度/缓冲刷新 */
    private fun startTicker() {
        tickerJob?.cancel()
        tickerJob = scope.launch {
            while (isActive) {
                delay(100)
                refreshProgress()
                tickEverySecond()
            }
        }
    }

    private var lastTickSecond = -1L
    private fun tickEverySecond() {
        val now = System.currentTimeMillis()
        val sec = now / 1000
        if (sec == lastTickSecond) return
        lastTickSecond = sec
        if (current != null && isPlaying.value && !loadFailed.value && !isBuffering.value) {
            listen.seconds += 1
            if (listen.seconds - listen.reported >= 30) flushListen(ListenFlushReason.Heartbeat)
        }
    }

    private fun refreshProgress() {
        // 工业级：切歌窗口期，player 当前 mediaId 与目标不一致时不更新 progress
        val playerMediaId = player.currentMediaItem?.mediaId
        val targetId = current?.id
        if (playerMediaId != targetId) return

        val d = player.duration.coerceAtLeast(0L)
        val dur = if (d == C.TIME_UNSET.toLong()) 0.0 else d / 1000.0
        if (dur > 0) {
            duration.value = dur
            currentTime.value = player.currentPosition / 1000.0
            progress.value = clamp01(player.currentPosition / 1000.0 / dur)
        }
        // 缓冲进度：已加载区间终点 / 总时长
        val buffered = player.bufferedPosition
        if (dur > 0) bufferProgress.value = clamp01(buffered / 1000.0 / dur)
        // 卡死检测：缓冲中 15s 无进展 → 自愈
        if (isBuffering.value) {
            if (bufferingStallStart == null) {
                bufferingStallStart = System.currentTimeMillis()
                stallProgressAtStart = progress.value
            } else if (System.currentTimeMillis() - (bufferingStallStart ?: 0) > stallTimeoutMs &&
                dur > 0 && progress.value - stallProgressAtStart < 0.01) {
                bufferingStallStart = null
                handlePlaybackFailure()
            }
        } else {
            bufferingStallStart = null
        }
    }

    // ---------- 失败自愈 ----------

    private fun handlePlaybackFailure() {
        if (loadFailed.value) return
        loadFailed.value = true
        isBuffering.value = false
        isPlaying.value = false
        bufferingStallStart = null
        val trackId = current?.id ?: return
        if (autoRetriedTrackId == trackId) return
        autoRetriedTrackId = trackId
        // 延迟 2s 自动重试一次（期间切歌/手动恢复则取消）
        scope.launch {
            delay(2000)
            if (current?.id == trackId && loadFailed.value) {
                playCurrent(flushReason = ListenFlushReason.Heartbeat)
            }
        }
    }

    // ---------- 播放核心 ----------

    /** 重建播放器队列：上一首 + 当前歌 + 后续预取命中的歌（对应 prepareQueuePlayer） */
    private fun prepareQueue(currentIndex: Int, currentURL: String) {
        val q = queue.value
        val t = q[currentIndex]
        val cur = MediaItem.Builder()
            .setMediaId(t.id)
            .setUri(currentURL)
            .setMediaMetadata(
                MediaMetadata.Builder()
                    .setTitle(t.title)
                    .setArtist(t.displayAuthor)
                    .apply { t.coverURL?.let { setArtworkUri(android.net.Uri.parse(it)) } }
                    .build()
            )
            .build()
        // 上一首（通知栏/锁屏上一首按钮需要 player 有前一个 item）
        val prevs = mutableListOf<MediaItem>()
        if (currentIndex > 0) {
            val pt = q[currentIndex - 1]
            signedURLPool[poolKey(pt.id, activeLow)]?.let { u ->
                prevs.add(MediaItem.Builder()
                    .setMediaId(pt.id)
                    .setUri(u)
                    .setMediaMetadata(
                        MediaMetadata.Builder()
                            .setTitle(pt.title)
                            .setArtist(pt.displayAuthor)
                            .apply { pt.coverURL?.let { setArtworkUri(android.net.Uri.parse(it)) } }
                            .build()
                    )
                    .build())
            }
        }
        val nexts = mutableListOf<MediaItem>()
        val end = minOf(currentIndex + 1 + prefetchAheadCount, q.size)
        for (i in (currentIndex + 1) until end) {
            val nt = q[i]
            val u = signedURLPool[poolKey(nt.id, activeLow)] ?: continue
            nexts.add(MediaItem.Builder()
                .setMediaId(nt.id)
                .setUri(u)
                .setMediaMetadata(
                    MediaMetadata.Builder()
                        .setTitle(nt.title)
                        .setArtist(nt.displayAuthor)
                        .apply { nt.coverURL?.let { setArtworkUri(android.net.Uri.parse(it)) } }
                        .build()
                )
                .build())
        }
        // startIndex = prevs.size（从 cur 开始播放）
        player.setMediaItems(prevs + listOf(cur) + nexts, prevs.size, 0)
        player.prepare()
        player.playWhenReady = true

        // 异步补充队列里其余歌的 URL
        scope.launch {
            // 补前一首的 URL（通知栏上一首按钮需要 player 有前一个 item）
            if (currentIndex > 0) {
                val pt = q[currentIndex - 1]
                if (!signedURLPool.containsKey(poolKey(pt.id, activeLow))) {
                    try {
                        val u = Api.signedStreamUrl(pt.id)
                        signedURLPool[poolKey(pt.id, activeLow)] = u
                        withContext(Dispatchers.Main) {
                            var exists = false
                            for (j in 0 until player.mediaItemCount) {
                                if (player.getMediaItemAt(j).mediaId == pt.id) { exists = true; break }
                            }
                            if (!exists) {
                                player.addMediaItem(0, MediaItem.Builder()
                                    .setMediaId(pt.id)
                                    .setUri(u)
                                    .setMediaMetadata(
                                        MediaMetadata.Builder()
                                            .setTitle(pt.title)
                                            .setArtist(pt.displayAuthor)
                                            .apply { pt.coverURL?.let { setArtworkUri(android.net.Uri.parse(it)) } }
                                            .build()
                                    )
                                    .build())
                            }
                        }
                    } catch (_: Exception) {}
                }
            }
            for (i in (currentIndex + 1) until end) {
                val nt = queue.value[i]
                if (signedURLPool.containsKey(poolKey(nt.id, activeLow))) continue
                try {
                    val u = Api.signedStreamUrl(nt.id)
                    signedURLPool[poolKey(nt.id, activeLow)] = u
                    withContext(Dispatchers.Main) {
                        var exists = false
                        for (j in 0 until player.mediaItemCount) {
                            if (player.getMediaItemAt(j).mediaId == nt.id) { exists = true; break }
                        }
                        if (!exists) {
                            player.addMediaItem(MediaItem.Builder()
                                .setMediaId(nt.id)
                                .setUri(u)
                                .setMediaMetadata(
                                    MediaMetadata.Builder()
                                        .setTitle(nt.title)
                                        .setArtist(nt.displayAuthor)
                                        .apply { nt.coverURL?.let { setArtworkUri(android.net.Uri.parse(it)) } }
                                        .build()
                                )
                                .build())
                        }
                    }
                } catch (_: Exception) {}
            }
        }
    }

    /** 队列末尾歌之后补插后续歌（对应 topUpQueue） */
    private fun topUpQueue() {
        val q = queue.value
        if (q.isEmpty()) return
        val lastId = player.currentMediaItem?.mediaId ?: return
        val lastIdx = q.indexOfFirst { it.id == lastId }
        if (lastIdx < 0) return
        val end = minOf(lastIdx + 1 + prefetchAheadCount, q.size)
        val startInsert = lastIdx + 1
        for (i in startInsert until end) {
            val t = q[i]
            val u = signedURLPool[poolKey(t.id, activeLow)] ?: break
            var already = false
            for (j in 0 until player.mediaItemCount) {
                if (player.getMediaItemAt(j).mediaId == t.id) { already = true; break }
            }
            if (already) continue
            player.addMediaItem(MediaItem.Builder().setMediaId(t.id).setUri(u).build())
        }
    }

    private var debounceJob: Job? = null

    fun play(track: Track, tracks: List<Track>) {
        if (tracks.isEmpty()) return
        if (queue.value != tracks) queue.value = tracks
        val idx = tracks.indexOfFirst { it.id == track.id }
        currentIndex.value = if (idx >= 0) idx else 0
        playCurrent()
    }

    /** 核心播放入口（对应 playCurrent 三态判断：alreadyOnTarget / canAdvance / 重建） */
    internal fun playCurrent(flushReason: ListenFlushReason? = null,
                             resumeSeconds: Double? = null,
                             autoResume: Boolean = true) {
        val cur = current ?: return
        // 启动媒体播放服务（此时 player 即将有 media item，MediaSessionService 会自动显示通知）
        androidx.core.content.ContextCompat.startForegroundService(appContext, android.content.Intent(appContext, PlaybackService::class.java))
        prefetchJob?.cancel()
        prefetchJob = null
        pendingSeekFraction = null
        loadJob.get()?.cancel()

        // 高频切歌：立即停止旧流（工业级：不等 URL，立即清空，避免旧音频残留）
        player.pause()
        player.clearMediaItems()
        player.stop()

        val sameTrack = listen.trackId == cur.id
        flushListen(flushReason ?: if (sameTrack) ListenFlushReason.Heartbeat else ListenFlushReason.SwitchTrack)
        // 工业级：切歌时记录上一首播放历史（本地 MRU + 后端上报；本地只存元数据）
        if (!sameTrack && listen.trackId.isNotEmpty()) {
            val prevId = listen.trackId
            val prevTrack = queue.value.find { it.id == prevId }
            prevTrack?.let { LocalPlayHistory.record(it) }
            scope.launch {
                try {
                    Api.recordHistory(prevId, prevTrack?.title ?: "", prevTrack?.displayAuthor ?: "", prevTrack?.cover)
                } catch (_: Exception) {}
            }
        }
        if (!sameTrack) {
            listen = ListenState(trackId = cur.id)
            autoRetriedTrackId = null
        }

        isPlaying.value = autoResume
        player.playWhenReady = autoResume
        if (resumeSeconds == null) {
            duration.value = 0.0
            progress.value = 0.0
            currentTime.value = 0.0
            bufferProgress.value = 0.0
        }
        isBuffering.value = true
        loadFailed.value = false
        bufferingStallStart = null

        // 三态判断（player 已清空，alreadyOnTarget 恒 false，canAdvance 恒 false）
        val currentMediaId = player.currentMediaItem?.mediaId
        val nextMediaId = if (player.mediaItemCount > 1) player.getMediaItemAt(1).mediaId else null
        val alreadyOnTarget = currentMediaId == cur.id
        val canAdvance = nextMediaId == cur.id

        if ((alreadyOnTarget || canAdvance) && !autoResume) {
            player.pause()
        }

        loadJob.set(scope.launch {
            val trackId = cur.id
            // 码率决策：蜂窝弱网 → 低码率秒开；low 失败已升级 → 原码率；离线 → 只用已升级档
            val low = if (NetworkMonitor.isOffline.value) {
                bitrateUpgraded.contains(trackId)
            } else {
                NetworkMonitor.isCellular.value && trackId !in bitrateUpgraded
            }
            activeLow = low
            val key = poolKey(trackId, low)
            val cached = signedURLPool.remove(key).also {
                if (it != null) urlPoolOrder.remove(key)
            }
            // 弱网工业级：signedStreamUrl 重试 3 次（指数退避 1s/2s/4s）
            val url = cached ?: run {
                var lastError: Exception? = null
                for (attempt in 0..2) {
                    try {
                        return@run Api.signedStreamUrl(trackId, low)
                    } catch (e: Exception) {
                        lastError = e
                        if (attempt < 2) kotlinx.coroutines.delay(1000L * (1 shl attempt))
                    }
                }
                throw lastError ?: Exception("signedStreamUrl failed")
            }
            if (loadJob.get()?.isCancelled == true) return@launch
            if (current?.id != trackId) return@launch

            if (canAdvance) {
                // 预取就绪：秒开（对应 advanceToNextItem）
                player.seekToNextMediaItem()
                topUpQueue()
            } else if (!alreadyOnTarget) {
                prepareQueue(currentIndex.value, url)
            }
            if (resumeSeconds != null) {
                player.seekTo((resumeSeconds * 1000).toLong())
                if (autoResume) player.play()
            } else if (autoResume) {
                player.play()
            }
            schedulePrefetch()
        })
        // 播放上报
        scope.launch { Api.reportPlay(cur.id) }
    }

    fun toggle() {
        if (current == null) return
        if (isPlaying.value) pausePlayback() else resumePlayback()
    }

    fun resumePlayback() {
        if (loadFailed.value) { reloadCurrent(); return }
        player.play()
        isPlaying.value = true
    }

    fun pausePlayback() {
        flushListen(ListenFlushReason.Pause)
        player.pause()
        isPlaying.value = false
    }

    fun reloadCurrent() {
        if (current == null) return
        playCurrent(flushReason = ListenFlushReason.Heartbeat)
    }

    fun seekToFraction(toFraction: Double) {
        val d = duration.value
        if (d > 0) {
            player.seekTo((toFraction * d * 1000).toLong())
        } else {
            pendingSeekFraction = toFraction
        }
    }

    fun seekToSeconds(toSeconds: Double) {
        if (duration.value > 0) {
            player.seekTo((toSeconds * 1000).toLong())
        } else {
            pendingSeekFraction = toSeconds / maxOf(duration.value, 1.0)
        }
    }

    // ---------- 切歌 ----------

    fun next() {
        val q = queue.value
        if (q.isEmpty()) return
        val prevIndex = currentIndex.value
        when (playMode.value) {
            PlayMode.SingleLoop -> {
                currentIndex.value = prevIndex
                playCurrent()
            }
            PlayMode.Shuffle -> {
                currentIndex.value = randomIndex(excluding = currentIndex.value)
                playCurrent()
            }
            PlayMode.ListLoop -> {
                if (currentIndex.value < q.size - 1) {
                    currentIndex.value += 1
                    playCurrent()
                } else if (listenMode.value == ListenMode.Normal) {
                    loadNextBatchOrLoop()
                } else {
                    currentIndex.value = 0
                    playCurrent()
                }
            }
        }
    }

    fun previous() {
        val q = queue.value
        if (q.isEmpty()) return
        when (playMode.value) {
            PlayMode.SingleLoop -> playCurrent()
            PlayMode.Shuffle -> { currentIndex.value = randomIndex(currentIndex.value); playCurrent() }
            PlayMode.ListLoop -> {
                currentIndex.value = (currentIndex.value - 1 + q.size) % q.size
                playCurrent()
            }
        }
    }

    fun cyclePlayMode() {
        val all = PlayMode.entries
        val idx = all.indexOf(playMode.value)
        playMode.value = all[(idx + 1) % all.size]
    }

    private fun randomIndex(excluding: Int): Int {
        val count = queue.value.size
        if (count <= 1) return 0
        var target = Random.nextInt(count)
        if (target == excluding) target = (target + 1) % count
        return target
    }

    // ---------- 默认模式队尾续播（汽水式无限流） ----------

    private fun loadNextBatchOrLoop() {
        val lastIndex = currentIndex.value
        val baseCount = queue.value.size
        val isSearchStream = Library.searchContext.value != null
        scope.launch {
            if (isSearchStream) {
                Library.loadMore()
            } else {
                val excluding = recommendedIds.toList().takeLast(recommendedExcludeCap)
                val next = try { Api.recommend(excluding = excluding) } catch (_: Exception) { emptyList() }
                if (next.isNotEmpty()) {
                    recommendedIds.addAll(next.map { it.id })
                    val existing = queue.value.map { it.id }.toSet()
                    val fresh = next.filter { it.id !in existing }
                    if (fresh.isNotEmpty()) {
                        queue.update { it + fresh }
                        trimQueueIfNeeded()
                    }
                }
            }
            val grew = queue.value.size > baseCount
            val stillAtEnd = currentIndex.value == lastIndex
            if (grew && stillAtEnd && listenMode.value == ListenMode.Normal) {
                currentIndex.value = baseCount
                playCurrent()
            } else if (!grew && stillAtEnd) {
                currentIndex.value = 0
                playCurrent()
            }
        }
    }

    /** 预加载下一批歌曲（滑到倒数第2页时触发，只追加不跳转） */
    fun preloadNextBatch() {
        if (Library.searchContext.value != null) {
            Library.loadMore()
            return
        }
        scope.launch {
            try {
                val excluding = recommendedIds.toList().takeLast(recommendedExcludeCap)
                val next = Api.recommend(excluding = excluding)
                if (next.isNotEmpty()) {
                    recommendedIds.addAll(next.map { it.id })
                    val existing = queue.value.map { it.id }.toSet()
                    val fresh = next.filter { it.id !in existing }
                    if (fresh.isNotEmpty()) {
                        queue.update { it + fresh }
                        trimQueueIfNeeded()
                    }
                }
            } catch (_: Exception) {}
        }
    }

    // ---------- 队列修剪 ----------

    fun trimQueueIfNeeded() {
        val limit = 200
        val keepBefore = 20
        val q = queue.value
        val idx = currentIndex.value
        if (q.size > limit && idx > keepBefore) {
            val removeCount = idx - keepBefore
            if (removeCount > 0) {
                queue.value = q.drop(removeCount)
                currentIndex.value -= removeCount
                queueRevision.update { it + 1 }
            }
        }
    }

    // ---------- 预加载（签名 URL + 元数据） ----------

    private fun schedulePrefetch() {
        prefetchJob?.cancel()
        val q = queue.value
        val idx = currentIndex.value
        if (q.isEmpty() || idx < 0) return
        val start = idx + 1
        val end = minOf(start + prefetchAheadCount, q.size)
        if (start >= end) return
        val targets = q.subList(start, end)
        prefetchJob = scope.launch {
            // 阶段1：并行签发签名 URL
            val jobs = targets.map { t ->
                launch {
                    warmURLOnly(t)
                }
            }
            jobs.forEach { it.join() }
            // 阶段2：预热元数据
            for (t in targets) {
                if (!isActive) break
                warmMetadata(t)
            }
        }
    }

    private suspend fun warmURLOnly(t: Track) {
        // 预取码率与播放决策一致：蜂窝弱网 → 低码率（预取 low 档，秒开且省流量）
        val low = effectiveLowFor(t.id)
        val key = poolKey(t.id, low)
        if (signedURLPool.containsKey(key)) {
            withContext(Dispatchers.Main) { topUpQueue() }
            return
        }
        val fetched = Api.signedStreamUrl(t.id, low)
        synchronized(signedURLPool) {
            if (signedURLPool.size >= urlPoolLimit && urlPoolOrder.isNotEmpty()) {
                signedURLPool.remove(urlPoolOrder.removeAt(0))
            }
            signedURLPool[key] = fetched
            urlPoolOrder.add(key)
        }
        withContext(Dispatchers.Main) { topUpQueue() }
    }

    private suspend fun warmMetadata(t: Track) {
        // 封面图 → Coil 内存缓存（切歌时 CoverImage 直接命中，无需网络）
        t.coverURL?.let { url ->
            try {
                coil.ImageLoader(appContext)
                    .execute(coil.request.ImageRequest.Builder(appContext).data(url).build())
            } catch (_: Exception) {}
        }
        // 主色 → 内存缓存（切歌时背景色立即命中）
        t.coverURL?.let { url ->
            if (ColorPalette.colorFor(t.id, url) == null) {
                ColorPalette.load(t.id, url)
            }
        }
        // 歌词 → 内存缓存
        if (t.hasLyric == true && !LyricsLinesCache.map.containsKey(t.id)) {
            try {
                val text = Api.fetchLyric(t.id)
                val lines = parseLyrics(text)
                if (lines.isNotEmpty()) LyricsLinesCache.map[t.id] = lines
            } catch (_: Exception) { }
        }
    }

    /** 冷启动预热首曲签名 URL（码率档与当前网络一致） */
    suspend fun prewarm(t: Track) {
        val low = effectiveLowFor(t.id)
        val key = poolKey(t.id, low)
        if (!signedURLPool.containsKey(key)) {
            val fetched = Api.signedStreamUrl(t.id, low)
            synchronized(signedURLPool) {
                if (signedURLPool.size >= urlPoolLimit && urlPoolOrder.isNotEmpty()) {
                    signedURLPool.remove(urlPoolOrder.removeAt(0))
                }
                signedURLPool[key] = fetched
                urlPoolOrder.add(key)
            }
        }
    }

    // ---------- 播放入口（搜索/发现/通知/我的页） ----------

    fun playInNormalMode(track: Track, tracks: List<Track>) {
        if (listenMode.value != ListenMode.Normal) {
            saveSession(listenMode.value)
            listenMode.value = ListenMode.Normal
        }
        play(track, tracks)
    }

    fun playFromDiscover(track: Track) {
        Library.searchContext.value = null
        startRecommendedStream(startingAt = track, fallback = Library.tracks.value)
    }

    fun playNotificationTrack(track: Track) {
        val q = queue.value
        if (q.isEmpty()) {
            play(track, listOf(track))
            return
        }
        val idx = if (currentIndex.value in q.indices) currentIndex.value else 0
        if (q[idx].id == track.id) {
            currentIndex.value = idx
            playCurrent()
            return
        }
        val found = q.indexOfFirst { it.id == track.id }
        if (found >= 0) {
            currentIndex.value = found
            playCurrent()
            return
        }
        val newQ = q.toMutableList()
        newQ.add(idx + 1, track)
        queue.value = newQ
        currentIndex.value = idx + 1
        queueRevision.update { it + 1 }
        playCurrent()
    }

    fun noteRecommended(ids: List<String>) {
        recommendedIds.addAll(ids)
    }

    // ---------- 推荐流 ----------

    fun startRecommendedStream(startingAt: Track? = null, fallback: List<Track> = emptyList(),
                               fresh: Boolean = false) {
        if (listenMode.value != ListenMode.Normal) {
            saveSession(listenMode.value)
            listenMode.value = ListenMode.Normal
        }
        val excluding = recommendedIds.toList().takeLast(recommendedExcludeCap)
        scope.launch {
            val list = try { Api.recommend(excluding = excluding, fresh = fresh) } catch (_: Exception) { emptyList() }
            if (list.isEmpty()) {
                // 推荐不可用：回退保底队列
                if (fallback.isNotEmpty()) {
                    val base = fallback
                    when {
                        startingAt != null && base.any { it.id == startingAt.id } -> play(startingAt, base)
                        startingAt != null -> play(startingAt, listOf(startingAt) + base.filter { it.id != startingAt.id })
                        else -> base.firstOrNull()?.let { play(it, base) }
                    }
                } else if (startingAt != null) {
                    play(startingAt, listOf(startingAt))
                }
                return@launch
            }
            recommendedIds.addAll(list.map { it.id })
            when {
                startingAt != null && list.any { it.id == startingAt.id } -> play(startingAt, list)
                startingAt != null -> {
                    recommendedIds.add(startingAt.id)
                    play(startingAt, listOf(startingAt) + list)
                }
                else -> list.firstOrNull()?.let { play(it, list) }
            }
        }
    }

    // ---------- 听歌模式会话 ----------

    private fun saveSession(mode: ListenMode) {
        val q = queue.value
        if (q.isEmpty()) return
        sessions[mode] = ModeSession(
            queue = q,
            currentIndex = currentIndex.value,
            wasPlaying = isPlaying.value,
            searchContext = if (mode == ListenMode.Normal) Library.searchContext.value else null,
            mode = mode
        )
    }

    private fun restoreSession(s: ModeSession) {
        if (s.queue.isEmpty() || s.currentIndex !in s.queue.indices) return
        if (s.mode == ListenMode.Normal) {
            Library.searchContext.value = s.searchContext
        }
        val resumeIndex = if (s.currentIndex + 1 in s.queue.indices) s.currentIndex + 1 else 0
        play(s.queue[resumeIndex], s.queue)
        if (!s.wasPlaying) pausePlayback()
    }

    fun applyListenMode(mode: ListenMode) {
        if (mode == listenMode.value && mode != ListenMode.Liked && mode != ListenMode.Works) return
        val previous = listenMode.value
        saveSession(previous)
        listenMode.value = mode
        when (mode) {
            ListenMode.Normal -> restoreNormalStream()
            ListenMode.Works -> switchToWorks(previous)
            ListenMode.Liked -> switchToLiked(previous)
            ListenMode.Fresh -> switchToFresh(previous)
        }
    }

    private fun handleFailedSwitch(fallback: ListenMode) {
        if (fallback == listenMode.value) return
        val has = when (fallback) {
            ListenMode.Normal -> sessions.containsKey(ListenMode.Normal)
            ListenMode.Works -> sessions.containsKey(ListenMode.Works)
            ListenMode.Liked -> sessions.containsKey(ListenMode.Liked)
            ListenMode.Fresh -> sessions.containsKey(ListenMode.Fresh)
        }
        if (!has) {
            listenMode.value = ListenMode.Normal
            restoreNormalStream()
            return
        }
        listenMode.value = fallback
        when (fallback) {
            ListenMode.Normal -> restoreNormalStream()
            ListenMode.Works -> switchToWorks(null)
            ListenMode.Liked -> switchToLiked(null)
            ListenMode.Fresh -> switchToFresh(null)
        }
    }

    private fun restoreNormalStream() {
        playMode.value = savedNormalMode
        val s = sessions[ListenMode.Normal]
        if (s != null && s.queue.isNotEmpty()) {
            restoreSession(s)
            return
        }
        startRecommendedStream(fallback = Library.tracks.value)
    }

    private fun switchToLiked(fallback: ListenMode?, startAt: Track? = null, known: List<Track> = emptyList()) {
        val s = sessions[ListenMode.Liked]
        if (s != null && s.queue.isNotEmpty()) {
            if (startAt != null && s.queue.none { it.id == startAt.id }) {
                // 目标歌不在缓存会话：重新拉全量
            } else {
                if (startAt != null) {
                    val idx = s.queue.indexOfFirst { it.id == startAt.id }
                    play(startAt, s.queue)
                    return
                }
                restoreSession(s)
                return
            }
        }
        savedNormalMode = playMode.value
        playMode.value = PlayMode.ListLoop
        val uid = AuthManager.currentUserValue?.id ?: run {
            fallback?.let { handleFailedSwitch(it) }
            return
        }
        scope.launch {
            val list = try { Api.likedTracks(uid) } catch (_: Exception) { emptyList() }
            if (listenMode.value != ListenMode.Liked) return@launch
            var base = list
            if (base.isEmpty() && known.isNotEmpty()) base = known
            if (base.isEmpty()) {
                fallback?.let { handleFailedSwitch(it) }
                return@launch
            }
            val session = ModeSession(queue = base, currentIndex = 0, wasPlaying = true, mode = ListenMode.Liked)
            if (startAt != null) {
                val idx = base.indexOfFirst { it.id == startAt.id }
                if (idx >= 0) { play(startAt, base); return@launch }
            }
            sessions[ListenMode.Liked] = session
            restoreSession(session)
        }
    }

    private fun switchToWorks(fallback: ListenMode?, startAt: Track? = null, known: List<Track> = emptyList()) {
        val s = sessions[ListenMode.Works]
        if (s != null && s.queue.isNotEmpty()) {
            if (startAt != null && s.queue.none { it.id == startAt.id }) {
                // 重新拉全量
            } else {
                if (startAt != null) {
                    play(startAt, s.queue)
                    return
                }
                restoreSession(s)
                return
            }
        }
        savedNormalMode = playMode.value
        playMode.value = PlayMode.ListLoop
        val uid = AuthManager.currentUserValue?.id ?: run {
            fallback?.let { handleFailedSwitch(it) }
            return
        }
        scope.launch {
            // 循环拉取全部作品（分页直到 hasMore=false；上限保护）
            var list = emptyList<Track>().toMutableList()
            var page = 1
            while (page <= 20) {
                val r = try { Api.myTracks(page = page, pageSize = 50) } catch (_: Exception) { break }
                list += r.list
                if (!r.hasMore) break
                page += 1
            }
            if (listenMode.value != ListenMode.Works) return@launch
            var base = list
            if (base.isEmpty() && known.isNotEmpty()) base = known.toMutableList()
            if (base.isEmpty()) {
                fallback?.let { handleFailedSwitch(it) }
                return@launch
            }
            val session = ModeSession(queue = base, currentIndex = 0, wasPlaying = true, mode = ListenMode.Works)
            if (startAt != null) {
                val idx = base.indexOfFirst { it.id == startAt.id }
                if (idx >= 0) { play(startAt, base); return@launch }
            }
            sessions[ListenMode.Works] = session
            restoreSession(session)
        }
    }

    fun playLikedTrack(t: Track, known: List<Track>) {
        if (listenMode.value != ListenMode.Liked) saveSession(listenMode.value)
        listenMode.value = ListenMode.Liked
        switchToLiked(null, startAt = t, known = known)
    }

    fun playWorksTrack(t: Track, known: List<Track>) {
        if (listenMode.value != ListenMode.Works) saveSession(listenMode.value)
        listenMode.value = ListenMode.Works
        switchToWorks(null, startAt = t, known = known)
    }

    private fun switchToFresh(fallback: ListenMode?) {
        val s = sessions[ListenMode.Fresh]
        if (s != null && s.queue.isNotEmpty()) {
            restoreSession(s)
            return
        }
        savedNormalMode = playMode.value
        playMode.value = PlayMode.Shuffle
        val base = if (Library.tracks.value.isEmpty()) queue.value else Library.tracks.value
        if (base.isEmpty()) {
            fallback?.let { handleFailedSwitch(it) }
            return
        }
        val fresh = base.shuffled().toMutableList()
        current?.let { cur ->
            val idx = fresh.indexOfFirst { it.id == cur.id }
            if (idx >= 0) {
                fresh.removeAt(idx)
                fresh.add(0, cur)
            }
        }
        val session = ModeSession(queue = fresh, currentIndex = 0, wasPlaying = true, mode = ListenMode.Fresh)
        sessions[ListenMode.Fresh] = session
        restoreSession(session)
    }

    // ---------- 音效（系统均衡器近似） ----------

    fun applyEQ(name: String) {
        if (name == selectedEQ.value) return
        selectedEQ.value = name
        if (loadFailed.value) {
            reloadCurrent()
            return
        }
        applyEqMode(name)
    }

    private fun applyEqMode(name: String) {
        try {
            val eq = getEq() ?: return
            if (name == "原音") {
                eq.enabled = false
                return
            }
            eq.enabled = true
            val levels = eqLevels(name)
            val bands = eq.numberOfBands
            val range = eq.bandLevelRange  // [min, max] in millibel
            for (i in 0 until bands) {
                val idx = minOf(i, levels.size - 1)
                val target = levels[idx].toShort()
                try {
                    eq.setBandLevel(i.toShort(), target)
                } catch (_: Exception) { }
            }
        } catch (_: Exception) { }
    }

    private fun getEq(): Equalizer? {
        if (eq == null) {
            try {
                eq = Equalizer(0, exoPlayer.audioSessionId)
            } catch (_: Exception) { eq = null }
        }
        return eq
    }

    /** 各音效的频段增益（毫贝），映射系统均衡器 5 个 band：低频→高频 */
    private fun eqLevels(name: String): List<Int> = when (name) {
        "3D 立体音效" -> listOf(0, 200, 350, 400, 250)
        "360 环绕" -> listOf(100, 200, 250, 300, 200)
        "复古" -> listOf(-150, -250, -100, 50, 100)
        "现场" -> listOf(100, 150, 250, 400, 350)
        "流行" -> listOf(50, 200, 300, 250, 100)
        "摇滚" -> listOf(250, 150, -100, 150, 300)
        else -> listOf(0, 0, 0, 0, 0)
    }

    fun clearEq() {
        try { eq?.release(); eq = null } catch (_: Exception) { }
    }

    // ---------- 收听结算 ----------

    internal enum class ListenFlushReason { SwitchTrack, Pause, Complete, Heartbeat, Background }

    private fun flushListen(reason: ListenFlushReason) {
        if (listen.trackId.isEmpty()) return
        val delta = listen.seconds - listen.reported
        if (delta < 1) return
        val frac = if (duration.value > 0) clamp01(listen.seconds / duration.value) else 0.0
        val meta = BehaviorEvent.metaJSON(mapOf(
            "fraction" to (frac * 100).toInt() / 100.0,
            "plays" to listen.completedPlays,
            "seconds" to listen.seconds.toInt(),
        ))
        val ev = BehaviorEvent(trackId = listen.trackId, event = "listen", value = delta, meta = meta)
        scope.launch { Api.reportBehavior(listOf(ev)) }
        listen.reported = listen.seconds
        if (reason == ListenFlushReason.SwitchTrack && delta >= 5 && frac < 0.3) {
            val skipEv = BehaviorEvent(
                trackId = listen.trackId, event = "skip", value = 0.0,
                meta = BehaviorEvent.metaJSON(mapOf("fraction" to (frac * 100).toInt() / 100.0))
            )
            scope.launch { Api.reportBehavior(listOf(skipEv)) }
        }
    }

    /** 内存压力：清空图片/歌词/主色缓存 */
    fun onLowMemory() {
        CoverCache.map.clear()
        LyricsLinesCache.map.clear()
        ColorPalette.clear()
        Api.clearLyricCache()
    }

    private fun clamp01(v: Double): Double = if (v.isNaN()) 0.0 else v.coerceIn(0.0, 1.0)
}
