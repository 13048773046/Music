package app.star2936.guava3291.ui.mine

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Pause
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.star2936.guava3291.data.Api
import app.star2936.guava3291.data.MyComment
import app.star2936.guava3291.data.Track
import app.star2936.guava3291.state.AppPreloader
import app.star2936.guava3291.state.AuthManager
import app.star2936.guava3291.state.NotificationBus
import app.star2936.guava3291.state.PlayerManager
import app.star2936.guava3291.ui.components.EqualizerBars
import app.star2936.guava3291.ui.components.CoverImage
import app.star2936.guava3291.ui.theme.Accent
import app.star2936.guava3291.ui.theme.Background
import app.star2936.guava3291.ui.theme.Card
import app.star2936.guava3291.ui.theme.Lilac
import app.star2936.guava3291.ui.theme.TextPrimary
import app.star2936.guava3291.ui.theme.TextSecondary
import app.star2936.guava3291.ui.theme.TextTertiary
import app.star2936.guava3291.util.dateString
import coil.compose.AsyncImage
import kotlinx.coroutines.launch

// 对应 iOS MineView.swift 1:1 复刻

class MinePager<T> {
    var items: List<T> = emptyList()
    var page: Int = 1
    var total: Int = 0
    var hasMore: Boolean = false
    var isLoading: Boolean = false
    var loadedOnce: Boolean = false
    var failed: Boolean = false
    val isEmpty: Boolean get() = loadedOnce && items.isEmpty()
}

private const val PAGE_SIZE = 20

