package app.star2936.guava3291

import android.Manifest
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.content.Intent
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import app.star2936.guava3291.ui.theme.Accent
import app.star2936.guava3291.ui.theme.Card
import app.star2936.guava3291.ui.theme.TextPrimary
import app.star2936.guava3291.ui.theme.TextSecondary
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.media3.common.Player
import app.star2936.guava3291.state.AuthManager
import app.star2936.guava3291.state.Library
import app.star2936.guava3291.state.NotificationBus
import app.star2936.guava3291.state.PlayerManager
import app.star2936.guava3291.state.PlayerSession
import app.star2936.guava3291.state.PlaybackService
import app.star2936.guava3291.ui.main.MainScreen
import app.star2936.guava3291.ui.login.LoginScreen
import app.star2936.guava3291.ui.splash.SplashScreen
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var audioManager: AudioManager? = null
    private var audioDeviceCallback: AudioDeviceCallback? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        // Android 13+ 锁屏控制通知权限
        if (Build.VERSION.SDK_INT >= 33) {
            val granted = checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == android.content.pm.PackageManager.PERMISSION_GRANTED
            if (!granted) {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 100)
            }
        }

        // 耳机/蓝牙插拔：拔插后音频流恢复（对应 iOS 音频恢复加固）
        audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
        audioDeviceCallback = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) { resumeAfterDeviceChange() }
            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) { resumeAfterDeviceChange() }
        }
        audioManager?.registerAudioDeviceCallback(audioDeviceCallback, null)

        // 生命周期：前台重连 WS + 复位音量；后台保存播放会话
        lifecycle.addObserver(LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> {
                    NotificationBus.resetAndReconnect()
                    Library.load()
                    // 切前台强制复位音量（对应 iOS 打断完整恢复逻辑）
                    PlayerManager.player.volume = 1.0f
                    // 回前台同步未读数（对应 iOS didBecomeActive）
                    kotlinx.coroutines.GlobalScope.launch(kotlinx.coroutines.Dispatchers.IO) {
                        try {
                            val r = app.star2936.guava3291.data.Api.notifications()
                            NotificationBus.setUnread(r.unread)
                        } catch (_: Exception) {}
                    }
                }
                Lifecycle.Event.ON_STOP -> {
                    PlayerSession.saveToDisk()
                    NotificationBus.stop()
                }
                else -> {}
            }
        })

        setContent {
            // 启动时并行预加载发现页/我的页数据
            app.star2936.guava3291.state.AppPreloader.preload()
            UpdateCheckDialog()
            AppRoot()
        }
    }

    private fun resumeAfterDeviceChange() {
        // 拔插瞬间播放器常被系统打断：短暂延迟后若仍在播放目标则恢复
        scope.launch {
            kotlinx.coroutines.delay(400)
            val player = PlayerManager.player
            val shouldPlay = PlayerManager.isPlaying.value
            if (shouldPlay &&
                player.playbackState != Player.STATE_BUFFERING &&
                !player.playWhenReady) {
                player.play()
            }
        }
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        PlayerManager.onLowMemory()
    }

    override fun onDestroy() {
        audioDeviceCallback?.let { audioManager?.unregisterAudioDeviceCallback(it) }
        super.onDestroy()
    }
}

@Composable
fun AppRoot() {
    val user by AuthManager.currentUser.collectAsState()
    var showSplash by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(true) }
    // 切换账号时的加载
    var showSwitchLoading by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(false) }
    var prevUid by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(user?.id) }

    // 断网恢复自动续播（对应 iOS NetworkMonitor 恢复回调）：
    // 离线期间播放失败 → 网络恢复后自动重试当前曲，无需用户手动点重试
    var wasOffline by androidx.compose.runtime.remember {
        androidx.compose.runtime.mutableStateOf(app.star2936.guava3291.state.NetworkMonitor.isOffline.value)
    }
    val offline by app.star2936.guava3291.state.NetworkMonitor.isOffline.collectAsState()
    androidx.compose.runtime.LaunchedEffect(offline) {
        if (wasOffline && !offline) {
            if (app.star2936.guava3291.state.PlayerManager.loadFailed.value) {
                app.star2936.guava3291.state.PlayerManager.reloadCurrent()
            }
        }
        wasOffline = offline
    }

    androidx.compose.runtime.LaunchedEffect(user?.id) {
        // 启动页最短展示 1.2s：数据就绪也至少停留 1.2s（避免闪跳）；超时 6s 兜底（对齐 iOS）
        val minShowMs = 1200L
        val maxWaitMs = 6000L
        if (user != null && prevUid != null && user?.id != prevUid) {
            // 切换账号：显示加载并预加载
            showSwitchLoading = true
            app.star2936.guava3291.state.AppPreloader.preload()
            val switchStart = System.currentTimeMillis()
            while (System.currentTimeMillis() - switchStart < maxWaitMs) {
                if ((System.currentTimeMillis() - switchStart >= minShowMs) &&
                    app.star2936.guava3291.state.AppPreloader.discoverRecommendedReady.value &&
                    app.star2936.guava3291.state.AppPreloader.mineLoaded.value
                ) break
                kotlinx.coroutines.delay(100)
            }
            showSwitchLoading = false
        }
        prevUid = user?.id
        if (user != null) {
            app.star2936.guava3291.state.AppPreloader.preload()
            val start = System.currentTimeMillis()
            while (System.currentTimeMillis() - start < maxWaitMs) {
                if ((System.currentTimeMillis() - start >= minShowMs) &&
                    app.star2936.guava3291.state.AppPreloader.discoverRecommendedReady.value &&
                    app.star2936.guava3291.state.AppPreloader.mineLoaded.value
                ) break
                kotlinx.coroutines.delay(100)
            }
        } else {
            kotlinx.coroutines.delay(1200)
        }
        showSplash = false
    }

    when {
        showSplash -> SplashScreen()
        showSwitchLoading -> SplashScreen()
        user == null -> LoginScreen()
        else -> MainScreen()
    }
}

@Composable
fun UpdateCheckDialog() {
    var update by remember { mutableStateOf<app.star2936.guava3291.data.UpdateCheck?>(null) }
    val ctx = LocalContext.current
    LaunchedEffect(Unit) {
        kotlinx.coroutines.delay(1500)
        val u = try { app.star2936.guava3291.data.Api.checkUpdate() } catch (_: Exception) { null }
        if (u != null && u.hasUpdate) update = u
    }
    update?.let { u ->
        AlertDialog(
            onDismissRequest = { if (u.forceUpdate != 1) update = null },
            confirmButton = {
                TextButton(onClick = {
                    try {
                        val url = u.downloadUrl ?: ""
                        if (url.isNotEmpty()) {
                            val intent = Intent(Intent.ACTION_VIEW, android.net.Uri.parse(url))
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            ctx.startActivity(intent)
                        }
                    } catch (_: Exception) {}
                    if (u.forceUpdate != 1) update = null
                }) { Text("去更新", color = Accent) }
            },
            dismissButton = if (u.forceUpdate != 1) {
                { TextButton(onClick = { update = null }) { Text("以后再说", color = TextSecondary) } }
            } else null,
            title = { Text(u.title ?: "发现新版本", color = TextPrimary) },
            text = {
                Column {
                    if (!u.version.isNullOrEmpty()) {
                        Text("新版本：${u.version}", color = Color(0xFF5CD68A))
                        Spacer(Modifier.height(8.dp))
                    }
                    Text(u.content ?: "", color = TextSecondary)
                }
            },
            containerColor = Card
        )
    }
}
