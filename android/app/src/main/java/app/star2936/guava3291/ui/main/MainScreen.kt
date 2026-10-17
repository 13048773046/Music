package app.star2936.guava3291.ui.main

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.outlined.Pause
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import app.star2936.guava3291.ui.login.LoginScreen
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import app.star2936.guava3291.state.AppRouter
import app.star2936.guava3291.ui.sidebar.SidebarContent
import app.star2936.guava3291.ui.home.HomeScreen
import app.star2936.guava3291.ui.discover.DiscoverScreen
import app.star2936.guava3291.ui.search.SearchScreen
import app.star2936.guava3291.ui.mine.MineScreen
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import app.star2936.guava3291.data.Announcement
import app.star2936.guava3291.data.Api
import app.star2936.guava3291.data.UpdateCheck
import app.star2936.guava3291.state.AppPreloader
import app.star2936.guava3291.state.AuthManager
import app.star2936.guava3291.state.Library
import app.star2936.guava3291.state.NotificationBus
import app.star2936.guava3291.state.PlayerManager
import app.star2936.guava3291.ui.components.AlbumArtPlaceholder
import app.star2936.guava3291.ui.components.CoverImage
import app.star2936.guava3291.ui.components.EqualizerBars
import app.star2936.guava3291.ui.discover.DiscoverScreen
import app.star2936.guava3291.ui.home.HomeScreen
import app.star2936.guava3291.ui.mine.MineScreen
import app.star2936.guava3291.ui.theme.Accent
import app.star2936.guava3291.ui.theme.Background
import app.star2936.guava3291.ui.theme.Card
import app.star2936.guava3291.ui.theme.CardBorder
import app.star2936.guava3291.ui.theme.TextSecondary
import app.star2936.guava3291.ui.theme.darkened

// 对应 iOS MusicApp.swift MainTabView：三页常驻 + 顶部栏 + 悬浮 TabBar + 侧边栏抽屉