@Composable
fun MineScreen(
    onOpenUpload: (android.net.Uri?) -> Unit,
    onOpenNotifications: () -> Unit,
    onOpenSettings: () -> Unit,
    onOpenHistory: () -> Unit = {},
    onOpenPlaylists: () -> Unit = {},
) {
    val user by AuthManager.currentUser.collectAsState()
    var works by remember { mutableStateOf(MinePager<Track>()) }
    var likes by remember { mutableStateOf(MinePager<Track>()) }
    var comments by remember { mutableStateOf(MinePager<MyComment>()) }
    var selectedTab by remember { mutableIntStateOf(0) }
    val unread by NotificationBus.unreadCount.collectAsState()
    val ctx = LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val listState = rememberLazyListState()
    var followerCount by remember { mutableIntStateOf(0) }
    var followingCount by remember { mutableIntStateOf(0) }
    var mutualCount by remember { mutableIntStateOf(0) }

    // 加载未读通知数
    val currentUid = user?.id
    LaunchedEffect(currentUid) {
        runCatching { app.star2936.guava3291.data.Api.notifications() }.getOrNull()?.let { r ->
            NotificationBus.setUnread(r.unread)
        }
    }

    // 实时监听 WS 数据事件：我的作品/资料变化时刷新
    val lastDataEvent by NotificationBus.lastDataEvent.collectAsState()
    var worksRefreshTrigger by remember { mutableIntStateOf(0) }
    LaunchedEffect(lastDataEvent) {
        val ev = lastDataEvent ?: return@LaunchedEffect
        when (ev.event) {
            "my_tracks" -> {
                worksRefreshTrigger++
            }
            "profile" -> {
                ev.user?.let { AuthManager.applyRemoteProfile(it) }
            }
        }
    }

    val filePicker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        uri?.let { onOpenUpload(it) }
    }

    suspend fun loadWorks(reset: Boolean) {
        val p = if (reset) MinePager<Track>().also { works = it } else works
        if (p.isLoading || (!reset && !p.hasMore && p.loadedOnce)) return
        p.isLoading = true
        try {
            val r = Api.myTracks(p.page, PAGE_SIZE)
            p.items = if (reset) r.list else (p.items + r.list)
            p.total = r.total; p.hasMore = r.hasMore; p.page += 1
            p.loadedOnce = true; p.failed = false
        } catch (_: Exception) { p.failed = true }
        p.isLoading = false
    }
    LaunchedEffect(worksRefreshTrigger) {
        if (worksRefreshTrigger > 0) loadWorks(true)
    }
    suspend fun loadLikes(reset: Boolean) {
        val p = if (reset) MinePager<Track>().also { likes = it } else likes
        if (p.isLoading || (!reset && !p.hasMore && p.loadedOnce)) return
        p.isLoading = true
        try {
            val r = Api.myLikes(p.page, PAGE_SIZE)
            p.items = if (reset) r.list else (p.items + r.list)
            p.total = r.total; p.hasMore = r.hasMore; p.page += 1
            p.loadedOnce = true; p.failed = false
        } catch (_: Exception) { p.failed = true }
        p.isLoading = false
    }
    suspend fun loadComments(reset: Boolean) {
        val p = if (reset) MinePager<MyComment>().also { comments = it } else comments
        if (p.isLoading || (!reset && !p.hasMore && p.loadedOnce)) return
        p.isLoading = true
        try {
            val r = Api.myComments(p.page, PAGE_SIZE)
            p.items = if (reset) r.list else (p.items + r.list)
            p.total = r.total; p.hasMore = r.hasMore; p.page += 1
            p.loadedOnce = true; p.failed = false
        } catch (_: Exception) { p.failed = true }
        p.isLoading = false
    }
    suspend fun loadStats() {
        try {
            val uid = user?.id ?: return
            val p = Api.fetchUserProfile(uid)
            followerCount = p.followerCount; followingCount = p.followingCount; mutualCount = p.mutualCount
        } catch (_: Exception) {}
    }

    LaunchedEffect(currentUid) {
        // 切换账号后重置数据
        works = MinePager(); likes = MinePager(); comments = MinePager()
        if (AppPreloader.mineLoaded.value) {
            works = preloadPager(AppPreloader.works.value, AppPreloader.worksTotal.value)
            likes = preloadPager(AppPreloader.likes.value, AppPreloader.likesTotal.value)
            comments = preloadPager(AppPreloader.comments.value, AppPreloader.commentsTotal.value)
        } else {
            scope.launch {
                kotlinx.coroutines.coroutineScope {
                    launch { loadWorks(true) }; launch { loadLikes(true) }; launch { loadComments(true) }
                }
            }
        }
        loadStats()
    }

    LaunchedEffect(user?.id) { loadStats() }

    LaunchedEffect(listState, selectedTab) {
        androidx.compose.runtime.snapshotFlow { listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: -1 }
            .collect { idx ->
                val total = listState.layoutInfo.totalItemsCount
                if (total > 0 && idx >= total - 4) {
                    when (selectedTab) {
                        0 -> if (works.hasMore && works.loadedOnce) scope.launch { loadWorks(false) }
                        1 -> if (likes.hasMore && likes.loadedOnce) scope.launch { loadLikes(false) }
                        2 -> if (comments.hasMore && comments.loadedOnce) scope.launch { loadComments(false) }
                    }
                }
            }
    }

    val statusBarTop = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()

    Box(Modifier.fillMaxSize().background(Background)) {
        LazyColumn(state = listState, modifier = Modifier.fillMaxSize()) {
            item(key = "header") {
                UserHeader(
                    user = user,
                    unreadCount = unread,
                    worksTotal = works.total,
                    followerCount = followerCount,
                    followingCount = followingCount,
                    mutualCount = mutualCount,
                    statusBarTop = statusBarTop,
                    onUpload = { filePicker.launch("audio/*") },
                    onNotifications = { onOpenNotifications() },
                    onSettings = onOpenSettings,
                )
            }
            item(key = "shortcuts") {
                QuickEntries(onOpenHistory = onOpenHistory, onOpenPlaylists = onOpenPlaylists)
            }
            item(key = "tabs") {
                TabIndicator(
                    worksTotal = works.total, likesTotal = likes.total, commentsTotal = comments.total,
                    selectedTab = selectedTab, onSelect = { selectedTab = it }
                )
            }
            when (selectedTab) {
                0 -> itemsIndexed(works.items, key = { _, t -> t.id }) { _, t ->
                    MineTrackRow(track = t) { PlayerManager.playWorksTrack(t, works.items) }
                }
                1 -> itemsIndexed(likes.items, key = { _, t -> t.id }) { _, t ->
                    MineTrackRow(track = t) { PlayerManager.playLikedTrack(t, likes.items) }
                }
                2 -> itemsIndexed(comments.items, key = { _, c -> c.trackId }) { _, c ->
                    CommentRow(c = c) { playComment(c) }
                }
            }
            when (selectedTab) {
                0 -> if (works.failed) item { Hint("加载失败") } else if (works.isEmpty) item { Hint("还没有上传歌曲") }
                1 -> if (likes.failed) item { Hint("加载失败") } else if (likes.isEmpty) item { Hint("还没有点赞过歌曲") }
                2 -> if (comments.failed) item { Hint("加载失败") } else if (comments.isEmpty) item { Hint("还没有发表过评论") }
            }
            when (selectedTab) {
                0 -> if (works.hasMore) item { MoreFooter() }
                1 -> if (likes.hasMore) item { MoreFooter() }
                2 -> if (comments.hasMore) item { MoreFooter() }
            }
            item(key = "bottom_space") { Spacer(Modifier.height(20.dp)) }
        }
    }
}

