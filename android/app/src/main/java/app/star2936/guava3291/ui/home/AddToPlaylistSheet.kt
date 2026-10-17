package app.star2936.guava3291.ui.home

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.star2936.guava3291.data.Api
import app.star2936.guava3291.data.Playlist
import app.star2936.guava3291.data.Track
import app.star2936.guava3291.ui.theme.Accent
import app.star2936.guava3291.ui.theme.Card
import app.star2936.guava3291.ui.theme.TextPrimary
import app.star2936.guava3291.ui.theme.TextSecondary
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddToPlaylistSheet(
    track: Track,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var playlists by remember { mutableStateOf<List<Playlist>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var showCreateDialog by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    suspend fun load() {
        playlists = Api.fetchPlaylists()
        loading = false
    }

    LaunchedEffect(Unit) { load() }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = Card,
    ) {
        Column(Modifier.fillMaxWidth().padding(bottom = 24.dp)) {
            Box(Modifier.fillMaxWidth().padding(vertical = 16.dp), contentAlignment = Alignment.Center) {
                Text("添加到歌单", fontSize = 17.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold, color = TextPrimary)
            }

            if (loading) {
                Box(Modifier.fillMaxWidth().height(200.dp), contentAlignment = Alignment.Center) {
                    androidx.compose.material3.CircularProgressIndicator(color = TextSecondary)
                }
            } else {
                LazyColumn(Modifier.fillMaxWidth()) {
                    items(playlists) { pl ->
                        PlaylistRow(pl) {
                            scope.launch {
                                Api.addToPlaylist(
                                    playlistId = pl.id,
                                    trackId = track.id,
                                    title = track.title,
                                    artist = track.displayAuthor,
                                    cover = track.cover
                                )
                                onDismiss()
                            }
                        }
                    }
                    // 创建新歌单按钮（与歌单封面同尺寸）
                    item {
                        Row(
                            Modifier.fillMaxWidth().clickable { showCreateDialog = true }
                                .padding(horizontal = 20.dp, vertical = 14.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Box(
                                Modifier.size(48.dp).clip(RoundedCornerShape(8.dp))
                                    .background(Accent.copy(alpha = 0.15f)),
                                contentAlignment = Alignment.Center
                            ) {
                                Icon(Icons.Default.Add, contentDescription = null, tint = Accent, modifier = Modifier.size(20.dp))
                            }
                            Spacer(Modifier.width(14.dp))
                            Text("创建新歌单", color = Accent, fontSize = 15.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.Medium)
                        }
                    }
                }
            }
        }
    }

    if (showCreateDialog) {
        var name by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { showCreateDialog = false },
            title = { Text("新建歌单", color = TextPrimary) },
            text = {
                OutlinedTextField(value = name, onValueChange = { name = it }, label = { Text("歌单名称") }, singleLine = true)
            },
            confirmButton = {
                TextButton(onClick = {
                    if (name.isNotBlank()) {
                        scope.launch {
                            try {
                                val pl = Api.createPlaylist(name.trim())
                                Api.addToPlaylist(pl.id, track.id, track.title, track.displayAuthor, track.cover)
                                showCreateDialog = false
                                onDismiss()
                            } catch (_: Exception) {}
                        }
                    }
                }) { Text("创建", color = Accent) }
            },
            dismissButton = { TextButton(onClick = { showCreateDialog = false }) { Text("取消", color = TextSecondary) } },
            containerColor = Card,
        )
    }
}

@Composable
private fun PlaylistRow(pl: Playlist, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 20.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        if (!pl.cover.isNullOrEmpty()) {
            coil.compose.AsyncImage(
                model = pl.cover,
                contentDescription = null,
                modifier = Modifier.size(48.dp).clip(RoundedCornerShape(8.dp)),
                contentScale = androidx.compose.ui.layout.ContentScale.Crop
            )
        } else {
            Box(
                Modifier.size(48.dp).clip(RoundedCornerShape(8.dp))
                    .background(androidx.compose.ui.graphics.Color(0xFF2A2A2E)),
                contentAlignment = Alignment.Center
            ) {
                Text(pl.name.take(1), color = Accent, fontSize = 16.sp)
            }
        }
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(pl.name, color = TextPrimary, fontSize = 15.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.Medium)
            Text("${pl.trackCount} 首", color = TextSecondary, fontSize = 12.sp)
        }
    }
}
