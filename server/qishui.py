# -*- coding: utf-8 -*-
"""流萤音乐 · 后端模块化包（由线上 server.py 机械重放，函数体零改写）。"""
import os
import json
import ssl
import sqlite3
import time
import random
import uuid
import hashlib
import hmac
import mimetypes
import re
import secrets
import logging
import socket
import struct
import base64
import threading
import difflib
import subprocess
import urllib.parse
import urllib.request
from html import escape as html_escape
from collections import deque
from http.server import BaseHTTPRequestHandler

from server.config import *
from server.database import db
from server.common import *

__all__ = ['_qishui_cover_original', '_qishui_fetch_share', '_qishui_parse_share', '_qishui_router_data', '_qishui_sentences_lrc']

def _qishui_fetch_share(url):
    """抓取汽水音乐分享短链（跟随重定向），返回最终落地页 HTML 文本。"""
    if not url or "://" not in url:
        raise ValueError("无效链接")
    req = urllib.request.Request(url, headers={
        "User-Agent": QISHUI_SHARE_UA,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    })
    opener = urllib.request.build_opener(urllib.request.HTTPRedirectHandler())
    with opener.open(req, timeout=25) as r:
        raw = r.read()
    # 优先按响应头编码，缺省 utf-8
    charset = "utf-8"
    ctype = r.headers.get("Content-Type", "")
    m = re.search(r"charset=([\w-]+)", ctype, re.I)
    if m:
        charset = m.group(1)
    return raw.decode(charset, "replace")


def _qishui_router_data(html):
    """从分享页 HTML 中提取 _ROUTER_DATA JSON。"""
    m = re.search(r"_ROUTER_DATA\s*=\s*(\{[\s\S]*?\});", html)
    if not m:
        raise ValueError("页面数据解析失败（_ROUTER_DATA 未找到）")
    return json.loads(m.group(1))


def _qishui_cover_original(cover_url):
    """封面转原图：抖音 pic 地址形如 xxx~c5_375x375.jpg（缩略图），去掉尺寸段即 3000x3000 原图。"""
    if not cover_url:
        return ""
    return re.sub(r"~c5_\d+x\d+\.(\w+)$", r"~c5.\1", str(cover_url).strip())


def _qishui_sentences_lrc(sentences):
    """汽水歌词 sentences → 文本：逐字时间戳齐全时输出 KRC（卡拉OK逐字高亮），否则输出标准 LRC。

    - KRC 行：[mm:ss.xx]<开始ms,持续ms>字<开始ms,持续ms>字...（App 端 parseLyrics 自动识别逐字）
    - LRC 行：[mm:ss.xx]整行文本（词曲信息行 / 无逐字时间戳的歌）
    两种格式混在同一文件里 App 都能正确解析（逐字行走逐字高亮，行级行走整句高亮）。
    """
    if not isinstance(sentences, list):
        return ""
    lines = []
    for s in sentences:
        if not isinstance(s, dict):
            continue
        text = str(s.get("text") or "").strip()
        if not text:
            continue
        # 水印/贡献者行直接丢弃（App 端也有过滤，服务端先滤一道）
        if "滚动歌词" in text or "翻译贡献者" in text or "贡献者" in text:
            continue
        start_ms = int(s.get("startMs") or 0)
        head = "[%02d:%02d.%02d]" % (start_ms // 60000, (start_ms // 1000) % 60, (start_ms % 1000) // 10)
        # 逐字提取：每字独立 startMs/endMs → KRC <开始ms,持续ms>字
        words_out = []
        words = s.get("words")
        if isinstance(words, list):
            for w in words:
                if not isinstance(w, dict):
                    continue
                wt = str(w.get("text") or "").replace("<", "").strip()
                if not wt:
                    continue
                w_start = int(w.get("startMs") or 0)
                w_end = int(w.get("endMs") or 0)
                words_out.append((w_start, w_end, wt))
        # 至少 2 个字且每个字都有有效开始时间戳，才按 KRC 逐字输出；否则退化为整行 LRC
        if len(words_out) > 1 and all(wt0 > 0 for wt0, _, _ in words_out):
            parts = []
            for w_start, w_end, wt in words_out:
                dur = w_end - w_start
                if dur <= 0:
                    dur = 200            # 缺结束时间/数据异常：默认 200ms
                parts.append("<%d,%d>%s" % (w_start, dur, wt))
            lines.append(head + "".join(parts))
        else:
            lines.append(head + text)
    return "\n".join(lines)


def _qishui_parse_share(url):
    """解析汽水音乐分享链接 → 歌曲元数据 dict（含封面原图 / LRC 歌词 / 音乐标签 / 音频直链）。

    返回字段：track_id,title,artist,album,album_id,cover,cover_original,genre_tag,
              duration,lyric_lrc,audio_url,audio_size
    """
    html = _qishui_fetch_share(url)
    data = _qishui_router_data(html)
    tp = (data.get("loaderData") or {}).get("track_page") or {}
    awl = tp.get("audioWithLyricsOption") or {}
    track_id = str(awl.get("track_id") or tp.get("track_id") or "").strip()
    if not track_id:
        raise ValueError("未能从链接中解析出歌曲 ID")
    title = str(awl.get("trackName") or "").strip()
    artist = str(awl.get("artistName") or "").strip()
    album = ""
    album_id = ""
    ti = awl.get("trackInfo") or {}
    if isinstance(ti, dict) and isinstance(ti.get("album"), dict):
        album = str(ti["album"].get("name") or "").strip()
        album_id = str(ti["album"].get("id") or "").strip()
    if not album:
        album = title
    cover = str(awl.get("coverURL") or "").strip()
    cover_original = _qishui_cover_original(cover)
    genre_tag = str(awl.get("genre_tag") or "").strip()
    # 音乐标签可能多个：中文主标签 genre_tag + trackInfo.tags 的一/二级标签，去重保序后逗号拼接
    tag_list = [genre_tag] if genre_tag else []
    if isinstance(ti, dict) and isinstance(ti.get("tags"), list):
        for t in ti["tags"]:
            if not isinstance(t, dict):
                continue
            for _k in ("first_level_tag", "second_level_tag"):
                _v = t.get(_k)
                if isinstance(_v, dict) and str(_v.get("tag_name") or "").strip():
                    tag_list.append(str(_v["tag_name"]).strip())
    seen_tags = set()
    genre = ",".join([x for x in tag_list if not (x in seen_tags or seen_tags.add(x))])
    duration = 0
    try:
        duration = int(round(float(awl.get("duration") or 0)))
    except Exception:
        duration = 0
    lyric_lrc = _qishui_sentences_lrc((awl.get("lyrics") or {}).get("sentences"))
    audio_url = str(awl.get("url") or "").strip()
    audio_size = 0
    if isinstance(ti, dict) and isinstance(ti.get("bit_rates"), list) and ti["bit_rates"]:
        # 取最高音质档位的 size（未实际下载，仅预估展示）
        audio_size = max([int(b.get("size") or 0) for b in ti["bit_rates"] if isinstance(b, dict)] or [0])
    return {
        "track_id": track_id, "title": title, "artist": artist,
        "album": album, "album_id": album_id, "cover": cover,
        "cover_original": cover_original, "genre_tag": genre_tag, "genre": genre,
        "duration": duration, "lyric_lrc": lyric_lrc, "audio_url": audio_url,
        "audio_size": audio_size,
    }
