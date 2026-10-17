package app.star2936.guava3291.ui.sidebar

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.DirectionsBus
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.DirectionsRun
import androidx.compose.material.icons.filled.Eco
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Nightlight
import androidx.compose.material.icons.filled.NightsStay
import androidx.compose.material.icons.filled.SentimentSatisfied
import androidx.compose.material.icons.filled.Speaker
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.star2936.guava3291.state.AuthManager
import app.star2936.guava3291.state.ListenMode
import app.star2936.guava3291.state.PlayerManager
import app.star2936.guava3291.ui.theme.Accent

// 对应 iOS SidebarView.swift：听歌模式 + 场景音乐宫格 + 品牌区

private data class SceneItem(val icon: ImageVector, val title: String)

private val scenes = listOf(
    SceneItem(Icons.Filled.DirectionsBus, "通勤必听"),
    SceneItem(Icons.Filled.DirectionsCar, "驾车"),
    SceneItem(Icons.Filled.WbSunny, "起床"),
    SceneItem(Icons.Filled.Nightlight, "深夜 EMO"),
    SceneItem(Icons.Filled.Speaker, "DJ 模式"),
    SceneItem(Icons.Filled.NightsStay, "助眠模式"),
    SceneItem(Icons.Filled.DirectionsRun, "动感健身"),
    SceneItem(Icons.Filled.MusicNote, "抖音漫游"),
    SceneItem(Icons.Filled.WaterDrop, "洗澡"),
    SceneItem(Icons.Filled.Eco, "Chill 放松"),
    SceneItem(Icons.Filled.SentimentSatisfied, "快乐时光"),
    SceneItem(Icons.Filled.Mic, "电音"),
)

@Composable
fun SidebarContent(onClose: () -> Unit) {
    val listenMode by PlayerManager.listenMode.collectAsState()
    val user by AuthManager.currentUser.collectAsState()
    // 用户是否有作品（没有则不显示"我的作品"按钮）
    var hasWorks by remember { mutableStateOf<Boolean?>(null) }
    LaunchedEffect(user?.id) {
        val uid = user?.id ?: run { hasWorks = false; return@LaunchedEffect }
        try {
            val r = app.star2936.guava3291.data.Api.myTracks(page = 1, pageSize = 1)
            hasWorks = r.list.isNotEmpty()
        } catch (_: Exception) {
            hasWorks = false
        }
    }

    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 0.dp)
    ) {
        // 顶部品牌区
        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(top = 30.dp, bottom = 26.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            androidx.compose.foundation.Image(
                painter = androidx.compose.ui.res.painterResource(app.star2936.guava3291.R.drawable.app_logo),
                contentDescription = null,
                modifier = Modifier.size(40.dp).clip(RoundedCornerShape(10.dp))
            )
            Spacer(Modifier.width(12.dp))
            Column {
                Text("流萤音乐", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Black)
                Text(
                    user?.let { if (!it.signature.isNullOrEmpty()) it.signature else if (it.name.isNotEmpty()) it.name else "已登录" } ?: "登录后推荐更精准",
                    color = Color.White.copy(alpha = 0.5f), fontSize = 12.sp
                )
            }
        }

        // 听歌模式
        Text("听歌模式", color = Color.White.copy(alpha = 0.45f), fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(horizontal = 22.dp).padding(bottom = 10.dp))
        ListenMode.entries.forEach { mode ->
            // 用户没有作品时不显示"我的作品"按钮
            if (mode == ListenMode.Works && hasWorks == false) return@forEach
            SidebarModeButton(
                title = mode.label,
                icon = modeIcon(mode),
                selected = listenMode == mode,
                onClick = {
                    PlayerManager.applyListenMode(mode)
                    onClose()
                }
            )
        }
        Spacer(Modifier.height(22.dp))

        // 场景音乐
        Text("场景音乐", color = Color.White.copy(alpha = 0.45f), fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(horizontal = 22.dp).padding(bottom = 10.dp))
        LazyVerticalGrid(
            columns = GridCells.Fixed(3),
            modifier = Modifier
                .fillMaxWidth()
                .height(92.dp * (scenes.size / 3 + 1)),
            horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp),
            verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(22.dp),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp),
        ) {
            items(scenes) { item ->
                SceneGridItem(icon = item.icon, title = item.title)
            }
        }
        Spacer(Modifier.height(12.dp))
    }
}

private fun modeIcon(mode: ListenMode): ImageVector = when (mode) {
    ListenMode.Normal -> Icons.Filled.AutoAwesome
    ListenMode.Works -> Icons.Filled.MusicNote
    ListenMode.Liked -> Icons.Filled.Favorite
    ListenMode.Fresh -> Icons.Filled.Bolt
}

@Composable
private fun SidebarModeButton(title: String, icon: ImageVector, selected: Boolean, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp)
            .padding(vertical = 5.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(if (selected) Accent.copy(alpha = 0.16f) else Color.White.copy(alpha = 0.05f))
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp)
            .height(58.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            Modifier
                .size(38.dp)
                .clip(RoundedCornerShape(11.dp))
                .background(if (selected) Accent else Color.White.copy(alpha = 0.1f)),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                icon, contentDescription = null,
                tint = if (selected) Color(0xFF121214) else Color.White.copy(alpha = 0.85f),
                modifier = Modifier.size(16.dp)
            )
        }
        Spacer(Modifier.width(14.dp))
        Text(title, color = Color.White, fontSize = 16.sp, fontWeight = if (selected) FontWeight.Bold else FontWeight.SemiBold)
        Spacer(Modifier.weight(1f))
        if (selected) {
            Text("✓", color = Accent, fontSize = 13.sp, fontWeight = FontWeight.Bold)
        }
    }
}

@Composable
private fun SceneGridItem(icon: ImageVector, title: String) {
    Column(
        Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Box(
            Modifier
                .size(46.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(Color.White.copy(alpha = 0.08f)),
            contentAlignment = Alignment.Center
        ) {
            Icon(icon, contentDescription = null, tint = Color.White.copy(alpha = 0.92f), modifier = Modifier.size(20.dp))
        }
        Spacer(Modifier.height(9.dp))
        Text(title, color = Color.White.copy(alpha = 0.75f), fontSize = 12.sp, fontWeight = FontWeight.Medium)
    }
}
