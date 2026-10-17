package app.star2936.guava3291.state

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * 网络状态感知（对应 iOS NetworkMonitor.swift 的逻辑，按 Android 体系实现）。
 *
 * Android 碎片化适配（minSdk 29 / Android 10+，覆盖各厂商 ROM）：
 * 1. 离线判定只依赖 NET_CAPABILITY_INTERNET，**不依赖 VALIDATED**——
 *    国产 ROM / 企业网 / 无 Captive Portal 环境下 VALIDATED 可能长期为 false，
 *    若据此判离线会误触发"无限缓冲/停预取"。真实断网（飞行模式/关数据）会触发
 *    onLost/onUnavailable，INTERNET 能力消失 → offline=true。
 * 2. onUnavailable（API 26+）兜底：部分 ROM 断网只回调 onUnavailable 不回调 onLost。
 * 3. NetworkCallback 回调运行在系统 Binder 线程，StateFlow 赋值线程安全，无锁无竞态。
 * 4. getNetworkCapabilities 在切换窗口可能返回 null → 保持上次状态，不抖动。
 * 5. 弱网降级（isCellular）与播放器错误重试互为兜底：即使 ROM 状态上报延迟，
 *    ExoPlayer 实际请求失败仍会走 onPlayerError 的重试/升级路径。
 */
object NetworkMonitor {
    private val _isOffline = MutableStateFlow(false)
    /** 当前无网络（断网 / 飞行模式 / 无蜂窝与 Wi-Fi） */
    val isOffline: StateFlow<Boolean> = _isOffline.asStateFlow()

    private val _isCellular = MutableStateFlow(false)
    /** 当前走蜂窝数据（弱网降级的保守依据：蜂窝网常弱于 Wi-Fi） */
    val isCellular: StateFlow<Boolean> = _isCellular.asStateFlow()

    private var cm: ConnectivityManager? = null
    private var callback: ConnectivityManager.NetworkCallback? = null

    fun init(context: Context) {
        cm = context.applicationContext
            .getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { update() }
            override fun onLost(network: Network) { update() }
            override fun onUnavailable() { update() }
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) { update() }
        }
        try {
            cm?.registerDefaultNetworkCallback(callback!!)
        } catch (_: Exception) { }
        update()
    }

    private fun update() {
        val caps = cm?.getNetworkCapabilities(cm?.activeNetwork) ?: return
        val hasInternet = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        _isOffline.value = !hasInternet
        _isCellular.value = caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
    }
}
