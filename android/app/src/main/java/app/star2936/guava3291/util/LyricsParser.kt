package app.star2936.guava3291.util

// 对应 iOS LyricView.swift：KRC / LRC 歌词解析（毫秒级逐字时间戳）

data class KRWord(val text: String, val start: Double, var end: Double)

data class KRCLine(val words: List<KRWord>, val start: Double, val end: Double) {
    val text: String get() = words.joinToString("") { it.text }
}

private val rowRegex = Regex("""\[(\d+):(\d+)(?:[.:](\d+))?(?:,(\d+))?\]""")
private val wordRegex = Regex("""<(\d+),(\d+)>([^<]*)""")

fun parseLyrics(text: String): List<KRCLine> {
    if (text.isEmpty()) return emptyList()
    val lines = mutableListOf<KRCLine>()

    for (raw in text.lines()) {
        val rowMatch = rowRegex.find(raw) ?: continue
        if (rowMatch.range.first != 0) continue
        val mm = rowMatch.groupValues[1].toDoubleOrNull() ?: 0.0
        val ss = rowMatch.groupValues[2].toDoubleOrNull() ?: 0.0
        var frac = 0.0
        if (rowMatch.groupValues[3].isNotEmpty()) {
            val f = rowMatch.groupValues[3].toDoubleOrNull() ?: 0.0
            frac = f / (if (f >= 100) 1000.0 else 100.0)   // 三位=毫秒，两位=百分秒
        }
        val rowStart = mm * 60 + ss + frac
        val body = raw.substring(rowMatch.range.last + 1)

        val words = mutableListOf<KRWord>()
        var wordFound = false
        for (m in wordRegex.findAll(body)) {
            val stMs = m.groupValues[1].toDoubleOrNull() ?: 0.0
            val durMs = m.groupValues[2].toDoubleOrNull() ?: 0.0
            val txt = m.groupValues[3]
            if (txt.isEmpty()) continue
            words.add(KRWord(txt, stMs / 1000.0, (stMs + durMs) / 1000.0))
            wordFound = true
        }

        if (!wordFound) {
            val txt = body.trim()
            if (txt.isEmpty()) continue
            words.add(KRWord(txt, rowStart, rowStart))
        }
        if (words.isEmpty()) continue

        // 过滤平台水印/贡献者等非歌词元信息行
        val joined = words.joinToString("") { it.text }
        if (joined.contains("滚动歌词") || joined.contains("翻译贡献者") || joined.contains("贡献者")) continue

        lines.add(KRCLine(words, words.first().start, words.last().end))
    }

    if (lines.isEmpty()) return emptyList()
    lines.sortBy { it.start }
    // LRC 行（end == start）的结束时间取下一行开始时间
    for (i in lines.indices) {
        if (lines[i].end <= lines[i].start) {
            val nextStart = if (i + 1 < lines.size) lines[i + 1].start else lines[i].start + 3.0
            if (nextStart > lines[i].start) {
                val words = lines[i].words.toMutableList()
                val last = words.last()
                words[words.size - 1] = KRWord(last.text, last.start, nextStart)
                lines[i] = KRCLine(words, lines[i].start, nextStart)
            }
        }
    }
    return lines
}
