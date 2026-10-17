package app.star2936.guava3291.ui.upload

import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
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
import app.star2936.guava3291.ui.theme.*

@Composable
fun UploadScreenCompat(fileUri: Uri?, onBack: () -> Unit) {
    val statusBarTop = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    var title by remember { mutableStateOf("") }
    var artist by remember { mutableStateOf("") }
    var album by remember { mutableStateOf("") }

    Box(Modifier.fillMaxSize().background(Background)) {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(top = statusBarTop)
        ) {
            // Header
            Row(
                Modifier.padding(horizontal = 20.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    Modifier.size(38.dp).clip(CircleShape).background(Card).clickable { onBack() },
                    contentAlignment = Alignment.Center
                ) { Icon(Icons.Filled.ArrowBack, contentDescription = null, tint = TextPrimary, modifier = Modifier.size(18.dp)) }
                Spacer(Modifier.width(12.dp))
                Text("上传歌曲", color = TextPrimary, fontSize = 20.sp, fontWeight = FontWeight.Bold)
            }

            Spacer(Modifier.height(16.dp))

            // 歌曲信息
            Text("歌曲信息", color = TextTertiary, fontSize = 12.sp, fontWeight = FontWeight.Medium, modifier = Modifier.padding(start = 20.dp, bottom = 8.dp))
            Column(
                Modifier.padding(horizontal = 20.dp).clip(RoundedCornerShape(18.dp)).background(Card)
            ) {
                FormField("标题", title) { title = it }
                DividerLine()
                FormField("歌手", artist) { artist = it }
                DividerLine()
                FormField("专辑", album) { album = it }
            }

            Spacer(Modifier.height(24.dp))

            // 歌曲封面
            Text("歌曲封面", color = TextTertiary, fontSize = 12.sp, fontWeight = FontWeight.Medium, modifier = Modifier.padding(start = 20.dp, bottom = 8.dp))
            Column(
                Modifier.padding(horizontal = 20.dp).clip(RoundedCornerShape(18.dp)).background(Card).padding(16.dp)
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        Modifier.size(84.dp).clip(RoundedCornerShape(12.dp)).background(CardBorder),
                        contentAlignment = Alignment.Center
                    ) { Text("+", color = TextTertiary, fontSize = 26.sp) }
                    Spacer(Modifier.width(16.dp))
                    Text("选择封面", color = Accent, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                }
                Spacer(Modifier.height(8.dp))
                Text("必须选择封面后才能上传", color = Color(0xFFFF9500), fontSize = 12.sp)
            }

            Spacer(Modifier.height(24.dp))

            // 上传按钮
            Box(
                Modifier.padding(horizontal = 20.dp).fillMaxWidth()
                    .clip(RoundedCornerShape(14.dp)).background(Accent)
                    .clickable { },
                contentAlignment = Alignment.Center
            ) {
                Text("上传", color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(vertical = 14.dp))
            }

            Spacer(Modifier.height(40.dp))
        }
    }
}

@Composable
private fun FormField(label: String, value: String, onChange: (String) -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(label, color = TextTertiary, fontSize = 15.sp, modifier = Modifier.width(60.dp))
        BasicTextField(
            value = value,
            onValueChange = onChange,
            textStyle = androidx.compose.ui.text.TextStyle(color = TextPrimary, fontSize = 15.sp),
            modifier = Modifier.weight(1f)
        )
    }
}

@Composable
private fun DividerLine() {
    Box(Modifier.padding(start = 16.dp).fillMaxWidth().height(0.5.dp).background(CardBorder))
}
