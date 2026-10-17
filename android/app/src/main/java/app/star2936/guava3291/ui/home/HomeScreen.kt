package app.star2936.guava3291.ui.home

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.pager.VerticalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.star2936.guava3291.R
import app.star2936.guava3291.data.Api
import app.star2936.guava3291.data.BehaviorEvent
import app.star2936.guava3291.data.Track
import app.star2936.guava3291.state.AuthManager
import app.star2936.guava3291.state.LyricsLinesCache
import app.star2936.guava3291.state.NetworkMonitor
import app.star2936.guava3291.state.PlayerManager
import app.star2936.guava3291.state.AppRouter
import app.star2936.guava3291.ui.components.CoverImage
import app.star2936.guava3291.ui.components.MarqueeText
import app.star2936.guava3291.ui.theme.Accent
import app.star2936.guava3291.ui.theme.Card
import app.star2936.guava3291.ui.theme.TextPrimary
import app.star2936.guava3291.ui.theme.TextSecondary
import app.star2936.guava3291.ui.theme.TextTertiary
import app.star2936.guava3291.ui.theme.darkened
import app.star2936.guava3291.util.KRCLine
import app.star2936.guava3291.util.parseLyrics
import app.star2936.guava3291.util.formatTime
import kotlin.math.min
import kotlinx.coroutines.launch

// 对应 iOS VerticalPager.swift + LyricView.swift：播放页竖滑切歌 + 歌词渲染

@Composable
fun HomeScreen() {
    val queue by PlayerManager.queue.collectAsState()
    val currentIndex by PlayerManager.currentIndex.collectAsState()

    val initial = if (currentIndex in queue.indices) currentIndex else 0
    val pagerState = rememberPagerState(initialPage = initial) { queue.size }

    // 用户翻页完成 → 切歌（对标 iOS didFinishAnimating：滑动结束稳定后才回调）
    LaunchedEffect(pagerState.settledPage, queue.size) {
        if (pagerState.isScrollInProgress) return@LaunchedEffect
        if (pagerState.settledPage != currentIndex) {
            val t = queue.getOrNull(pagerState.settledPage)
            if (t != null) PlayerManager.play(t, queue)
        }
    }
    // 滑到倒数第 2 页时预加载下一批歌曲
    LaunchedEffect(pagerState.settledPage, queue.size) {
        if (pagerState.settledPage >= queue.size - 2 && queue.isNotEmpty()) {
            PlayerManager.preloadNextBatch()
        }
    }
    // 自动切歌（播完/通知栏切歌）→ Pager 平滑跟随翻页
    // 对标 iOS updateUIViewController：用户手势翻页期间禁止程序化回跳
    // 用户滑动切歌时 settledPage 已等于 currentIndex，不会触发这里翻页
    LaunchedEffect(currentIndex, queue.size) {
        if (pagerState.isScrollInProgress) return@LaunchedEffect
        if (currentIndex in queue.indices
            && currentIndex != pagerState.settledPage
            && currentIndex != pagerState.currentPage
        ) {
            pagerState.animateScrollToPage(currentIndex)
        }
    }

    VerticalPager(
        state = pagerState,
        modifier = Modifier.fillMaxSize(),
        key = { page -> queue.getOrNull(page)?.id ?: page },
    ) { page ->
        val track = queue.getOrNull(page)
        if (track != null) {
            key(track.id) {
                PlayerCard(track = track, active = page == currentIndex)
            }
        }
    }
}

