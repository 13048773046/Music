package app.star2936.guava3291.ui.comment

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AddPhotoAlternate
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.star2936.guava3291.data.Api
import app.star2936.guava3291.data.BehaviorEvent
import app.star2936.guava3291.data.Comment
import app.star2936.guava3291.data.Track
import app.star2936.guava3291.state.AuthManager
import app.star2936.guava3291.ui.theme.Accent
import app.star2936.guava3291.ui.theme.AccentSoft
import app.star2936.guava3291.ui.theme.Background
import app.star2936.guava3291.ui.theme.Card
import app.star2936.guava3291.ui.theme.TextPrimary
import app.star2936.guava3291.ui.theme.TextSecondary
import app.star2936.guava3291.ui.theme.TextTertiary
import coil.compose.AsyncImage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
fun CommentSheet(track: Track, highlightCommentId: String? = null, onDismiss: () -> Unit) {
    var comments by remember { mutableStateOf<List<Comment>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var text by remember { mutableStateOf("") }
    var sending by remember { mutableStateOf(false) }
    var uploadingImages by remember { mutableStateOf(false) }
    var pendingImages by remember { mutableStateOf<List<String>>(emptyList()) }
    var previewImage by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val listState = rememberLazyListState()
    val context = LocalContext.current

    suspend fun load() {
        loading = true
        comments = try { Api.fetchComments(track.id) } catch (_: Exception) { emptyList() }
        loading = false
    }

    LaunchedEffect(Unit) {
        if (AuthManager.currentUserValue != null) {
            Api.reportBehavior(listOf(BehaviorEvent(trackId = track.id, event = "comment_open", value = 1.0)))
        }
        load()
    }

    LaunchedEffect(comments, highlightCommentId) {
        val target = highlightCommentId ?: return@LaunchedEffect
        val idx = comments.indexOfFirst { it.id == target }
        if (idx >= 0) listState.animateScrollToItem(idx)
    }

    // 选图
    val pickImage = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri: Uri? ->
        uri ?: return@rememberLauncherForActivityResult
        scope.launch {
            uploadingImages = true
            try {
                val bytes = withContext(Dispatchers.IO) {
                    context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                } ?: return@launch
                val name = Api.uploadCommentImage(bytes, "comment_${System.currentTimeMillis()}.jpg")
                pendingImages = pendingImages + name
            } catch (_: Exception) { }
            uploadingImages = false
        }
    }

    fun send() {
        val u = AuthManager.currentUserValue ?: return
        if (text.trim().isEmpty() && pendingImages.isEmpty()) return
        sending = true
        scope.launch {
            try {
                Api.postComment(
                    trackId = track.id, userId = u.id, userName = u.name,
                    content = text.trim(), images = pendingImages
                )
                text = ""
                pendingImages = emptyList()
                load()
                Api.reportBehavior(listOf(BehaviorEvent(trackId = track.id, event = "comment", value = 1.0)))
            } catch (_: Exception) {}
            sending = false
        }
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(Background)
            .statusBarsPadding()
            .navigationBarsPadding()
            .imePadding()
    ) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text("评论 ${comments.size}", color = TextPrimary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            Text("✕", color = TextSecondary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { onDismiss() }.padding(8.dp))
        }

        Box(Modifier.fillMaxSize().weight(1f)) {
            when {
                loading -> CircularProgressIndicator(color = Accent, strokeWidth = 2.dp,
                    modifier = Modifier.align(Alignment.Center).size(26.dp))
                comments.isEmpty() -> Column(
                    Modifier.fillMaxSize(),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center
                ) {
                    Text("💬", fontSize = 30.sp)
                    Spacer(Modifier.height(10.dp))
                    Text("还没有评论，来抢沙发", color = TextSecondary, fontSize = 14.sp)
                }
                else -> LazyColumn(state = listState, modifier = Modifier.fillMaxSize()) {
                    items(comments, key = { it.id }) { c ->
                        CommentRow(c = c, highlighted = c.id == highlightCommentId,
                            onImageClick = { previewImage = c.commentImageURL })
                    }
                }
            }
        }

        // 已选图片缩略图行
        if (pendingImages.isNotEmpty() || uploadingImages) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                pendingImages.forEach { name ->
                    Box {
                        AsyncImage(
                            model = name,
                            contentDescription = null,
                            modifier = Modifier.size(56.dp).clip(RoundedCornerShape(8.dp)),
                            contentScale = ContentScale.Crop
                        )
                        Icon(
                            Icons.Outlined.Close, contentDescription = null, tint = Color.White,
                            modifier = Modifier.align(Alignment.TopEnd)
                                .size(18.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.6f))
                                .clickable { pendingImages = pendingImages - name }
                        )
                    }
                }
                if (uploadingImages) {
                    CircularProgressIndicator(color = Accent, strokeWidth = 2.dp,
                        modifier = Modifier.size(56.dp).padding(14.dp))
                }
            }
        }

        Row(
            Modifier.fillMaxWidth().background(Background).padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            // 选图按钮
            Icon(
                Icons.Outlined.AddPhotoAlternate, contentDescription = "添加图片", tint = TextSecondary,
                modifier = Modifier.size(26.dp).clickable { pickImage.launch("image/*") }
            )
            Spacer(Modifier.width(10.dp))
            TextField(
                value = text,
                onValueChange = { text = it },
                placeholder = { Text("发条友善的评论…", color = TextTertiary, fontSize = 14.sp) },
                singleLine = true,
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = Card, unfocusedContainerColor = Card,
                    focusedTextColor = TextPrimary, unfocusedTextColor = TextPrimary,
                    cursorColor = Accent,
                    focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent,
                ),
                modifier = Modifier.weight(1f).clip(RoundedCornerShape(18.dp))
            )
            Spacer(Modifier.width(10.dp))
            if (sending) {
                CircularProgressIndicator(color = Accent, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
            } else {
                Text("发送",
                    color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(if (text.trim().isEmpty() && pendingImages.isEmpty()) Accent.copy(alpha = 0.4f) else Accent)
                        .clickable(enabled = text.trim().isNotEmpty() || pendingImages.isNotEmpty()) { send() }
                        .padding(horizontal = 16.dp, vertical = 10.dp)
                )
            }
        }
    }

    // 大图预览
    previewImage?.let { url ->
        AlertDialog(
            onDismissRequest = { previewImage = null },
            confirmButton = { Text("关闭", color = Accent, modifier = Modifier.clickable { previewImage = null }) },
            text = {
                AsyncImage(model = url, contentDescription = null,
                    modifier = Modifier.fillMaxWidth().height(300.dp).clip(RoundedCornerShape(12.dp)),
                    contentScale = ContentScale.Fit)
            },
            containerColor = Background
        )
    }
}