/** 全屏子页面（对应 fullScreenCover / push） */
sealed class SubPage {
    object Search : SubPage()
    object Notifications : SubPage()
    object OfficialMessages : SubPage()
    object Settings : SubPage()
    object ProfileEdit : SubPage()
    object ChangePassword : SubPage()
    object About : SubPage()
    object Upload : SubPage()
    object History : SubPage()
    object Playlists : SubPage()
    object Login : SubPage()
    data class PlaylistDetail(val playlistId: String, val playlistName: String) : SubPage()
    data class UserProfile(val userId: String) : SubPage()
}

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun MainScreen() {
    // 抽屉进度带平滑动画
    var drawerTarget by remember { mutableStateOf(0f) }
    val drawerProgress by androidx.compose.animation.core.animateFloatAsState(
        targetValue = drawerTarget,
        animationSpec = androidx.compose.animation.core.tween(durationMillis = 300, easing = androidx.compose.animation.core.FastOutSlowInEasing),
        label = "drawer"
    )
    var subPageStack by remember { mutableStateOf<List<SubPage>>(emptyList()) }
    val subPage = subPageStack.lastOrNull()
    fun pushPage(p: SubPage) { subPageStack = subPageStack + p }
    fun popPage() { subPageStack = subPageStack.dropLast(1) }
    var announcement by remember { mutableStateOf<Announcement?>(null) }
    var updateNotice by remember { mutableStateOf<UpdateCheck?>(null) }
    var uploadUri by remember { mutableStateOf<android.net.Uri?>(null) }

    val selectedTab by AppRouter.selectedTab.collectAsState()
    // 评论弹窗（通知点击定位）
    val showCommentSheet by AppRouter.showCommentSheet.collectAsState()
    val pendingCommentTrack by AppRouter.pendingCommentTrack.collectAsState()
    val highlightCommentId by AppRouter.highlightCommentId.collectAsState()

    // 启动拉取公告/更新（与 iOS fetchAnnouncement/fetchUpdate 一致）
    val ctx = LocalContext.current
    LaunchedEffect(Unit) {
        try {
            val ann = Api.fetchAnnouncement()
            if (ann != null && ann.title.isNotEmpty() && ann.id.isNotEmpty()) {
                val shown = ctx.getSharedPreferences("announcement", android.content.Context.MODE_PRIVATE)
                    .getString("shown_id", null)
                if (ann.showOnce != 1 || shown != ann.id) announcement = ann
            }
        } catch (_: Exception) { }
        try {
            val upd = Api.checkUpdate()
            if (upd?.hasUpdate == true) updateNotice = upd
        } catch (_: Exception) { }
    }

    // 登录后建立 WebSocket；WS 数据事件驱动刷新（track_list/profile/stats）
    val lastDataEvent by NotificationBus.lastDataEvent.collectAsState()
    LaunchedEffect(lastDataEvent) {
        val ev = lastDataEvent ?: return@LaunchedEffect
        when (ev.event) {
            "track_list" -> Library.load(force = true)
            "profile" -> ev.user?.let { AuthManager.applyRemoteProfile(it) }
            "stats" -> ev.totalSeconds?.let { AppPreloader.mineStatsSeconds.value = it }
            else -> {}
        }
    }

    BackHandler(enabled = subPage != null) { popPage() }
    BackHandler(enabled = drawerProgress > 0.01f) { drawerTarget = 0f }

    Box(Modifier.fillMaxSize()) {
        val panelWidthDp = (LocalConfiguration.current.screenWidthDp * 0.85f).dp

        // ===== 侧边栏在最底层（从左滑入）=====
        SidebarDrawer(
            progress = drawerProgress,
            onClose = { drawerTarget = 0f },
        )

        // ===== 主内容：fillMaxSize 延伸到底部，TabBar 浮在上面 =====
        Column(
            Modifier
                .fillMaxSize()
                .offset(x = panelWidthDp * drawerProgress)
        ) {
            Box(Modifier.weight(1f)) {
                // 三页常驻：选中页 zIndex 置顶 + 透明度动画
                Box(Modifier.fillMaxSize().zIndex(if (selectedTab == 0) 1f else 0f).graphicsLayer { alpha = if (selectedTab == 0) 1f else 0f }) {
                    DiscoverScreen()
                }
                Box(Modifier.fillMaxSize().zIndex(if (selectedTab == 1) 1f else 0f).graphicsLayer { alpha = if (selectedTab == 1) 1f else 0f }) {
                    HomeScreen()
                }
                Box(Modifier.fillMaxSize().zIndex(if (selectedTab == 2) 1f else 0f).graphicsLayer { alpha = if (selectedTab == 2) 1f else 0f }) {
                    MineScreen(
                        onOpenUpload = { uri -> uploadUri = uri; pushPage(SubPage.Upload) },
                        onOpenNotifications = { pushPage(SubPage.Notifications) },
                        onOpenSettings = { pushPage(SubPage.Settings) },
                        onOpenHistory = { pushPage(SubPage.History) },
                        onOpenPlaylists = { pushPage(SubPage.Playlists) },
                    )
                }

                // 顶部栏（仅首页播放页显示）
                if (selectedTab == 1) {
                    GlobalTopBar(
                        onOpenSidebar = { drawerTarget = 1f },
                        onOpenSearch = { pushPage(SubPage.Search) },
                    )
                }
            }
        }

        // ===== TabBar 浮在内容上面（播放页时透明，背景延伸过来）=====
        Box(
            Modifier
                .align(Alignment.BottomCenter)
                .offset(x = panelWidthDp * drawerProgress)
                .zIndex(5f)
        ) {
            AppTabBar(
                selection = selectedTab,
                onSelect = { AppRouter.selectedTab.value = it },
            )
        }

        // 点击主内容区域关闭抽屉
        if (drawerProgress > 0.01f) {
            Box(
                Modifier
                    .fillMaxSize()
                    .offset(x = panelWidthDp * drawerProgress)
                    .clickable { drawerTarget = 0f }
                    .zIndex(7f)
            )
        }

        // ===== 全屏子页面 =====
        subPage?.let { page ->
            SubPageHost(onBack = { popPage() }) {
                when (page) {
                    SubPage.Search -> SearchScreenCompat(onBack = { popPage() })
                    SubPage.Notifications -> NotificationsScreenCompat(
                        onBack = { popPage() },
                        onOpenOfficial = { pushPage(SubPage.OfficialMessages) })
                    SubPage.OfficialMessages -> OfficialMessagesScreenCompat(onBack = { popPage() })
                    SubPage.Settings -> SettingsScreenCompat(
                        onBack = { popPage() },
                        onOpenProfileEdit = { pushPage(SubPage.ProfileEdit) },
                        onOpenChangePassword = { pushPage(SubPage.ChangePassword) },
                        onOpenAbout = { pushPage(SubPage.About) },
                        onOpenLogin = { pushPage(SubPage.Login) })
                    SubPage.Login -> LoginScreen(onLoginSuccess = { popPage() })
                    SubPage.ProfileEdit -> ProfileEditScreenCompat(onBack = { popPage() })
                    SubPage.ChangePassword -> ChangePasswordScreenCompat(onBack = { popPage() })
                    SubPage.About -> AboutScreenCompat(onBack = { popPage() })
                    SubPage.Upload -> UploadScreenCompat(fileUri = uploadUri, onBack = { popPage() })
                    SubPage.History -> HistoryScreenCompat(onBack = { popPage() })
                    SubPage.Playlists -> PlaylistsScreenCompat(onBack = { popPage() },
                        onOpenPlaylist = { id, name -> pushPage(SubPage.PlaylistDetail(id, name)) })
                    is SubPage.PlaylistDetail -> PlaylistDetailScreenCompat(
                        playlistId = (page as SubPage.PlaylistDetail).playlistId,
                        playlistName = (page as SubPage.PlaylistDetail).playlistName,
                        onBack = { popPage() })
                    is SubPage.UserProfile -> UserProfileScreenCompat(
                        userId = (page as SubPage.UserProfile).userId,
                        onBack = { popPage() })
                }
            }
        }
    }

    // 公告/更新弹窗
    announcement?.let { AnnouncementSheetCompat(announcement = it, onDismiss = { announcement = null }) }
    updateNotice?.let { UpdateSheetCompat(update = it, onDismiss = { updateNotice = null }) }

    // 评论弹窗（对应 iOS CommentSheet presentation）
    val commentTrack = pendingCommentTrack
    if (showCommentSheet && commentTrack != null) {
        androidx.compose.material3.ModalBottomSheet(
            onDismissRequest = { AppRouter.showCommentSheet.value = false },
            containerColor = Background,
            sheetState = androidx.compose.material3.rememberModalBottomSheetState(skipPartiallyExpanded = true)
        ) {
            app.star2936.guava3291.ui.comment.CommentSheet(
                track = commentTrack,
                highlightCommentId = highlightCommentId,
                onDismiss = { AppRouter.showCommentSheet.value = false }
            )
        }
    }
}

