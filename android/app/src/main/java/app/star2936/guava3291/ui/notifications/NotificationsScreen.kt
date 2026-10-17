package app.star2936.guava3291.ui.notifications

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.star2936.guava3291.data.Api
import app.star2936.guava3291.data.Notification
import app.star2936.guava3291.data.OfficialMessage
import app.star2936.guava3291.ui.theme.*
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.TimeUnit

@Composable
fun NotificationsScreenCompat(onBack: () -> Unit, onOpenOfficial: () -> Unit) {
    val statusBarTop = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    var notifications by remember { mutableStateOf<List<Notification>>(emptyList()) }
    var officialMsg by remember { mutableStateOf<OfficialMessage?>(null) }
    var isLoading by remember { mutableStateOf(true) }
    var notifPage by remember { mutableIntStateOf(1) }
    var hasMore by remember { mutableStateOf(false) }
    var loadingMore by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    val currentUid = app.star2936.guava3291.state.AuthManager.currentUser.collectAsState().value?.id

    suspend fun loadAll() {
        isLoading = true
        // 并行加载官方消息 + 互动通知
        val offJob = scope.launch {
            officialMsg = runCatching { Api.officialMessages() }.getOrNull()?.firstOrNull()
        }
        val notifJob = scope.launch {
            runCatching { Api.notifications(page = 1, size = 30) }.getOrNull()?.let { r ->
                notifications = r.list.filter { it.type != "official" }
                notifPage = 1
                hasMore = r.hasMore
                app.star2936.guava3291.state.NotificationBus.setUnread(r.unread)
            }
            runCatching { Api.markNotificationsRead() }
            app.star2936.guava3291.state.NotificationBus.setUnread(0)
        }
        offJob.join(); notifJob.join()
        isLoading = false
    }

    suspend fun loadMore() {
        if (loadingMore || !hasMore) return
        loadingMore = true
        runCatching { Api.notifications(page = notifPage + 1, size = 30) }.getOrNull()?.let { r ->
            val fresh = r.list.filter { it.type != "official" && notifications.none { n -> n.id == it.id } }
            notifications = notifications + fresh
            notifPage++
            hasMore = r.hasMore
        }
        loadingMore = false
    }

    LaunchedEffect(currentUid) {
        notifications = emptyList(); officialMsg = null; isLoading = true
        loadAll()
    }

    // 实时监听 WS 推送：收到新通知重新加载整个列表（对标 iOS onReceive lastEvent → loadAll）
    val lastEvent by app.star2936.guava3291.state.NotificationBus.lastEvent.collectAsState()
    LaunchedEffect(lastEvent) {
        if (lastEvent != null && currentUid != null) loadAll()
    }

    Box(Modifier.fillMaxSize().background(Background)) {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(top = statusBarTop)
        ) {
            // Header
            Row(
                Modifier.padding(horizontal = 20.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    Modifier.size(38.dp).clip(CircleShape).background(Card).clickable { onBack() },
                    contentAlignment = Alignment.Center
                ) { Icon(Icons.Filled.ArrowBack, null, tint = TextPrimary, modifier = Modifier.size(18.dp)) }
                Spacer(Modifier.width(12.dp))
                Text("消息通知", color = TextPrimary, fontSize = 20.sp, fontWeight = FontWeight.Bold)
            }

            Spacer(Modifier.height(8.dp))

            // 官方通知分区（常驻显示）
            SectionHeader("官方通知")
            OfficialRow(msg = officialMsg, onClick = onOpenOfficial)
            Spacer(Modifier.height(18.dp))

            // 互动通知分区
            SectionHeader("互动通知")
            when {
                isLoading -> Box(Modifier.fillMaxWidth().padding(top = 60.dp), contentAlignment = Alignment.Center) {
                    Text("加载中…", color = TextTertiary, fontSize = 13.sp)
                }
                notifications.isEmpty() -> Box(Modifier.fillMaxWidth().padding(top = 60.dp), contentAlignment = Alignment.Center) {
                    Text("暂无互动通知\n有人赞你、评论你时会出现在这里", color = TextTertiary, fontSize = 13.sp, textAlign = TextAlign.Center)
                }
                else -> notifications.forEach { n -> InteractionRow(n, onBack = onBack) }
            }
            // 分页加载更多
            if (hasMore) {
                Box(
                    Modifier.fillMaxWidth().clickable(enabled = !loadingMore) {
                        scope.launch { loadMore() }
                    }.padding(vertical = 14.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        if (loadingMore) "加载中…" else "加载更多",
                        color = Accent, fontSize = 13.sp
                    )
                }
            }

            Spacer(Modifier.height(100.dp))
        }
    }
}

@Composable
private fun SectionHeader(title: String) {
    Text(title, color = TextTertiary, fontSize = 12.sp, fontWeight = FontWeight.Medium,
        modifier = Modifier.padding(start = 20.dp, top = 18.dp, bottom = 2.dp))
}

