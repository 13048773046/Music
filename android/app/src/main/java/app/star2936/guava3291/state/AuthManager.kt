package app.star2936.guava3291.state

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import app.star2936.guava3291.data.Api
import app.star2936.guava3291.data.User
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

// 对应 iOS Auth.swift：登录态管理（Keychain → EncryptedSharedPreferences）

object AuthManager {
    private const val PrefsName = "auth_session"
    private const val KeyUser = "current_user"
    private const val KeySavedAccounts = "saved_accounts"

    private lateinit var prefs: SharedPreferences
    private val _currentUser = MutableStateFlow<User?>(null)
    val currentUser: StateFlow<User?> = _currentUser.asStateFlow()

    private val _savedAccounts = MutableStateFlow<List<User>>(emptyList())
    val savedAccounts: StateFlow<List<User>> = _savedAccounts.asStateFlow()

    var currentUserValue: User?
        get() = _currentUser.value
        set(value) { _currentUser.value = value }

    fun init(context: Context) {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        prefs = EncryptedSharedPreferences.create(
            context,
            PrefsName,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
        restore()
    }

    /** 启动时从加密存储恢复登录态 */
    private fun restore() {
        val raw = prefs.getString(KeyUser, null)
        if (raw != null) {
            try { _currentUser.value = Api.json.decodeFromString<User>(raw) } catch (_: Exception) {
                prefs.edit().remove(KeyUser).apply()
            }
        }
        // 加载历史账号列表
        val savedRaw = prefs.getString(KeySavedAccounts, null)
        if (savedRaw != null) {
            try { _savedAccounts.value = Api.json.decodeFromString<List<User>>(savedRaw) } catch (_: Exception) { }
        }
        // 兜底：如果有当前登录用户但 savedAccounts 里没有，加进去
        _currentUser.value?.let { u ->
            if (_savedAccounts.value.none { it.id == u.id }) {
                _savedAccounts.value = _savedAccounts.value + u
            }
        }
    }

    /** 接口返回 401：清除本地登录态，下次进 App 重新登录 */
    fun handleUnauthorized() {
        if (_currentUser.value == null) return
        _currentUser.value = null
        prefs.edit().remove(KeyUser).apply()
    }

    suspend fun login(account: String, password: String) {
        saveSession(Api.login(account, password))
    }

    suspend fun register(password: String, name: String, avatarData: ByteArray?,
                         gender: String, age: Int, signature: String,
                         backgroundData: ByteArray?) {
        val user = Api.register(password, name, avatarData, gender, age, signature, backgroundData)
        saveSession(user)
    }

    fun logout() {
        _currentUser.value = null
        prefs.edit().remove(KeyUser).apply()
    }

    suspend fun updateProfile(name: String, gender: String, age: Int, signature: String,
                              avatarData: ByteArray?, backgroundData: ByteArray?) {
        val u = _currentUser.value ?: return
        val updated = Api.updateProfile(u.account, name, gender, age, signature,
            avatarData, backgroundData)
        saveSession(updated)
    }

    /** WebSocket 推送资料更新（多端同步）：合并当前 token 后刷新登录态 */
    fun applyRemoteProfile(user: User) {
        if (_currentUser.value == null) return
        saveSession(user)
    }

    suspend fun changePassword(old: String, new: String) {
        Api.changePassword(old, new)
    }

    private fun saveSession(user: User) {
        // 后端 profile/update 响应不含 token：合并保留已有 token，避免 401
        var u = user
        if (u.token.isNullOrEmpty()) {
            u = u.copy(token = _currentUser.value?.token)
        }
        try {
            val raw = Api.json.encodeToString(u)
            prefs.edit().putString(KeyUser, raw).apply()
        } catch (_: Exception) { }
        _currentUser.update { u }
        // 保存到历史账号列表（去重）
        val list = (_savedAccounts.value.filter { it.id != u.id } + u).distinctBy { it.id }
        _savedAccounts.value = list
        try { prefs.edit().putString(KeySavedAccounts, Api.json.encodeToString(list)).apply() } catch (_: Exception) { }
        // 登录后启动 WebSocket
        NotificationBus.startIfNeeded()
        // 预加载我的页数据
        AppPreloader.invalidateMine()
        AppPreloader.preload()
    }

    /** 切换到历史账号（直接用保存的 token 恢复登录态） */
    fun switchTo(user: User) {
        // 先断开旧账号的 WebSocket，避免旧 token 重连
        NotificationBus.stop()
        saveSession(user)
    }
}
