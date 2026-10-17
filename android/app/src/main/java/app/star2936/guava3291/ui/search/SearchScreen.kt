package app.star2936.guava3291.ui.search

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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.star2936.guava3291.data.Api
import app.star2936.guava3291.data.BehaviorEvent
import app.star2936.guava3291.data.Track
import app.star2936.guava3291.state.Library
import app.star2936.guava3291.state.PlayerManager
import app.star2936.guava3291.ui.components.CoverImage
import app.star2936.guava3291.ui.components.EqualizerBars
import app.star2936.guava3291.ui.theme.Card
import app.star2936.guava3291.ui.theme.TextPrimary
import app.star2936.guava3291.ui.theme.TextSecondary
import kotlinx.coroutines.launch

// 对应 iOS SearchView.swift：搜索框 + 结果列表 + 请求序号防旧响应

@Composable
fun SearchScreen(onBack: () -> Unit) {
    var keyword by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<Track>>(emptyList()) }
    var searching by remember { mutableStateOf(false) }
    var hasSearched by remember { mutableStateOf(false) }
    var searchToken by remember { mutableIntStateOf(0) }
    var history by remember { mutableStateOf<List<String>>(emptyList()) }
    val scope = androidx.compose.runtime.rememberCoroutineScope()

    LaunchedEffect(Unit) {
        try { history = Api.fetchSearchHistory() } catch (_: Exception) { }
    }

    fun doSearch() {
        val kw = keyword.trim()
        if (kw.isEmpty()) return
        hasSearched = true
        searching = true
        searchToken += 1
        val token = searchToken
        val ev = BehaviorEvent(trackId = "", event = "search", value = 0.0,
            meta = BehaviorEvent.metaJSON(mapOf("kw" to kw)))
        scope.launch { Api.reportBehavior(listOf(ev)) }
        scope.launch { Api.recordSearch(kw) }
        scope.launch {
            val found = try { Api.search(kw) } catch (_: Exception) { emptyList() }
            if (token == searchToken) {
                results = found
                searching = false
            }
        }
    }

    fun play(track: Track) {
        val kw = keyword.trim()
        if (kw.isEmpty()) {
            Library.searchContext.value = null
            PlayerManager.startRecommendedStream(startingAt = track, fallback = Library.tracks.value)
        } else {
            Library.startSearchStream(keyword = kw, first = track)
        }
        onBack()
    }

    Column(Modifier.fillMaxSize().background(app.star2936.guava3291.ui.theme.Background).statusBarsPadding()) {
        // 顶部导航行：返回 + 标题
        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text("‹", color = TextPrimary, fontSize = 28.sp,
                modifier = Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .clickable { onBack() }
                    .padding(horizontal = 10.dp, vertical = 4.dp))
            Text("搜索", color = TextPrimary, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
        }

        // 搜索框
        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .padding(top = 8.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(Card)
                .padding(horizontal = 14.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(Icons.Outlined.Search, contentDescription = null, tint = Color.White.copy(alpha = 0.5f), modifier = Modifier.size(15.dp))
            Spacer(Modifier.width(8.dp))
            TextField(
                value = keyword,
                onValueChange = { keyword = it },
                placeholder = { Text("输入歌名或歌手", color = Color.White.copy(alpha = 0.5f), fontSize = 15.sp) },
                singleLine = true,
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = Color.Transparent,
                    unfocusedContainerColor = Color.Transparent,
                    focusedTextColor = Color.White,
                    unfocusedTextColor = Color.White,
                    cursorColor = Color.White,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                    disabledIndicatorColor = Color.Transparent
                ),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onSearch = { doSearch() }),
                modifier = Modifier.weight(1f)
            )
            if (keyword.isNotEmpty()) {
                Icon(
                    Icons.Filled.Close, contentDescription = "清除",
                    tint = Color.White.copy(alpha = 0.5f),
                    modifier = Modifier
                        .size(15.dp)
                        .clip(RoundedCornerShape(8.dp))
                        .clickable {
                            keyword = ""
                            results = emptyList()
                            hasSearched = false
                        }
                )
            }
        }

        Box(Modifier.fillMaxSize()) {
            when {
                searching -> CircularProgressIndicator(
                    color = Color.White, strokeWidth = 2.dp,
                    modifier = Modifier.align(Alignment.Center).size(26.dp))
                results.isEmpty() && hasSearched -> EmptyHint("没找到「$keyword」相关歌曲", icon = "?")
                results.isEmpty() -> SearchHistoryView(
                    history = history,
                    onClear = {
                        scope.launch { Api.clearSearchHistory(); history = emptyList() }
                    },
                    onPick = { kw -> keyword = kw; doSearch() }
                )
                else -> LazyColumn(
                    Modifier.fillMaxSize(),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 16.dp),
                ) {
                    items(results, key = { it.id }) { track ->
                        SearchRow(track = track, onClick = { play(track) })
                    }
                }
            }
        }
    }
}