/** 单曲播放卡片：封面 + 歌名 + 歌词预览 + 互动行 + 进度条（严格对齐 iOS VerticalPager 布局） */
@Composable
fun PlayerCard(track: Track, active: Boolean) {
    // 每个卡片独立提取自己的封面主色
    var cardDominant by remember(track.id) { mutableStateOf<androidx.compose.ui.graphics.Color?>(null) }
    LaunchedEffect(track.id) {
        val url = track.coverURL ?: return@LaunchedEffect
        val cached = app.star2936.guava3291.util.ColorPalette.colorFor(track.id, url)
        if (cached != null) {
            cardDominant = cached
        } else {
            app.star2936.guava3291.util.ColorPalette.load(track.id, url)?.let {
                cardDominant = it
            }
        }
    }
    if (active) {
        cardDominant?.let { PlayerManager.playerCardDominant.value = it }
    }
    val isPlaying by PlayerManager.isPlaying.collectAsState()
    val isBuffering by PlayerManager.isBuffering.collectAsState()
    val loadFailed by PlayerManager.loadFailed.collectAsState()
    val selectedEQ by PlayerManager.selectedEQ.collectAsState()
    val lyricsState = rememberLyrics(track.id)
    val lyrics = lyricsState.lines
    val progress = rememberProgressState()
    var showTrackMenu by remember { mutableStateOf(false) }
    var showEQPanel by remember { mutableStateOf(false) }
    var showAddToPlaylist by remember { mutableStateOf(false) }
    var showFullLyrics by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    // 背景：每个卡片独立主色×0.35（亮一点），平滑过渡
    val targetBg = cardDominant?.let { darkened(it, 0.35f) } ?: Color(0xFF1C1C1F)
    val bgColor by androidx.compose.animation.animateColorAsState(
        targetValue = targetBg,
        animationSpec = androidx.compose.animation.core.tween(durationMillis = 600),
        label = "bgColor"
    )

    // 沉浸式：动态获取系统状态栏/导航栏高度
    val statusBarTop = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val navBarBottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    // 顶部：状态栏 + APP TopBar(56dp) + 间距6dp
    val topPadding = statusBarTop + 56.dp + 6.dp
    // 底部：系统导航栏 + TabBar 高度（TabBar 现在浮在内容上面）
    val bottomPadding = navBarBottom + 64.dp

    BoxWithConstraints(
        Modifier
            .fillMaxSize()
            .background(bgColor)   // 背景延伸到状态栏和导航栏后面
    ) {
        // 封面大小 = 屏宽-28dp，不超过可用高度减顶部/底部预留
        val screenW = androidx.compose.ui.platform.LocalConfiguration.current.screenWidthDp.dp
        val screenH = androidx.compose.ui.platform.LocalConfiguration.current.screenHeightDp.dp
        // 尺寸缩放因子：以 800dp 屏高为基准，小屏紧凑、大屏舒展
        val s = (screenH.value / 800f).coerceIn(0.85f, 1.15f)
        fun Float.dpS() = (this * s).dp
        fun Int.dpS() = (this * s).dp
        fun Float.spS() = (this * s).sp

        val bottomReserved = 260.dpS() + bottomPadding
        val coverSize = minOf(screenW - 28.dp, maxHeight - bottomReserved - topPadding - 16.dp)

        // 封面：居中在上半部分
        Box(
            Modifier
                .fillMaxWidth()
                .align(Alignment.TopCenter)
                .padding(top = topPadding + 16.dp),
            contentAlignment = Alignment.TopCenter
        ) {
            Box(
                Modifier
                    .size(coverSize)
                    .clip(RoundedCornerShape(20.dp))
                    .pointerInput(track.id) {
                        detectTapGestures { PlayerManager.toggle() }
                    }
            ) {
                CoverImage(track = track, modifier = Modifier.fillMaxSize(), cornerRadius = 20.dp)
            }
        }

        // 底部区：歌名/歌词/互动/进度条，紧贴 AppTabBar 上方
        Column(
            Modifier
                .fillMaxWidth()
                .align(Alignment.BottomCenter)
                .padding(horizontal = 14.dp)
                .padding(bottom = bottomPadding),
            horizontalAlignment = Alignment.Start
        ) {
            // 歌名行
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(Modifier.weight(1f)) {
                    MarqueeText(
                        text = track.title,
                        style = androidx.compose.ui.text.TextStyle(
                            color = TextPrimary, fontSize = 24f.spS(), fontWeight = FontWeight.Bold
                        )
                    )
                    Spacer(Modifier.height(4.dpS()))
                    Text(
                        track.displayAuthor,
                        color = TextSecondary, fontSize = 15f.spS(), maxLines = 1
                    )
                }
            }

            Spacer(Modifier.height(12.dpS()))

            // 歌词预览（clip 裁掉第三句，让它被互动行挡住）
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(56.dpS())
                    .clip(RoundedCornerShape(0.dp))
                    .clickable { if (lyrics.isNotEmpty()) showFullLyrics = true }
            ) {
                if (loadFailed) {
                    LoadFailedView(track = track)
                } else if (lyrics.isEmpty()) {
                    NoLyricPlaceholder(artist = track.displayAuthor)
                } else {
                    LiveLyricPreview(
                        lines = lyrics,
                        progressSec = progress,
                    )
                }
            }

            // 遮罩：挡住第三句歌词（与背景同色，不裁剪滚动）
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(14.dpS())
                    .background(bgColor)
            )

            Spacer(Modifier.height(12.dpS()))

            // 互动行 + 三点菜单
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                InteractionRow(track = track, modifier = Modifier.weight(1f))
                Box(
                    Modifier
                        .size(34.dpS())
                        .clip(RoundedCornerShape(10.dpS()))
                        .clickable { showTrackMenu = true },
                    contentAlignment = Alignment.Center
                ) {
                    Text("⋮", color = TextPrimary, fontSize = 20f.spS(), fontWeight = FontWeight.Bold)
                }
            }

            Spacer(Modifier.height(10.dpS()))

            // 进度条
            PlayerProgressBar()
        }
    }

    // 三点菜单弹窗
    if (showTrackMenu) {
        TrackMenuSheet(
            track = track,
            eqName = selectedEQ,
            onDismiss = { showTrackMenu = false },
            onEQ = { showEQPanel = true },
            onFullScreen = { showFullLyrics = true },
            onAddToPlaylist = { showAddToPlaylist = true },
        )
    }

    // 添加到歌单
    if (showAddToPlaylist) {
        AddToPlaylistSheet(track = track, onDismiss = { showAddToPlaylist = false })
    }

    // EQ 音效面板
    if (showEQPanel) {
        EQPanel(current = selectedEQ, onSelect = { name ->
            PlayerManager.applyEQ(name)
            showEQPanel = false
        }, onDismiss = { showEQPanel = false })
    }

    // 全屏歌词
    if (showFullLyrics) {
        androidx.compose.ui.window.Dialog(
            onDismissRequest = { showFullLyrics = false },
            properties = androidx.compose.ui.window.DialogProperties(
                usePlatformDefaultWidth = false,
                dismissOnBackPress = true,
            )
        ) {
            FullScreenLyricScreen(
                track = track,
                lines = lyrics,
                onDismiss = { showFullLyrics = false },
            )
        }
    }
}