@Composable
private fun OfficialRow(msg: OfficialMessage?, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable { onClick() }.padding(horizontal = 20.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(Modifier.size(40.dp).clip(CircleShape).background(Card), contentAlignment = Alignment.Center) {
            androidx.compose.foundation.Image(
                painter = androidx.compose.ui.res.painterResource(app.star2936.guava3291.R.drawable.app_logo),
                null, modifier = Modifier.size(40.dp).clip(CircleShape), contentScale = ContentScale.Crop
            )
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("流萤音乐官方", color = TextPrimary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.width(6.dp))
                msg?.let { Text(timeString(it.created), color = TextTertiary, fontSize = 11.sp) }
            }
            Spacer(Modifier.height(4.dp))
            Text(msg?.content ?: "查看官方通知", color = TextSecondary, fontSize = 13.sp, maxLines = 1)
        }
        Text("›", color = TextTertiary.copy(alpha = 0.6f), fontSize = 14.sp)
    }
}

@Composable
private fun InteractionRow(n: Notification, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    var followed by remember { mutableStateOf(false) }
    Row(
        Modifier.fillMaxWidth()
            .clickable(enabled = n.type != "follow" && !n.trackId.isNullOrEmpty()) {
                // 点击跳转播放该歌曲；评论类自动打开评论弹窗并定位到对应评论
                scope.launch {
                    try {
                        val t = Api.track(n.trackId!!)
                        val isComment = n.type == "comment"
                        app.star2936.guava3291.state.AppRouter.jumpToHome(
                            play = t,
                            openComment = isComment,
                            commentId = if (isComment) n.commentId else null
                        )
                        onBack()
                    } catch (_: Exception) {}
                }
            }
            .padding(horizontal = 20.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // 头像：加载真实头像
        Box(
            Modifier.size(40.dp).clip(CircleShape).background(AccentSoft),
            contentAlignment = Alignment.Center
        ) {
            if (!n.fromUserId.isNullOrEmpty()) {
                coil.compose.AsyncImage(
                    model = app.star2936.guava3291.data.Api.avatarUrl(n.fromUserId),
                    contentDescription = null,
                    modifier = Modifier.size(40.dp).clip(CircleShape),
                    contentScale = ContentScale.Crop
                )
            } else {
                Icon(Icons.Filled.Person, null, tint = Accent, modifier = Modifier.size(18.dp))
            }
            if (n.unread) {
                Box(
                    Modifier.align(Alignment.TopEnd).size(7.dp).clip(CircleShape).background(Color(0xFFFF3B30))
                )
            }
        }
        Spacer(Modifier.width(12.dp))
        // 文字
        Column(Modifier.weight(1f)) {
            Text(n.fromUser ?: "有人", color = TextPrimary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(3.dp))
            Text(notificationText(n), color = TextSecondary, fontSize = 13.sp, maxLines = 2)
            Spacer(Modifier.height(2.dp))
            Text(timeString(n.created), color = TextTertiary, fontSize = 11.sp)
        }
        Spacer(Modifier.width(8.dp))
        // 右侧：follow 类型显示回关按钮（已互关则不显示），其他显示歌曲封面
        if (n.type == "follow") {
            if (!followed && !n.mutual) {
                Box(
                    Modifier.clip(RoundedCornerShape(20.dp)).background(Accent)
                        .clickable {
                            // 回关
                            n.fromUserId?.let { uid ->
                                scope.launch {
                                    runCatching { Api.toggleFollow(uid) }
                                    followed = true
                                }
                            }
                        }
                        .padding(horizontal = 16.dp, vertical = 7.dp)
                ) {
                    Text("回关", color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        } else if (!n.trackId.isNullOrEmpty()) {
            coil.compose.AsyncImage(
                model = app.star2936.guava3291.data.Api.coverUrl(n.trackId),
                contentDescription = null,
                modifier = Modifier.size(40.dp).clip(RoundedCornerShape(8.dp)),
                contentScale = ContentScale.Crop
            )
        } else {
            Box(
                Modifier.size(40.dp).clip(RoundedCornerShape(8.dp)).background(Card.copy(alpha = 0.7f)),
                contentAlignment = Alignment.Center
            ) { Icon(Icons.Filled.MusicNote, null, tint = TextTertiary, modifier = Modifier.size(16.dp)) }
        }
    }
    // 底部分隔线
    Box(Modifier.padding(start = 72.dp).fillMaxWidth().height(0.5.dp).background(CardBorder.copy(alpha = 0.6f)))
}

private fun notificationText(n: Notification): String {
    val trackName = n.trackTitle ?: "未知歌曲"
    return when (n.type) {
        "like" -> "赞了你的《$trackName》"
        "comment" -> "评论了你的《$trackName》"
        "share" -> "分享了你的《$trackName》"
        "follow" -> "回关了你"
        else -> n.content ?: ""
    }
}

private fun timeString(ts: Double): String {
    if (ts <= 0) return ""
    val now = System.currentTimeMillis() / 1000.0
    val diff = (now - ts).toLong()
    return when {
        diff < 60 -> "刚刚"
        diff < 3600 -> "${diff / 60}分钟前"
        diff < 86400 -> "${diff / 3600}小时前"
        diff < 86400 * 7 -> "${diff / 86400}天前"
        else -> SimpleDateFormat("MM-dd", Locale.getDefault()).format(Date(ts.toLong() * 1000))
    }
}
