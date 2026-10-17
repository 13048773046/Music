package app.star2936.guava3291.ui.profile

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.star2936.guava3291.data.Api
import app.star2936.guava3291.data.Track
import app.star2936.guava3291.data.UserProfile
import app.star2936.guava3291.state.PlayerManager
import app.star2936.guava3291.ui.components.StatusPlaceholder
import app.star2936.guava3291.ui.components.TrackRow
import app.star2936.guava3291.ui.theme.Accent
import app.star2936.guava3291.ui.theme.Background
import app.star2936.guava3291.ui.theme.TextPrimary
import app.star2936.guava3291.ui.theme.TextSecondary
import coil.compose.AsyncImage
import kotlinx.coroutines.launch

/** 用户主页（对应 iOS UserProfileView） */
@Composable
fun UserProfileScreen(userId: String, onBack: () -> Unit) {
    var profile by remember { mutableStateOf<UserProfile?>(null) }
    var tracks by remember { mutableStateOf<List<Track>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    val scope = rememberCoroutineScope()

    LaunchedEffect(userId) {
        try {
            profile = Api.fetchUserProfile(userId)
            tracks = Api.fetchUserTracks(userId)
        } catch (_: Exception) { }
        loading = false
    }

    Column(Modifier.fillMaxSize().background(Background).statusBarsPadding()) {
        Box(Modifier.fillMaxWidth().height(200.dp)) {
            // 背景图
            profile?.backgroundURL?.let {
                AsyncImage(
                    model = it, contentDescription = null,
                    modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop
                )
            }
            IconButton(onClick = onBack, modifier = Modifier.padding(8.dp)) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回", tint = Color.White)
            }
        }

        if (loading) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                androidx.compose.material3.CircularProgressIndicator(color = TextSecondary)
            }
        } else if (profile != null) {
            val p = profile!!
            Column(Modifier.padding(horizontal = 20.dp)) {
                // 头像重叠
                Box(Modifier.offset(y = (-40).dp)) {
                    AsyncImage(
                        model = p.avatarURL, contentDescription = null,
                        modifier = Modifier.size(80.dp).clip(CircleShape),
                        contentScale = ContentScale.Crop
                    )
                }
                Text(p.name, fontSize = 22.sp, fontWeight = FontWeight.Bold, color = TextPrimary)
                p.signature?.let {
                    Spacer(Modifier.height(4.dp))
                    Text(it, fontSize = 13.sp, color = TextSecondary)
                }
                Spacer(Modifier.height(16.dp))

                // 统计
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceAround) {
                    StatItem(p.workCount, "作品")
                    StatItem(p.followerCount, "粉丝")
                    StatItem(p.followingCount, "关注")
                    StatItem(p.mutualCount, "互关")
                }

                Spacer(Modifier.height(16.dp))

                // 关注按钮
                Button(
                    onClick = {
                        scope.launch {
                            val following = Api.toggleFollow(userId)
                            profile = p.copy(isFollowing = following)
                        }
                    },
                    colors = ButtonDefaults.buttonColors(
                        containerColor = if (p.isFollowing) Color(0xFF2A2A2E) else Accent,
                        contentColor = if (p.isFollowing) TextSecondary else Color.White
                    ),
                    shape = RoundedCornerShape(20.dp)
                ) {
                    Text(if (p.isFollowing) "已关注" else "关注", fontSize = 14.sp)
                }
            }

            Spacer(Modifier.height(16.dp))
            Text("作品", Modifier.padding(horizontal = 20.dp), fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = TextPrimary)
            Spacer(Modifier.height(8.dp))

            if (tracks.isEmpty()) {
                StatusPlaceholder(text = "暂无作品", modifier = Modifier.fillMaxSize())
            } else {
                LazyColumn(Modifier.fillMaxSize()) {
                    items(tracks) { t ->
                        TrackRow(track = t, onClick = { PlayerManager.play(t, tracks) })
                    }
                }
            }
        }
    }
}

@Composable
private fun StatItem(count: Int, label: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text("$count", fontSize = 18.sp, fontWeight = FontWeight.Bold, color = TextPrimary)
        Text(label, fontSize = 12.sp, color = TextSecondary)
    }
}