@Composable
private fun EmptyHint(text: String, icon: String) {
    Column(
        Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = androidx.compose.foundation.layout.Arrangement.Center
    ) {
        Text(if (icon == "search") "🔍" else "❓", fontSize = 40.sp)
        Spacer(Modifier.height(12.dp))
        Text(text, color = Color.White.copy(alpha = 0.5f), fontSize = 15.sp)
    }
}

@Composable
private fun SearchHistoryView(history: List<String>, onClear: () -> Unit, onPick: (String) -> Unit) {
    Column(Modifier.fillMaxSize().padding(20.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("搜索历史", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp, fontWeight = FontWeight.Medium)
            Spacer(Modifier.weight(1f))
            if (history.isNotEmpty()) {
                Text("清除", color = Color.White.copy(alpha = 0.4f), fontSize = 12.sp,
                    modifier = Modifier.clickable { onClear() })
            }
        }
        Spacer(Modifier.height(14.dp))
        if (history.isEmpty()) {
            Text("暂无搜索历史", color = Color.White.copy(alpha = 0.3f), fontSize = 13.sp)
        } else {
            // 流式标签
            val rows = remember(history) {
                val result = mutableListOf<List<String>>()
                var current = mutableListOf<String>()
                var width = 0
                history.forEach { tag ->
                    val w = tag.length * 14 + 32
                    if (width + w > 340 && current.isNotEmpty()) {
                        result.add(current); current = mutableListOf(); width = 0
                    }
                    current.add(tag); width += w + 10
                }
                if (current.isNotEmpty()) result.add(current)
                result
            }
            rows.forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    row.forEach { tag ->
                        Box(
                            Modifier.clip(RoundedCornerShape(20.dp)).background(Card)
                                .clickable { onPick(tag) }.padding(horizontal = 14.dp, vertical = 7.dp)
                        ) { Text(tag, color = Color.White.copy(alpha = 0.8f), fontSize = 13.sp) }
                    }
                }
                Spacer(Modifier.height(8.dp))
            }
        }
    }
}

@Composable
private fun SearchRow(track: Track, onClick: () -> Unit) {
    val isCurrent = PlayerManager.current?.id == track.id
    val isPlaying by PlayerManager.isPlaying.collectAsState()

    Row(
        Modifier
            .fillMaxWidth()
            .padding(vertical = 5.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(Card)
            .clickable(onClick = onClick)
            .padding(10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        CoverImage(track = track, modifier = Modifier.size(48.dp), cornerRadius = 8.dp)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(track.title, color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.Medium, maxLines = 1)
            Text(track.artist?.takeIf { it.isNotEmpty() } ?: "未知歌手", color = Color.White.copy(alpha = 0.5f), fontSize = 12.sp, maxLines = 1)
        }
        if (isCurrent && isPlaying) {
            EqualizerBars(barColor = Color.White)
        } else {
            Text(track.durText ?: "", color = Color.White.copy(alpha = 0.5f), fontSize = 12.sp)
        }
    }
}
