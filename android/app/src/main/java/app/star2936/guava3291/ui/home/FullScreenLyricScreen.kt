package app.star2936.guava3291.ui.home

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.star2936.guava3291.data.Track
import app.star2936.guava3291.state.PlayerManager
import app.star2936.guava3291.util.KRCLine
import kotlinx.coroutines.delay

/** 全屏歌词页（对应 iOS FullScreenLyricView 基础版） */
@Composable
fun FullScreenLyricScreen(
    track: Track,
    lines: List<KRCLine>,
    onDismiss: () -> Unit,
) {
    val progress by PlayerManager.progress.collectAsState()
    val duration by PlayerManager.duration.collectAsState()
    val currentTime = progress * duration

    val listState = rememberLazyListState()

    // 二分定位当前行
    val currentIndex = remember(lines, currentTime) {
        if (lines.isEmpty()) -1 else {
            var lo = 0; var hi = lines.size
            while (lo < hi) {
                val mid = (lo + hi) / 2
                if (lines[mid].start <= currentTime) lo = mid + 1 else hi = mid
            }
            lo - 1
        }
    }

    // 自动滚动到当前行
    LaunchedEffect(currentIndex) {
        if (currentIndex >= 0) {
            listState.animateScrollToItem(
                index = (currentIndex - 3).coerceAtLeast(0),
                scrollOffset = 0
            )
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color(0xFF121214))
            .statusBarsPadding()
            .navigationBarsPadding()
    ) {
        Column(Modifier.fillMaxSize()) {
            // 顶栏
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(Modifier.weight(1f)) {
                    Text(track.title, color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.Bold, maxLines = 1)
                    Text(track.artist ?: "未知歌手", color = Color.White.copy(alpha = 0.55f), fontSize = 12.sp)
                }
                Box(
                    Modifier.size(36.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.14f))
                        .clickable { onDismiss() },
                    contentAlignment = Alignment.Center
                ) {
                    Icon(Icons.Filled.Close, contentDescription = "关闭", tint = Color.White, modifier = Modifier.size(16.dp))
                }
            }

            // 歌词列表
            if (lines.isEmpty()) {
                Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(track.artist ?: "未知歌手", color = Color.White.copy(alpha = 0.55f), fontSize = 16.sp)
                        Spacer(Modifier.height(12.dp))
                        Text("该歌曲暂无歌词", color = Color.White.copy(alpha = 0.45f), fontSize = 20.sp)
                    }
                }
            } else {
                LazyColumn(
                    state = listState,
                    modifier = Modifier.weight(1f).fillMaxWidth().padding(horizontal = 24.dp),
                    contentPadding = PaddingValues(vertical = 100.dp),
                    verticalArrangement = Arrangement.spacedBy(20.dp)
                ) {
                    items(lines.size) { i ->
                        val line = lines[i]
                        val isCurrent = i == currentIndex
                        Text(
                            text = line.text,
                            color = if (isCurrent) Color.White else Color.White.copy(alpha = 0.35f),
                            fontSize = if (isCurrent) 22.sp else 16.sp,
                            fontWeight = if (isCurrent) FontWeight.Bold else FontWeight.Normal,
                            maxLines = 2,
                            modifier = Modifier.fillMaxWidth()
                        )
                    }
                }
            }

            // 底部进度
            Column(Modifier.padding(horizontal = 26.dp, vertical = 16.dp)) {
                Row {
                    Text(fmtTime(currentTime), color = Color.White.copy(alpha = 0.55f), fontSize = 12.sp)
                    Spacer(Modifier.weight(1f))
                    Text(fmtTime(duration), color = Color.White.copy(alpha = 0.55f), fontSize = 12.sp)
                }
                Spacer(Modifier.height(8.dp))
                Box(Modifier.fillMaxWidth().height(3.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.16f))) {
                    Box(
                        Modifier.fillMaxHeight().fillMaxWidth(progress.toFloat().coerceIn(0f, 1f))
                            .clip(CircleShape).background(Color.White.copy(alpha = 0.85f))
                    )
                }
            }
        }
    }
}

private fun fmtTime(s: Double): String {
    val t = s.toInt().coerceAtLeast(0)
    return "%d:%02d".format(t / 60, t % 60)
}