private fun <T> preloadPager(items: List<T>, total: Int): MinePager<T> {
    val p = MinePager<T>(); p.items = items; p.total = total; p.page = 2
    p.hasMore = total > items.size; p.loadedOnce = true; return p
}

private fun playComment(c: MyComment) {
    if (c.trackId.isEmpty()) return
    PlayerManager.playNotificationTrack(Track(id = c.trackId, title = c.title ?: "未知歌曲", artist = null))
}

@Composable
private fun UserHeader(
    user: app.star2936.guava3291.data.User?,
    unreadCount: Int,
    worksTotal: Int,
    followerCount: Int,
    followingCount: Int,
    mutualCount: Int,
    statusBarTop: androidx.compose.ui.unit.Dp,
    onUpload: () -> Unit,
    onNotifications: () -> Unit,
    onSettings: () -> Unit,
) {
    // 头部高 260dp + 状态栏
    Box(
        Modifier
            .fillMaxWidth()
            .height(260.dp + statusBarTop)
    ) {
        // 背景：有图用图，无图用 accent 渐变
        Box(Modifier.fillMaxSize()) {
            if (user?.backgroundURL != null) {
                AsyncImage(
                    model = user.backgroundURL, contentDescription = null,
                    modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop
                )
            } else {
                Box(
                    Modifier.fillMaxSize().background(
                        Brush.verticalGradient(listOf(Accent.copy(alpha = 0.25f), Accent.copy(alpha = 0.05f)))
                    )
                )
            }
        }
        // 底部渐变遮罩：从透明到 Background，自然融合
        Box(
            Modifier
                .fillMaxWidth()
                .height(140.dp)
                .align(Alignment.BottomCenter)
                .background(Brush.verticalGradient(listOf(Color.Transparent, Background)))
        )
        // 右上角按钮行
        Row(
            Modifier
                .align(Alignment.TopEnd)
                .padding(top = statusBarTop + 8.dp, end = 20.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            TopCircleButton(Icons.Filled.Add, onUpload)
            TopCircleButton(Icons.Filled.Notifications, onNotifications, unreadCount)
            TopCircleButton(Icons.Outlined.Settings, onSettings)
        }
        // 底部：头像 + 信息 + 统计
        Column(
            Modifier
                .align(Alignment.BottomStart)
                .padding(horizontal = 20.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                // 头像 72dp 圆形白边
                Box(
                    Modifier
                        .size(72.dp)
                        .clip(CircleShape)
                        .background(Accent.copy(alpha = 0.2f)),
                    contentAlignment = Alignment.Center
                ) {
                    if (user?.avatarURL != null) {
                        AsyncImage(model = user.avatarURL, contentDescription = "头像",
                            modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                    } else {
                        Icon(Icons.Filled.Person, contentDescription = null, tint = Accent, modifier = Modifier.size(28.dp))
                    }
                }
                Spacer(Modifier.width(16.dp))
                Column {
                    Text(user?.name ?: "未登录", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold, maxLines = 1)
                    Spacer(Modifier.height(6.dp))
                    if (!user?.account.isNullOrEmpty()) {
                        Text(
                            "ID ${user!!.account}",
                            color = Color.White.copy(alpha = 0.8f), fontSize = 11.sp, fontWeight = FontWeight.Medium,
                            modifier = Modifier
                                .clip(RoundedCornerShape(percent = 50))
                                .background(Color.White.copy(alpha = 0.15f))
                                .padding(horizontal = 8.dp, vertical = 3.dp)
                        )
                    }
                    Spacer(Modifier.height(6.dp))
                    if (!user?.signature.isNullOrEmpty()) {
                        Text(user!!.signature!!, color = Color.White.copy(alpha = 0.6f), fontSize = 12.sp, maxLines = 1)
                    }
                }
            }
            Spacer(Modifier.height(16.dp))
            // 统计数据行：作品|粉丝|关注|互关
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceAround
            ) {
                StatItem("$worksTotal", "作品")
                StatDivider()
                StatItem("$followerCount", "粉丝")
                StatDivider()
                StatItem("$followingCount", "关注")
                StatDivider()
                StatItem("$mutualCount", "互关")
            }
        }
    }
}

@Composable
private fun StatItem(value: String, label: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value, color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(4.dp))
        Text(label, color = Color.White.copy(alpha = 0.5f), fontSize = 11.sp)
    }
}