/** 全屏子页面宿主：统一深色背景 */
@Composable
fun SubPageHost(onBack: () -> Unit, content: @Composable () -> Unit) {
    Box(Modifier.fillMaxSize().background(Background).zIndex(20f)) { content() }
}

// 子页面转发（由各自模块实现，避免编译顺序问题）
@Composable
fun SearchScreenCompat(onBack: () -> Unit) { app.star2936.guava3291.ui.search.SearchScreen(onBack = onBack) }
@Composable
fun NotificationsScreenCompat(onBack: () -> Unit, onOpenOfficial: () -> Unit) { app.star2936.guava3291.ui.notifications.NotificationsScreenCompat(onBack = onBack, onOpenOfficial = onOpenOfficial) }
@Composable
fun OfficialMessagesScreenCompat(onBack: () -> Unit) { app.star2936.guava3291.ui.notifications.OfficialMessagesScreenCompat(onBack = onBack) }
@Composable
fun SettingsScreenCompat(onBack: () -> Unit, onOpenProfileEdit: () -> Unit, onOpenChangePassword: () -> Unit, onOpenAbout: () -> Unit, onOpenLogin: () -> Unit) { app.star2936.guava3291.ui.settings.SettingsScreenCompat(onBack = onBack, onOpenProfileEdit = onOpenProfileEdit, onOpenChangePassword = onOpenChangePassword, onOpenAbout = onOpenAbout, onOpenLogin = onOpenLogin) }
@Composable
fun ProfileEditScreenCompat(onBack: () -> Unit) { app.star2936.guava3291.ui.settings.ProfileEditScreenCompat(onBack = onBack) }
@Composable
fun ChangePasswordScreenCompat(onBack: () -> Unit) { app.star2936.guava3291.ui.settings.ChangePasswordScreenCompat(onBack = onBack) }
@Composable
fun AboutScreenCompat(onBack: () -> Unit) { app.star2936.guava3291.ui.settings.AboutScreenCompat(onBack = onBack) }
@Composable
fun UploadScreenCompat(fileUri: android.net.Uri?, onBack: () -> Unit) { app.star2936.guava3291.ui.upload.UploadScreenCompat(fileUri = fileUri, onBack = onBack) }
@Composable
fun HistoryScreenCompat(onBack: () -> Unit) { app.star2936.guava3291.ui.history.HistoryScreen(onBack = onBack) }
@Composable
fun PlaylistsScreenCompat(onBack: () -> Unit, onOpenPlaylist: (String, String) -> Unit) { app.star2936.guava3291.ui.playlists.PlaylistsScreen(onBack = onBack, onOpenPlaylist = onOpenPlaylist) }
@Composable
fun PlaylistDetailScreenCompat(playlistId: String, playlistName: String, onBack: () -> Unit) { app.star2936.guava3291.ui.playlists.PlaylistDetailScreen(playlistId = playlistId, playlistName = playlistName, onBack = onBack) }
@Composable
fun UserProfileScreenCompat(userId: String, onBack: () -> Unit) { app.star2936.guava3291.ui.profile.UserProfileScreen(userId = userId, onBack = onBack) }

