package app.star2936.guava3291

import android.app.Application
import android.content.ComponentCallbacks2
import app.star2936.guava3291.state.AuthManager
import app.star2936.guava3291.state.LocalPlayHistory
import app.star2936.guava3291.state.NetworkMonitor
import app.star2936.guava3291.state.NotificationBus
import app.star2936.guava3291.state.PlayerManager
import app.star2936.guava3291.state.PlayerSession
import app.star2936.guava3291.state.WeatherContext

class MusicApplication : Application(), ComponentCallbacks2 {

    override fun onCreate() {
        super.onCreate()
        AuthManager.init(this)
        PlayerSession.init(this)
        PlayerManager.init(this)
        NotificationBus.register()
        WeatherContext.init(this)
        NetworkMonitor.init(this)
        LocalPlayHistory.init(this)
        registerComponentCallbacks(this)
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if (level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW) {
            PlayerManager.onLowMemory()
        }
    }

    override fun onLowMemory() {
        super.onLowMemory()
        PlayerManager.onLowMemory()
    }
}
