package app.star2936.guava3291.ui.notifications

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.star2936.guava3291.ui.theme.*

@Composable
fun OfficialMessagesScreenCompat(onBack: () -> Unit) {
    val statusBarTop = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    var messages by remember { mutableStateOf<List<app.star2936.guava3291.data.OfficialMessage>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }

    LaunchedEffect(Unit) {
        try {
            messages = app.star2936.guava3291.data.Api.officialMessages().reversed()
        } catch (_: Exception) { }
        isLoading = false
    }

    Box(Modifier.fillMaxSize().background(Background)) {
        Column(Modifier.fillMaxSize().padding(top = statusBarTop)) {
            // Header
            Row(
                Modifier.padding(horizontal = 20.dp).padding(top = 10.dp, bottom = 6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    Modifier.size(38.dp).clip(CircleShape).background(Card).clickable { onBack() },
                    contentAlignment = Alignment.Center
                ) { Icon(Icons.Filled.ArrowBack, null, tint = TextPrimary, modifier = Modifier.size(18.dp)) }
                Spacer(Modifier.width(12.dp))
                Text("官方消息", color = TextPrimary, fontSize = 20.sp, fontWeight = FontWeight.Bold)
            }

            // 聊天内容
            Column(
                Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp)
            ) {
                Text(
                    "仅流萤音乐官方可发送，无法回复",
                    color = TextTertiary.copy(alpha = 0.8f),
                    fontSize = 11.sp,
                    modifier = Modifier.padding(top = 10.dp, bottom = 6.dp).align(Alignment.CenterHorizontally)
                )

                if (isLoading) {
                    Text("加载中…", color = TextTertiary, fontSize = 13.sp, modifier = Modifier.padding(top = 40.dp).align(Alignment.CenterHorizontally))
                } else if (messages.isEmpty()) {
                    Text("暂无官方通知", color = TextTertiary, fontSize = 13.sp, modifier = Modifier.padding(top = 40.dp).align(Alignment.CenterHorizontally))
                } else {
                messages.forEachIndexed { index, msg ->
                    val showHeader = index == 0
                    Column(Modifier.padding(vertical = 4.dp)) {
                        if (showHeader) {
                            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 6.dp, bottom = 4.dp)) {
                                Box(
                                    Modifier.size(28.dp).clip(CircleShape).background(Accent.copy(alpha = 0.15f)),
                                    contentAlignment = Alignment.Center
                                ) {
                                    androidx.compose.foundation.Image(
                                        painter = androidx.compose.ui.res.painterResource(app.star2936.guava3291.R.drawable.app_logo),
                                        contentDescription = null,
                                        modifier = Modifier.size(28.dp).clip(CircleShape),
                                        contentScale = androidx.compose.ui.layout.ContentScale.Crop
                                    )
                                }
                                Spacer(Modifier.width(8.dp))
                                Text(msg.sender ?: "流萤音乐官方", color = TextTertiary, fontSize = 12.sp, fontWeight = FontWeight.Medium)
                            }
                        }
                        Box(
                            Modifier
                                .clip(RoundedCornerShape(topStart = 4.dp, topEnd = 16.dp, bottomStart = 16.dp, bottomEnd = 16.dp))
                                .background(Card)
                                .padding(horizontal = 14.dp, vertical = 10.dp)
                        ) {
                            Text(msg.content, color = TextPrimary, fontSize = 14.sp)
                        }
                    }
                }
                }

                Text(
                    "— 已显示全部官方通知 —",
                    color = TextTertiary.copy(alpha = 0.7f),
                    fontSize = 10.sp,
                    modifier = Modifier.padding(top = 14.dp, bottom = 20.dp).align(Alignment.CenterHorizontally)
                )
            }
        }
    }
}
