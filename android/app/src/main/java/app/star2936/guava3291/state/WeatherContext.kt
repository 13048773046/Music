package app.star2936.guava3291.state

import android.annotation.SuppressLint
import android.content.Context
import android.location.Geocoder
import android.location.Location
import android.location.LocationManager
import android.os.Build
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import app.star2936.guava3291.data.Api
import java.util.Calendar
import java.util.Locale

data class WeatherInfo(
    val ok: Boolean = false,
    val temp: Double? = null,
    val code: Int? = null,
    val hour: Int? = null,
    val scene: String? = null,
    val sceneLabel: String? = null,
)

/** 对应 iOS WeatherContext.swift：定位 + 天气×时段场景单例 */
object WeatherContext {
    private val _scene = MutableStateFlow<String?>(null)
    val scene: StateFlow<String?> = _scene
    private val _sceneLabel = MutableStateFlow<String?>(null)
    val sceneLabel: StateFlow<String?> = _sceneLabel
    private val _temperature = MutableStateFlow<Double?>(null)
    val temperature: StateFlow<Double?> = _temperature
    private val _city = MutableStateFlow<String?>(null)
    val city: StateFlow<String?> = _city
    private val _isAvailable = MutableStateFlow(false)
    val isAvailable: StateFlow<Boolean> = _isAvailable

    var lat: Double? = null
    var lng: Double? = null
        private set

    val hour: Int get() = Calendar.getInstance().get(Calendar.HOUR_OF_DAY)

    private var lastSuccessAt: Long = 0
    private var appContext: Context? = null

    fun init(ctx: Context) {
        appContext = ctx.applicationContext
    }

    @SuppressLint("MissingPermission")
    suspend fun refresh(force: Boolean = false): Boolean {
        if (!force && System.currentTimeMillis() - lastSuccessAt < 30 * 60 * 1000L) {
            return _isAvailable.value
        }
        val ctx = appContext ?: return false
        val lm = ctx.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return false

        val fine = ctx.checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) == android.content.pm.PackageManager.PERMISSION_GRANTED
        val coarse = ctx.checkSelfPermission(android.Manifest.permission.ACCESS_COARSE_LOCATION) == android.content.pm.PackageManager.PERMISSION_GRANTED
        if (!fine && !coarse) return false

        val location: Location? = try {
            @Suppress("DEPRECATION")
            lm.getProviders(true).firstNotNullOfOrNull { provider ->
                if (lm.isProviderEnabled(provider)) lm.getLastKnownLocation(provider) else null
            }
        } catch (_: Exception) { null }

        if (location != null) {
            lat = location.latitude
            lng = location.longitude
            // 反查城市
            try {
                val geo = Geocoder(ctx, Locale.getDefault())
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    geo.getFromLocation(location.latitude, location.longitude, 1) { list ->
                        _city.value = list?.firstOrNull()?.locality ?: list?.firstOrNull()?.subLocality
                    }
                } else {
                    @Suppress("DEPRECATION")
                    val list = geo.getFromLocation(location.latitude, location.longitude, 1)
                    _city.value = list?.firstOrNull()?.locality ?: list?.firstOrNull()?.subLocality
                }
            } catch (_: Exception) {}
        }

        // 调天气接口
        val latV = lat ?: return false
        val lngV = lng ?: return false
        val wx = try { Api.fetchWeather(latV, lngV, hour) } catch (_: Exception) { null }
        if (wx == null || !wx.ok) return false
        _scene.value = wx.scene
        _sceneLabel.value = wx.sceneLabel
        _temperature.value = wx.temp
        lastSuccessAt = System.currentTimeMillis()
        _isAvailable.value = true
        return true
    }
}
