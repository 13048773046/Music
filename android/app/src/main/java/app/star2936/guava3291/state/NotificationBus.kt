package app.star2936.guava3291.state

import app.star2936.guava3291.data.Api
import app.star2936.guava3291.data.BehaviorEvent
import app.star2936.guava3291.data.Notification
import app.star2936.guava3291.data.User
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.concurrent.TimeUnit

// 对应 iOS NotificationBus.swift（WebSocket 实时通知总线）
// 下行：{"kind":"notification","notification":{...},"unread":N}
//      {"kind":"event","event":"stats|recommend|track_list|profile|my_tracks",...}
// 上行：{"type":"behavior","events":[...]}

data class NotificationEvent(val notification: Notification?, val unread: Int? = null)
data class DataEvent(val event: String, val user: User? = null, val totalSeconds: Int? = null)

object NotificationBus {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var webSocket: WebSocket? = null
    private var reconnectJob: Job? = null
    private var heartbeatJob: Job? = null
    private var reconnectAttempt = 0
    private var started = false

    val lastEvent = MutableStateFlow<NotificationEvent?>(null)
    val lastDataEvent = MutableStateFlow<DataEvent?>(null)
    val unreadCount = MutableStateFlow(0)

    // 注册到 Api.reportBehavior（HTTP 回退通道）
    fun register() {
        // WS 通道直连；HTTP 回退由 Api 自行判断
    }

    fun startIfNeeded() {
        if (started) return
        started = true
        connect()
    }

    fun resetAndReconnect() {
        started = true
        reconnectAttempt = 0
        connect()
    }

    fun stop() {
        started = false
        reconnectJob?.cancel()
        heartbeatJob?.cancel()
        webSocket?.close(1000, "logout")
        webSocket = null
    }

    fun setUnread(n: Int) {
        unreadCount.value = n
    }

    /** 行为实时上报：WS 已连接则发送并返回 true；未连接返回 false（调用方回退 HTTP） */
    fun sendBehavior(events: List<BehaviorEvent>): Boolean {
        val ws = webSocket ?: return false
        if (events.isEmpty()) return false
        return try {
            val json = buildJsonObject {
                put("type", "behavior")
                put("events", kotlinx.serialization.json.buildJsonArray {
                    events.forEach { ev ->
                        add(kotlinx.serialization.json.buildJsonObject {
                            put("trackId", ev.trackId)
                            put("event", ev.event)
                            put("value", ev.value)
                            ev.meta?.let { put("meta", it) }
                        })
                    }
                })
            }.toString()
            ws.send(json)
        } catch (_: Exception) { false }
    }

    private fun connect() {
        val token = AuthManager.currentUserValue?.token ?: return
        val url = Api.wsUrl(token)
        val client = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(60, TimeUnit.SECONDS)
            .pingInterval(25, TimeUnit.SECONDS)   // 25s 心跳（OkHttp 原生 ping 帧）
            .build()
        val request = Request.Builder().url(url).build()
        webSocket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(ws: WebSocket, response: Response) {
                reconnectAttempt = 0
            }

            override fun onMessage(ws: WebSocket, text: String) {
                handleMessage(text)
            }

            override fun onClosed(ws: WebSocket, code: Int, reason: String) {
                scheduleReconnect()
            }

            override fun onFailure(ws: WebSocket, t: Throwable, response: Response?) {
                scheduleReconnect()
            }
        })
    }

    private fun handleMessage(text: String) {
        try {
            val root = Json.parseToJsonElement(text).jsonObject
            val kind = root["kind"]?.jsonPrimitive?.contentOrNull ?: return
            when (kind) {
                "notification" -> {
                    val nObj = root["notification"]?.let {
                        Api.json.decodeFromJsonElement<Notification>(it)
                    }
                    val unread = root["unread"]?.jsonPrimitive?.intOrNull
                    unread?.let { unreadCount.value = it }
                    lastEvent.value = NotificationEvent(nObj, unread)
                }
                "event" -> {
                    val ev = root["event"]?.jsonPrimitive?.contentOrNull ?: ""
                    val user = root["user"]?.let {
                        try { Api.json.decodeFromJsonElement<User>(it) } catch (_: Exception) { null }
                    }
                    val total = root["totalSeconds"]?.jsonPrimitive?.intOrNull
                    lastDataEvent.value = DataEvent(ev, user, total)
                }
            }
        } catch (_: Exception) { }
    }

    private fun scheduleReconnect() {
        if (!started) return
        reconnectJob?.cancel()
        reconnectJob = scope.launch {
            // 指数退避：1s,2s,4s...最大 60s，无重连上限（对应 iOS）
            val delayMs = minOf(1000L shl minOf(reconnectAttempt, 6), 60_000L)
            reconnectAttempt += 1
            delay(delayMs)
            if (isActive && started) connect()
        }
    }
}