@Composable
private fun StatDivider() {
    Box(Modifier.width(1.dp).height(20.dp).background(Color.White.copy(alpha = 0.15f)))
}

@Composable
private fun TopCircleButton(icon: androidx.compose.ui.graphics.vector.ImageVector, onClick: () -> Unit, badge: Int = 0) {
    Box(
        Modifier
            .size(38.dp)
            .clip(CircleShape)
            .background(Color.White.copy(alpha = 0.12f))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
        if (badge > 0) {
            Box(
                Modifier
                    .align(Alignment.TopEnd)
                    .offset(x = 8.dp, y = (-8).dp)
                    .size(16.dp).clip(CircleShape).background(Color.Red),
                contentAlignment = Alignment.Center
            ) {
                Text(if (badge > 99) "99+" else "$badge", color = Color.White, fontSize = 9.sp, fontWeight = FontWeight.Bold)
            }
        }
    }
}

@Composable
private fun QuickEntries(onOpenHistory: () -> Unit, onOpenPlaylists: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        QuickCard("播放历史", "最近听过的歌", Accent, Icons.Filled.Notifications, Modifier.weight(1f), onOpenHistory)
        QuickCard("我的歌单", "收藏喜欢的歌曲", Color(0xFFB388FF), Icons.Filled.MusicNote, Modifier.weight(1f), onOpenPlaylists)
    }
}

@Composable
private fun QuickCard(title: String, subtitle: String, color: Color, icon: androidx.compose.ui.graphics.vector.ImageVector, modifier: Modifier, onClick: () -> Unit) {
    Row(
        modifier
            .clip(RoundedCornerShape(14.dp))
            .background(Card)
            .clickable(onClick = onClick)
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            Modifier.size(40.dp).clip(RoundedCornerShape(10.dp)).background(color.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center
        ) {
            Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(17.dp))
        }
        Spacer(Modifier.width(12.dp))
        Column {
            Text(title, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(3.dp))
            Text(subtitle, color = Color.White.copy(alpha = 0.4f), fontSize = 11.sp)
        }
    }
}

