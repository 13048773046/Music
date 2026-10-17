package app.star2936.guava3291.ui.login

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.star2936.guava3291.state.AuthManager
import app.star2936.guava3291.ui.theme.Accent
import app.star2936.guava3291.ui.theme.Background
import app.star2936.guava3291.ui.theme.Card
import app.star2936.guava3291.ui.theme.CardBorder
import app.star2936.guava3291.ui.theme.TextPrimary
import app.star2936.guava3291.ui.theme.TextSecondary
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream

// 对应 iOS LoginView：登录 / 注册（账号后端自动生成 6 位数字，注册成功无弹窗）
@Composable
fun LoginScreen(onLoginSuccess: () -> Unit = {}) {
    var isRegister by remember { mutableStateOf(false) }
    var account by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var name by remember { mutableStateOf("") }
    var gender by remember { mutableStateOf("保密") }
    var ageText by remember { mutableStateOf("") }
    var signature by remember { mutableStateOf("") }
    var avatarData by remember { mutableStateOf<ByteArray?>(null) }
    var avatarBitmap by remember { mutableStateOf<android.graphics.Bitmap?>(null) }
    var bgData by remember { mutableStateOf<ByteArray?>(null) }
    var bgBitmap by remember { mutableStateOf<android.graphics.Bitmap?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val genders = listOf("男", "女", "保密")

    val canSubmit = !busy && password.isNotEmpty() &&
        (if (isRegister) name.trim().isNotEmpty() else account.trim().isNotEmpty())

    // 图片选择：头像 / 背景
    val context = androidx.compose.ui.platform.LocalContext.current

    fun decodeAndStore(ctx: android.content.Context, uri: Uri, storeAvatar: Boolean) {
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                try {
                    val decoded = decodeUri(ctx, uri) ?: return@withContext null
                    scaleAndEncode(decoded)
                } catch (_: Exception) { null }
            }
            if (result != null) {
                if (storeAvatar) {
                    avatarBitmap = result.first
                    avatarData = result.second
                } else {
                    bgBitmap = result.first
                    bgData = result.second
                }
            }
        }
    }

    val avatarPicker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        uri?.let { decodeAndStore(context, it, storeAvatar = true) }
    }
    val bgPicker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        uri?.let { decodeAndStore(context, it, storeAvatar = false) }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Background)
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(24.dp)
                .padding(top = 36.dp),
        ) {
            // Logo + App 名
            Box(
                modifier = Modifier
                    .size(76.dp)
                    .clip(RoundedCornerShape(20.dp))
                    .background(Brush.linearGradient(listOf(Accent, Color(0xFF2FA97C)))),
                contentAlignment = Alignment.Center
            ) {
                Text("♪", color = Color(0xFF06281C), fontSize = 40.sp, fontWeight = FontWeight.Bold)
            }
            Spacer(Modifier.height(12.dp))
            Text("流萤音乐", color = TextPrimary, fontSize = 24.sp, fontWeight = FontWeight.Bold)

            Spacer(Modifier.height(16.dp))

            if (isRegister) {
                // 背景图选择
                BackgroundPicker(bgBitmap = bgBitmap, onClick = { bgPicker.launch("image/*") })
                Spacer(Modifier.height(12.dp))
                // 头像选择
                AvatarPicker(avatarBitmap = avatarBitmap, onClick = { avatarPicker.launch("image/*") })
                Spacer(Modifier.height(12.dp))
                // 昵称
                field("昵称", value = name, onChange = { name = it })
                Spacer(Modifier.height(12.dp))
                // 性别行
                GenderRow(genders, selected = gender, onSelect = { gender = it })
                Spacer(Modifier.height(12.dp))
                // 年龄
                field("年龄", value = ageText, onChange = { ageText = it }, numberPad = true)
                Spacer(Modifier.height(12.dp))
                // 签名
                field("签名（一句话介绍自己）", value = signature, onChange = { signature = it })
                Spacer(Modifier.height(10.dp))
                Text(
                    "账号将由系统自动生成 6 位数字，注册成功后请牢记",
                    color = TextSecondary, fontSize = 12.sp
                )
                Spacer(Modifier.height(8.dp))
            } else {
                field("账号", value = account, onChange = { account = it })
                Spacer(Modifier.height(12.dp))
            }

            // 密码
            PasswordField("密码", value = password, onChange = { password = it })
            Spacer(Modifier.height(16.dp))

            // 提交按钮
            Button(
                onClick = {
                    busy = true
                    error = null
                    scope.launch {
                        try {
                            if (isRegister) {
                                AuthManager.register(
                                    password = password,
                                    name = name.trim(),
                                    avatarData = avatarData,
                                    gender = gender,
                                    age = ageText.toIntOrNull() ?: 0,
                                    signature = signature.trim(),
                                    backgroundData = bgData,
                                )
                            } else {
                                AuthManager.login(
                                    account = account.trim(),
                                    password = password,
                                )
                            }
                        } catch (e: Exception) {
                            error = e.message ?: "操作失败"
                        }
                        busy = false
                        // 登录/注册成功后自动返回
                        if (error == null) onLoginSuccess()
                    }
                },
                enabled = canSubmit,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(50.dp),
                shape = RoundedCornerShape(14.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = Accent,
                    disabledContainerColor = Accent.copy(alpha = 0.4f),
                    contentColor = Color.White,
                    disabledContentColor = Color.White.copy(alpha = 0.7f)
                ),
            ) {
                if (busy) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), color = Color.White, strokeWidth = 2.dp)
                } else {
                    Text(if (isRegister) "注册并进入" else "登录", fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                }
            }
            Spacer(Modifier.height(12.dp))

            // 切换登录/注册
            Text(
                text = if (isRegister) "已有账号？去登录" else "没有账号？注册新账号",
                color = TextSecondary,
                fontSize = 13.sp,
                modifier = Modifier
                    .align(Alignment.CenterHorizontally)
                    .clip(RoundedCornerShape(6.dp))
                    .clickable {
                        isRegister = !isRegister
                        error = null
                    }
                    .padding(6.dp)
            )
            Spacer(Modifier.height(8.dp))

            error?.let {
                Text(it, color = Color(0xFFFF6B6B), fontSize = 13.sp)
            }
        }
    }
}

