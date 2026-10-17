package app.star2936.guava3291.ui.settings

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
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import kotlinx.coroutines.launch
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.star2936.guava3291.ui.theme.*

@Composable
fun ProfileEditScreenCompat(onBack: () -> Unit) {
    val statusBarTop = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    var name by remember { mutableStateOf("") }
    var gender by remember { mutableStateOf("保密") }
    var ageText by remember { mutableStateOf("") }
    var signature by remember { mutableStateOf("") }
    val genders = listOf("男", "女", "保密")
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        val u = app.star2936.guava3291.state.AuthManager.currentUser.value ?: return@LaunchedEffect
        name = u.name; gender = u.gender ?: "保密"; signature = u.signature ?: ""
        ageText = (u.age ?: 0).let { if (it > 0) it.toString() else "" }
    }

    Box(Modifier.fillMaxSize().background(Background)) {
        Column(Modifier.fillMaxSize().padding(top = statusBarTop)) {
            Row(
                Modifier.padding(horizontal = 20.dp).padding(top = 10.dp, bottom = 6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    Modifier.size(38.dp).clip(CircleShape).background(Card).clickable { onBack() },
                    contentAlignment = Alignment.Center
                ) { Icon(Icons.Filled.ArrowBack, null, tint = TextPrimary, modifier = Modifier.size(18.dp)) }
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text("编辑资料", color = TextPrimary, fontSize = 30.sp, fontWeight = FontWeight.Bold)
                    Text("完善你的个人主页", color = TextSecondary, fontSize = 12.sp)
                }
                Text(
                    if (busy) "…" else "保存",
                    color = Accent, fontSize = 16.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clickable(enabled = !busy) {
                        busy = true
                        scope.launch {
                            try {
                                app.star2936.guava3291.state.AuthManager.updateProfile(
                                    name.trim(), gender, ageText.toIntOrNull() ?: 0, signature.trim(), null, null
                                )
                                onBack()
                            } catch (_: Exception) { busy = false }
                        }
                    }
                )
            }

            Column(
                Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(20.dp)
            ) {
                Box(
                    Modifier.fillMaxWidth().height(200.dp).clip(RoundedCornerShape(20.dp)).background(Card)
                ) {
                    // 背景图
                    val user = app.star2936.guava3291.state.AuthManager.currentUser.value
                    if (user?.backgroundURL != null) {
                        coil.compose.AsyncImage(
                            model = user.backgroundURL,
                            contentDescription = null,
                            modifier = Modifier.fillMaxWidth().height(160.dp),
                            contentScale = androidx.compose.ui.layout.ContentScale.Crop
                        )
                    } else {
                        Box(Modifier.fillMaxWidth().height(160.dp).background(Accent.copy(alpha = 0.2f)))
                    }
                    // 头像
                    coil.compose.AsyncImage(
                        model = user?.avatarURL,
                        contentDescription = null,
                        modifier = Modifier.padding(start = 16.dp).offset(y = 122.dp).size(76.dp).clip(CircleShape),
                        contentScale = androidx.compose.ui.layout.ContentScale.Crop
                    )
                }

                Spacer(Modifier.height(18.dp))

                Column(
                    Modifier.clip(RoundedCornerShape(18.dp)).background(Card).padding(18.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp)
                ) {
                    Text("昵称", color = TextTertiary, fontSize = 12.sp, fontWeight = FontWeight.Medium)
                    InputField("输入昵称", name) { name = it }

                    Text("性别", color = TextTertiary, fontSize = 12.sp, fontWeight = FontWeight.Medium)
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        genders.forEach { g ->
                            Box(
                                Modifier.weight(1f).clip(RoundedCornerShape(10.dp))
                                    .background(if (gender == g) Accent else Background)
                                    .clickable { gender = g }
                                    .padding(vertical = 10.dp),
                                contentAlignment = Alignment.Center
                            ) { Text(g, color = if (gender == g) Color.White else TextSecondary, fontSize = 14.sp) }
                        }
                    }

                    Text("年龄", color = TextTertiary, fontSize = 12.sp, fontWeight = FontWeight.Medium)
                    InputField("输入年龄", ageText) { ageText = it }

                    Text("签名", color = TextTertiary, fontSize = 12.sp, fontWeight = FontWeight.Medium)
                    InputField("一句话介绍自己", signature) { signature = it }
                }

                Spacer(Modifier.height(40.dp))
            }
        }
    }
}

@Composable
private fun InputField(hint: String, value: String, onChange: (String) -> Unit) {
    BasicTextField(
        value = value,
        onValueChange = onChange,
        textStyle = androidx.compose.ui.text.TextStyle(color = TextPrimary, fontSize = 15.sp),
        modifier = Modifier.clip(RoundedCornerShape(10.dp)).background(Background).padding(horizontal = 14.dp, vertical = 12.dp),
        decorationBox = { inner ->
            if (value.isEmpty()) Text(hint, color = TextTertiary, fontSize = 15.sp)
            inner()
        }
    )
}