@Composable
private fun TabIndicator(worksTotal: Int, likesTotal: Int, commentsTotal: Int, selectedTab: Int, onSelect: (Int) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 8.dp, bottom = 4.dp)) {
        TabItem("作品", worksTotal, selectedTab == 0, Modifier.weight(1f)) { onSelect(0) }
        TabItem("点赞", likesTotal, selectedTab == 1, Modifier.weight(1f)) { onSelect(1) }
        TabItem("评论", commentsTotal, selectedTab == 2, Modifier.weight(1f)) { onSelect(2) }
    }
}

@Composable
private fun TabItem(title: String, count: Int, selected: Boolean, modifier: Modifier, onClick: () -> Unit) {
    Column(
        modifier.clickable(onClick = onClick).padding(vertical = 6.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(title, color = if (selected) Color.White else Color.White.copy(alpha = 0.5f),
                fontSize = 14.sp, fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium)
            Spacer(Modifier.width(4.dp))
            Text("$count", color = if (selected) Accent else Color.White.copy(alpha = 0.3f),
                fontSize = 11.sp, fontWeight = FontWeight.Bold)
        }
        Spacer(Modifier.height(6.dp))
        Box(
            Modifier.width(24.dp).height(3.dp)
                .clip(RoundedCornerShape(percent = 50))
                .background(if (selected) Accent else Color.Transparent)
        )
    }
}

@Composable
private fun MineTrackRow(track: Track, onClick: () -> Unit) {
    val playingThis = PlayerManager.current?.id == track.id
    val isPlaying by PlayerManager.isPlaying.collectAsState()
    Row(
        Modifier
            .padding(horizontal = 16.dp).padding(vertical = 5.dp)
            .clip(RoundedCornerShape(14.dp)).background(Card)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        CoverImage(track = track, modifier = Modifier.size(44.dp), cornerRadius = 9.dp)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(track.title, color = TextPrimary, fontSize = 14.sp, fontWeight = FontWeight.Medium, maxLines = 1)
            Text(track.displayAuthor, color = TextSecondary, fontSize = 12.sp, maxLines = 1)
        }
        if (playingThis) {
            if (isPlaying) EqualizerBars(barColor = Accent, modifier = Modifier)
            else Icon(Icons.Outlined.Pause, null, tint = Accent, modifier = Modifier.size(10.dp))
        }
        if (!track.durText.isNullOrEmpty()) Text(track.durText, color = TextTertiary, fontSize = 11.sp)
    }
}

@Composable
private fun CommentRow(c: MyComment, onClick: () -> Unit) {
    Column(
        Modifier
            .padding(horizontal = 16.dp).padding(vertical = 5.dp)
            .clip(RoundedCornerShape(14.dp)).background(Card)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.MusicNote, null, tint = Lilac, modifier = Modifier.size(11.dp))
            Spacer(Modifier.width(8.dp))
            Text(c.title ?: "未知歌曲", color = TextPrimary, fontSize = 14.sp, fontWeight = FontWeight.Medium, maxLines = 1, modifier = Modifier.weight(1f))
            if ((c.created ?: 0.0) > 0) Text(dateString(c.created!!), color = TextTertiary, fontSize = 11.sp)
        }
        Spacer(Modifier.height(5.dp))
        Text("「${c.content}」", color = TextSecondary, fontSize = 13.sp, maxLines = 2)
    }
}

@Composable
private fun Hint(text: String) {
    Text(text, color = TextTertiary, fontSize = 13.sp,
        modifier = Modifier.fillMaxWidth().padding(vertical = 48.dp),
        textAlign = androidx.compose.ui.text.style.TextAlign.Center)
}

@Composable
private fun MoreFooter() {
    Box(Modifier.fillMaxWidth().padding(vertical = 14.dp), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(color = Accent, strokeWidth = 2.dp, modifier = Modifier.size(20.dp))
    }
}