@Composable
private fun field(title: String, value: String, onChange: (String) -> Unit, numberPad: Boolean = false) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        placeholder = { Text(title, color = TextSecondary, fontSize = 15.sp) },
        modifier = Modifier.fillMaxWidth(),
        singleLine = true,
        shape = RoundedCornerShape(12.dp),
        keyboardOptions = if (numberPad) KeyboardOptions(keyboardType = KeyboardType.Number) else KeyboardOptions.Default,
        colors = OutlinedTextFieldDefaults.colors(
            focusedContainerColor = Card,
            unfocusedContainerColor = Card,
            focusedTextColor = TextPrimary,
            unfocusedTextColor = TextPrimary,
            cursorColor = Accent,
            focusedBorderColor = CardBorder,
            unfocusedBorderColor = CardBorder,
        )
    )
}

@Composable
private fun PasswordField(title: String, value: String, onChange: (String) -> Unit) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        placeholder = { Text(title, color = TextSecondary, fontSize = 15.sp) },
        modifier = Modifier.fillMaxWidth(),
        singleLine = true,
        visualTransformation = PasswordVisualTransformation(),
        shape = RoundedCornerShape(12.dp),
        colors = OutlinedTextFieldDefaults.colors(
            focusedContainerColor = Card,
            unfocusedContainerColor = Card,
            focusedTextColor = TextPrimary,
            unfocusedTextColor = TextPrimary,
            cursorColor = Accent,
            focusedBorderColor = CardBorder,
            unfocusedBorderColor = CardBorder,
        )
    )
}

@Composable
private fun GenderRow(genders: List<String>, selected: String, onSelect: (String) -> Unit) {
    Row(horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(10.dp)) {
        genders.forEach { g ->
            val isSel = selected == g
            Box(
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(10.dp))
                    .background(if (isSel) Accent else Card)
                    .clickable { onSelect(g) }
                    .padding(vertical = 10.dp),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    g,
                    color = if (isSel) Color.White else TextSecondary,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium
                )
            }
        }
    }
}

@Composable
private fun AvatarPicker(avatarBitmap: android.graphics.Bitmap?, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(76.dp)
            .clip(CircleShape)
            .background(Card)
            .border(1.dp, CardBorder, CircleShape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        if (avatarBitmap != null) {
            Image(
                bitmap = avatarBitmap.asImageBitmap(),
                contentDescription = "头像",
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Crop
            )
        } else {
            Icon(Icons.Outlined.Person, contentDescription = null, tint = Accent, modifier = Modifier.size(22.dp))
        }
    }
}

@Composable
private fun BackgroundPicker(bgBitmap: android.graphics.Bitmap?, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(90.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(Card)
            .border(1.dp, CardBorder, RoundedCornerShape(12.dp))
            .clickable(onClick = onClick),
    ) {
        if (bgBitmap != null) {
            Image(
                bitmap = bgBitmap.asImageBitmap(),
                contentDescription = "背景图",
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Crop
            )
        } else {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Icon(Icons.Outlined.PhotoLibrary, contentDescription = null, tint = Accent, modifier = Modifier.size(20.dp))
            }
        }
        Box(
            modifier = Modifier
                .align(Alignment.BottomStart)
                .padding(10.dp)
                .clip(RoundedCornerShape(6.dp))
                .background(Color.Black.copy(alpha = 0.45f))
                .padding(horizontal = 8.dp, vertical = 4.dp)
        ) {
            Text(
                if (bgBitmap == null) "选择个人页背景图" else "更换背景图",
                color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.Medium
            )
        }
    }
}

// 工具：解析 URI → 缩放 → JPEG 编码
private fun decodeUri(context: android.content.Context, uri: Uri): android.graphics.Bitmap? {
    val resolver = context.contentResolver
    return try {
        val input = resolver.openInputStream(uri) ?: return null
        val bytes = input.use { it.readBytes() }
        android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
    } catch (_: Exception) { null }
}

private fun scaleAndEncode(bmp: android.graphics.Bitmap): Pair<android.graphics.Bitmap, ByteArray> {
    // 头像/背景统一限制长边 1200px，高质量 JPEG 肉眼无损
    val maxSide = 1200f
    val w = bmp.width.toFloat()
    val h = bmp.height.toFloat()
    val scale = if (w > h && w > maxSide) maxSide / w
                else if (h > w && h > maxSide) maxSide / h
                else if (w == h && w > maxSide) maxSide / w
                else 1f
    val scaled = if (scale < 1f) {
        android.graphics.Bitmap.createScaledBitmap(bmp, (w * scale).toInt(), (h * scale).toInt(), true)
    } else bmp
    val bos = ByteArrayOutputStream()
    scaled.compress(android.graphics.Bitmap.CompressFormat.JPEG, 95, bos)
    return scaled to bos.toByteArray()
}