// 状态桥接：播放页常用状态的 remember 包装
@Composable
private fun rememberProgressState(): Double {
    val progress by PlayerManager.progress.collectAsState()
    val duration by PlayerManager.duration.collectAsState()
    return progress * duration
}

// 歌词加载（内存缓存）
@Composable
private fun rememberLyrics(trackId: String): LyricsState {
    var lines by remember(trackId) { mutableStateOf(LyricsLinesCache.map[trackId] ?: emptyList()) }
    LaunchedEffect(trackId) {
        val cached = LyricsLinesCache.map[trackId]
        if (cached != null) { lines = cached; return@LaunchedEffect }
        try {
            val text = Api.fetchLyric(trackId)
            val parsed = parseLyrics(text)
            if (parsed.isNotEmpty()) {
                LyricsLinesCache.map[trackId] = parsed
                lines = parsed
            }
        } catch (_: Exception) { }
    }
    return LyricsState(lines)
}

data class LyricsState(val lines: List<KRCLine>)

// 加载失败重试（对应 iOS 失败重试胶囊；断网时文案区分「网络未连接」）
@Composable
private fun LoadFailedView(track: Track) {
    val offline by NetworkMonitor.isOffline.collectAsState()
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(if (offline) "网络未连接" else "加载失败", color = TextSecondary, fontSize = 14.sp)
        if (offline) {
            Spacer(Modifier.height(4.dp))
            Text("网络恢复后自动续播", color = TextTertiary, fontSize = 12.sp)
        }
        Spacer(Modifier.height(10.dp))
        Box(
            Modifier
                .clip(RoundedCornerShape(16.dp))
                .background(Card)
                .clickable { PlayerManager.reloadCurrent() }
                .padding(horizontal = 18.dp, vertical = 8.dp)
        ) {
            Text("重试", color = TextPrimary, fontSize = 14.sp, fontWeight = FontWeight.Medium)
        }
    }
}