// ===== 全局顶部栏（仅首页显示，颜色随封面亮度）=====
@Composable
fun GlobalTopBar(onOpenSidebar: () -> Unit, onOpenSearch: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp)
            .padding(top = 8.dp)
            .height(50.dp)
            .zIndex(2f),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Row(
            Modifier
                .clip(RoundedCornerShape(8.dp))
                .clickable { onOpenSidebar() }
                .padding(vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text("☰", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.width(8.dp))
            Text("流萤音乐", color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.Bold)
        }
        Spacer(Modifier.weight(1f))
        Icon(
            Icons.Outlined.Search,
            contentDescription = "搜索",
            tint = Color.White,
            modifier = Modifier
                .size(18.dp)
                .clip(RoundedCornerShape(8.dp))
                .clickable { onOpenSearch() }
                .padding(10.dp)
        )
    }
}

// ===== 悬浮底部 TabBar（对应 AppTabBar）=====
@Composable
fun AppTabBar(selection: Int, onSelect: (Int) -> Unit) {
    val playerIsPlaying by PlayerManager.isPlaying.collectAsState()
    val backgroundLight by PlayerManager.playerCardBackgroundLight.collectAsState()
    val unread by NotificationBus.unreadCount.collectAsState()
    val current = PlayerManager.current

    fun tabColor(selected: Boolean): Color {
        if (selection == 1) {
            if (selected) return Accent
            return if (backgroundLight) TextSecondary else Color.White.copy(alpha = 0.72f)
        }
        return if (selected) Accent else TextSecondary
    }

    // TabBar 背景色：播放页透明，其他页深色，带过渡动画
    val tabBarBg by androidx.compose.animation.animateColorAsState(
        targetValue = if (selection == 1) Color.Transparent else Card.copy(alpha = 0.98f),
        animationSpec = androidx.compose.animation.core.tween(300),
        label = "tabBarBg"
    )

    Box(
        Modifier
            .fillMaxWidth()
            .background(tabBarBg)
            .zIndex(2f)
    ) {
        if (selection != 1) {
            // 顶部 0.5 边框（对应 overlay cardBorder）
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(0.5.dp)
                    .background(CardBorder)
                    .align(Alignment.TopCenter)
            )
        }
        Row(Modifier.padding(top = 8.dp).padding(bottom = androidx.compose.foundation.layout.WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding() + 6.dp), verticalAlignment = Alignment.CenterVertically) {
            // 发现
            TabButton(
                icon = { Icon(Icons.Filled.AutoAwesome, contentDescription = null, tint = tabColor(selection == 0), modifier = Modifier.size(21.dp)) },
                label = "发现",
                color = tabColor(selection == 0),
                modifier = Modifier.weight(1f),
                onClick = { onSelect(0) }
            )
            // 中央播放控制
            Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                if (selection == 1) {
                    Box(
                        Modifier
                            .size(46.dp)
                            .clip(CircleShape)
                            .background(Accent)
                            .clickable { PlayerManager.toggle() },
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            if (playerIsPlaying) Icons.Outlined.Pause else Icons.Outlined.PlayArrow,
                            contentDescription = null,
                            tint = Color.White,
                            modifier = Modifier.size(20.dp)
                        )
                    }
                } else {
                    val track = current
                    Box(
                        Modifier
                            .size(44.dp)
                            .clip(RoundedCornerShape(12.dp))
                            .clickable { onSelect(1) }
                    ) {
                        if (track != null) {
                            CoverImage(track = track, modifier = Modifier.fillMaxSize(), cornerRadius = 12.dp)
                        } else {
                            AlbumArtPlaceholder("音乐", Modifier.fillMaxSize())
                        }
                        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.35f)))
                        if (playerIsPlaying) {
                            EqualizerBars(modifier = Modifier.align(Alignment.Center))
                        } else {
                            Icon(Icons.Outlined.Pause, contentDescription = null, tint = Color.White, modifier = Modifier.align(Alignment.Center).size(11.dp))
                        }
                    }
                }
            }
            // 我的（未读红点）
            Box(Modifier.weight(1f)) {
                TabButton(
                    icon = {
                        Box {
                            Icon(Icons.Outlined.Person, contentDescription = null, tint = tabColor(selection == 2), modifier = Modifier.size(21.dp))
                            if (unread > 0) {
                                Box(
                                    Modifier
                                        .size(9.dp)
                                        .clip(CircleShape)
                                        .background(Color.Red)
                                        .align(Alignment.TopEnd)
                                        .offset(x = 3.dp, y = (-2).dp)
                                )
                            }
                        }
                    },
                    label = "我的",
                    color = tabColor(selection == 2),
                    modifier = Modifier.fillMaxWidth(),
                    onClick = { onSelect(2) }
                )
            }
        }
    }
}

