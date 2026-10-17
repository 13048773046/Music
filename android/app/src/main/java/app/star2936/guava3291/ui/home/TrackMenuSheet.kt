package app.star2936.guava3291.ui.home

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.star2936.guava3291.data.Track
import app.star2936.guava3291.ui.theme.Card
import app.star2936.guava3291.ui.theme.CardBorder
import app.star2936.guava3291.ui.theme.TextSecondary
import app.star2936.guava3291.ui.theme.TextTertiary

/** 音效选项（对应 iOS eqOptions） */
val eqOptions = listOf(
    "原音",
    "3D 立体音效",
    "360 环绕",
    "复古",
    "现场",
    "流行",
    "摇滚",
)

/**
 * 播放页歌名右侧三点菜单弹出的底部 Sheet。
 * 上半：封面+歌名/歌手；下半：添加到歌单 / 音效 / 全屏播放。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TrackMenuSheet(
    track: Track,
    eqName: String,
    onDismiss: () -> Unit,
    onEQ: () -> Unit,
    onFullScreen: () -> Unit,
    onAddToPlaylist: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var showEQPicker by remember { mutableStateOf(false) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = Card,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 24.dp)
        ) {
            // 上半：封面 + 歌名/歌手
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 20.dp, vertical = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                coil.compose.AsyncImage(
                    model = track.coverURL,
                    contentDescription = null,
                    modifier = Modifier
                        .size(52.dp)
                        .clip(RoundedCornerShape(10.dp))
                        .background(CardBorder),
                    contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                )
                Spacer(Modifier.width(14.dp))
                Column {
                    Text(
                        track.title,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = Color.White,
                        maxLines = 1,
                    )
                    Text(
                        track.displayAuthor,
                        fontSize = 13.sp,
                        color = TextSecondary,
                        maxLines = 1,
                    )
                }
            }

            // 分隔线
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(0.5.dp)
                    .background(CardBorder)
            )

            // 操作项
            MenuRow(
                icon = Icons.Default.LibraryMusic,
                label = "添加到歌单",
                onClick = { onDismiss(); onAddToPlaylist() },
            )
            MenuRow(
                icon = Icons.Default.GraphicEq,
                label = "音效",
                trailing = eqName,
                onClick = { onDismiss(); onEQ() },
            )
            MenuRow(
                icon = Icons.Default.Fullscreen,
                label = "全屏播放",
                onClick = { onDismiss(); onFullScreen() },
            )
        }
    }
}

@Composable
private fun MenuRow(
    icon: ImageVector,
    label: String,
    trailing: String = "",
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 20.dp, vertical = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = TextSecondary, modifier = Modifier.size(22.dp))
        Spacer(Modifier.width(16.dp))
        Text(label, fontSize = 16.sp, color = Color.White)
        Spacer(Modifier.weight(1f))
        if (trailing.isNotEmpty()) {
            Text(trailing, fontSize = 13.sp, color = TextTertiary)
        }
    }
}
