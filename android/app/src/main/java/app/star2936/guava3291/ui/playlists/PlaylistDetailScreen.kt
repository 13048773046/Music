package app.star2936.guava3291.ui.playlists

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.star2936.guava3291.data.Api
import app.star2936.guava3291.data.Track
import app.star2936.guava3291.state.PlayerManager
import app.star2936.guava3291.ui.components.StatusPlaceholder
import app.star2936.guava3291.ui.components.TrackRow
import app.star2936.guava3291.ui.theme.Background
import app.star2936.guava3291.ui.theme.TextPrimary
import app.star2936.guava3291.ui.theme.TextSecondary

/** 歌单详情页（对应 iOS PlaylistDetailView） */
@Composable
fun PlaylistDetailScreen(playlistId: String, playlistName: String, onBack: () -> Unit) {
    var tracks by remember { mutableStateOf<List<Track>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }

    LaunchedEffect(playlistId) {
        tracks = Api.fetchPlaylistTracks(playlistId)
        loading = false
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(Background)
            .statusBarsPadding()
            .navigationBarsPadding()
    ) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回", tint = TextPrimary)
            }
            Spacer(Modifier.width(8.dp))
            Column {
                Text(playlistName, fontSize = 18.sp, fontWeight = FontWeight.Bold, color = TextPrimary)
                Text("${tracks.size} 首", fontSize = 12.sp, color = TextSecondary)
            }
        }

        when {
            loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                androidx.compose.material3.CircularProgressIndicator(color = TextSecondary)
            }
            tracks.isEmpty() -> StatusPlaceholder(text = "歌单为空", modifier = Modifier.fillMaxSize())
            else -> LazyColumn(Modifier.fillMaxSize()) {
                items(tracks) { t ->
                    TrackRow(track = t, onClick = { PlayerManager.play(t, tracks) })
                }
            }
        }
    }
}
