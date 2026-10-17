package app.star2936.guava3291.state

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.graphics.BitmapFactory
import android.widget.RemoteViews
import androidx.core.app.NotificationCompat
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import app.star2936.guava3291.R

// 对应 iOS 锁屏控制（MPRemoteCommandCenter）：通过 MediaSessionService 提供锁屏/通知栏媒体控制。
// 播放状态变化时手动构建完整媒体通知：封面、歌曲名、作者、上一首/下一首/播放暂停。
class PlaybackService : MediaSessionService() {

    private var mediaSession: MediaSession? = null
    private val notificationId = 1000
    private val channelId = "music_playback"

    private val listener = object : Player.Listener {
        override fun onMediaMetadataChanged(mediaMetadata: MediaMetadata) { updateNotification() }
        override fun onIsPlayingChanged(isPlaying: Boolean) { updateNotification() }
        override fun onPlaybackStateChanged(playbackState: Int) { updateNotification() }
        override fun onMediaItemTransition(mediaItem: androidx.media3.common.MediaItem?, reason: Int) { updateNotification() }
    }

    private var becomingNoisyReceiver: android.content.BroadcastReceiver? = null
    private var currentNotificationBuilder: NotificationCompat.Builder? = null

    override fun onCreate() {
        super.onCreate()

        // 耳机插拔自动暂停（工业级）
        becomingNoisyReceiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(context: android.content.Context?, intent: android.content.Intent?) {
                if (intent?.action == android.media.AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                    PlayerManager.pausePlayback()
                }
            }
        }
        registerReceiver(becomingNoisyReceiver, android.content.IntentFilter(android.media.AudioManager.ACTION_AUDIO_BECOMING_NOISY))

        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(channelId, "音乐播放", NotificationManager.IMPORTANCE_LOW).apply {
                description = "显示正在播放的歌曲与控制"
            }
        )

        val intent = Intent(this, app.star2936.guava3291.MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val piFlags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        val pi = PendingIntent.getActivity(this, 0, intent, piFlags)

        // 立即进入前台，避免 Android 14 超时
        val base = Notification.Builder(this, channelId)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("流萤音乐")
            .setContentText("正在播放")
            .setContentIntent(pi)
            .setOngoing(true)
            .setShowWhen(false)
            .build()
        startForeground(notificationId, base)

        val session = MediaSession.Builder(this, PlayerManager.player)
            .setSessionActivity(pi)
            .build()
        mediaSession = session

        PlayerManager.player.addListener(listener)
        updateNotification()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PREV -> PlayerManager.previous()
            ACTION_NEXT -> PlayerManager.next()
            ACTION_TOGGLE -> PlayerManager.toggle()
        }
        return super.onStartCommand(intent, flags, startId)
    }

    private fun updateNotification() {
        val session = mediaSession ?: return
        val player = PlayerManager.player
        val meta = player.currentMediaItem?.mediaMetadata
        val title = meta?.title?.toString().orEmpty().ifEmpty { "流萤音乐" }
        val artist = meta?.artist?.toString().orEmpty().ifEmpty { "正在播放" }
        val isPlaying = player.isPlaying

        // 异步加载封面
        val track = PlayerManager.current
        var largeIcon: android.graphics.Bitmap? = null
        meta?.artworkData?.takeIf { it.isNotEmpty() }?.let {
            largeIcon = runCatching { BitmapFactory.decodeByteArray(it, 0, it.size) }.getOrNull()
        }

        val contentIntent = Intent(this, app.star2936.guava3291.MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val piFlags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        val openPi = PendingIntent.getActivity(this, 1, contentIntent, piFlags)

        fun actionPi(code: Int, action: String): PendingIntent {
            val i = Intent(this, PlaybackService::class.java).setAction(action)
            return PendingIntent.getForegroundService(this, code, i, piFlags)
        }

        val builder = NotificationCompat.Builder(this, channelId)
            .setSmallIcon(R.drawable.app_logo)
            .setContentTitle(title)
            .setContentText(artist)
            .setContentIntent(openPi)
            .setOngoing(true)
            .setShowWhen(false)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
            .setStyle(
                androidx.media.app.NotificationCompat.MediaStyle()
                    .setMediaSession(session.sessionCompatToken)
                    .setShowActionsInCompactView(0, 1, 2)
            )
            .addAction(NotificationCompat.Action(android.R.drawable.ic_media_previous, "上一首", actionPi(2, ACTION_PREV)))
            .addAction(
                NotificationCompat.Action(
                    if (isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                    if (isPlaying) "暂停" else "播放",
                    actionPi(3, ACTION_TOGGLE)
                )
            )
            .addAction(NotificationCompat.Action(android.R.drawable.ic_media_next, "下一首", actionPi(4, ACTION_NEXT)))
        if (largeIcon != null) builder.setLargeIcon(largeIcon)
        currentNotificationBuilder = builder

        try {
            if (isPlaying) {
                startForeground(notificationId, builder.build())
            } else {
                getSystemService(NotificationManager::class.java).notify(notificationId, builder.build())
            }
        } catch (_: Exception) {}

        // 异步加载网络封面并更新
        val coverUrl = track?.coverURL
        if (coverUrl != null && largeIcon == null) {
            Thread {
                try {
                    val bmp = BitmapFactory.decodeStream(java.net.URL(coverUrl).openStream())
                    currentNotificationBuilder?.setLargeIcon(bmp)
                    currentNotificationBuilder?.let {
                        getSystemService(NotificationManager::class.java).notify(notificationId, it.build())
                    }
                } catch (_: Exception) {}
            }.start()
        }
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = mediaSession

    override fun onTaskRemoved(rootIntent: Intent?) {
        val player = PlayerManager.player
        if (!player.playWhenReady || player.playbackState == Player.STATE_IDLE) {
            player.stop()
            stopSelf()
        }
    }

    override fun onDestroy() {
        becomingNoisyReceiver?.let { runCatching { unregisterReceiver(it) } }
        PlayerManager.player.removeListener(listener)
        mediaSession?.release()
        mediaSession = null
        super.onDestroy()
    }

    companion object {
        const val ACTION_PREV = "app.star2936.guava3291.action.PREV"
        const val ACTION_NEXT = "app.star2936.guava3291.action.NEXT"
        const val ACTION_TOGGLE = "app.star2936.guava3291.action.TOGGLE"
    }
}
