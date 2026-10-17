package app.star2936.guava3291.ui.splash

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.star2936.guava3291.state.AppPreloader
import app.star2936.guava3291.state.Library
import app.star2936.guava3291.ui.theme.Accent
import app.star2936.guava3291.ui.theme.Background
import app.star2936.guava3291.ui.theme.TextSecondary

// 对应 iOS SplashView：启动页 Logo + 版本，期间并行预加载
@Composable
fun SplashScreen() {
    // 启动即开始预加载（发现页推荐 + 我的页数据 + 曲库），与 1.6s 展示并行
    LaunchedEffect(Unit) {
        Library.load()
        AppPreloader.preload()
    }
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Background),
        contentAlignment = Alignment.Center
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            // Logo：APP 图标
            androidx.compose.foundation.Image(
                painter = androidx.compose.ui.res.painterResource(app.star2936.guava3291.R.drawable.app_logo),
                contentDescription = null,
                modifier = Modifier.size(96.dp).clip(RoundedCornerShape(24.dp))
            )
            Spacer(Modifier.height(16.dp))
            Text("流萤音乐", color = Color(0xFFECECEC), fontSize = 24.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(6.dp))
            Text("v1.0.0", color = TextSecondary, fontSize = 12.sp)
        }
    }
}
