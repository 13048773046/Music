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
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import kotlinx.coroutines.launch
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.star2936.guava3291.ui.theme.*

@Composable
fun ChangePasswordScreenCompat(onBack: () -> Unit) {
    val statusBarTop = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    var oldPwd by remember { mutableStateOf("") }
    var newPwd by remember { mutableStateOf("") }
    var confirmPwd by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val scope = androidx.compose.runtime.rememberCoroutineScope()

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
                    Text("修改密码", color = TextPrimary, fontSize = 30.sp, fontWeight = FontWeight.Bold)
                    Text("设置新的登录密码", color = TextSecondary, fontSize = 12.sp)
                }
                Text(
                    if (busy) "…" else "确认",
                    color = Accent, fontSize = 16.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clickable(enabled = !busy) {
                        if (oldPwd.isEmpty()) { error = "请输入当前密码"; return@clickable }
                        if (newPwd.length !in 6..64) { error = "新密码长度需 6-64 位"; return@clickable }
                        if (newPwd != confirmPwd) { error = "两次输入的新密码不一致"; return@clickable }
                        error = null; busy = true
                        scope.launch {
                            try { app.star2936.guava3291.state.AuthManager.changePassword(oldPwd, newPwd); onBack() }
                            catch (e: Exception) { error = e.message; busy = false }
                        }
                    }
                )
            }

            Column(
                Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(20.dp)
            ) {
                Column(
                    Modifier.clip(RoundedCornerShape(18.dp)).background(Card)
                ) {
                    PwdField("当前密码", oldPwd) { oldPwd = it }
                    DividerLine()
                    PwdField("新密码（6-64 位）", newPwd) { newPwd = it }
                    DividerLine()
                    PwdField("确认新密码", confirmPwd) { confirmPwd = it }
                }
                error?.let { Text(it, color = Color(0xFFFF6B6B), fontSize = 13.sp, modifier = Modifier.padding(top = 12.dp)) }
                Spacer(Modifier.height(40.dp))
            }
        }
    }
}

@Composable
private fun PwdField(hint: String, value: String, onChange: (String) -> Unit) {
    BasicTextField(
        value = value,
        onValueChange = onChange,
        textStyle = androidx.compose.ui.text.TextStyle(color = TextPrimary, fontSize = 15.sp),
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 14.dp),
        decorationBox = { inner ->
            if (value.isEmpty()) Text(hint, color = TextTertiary, fontSize = 15.sp)
            inner()
        }
    )
}

@Composable
private fun DividerLine() {
    Box(Modifier.padding(start = 16.dp).fillMaxWidth().height(0.5.dp).background(CardBorder))
}