@Composable
fun TabButton(icon: @Composable () -> Unit, label: String, color: Color, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(8.dp))
            .clickable(onClick = onClick)
            .padding(vertical = 7.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Box(Modifier.height(24.dp), contentAlignment = Alignment.Center) { icon() }
        Spacer(Modifier.height(3.dp))
        Text(label, color = color, fontSize = 11.sp, fontWeight = FontWeight.Medium)
    }
}

// ===== 侧边栏抽屉（85% 宽，offset 跟随进度）=====
@Composable
fun SidebarDrawer(progress: Float, onClose: () -> Unit) {
    val density = LocalDensity.current
    val panelWidthDp = (LocalConfiguration.current.screenWidthDp * 0.85f).dp
    val panelWidthPx = with(density) { panelWidthDp.toPx() }
    val dominant by PlayerManager.playerCardDominant.collectAsState()

    val bg = dominant?.let { darkened(it, 0.18f) } ?: Card
    Box(
        Modifier
            .fillMaxHeight()
            .width(panelWidthDp)
            .offset(x = (progress * panelWidthPx - panelWidthPx).dp)
            .background(Brush.linearGradient(listOf(bg, bg.copy(alpha = 0.85f))))
            .zIndex(5f)
    ) {
        SidebarContent(onClose = onClose)
    }
}

// ===== 公告弹窗（半屏，对应 AnnouncementSheet）=====
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun AnnouncementSheetCompat(announcement: Announcement, onDismiss: () -> Unit) {
    val ctx = LocalContext.current
    androidx.compose.material3.ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF1C1C1E),
    ) {
        Column(Modifier.padding(24.dp)) {
            Text(announcement.title, color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(12.dp))
            Text(announcement.content, color = Color.White.copy(alpha = 0.85f), fontSize = 15.sp, lineHeight = 24.sp)
            if (announcement.version.isNotEmpty()) {
                Spacer(Modifier.height(10.dp))
                Text("版本：${announcement.version}", color = Color.White.copy(alpha = 0.5f), fontSize = 13.sp)
            }
            Spacer(Modifier.height(20.dp))
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(48.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(Accent)
                    .clickable {
                        if (announcement.showOnce == 1) {
                            ctx.getSharedPreferences("announcement", android.content.Context.MODE_PRIVATE)
                                .edit().putString("shown_id", announcement.id).apply()
                        }
                        onDismiss()
                    },
                contentAlignment = Alignment.Center
            ) {
                Text("我知道了", color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}

// ===== 更新弹窗（半屏，对应 UpdateSheet）=====
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun UpdateSheetCompat(update: UpdateCheck, onDismiss: () -> Unit) {
    val ctx = LocalContext.current
    androidx.compose.material3.ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF1C1C1E),
    ) {
        Column(Modifier.padding(24.dp)) {
            Text(update.title ?: "发现新版本", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold)
            if (!update.version.isNullOrEmpty()) {
                Spacer(Modifier.height(8.dp))
                Text("新版本：${update.version}", color = Color(0xFF5CD68A), fontSize = 14.sp)
            }
            Spacer(Modifier.height(12.dp))
            Text(update.content ?: "", color = Color.White.copy(alpha = 0.85f), fontSize = 15.sp, lineHeight = 24.sp)
            Spacer(Modifier.height(20.dp))
            val force = update.forceUpdate == 1
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(48.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(Accent)
                    .clickable {
                        update.downloadUrl?.let { url ->
                            try {
                                val intent = android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url))
                                ctx.startActivity(intent)
                            } catch (_: Exception) { }
                        }
                        if (!force) onDismiss()
                    },
                contentAlignment = Alignment.Center
            ) {
                Text("去更新", color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            }
            if (!force) {
                Spacer(Modifier.height(8.dp))
                Box(
                    Modifier
                        .fillMaxWidth()
                        .padding(vertical = 12.dp)
                        .clickable { onDismiss() },
                    contentAlignment = Alignment.Center
                ) {
                    Text("以后再说", color = Color.White.copy(alpha = 0.6f), fontSize = 15.sp)
                }
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}