@Composable
private fun CommentRow(c: Comment, highlighted: Boolean, onImageClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth()
            .padding(horizontal = 10.dp, vertical = 8.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(if (highlighted) Accent.copy(alpha = 0.14f) else Color.Transparent)
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalAlignment = Alignment.Top
    ) {
        Box(Modifier.size(36.dp).clip(CircleShape).background(AccentSoft), contentAlignment = Alignment.Center) {
            if (!c.userId.isNullOrEmpty()) {
                AsyncImage(model = Api.avatarUrl(c.userId), contentDescription = null,
                    modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            } else {
                Icon(Icons.Outlined.Person, contentDescription = null, tint = Accent, modifier = Modifier.size(15.dp))
            }
        }
        Spacer(Modifier.width(10.dp))
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(c.userName.ifEmpty { "用户" }, color = Accent, fontSize = 13.sp, fontWeight = FontWeight.Medium)
            Text(c.content, color = TextPrimary, fontSize = 14.sp)
            if (!c.commentImageURL.isNullOrEmpty()) {
                Spacer(Modifier.height(4.dp))
                AsyncImage(
                    model = c.commentImageURL,
                    contentDescription = null,
                    modifier = Modifier.size(120.dp).clip(RoundedCornerShape(10.dp)).clickable { onImageClick() },
                    contentScale = ContentScale.Crop
                )
            }
        }
    }
}
