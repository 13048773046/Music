package app.star2936.guava3291.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
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

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreenCompat(
    onBack: () -> Unit,
    onOpenProfileEdit: () -> Unit,
    onOpenChangePassword: () -> Unit,
    onOpenAbout: () -> Unit,
    onOpenLogin: () -> Unit = {},
) {
    val statusBarTop = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    var showSwitchDialog by remember { mutableStateOf(false) }
    var showLogoutDialog by remember { mutableStateOf(false) }
    var showLoginSheet by remember { mutableStateOf(false) }

    Box(Modifier.fillMaxSize().background(Background)) {
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(top = statusBarTop)
        ) {
            // Header
            Row(
                Modifier.padding(horizontal = 20.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    Modifier
                        .size(38.dp)
                        .clip(CircleShape)
                        .background(Card)
                        .clickable { onBack() },
                    contentAlignment = Alignment.Center
                ) {
                    Icon(Icons.Filled.ArrowBack, contentDescription = null, tint = TextPrimary, modifier = Modifier.size(18.dp))
                }
                Spacer(Modifier.width(12.dp))
                Column {
                    Text("设置", color = TextPrimary, fontSize = 30.sp, fontWeight = FontWeight.Bold)
                    Text("账号、通用与关于", color = TextSecondary, fontSize = 12.sp)
                }
            }

            Spacer(Modifier.height(12.dp))

            // 账号
            GroupTitle("账号")
            SectionCard {
                NavRow(Icons.Filled.AccountCircle, Accent, "修改用户信息", onClick = onOpenProfileEdit)
                DividerLine()
                NavRow(Icons.Filled.Lock, Color(0xFF5AC8FA), "修改密码", onClick = onOpenChangePassword)
            }

            Spacer(Modifier.height(24.dp))

            // 通用
            GroupTitle("通用")
            SectionCard {
                ActionRow(Icons.Filled.Delete, Color(0xFFFF9500), "清理缓存", value = null, showChevron = false, onClick = {})
                DividerLine()
                ActionRow(Icons.Filled.Refresh, Lilac, "检查更新", value = "v1.0.0", showChevron = true, onClick = {})
            }

            Spacer(Modifier.height(24.dp))

            // 关于
            GroupTitle("关于")
            SectionCard {
                NavRow(Icons.Filled.Info, Lilac, "关于 APP", onClick = onOpenAbout)
            }

            Spacer(Modifier.height(24.dp))

            // 登录
            GroupTitle("登录")
            SectionCard {
                ActionRow(Icons.Filled.SwapHoriz, Accent, "切换账号", showChevron = false, onClick = { showSwitchDialog = true })
                DividerLine()
                ActionRow(Icons.Filled.Logout, Color(0xFFFF6B6B), "退出登录", showChevron = false, onClick = { showLogoutDialog = true })
            }

            Spacer(Modifier.height(40.dp))
        }
    }

    // 切换账号底部弹窗
    if (showSwitchDialog) {
        androidx.compose.material3.ModalBottomSheet(
            onDismissRequest = { showSwitchDialog = false },
            containerColor = Background,
            shape = RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp)
        ) {
            val user = app.star2936.guava3291.state.AuthManager.currentUser.value
            Column(Modifier.padding(bottom = 20.dp)) {
                // 头部
                Row(Modifier.padding(horizontal = 20.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("切换账号", color = TextPrimary, fontSize = 24.sp, fontWeight = FontWeight.Bold)
                        Text("选择本地保存的账号快速登录", color = TextSecondary, fontSize = 12.sp)
                    }
                    Box(
                        Modifier.size(34.dp).clip(CircleShape).background(Card).clickable { showSwitchDialog = false },
                        contentAlignment = Alignment.Center
                    ) { Text("✕", color = TextPrimary, fontSize = 16.sp) }
                }
                Spacer(Modifier.height(8.dp))

                // 账号列表
                val savedList = app.star2936.guava3291.state.AuthManager.savedAccounts.collectAsState().value
                val currentId = app.star2936.guava3291.state.AuthManager.currentUser.value?.id
                Column(Modifier.padding(horizontal = 20.dp).clip(RoundedCornerShape(18.dp)).background(Card)) {
                    savedList.forEachIndexed { idx, u ->
                        Row(
                            Modifier.fillMaxWidth().clickable {
                                showSwitchDialog = false
                                if (u.id != currentId) {
                                    app.star2936.guava3291.state.AuthManager.switchTo(u)
                                }
                            }.padding(horizontal = 16.dp, vertical = 14.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            coil.compose.AsyncImage(
                                model = u.avatarURL,
                                contentDescription = null,
                                modifier = Modifier.size(48.dp).clip(CircleShape),
                                contentScale = androidx.compose.ui.layout.ContentScale.Crop
                            )
                            Spacer(Modifier.width(14.dp))
                            Column {
                                Text(u.name, color = TextPrimary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                                Text("账号 ${u.account}", color = TextSecondary, fontSize = 12.sp)
                            }
                            Spacer(Modifier.weight(1f))
                            Box(
                                Modifier.size(22.dp).clip(CircleShape)
                                    .background(if (u.id == currentId) Accent else Color.Transparent)
                                    .then(
                                        if (u.id != currentId) Modifier.border(1.5.dp, TextTertiary.copy(alpha = 0.5f), CircleShape) else Modifier
                                    ),
                                contentAlignment = Alignment.Center
                            ) {
                                if (u.id == currentId) Text("✓", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                            }
                        }
                        if (idx < savedList.size - 1) {
                            Box(Modifier.padding(start = 78.dp).fillMaxWidth().height(0.5.dp).background(CardBorder))
                        }
                    }

                    // 添加账号
                    Row(
                        Modifier.fillMaxWidth().clickable {
                            showSwitchDialog = false
                            onOpenLogin()
                        }.padding(horizontal = 16.dp, vertical = 14.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        // 虚线圆圈+加号
                        Box(
                            Modifier.size(48.dp).clip(CircleShape).background(AccentSoft),
                            contentAlignment = Alignment.Center
                        ) { Text("+", color = Accent, fontSize = 22.sp, fontWeight = FontWeight.SemiBold) }
                        Spacer(Modifier.width(14.dp))
                        Column {
                            Text("添加账号", color = TextPrimary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                            Text("登录新的账号", color = TextSecondary, fontSize = 12.sp)
                        }
                    }
                }
            }
        }
    }

    // 退出登录弹窗
    if (showLogoutDialog) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { showLogoutDialog = false },
            title = { Text("退出登录", color = TextPrimary, fontWeight = FontWeight.Bold) },
            text = { Text("确定要退出当前账号吗？", color = TextSecondary, fontSize = 14.sp) },
            confirmButton = {
                Text("退出", color = Color(0xFFFF6B6B), fontWeight = FontWeight.SemiBold, modifier = Modifier.clickable {
                    showLogoutDialog = false
                    app.star2936.guava3291.state.AuthManager.logout()
                })
            },
            dismissButton = {
                Text("取消", color = TextTertiary, modifier = Modifier.clickable { showLogoutDialog = false })
            }
        )
    }

}

@Composable
private fun GroupTitle(title: String) {
    Text(title, color = TextTertiary, fontSize = 12.sp, fontWeight = FontWeight.Medium, modifier = Modifier.padding(start = 24.dp, bottom = 8.dp))
}

@Composable
private fun SectionCard(content: @Composable ColumnScope.() -> Unit) {
    Column(
        Modifier
            .padding(horizontal = 20.dp)
            .clip(RoundedCornerShape(18.dp))
            .background(Card)
    ) {
        content()
    }
}

@Composable
private fun DividerLine() {
    Box(
        Modifier
            .padding(start = 56.dp)
            .fillMaxWidth()
            .height(0.5.dp)
            .background(CardBorder)
    )
}

@Composable
private fun RowScopeBase(icon: androidx.compose.ui.graphics.vector.ImageVector, tint: Color, title: String, value: String?, showChevron: Boolean, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable { onClick() }
            .padding(horizontal = 16.dp, vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            Modifier
                .size(28.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(tint.copy(alpha = 0.14f)),
            contentAlignment = Alignment.Center
        ) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
        }
        Spacer(Modifier.width(12.dp))
        Text(title, color = TextPrimary, fontSize = 15.sp)
        Spacer(Modifier.weight(1f))
        value?.let { Text(it, color = TextTertiary, fontSize = 13.sp) }
        if (showChevron) {
            Spacer(Modifier.width(4.dp))
            Text("›", color = TextTertiary.copy(alpha = 0.7f), fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun ActionRow(icon: androidx.compose.ui.graphics.vector.ImageVector, tint: Color, title: String, value: String? = null, showChevron: Boolean = true, onClick: () -> Unit) {
    RowScopeBase(icon, tint, title, value, showChevron, onClick)
}

@Composable
private fun NavRow(icon: androidx.compose.ui.graphics.vector.ImageVector, tint: Color, title: String, onClick: () -> Unit) {
    RowScopeBase(icon, tint, title, null, true, onClick)
}