// 进度条（对应 iOS PlayerProgressBar）
@Composable
private fun PlayerProgressBar() {
    val progress by PlayerManager.progress.collectAsState()
    val bufferProgress by PlayerManager.bufferProgress.collectAsState()
    val isBuffering by PlayerManager.isBuffering.collectAsState()
    val duration by PlayerManager.duration.collectAsState()
    val currentTime by PlayerManager.currentTime.collectAsState()
    val isPlaying by PlayerManager.isPlaying.collectAsState()

    var scrubFraction by remember { mutableStateOf<Float?>(null) }
    val shown = (scrubFraction ?: progress.toFloat()).coerceIn(0f, 1f)

    Column(Modifier.fillMaxWidth()) {
        Box(
            Modifier.fillMaxWidth().height(26.dp)
        ) {
            var widthPx by remember { mutableStateOf(0) }
            Box(Modifier.fillMaxSize().onSizeChanged { widthPx = it.width })

            // 总轨道
            Box(
                Modifier.fillMaxWidth().height(3.dp).align(Alignment.CenterStart)
                    .clip(RoundedCornerShape(2.dp))
                    .background(Color.White.copy(alpha = 0.18f))
            )
            // 缓冲段
            Box(
                Modifier.fillMaxWidth(bufferProgress.toFloat().coerceIn(0f, 1f)).height(3.dp).align(Alignment.CenterStart)
                    .clip(RoundedCornerShape(2.dp))
                    .background(Color.White.copy(alpha = 0.38f))
            )
            // 已播段
            Box(
                Modifier.fillMaxWidth(shown).height(3.dp).align(Alignment.CenterStart)
                    .clip(RoundedCornerShape(2.dp))
                    .background(Color.White)
            )
            // 拖头
            val density = androidx.compose.ui.platform.LocalDensity.current
            val thumbPx = with(density) { 10.dp.roundToPx() }
            Box(
                Modifier.size(10.dp).align(Alignment.CenterStart)
                    .offset {
                        val x = (shown * (widthPx - thumbPx)).toInt().coerceIn(0, maxOf(0, widthPx - thumbPx))
                        androidx.compose.ui.unit.IntOffset(x, 0)
                    }
                    .clip(androidx.compose.foundation.shape.CircleShape)
                    .background(Color.White)
            )
            // 手势
            Box(
                Modifier.fillMaxSize()
                    .pointerInput(Unit) {
                        detectHorizontalDragGestures(
                            onDragStart = { offset ->
                                if (widthPx > 0) scrubFraction = (offset.x / widthPx.toFloat()).coerceIn(0f, 1f)
                            },
                            onDragEnd = {
                                scrubFraction?.let { PlayerManager.seekToFraction(it.toDouble()) }
                                scrubFraction = null
                            },
                            onDragCancel = { scrubFraction = null },
                            onHorizontalDrag = { change, _ ->
                                change.consume()
                                if (widthPx > 0) scrubFraction = (change.position.x / widthPx.toFloat()).coerceIn(0f, 1f)
                            }
                        )
                    }
            )
        }
        // 时间行
        Row(Modifier.fillMaxWidth().padding(top = 2.dp), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(
                if (isBuffering) "缓冲中…"
                else if (scrubFraction != null) formatTime(duration * scrubFraction!!)
                else formatTime(currentTime),
                color = TextTertiary, fontSize = 12.sp, fontFamily = FontFamily.Monospace
            )
            Text(formatTime(duration), color = TextTertiary, fontSize = 12.sp, fontFamily = FontFamily.Monospace)
        }
    }
}

// 互动行：点赞 / 评论 / 分享
@Composable
private fun InteractionRow(track: Track, modifier: Modifier = Modifier) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var liked by remember(track.id) { mutableStateOf(track.isLiked == true) }
    var likeCount by remember(track.id) { mutableStateOf(track.likeCount ?: 0) }
    var shareCount by remember(track.id) { mutableStateOf(track.shareCount ?: 0) }

    fun openComments() {
        scope.launch {
            Api.reportBehavior(listOf(BehaviorEvent(trackId = track.id, event = "comment_open")))
        }
        AppRouter.pendingCommentTrack.value = track
        AppRouter.showCommentSheet.value = true
    }

    fun share() {
        scope.launch {
            val link = Api.shareLink(track.id)
            val text = "推荐一首歌《${track.title}》- ${track.displayAuthor}" + (link?.let { "\n$it" } ?: "")
            val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(android.content.Intent.EXTRA_TEXT, text)
            }
            runCatching {
                ctx.startActivity(android.content.Intent.createChooser(intent, "分享歌曲"))
            }
            Api.reportBehavior(listOf(BehaviorEvent(trackId = track.id, event = "share")))
            val count = Api.reportShare(track.id)
            if (count > 0) shareCount = count
        }
    }

    Row(
        modifier,
        horizontalArrangement = Arrangement.spacedBy(30.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // 点赞
        Box {
            Icon(
                painter = androidx.compose.ui.res.painterResource(R.drawable.ic_heart_fill),
                contentDescription = "点赞",
                tint = if (liked) Color(0xFFFF3B30) else TextPrimary,
                modifier = Modifier
                    .size(26.dp)
                    .clickable {
                        val uid = AuthManager.currentUserValue?.id ?: return@clickable
                        val wasLiked = liked
                        liked = !liked
                        likeCount = (likeCount + (if (liked) 1 else -1)).coerceAtLeast(0)
                        scope.launch {
                            try {
                                val (newLiked, newCount) = Api.toggleLike(track.id, uid)
                                liked = newLiked
                                likeCount = newCount
                                Api.reportBehavior(listOf(BehaviorEvent(trackId = track.id, event = "like")))
                            } catch (_: Exception) {
                                liked = wasLiked
                            }
                        }
                    }
            )
            if (likeCount > 0) {
                Text(
                    if (likeCount > 99) "99+" else "$likeCount",
                    color = TextPrimary,
                    fontSize = 10.sp,
                    modifier = Modifier.align(Alignment.TopEnd).offset(x = 8.dp, y = (-4).dp)
                )
            }
        }
        // 评论
        Box {
            Icon(
                painter = androidx.compose.ui.res.painterResource(R.drawable.ic_bubble_right_fill),
                contentDescription = "评论",
                tint = TextPrimary,
                modifier = Modifier
                    .size(26.dp)
                    .clickable { openComments() }
            )
            if ((track.commentCount ?: 0) > 0) {
                Text(
                    if (track.commentCount!! > 99) "99+" else "${track.commentCount}",
                    color = TextPrimary,
                    fontSize = 10.sp,
                    modifier = Modifier.align(Alignment.TopEnd).offset(x = 8.dp, y = (-4).dp)
                )
            }
        }
        // 分享
        Box {
            Icon(
                painter = androidx.compose.ui.res.painterResource(R.drawable.ic_turn_up_forward_fill),
                contentDescription = "分享",
                tint = TextPrimary,
                modifier = Modifier
                    .size(26.dp)
                    .clickable { share() }
            )
            if (shareCount > 0) {
                Text(
                    if (shareCount > 99) "99+" else "$shareCount",
                    color = TextPrimary,
                    fontSize = 10.sp,
                    modifier = Modifier.align(Alignment.TopEnd).offset(x = 8.dp, y = (-4).dp)
                )
            }
        }
    }
}

// EQ 面板（对应 iOS 音效选择面板）
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun EQPanel(current: String, onSelect: (String) -> Unit, onDismiss: () -> Unit) {
    val eqNames = listOf("原音", "3D 立体音效", "360 环绕", "复古", "现场", "流行", "摇滚")
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF1C1C1E),
    ) {
        Column(Modifier.padding(20.dp)) {
            Text("音效", color = TextPrimary, fontSize = 18.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(14.dp))
            eqNames.forEach { name ->
                val selected = name == current
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(if (selected) Accent.copy(alpha = 0.14f) else Color.Transparent)
                        .clickable { onSelect(name) }
                        .padding(horizontal = 14.dp, vertical = 13.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(name, color = if (selected) Accent else TextPrimary, fontSize = 15.sp,
                        fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal)
                    Spacer(Modifier.weight(1f))
                    if (selected) {
                        Text("✓", color = Accent, fontSize = 14.sp, fontWeight = FontWeight.Bold)
                    }
                }
            }
            Spacer(Modifier.height(20.dp))
        }
    }
}
