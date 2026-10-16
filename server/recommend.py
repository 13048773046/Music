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

__all__ = ['_rec_age_weight', '_rec_next_seq', '_rec_pieces', '_rec_reason', '_rec_recent_pushed', '_rec_remember_pushed', '_rec_seq_lock', '_rec_seq_state', '_rec_sim', '_rec_title_key', '_rec_title_sim', 'build_recommendations']

def _rec_age_weight(age_days):
    """行为事件时间窗口权重：越近越重要（短期兴趣驱动实时推荐）
    1 小时内 ×1.5 / 1 天内 ×1.25 / 7 天内 ×1.0 / 30 天内 ×0.7 / 更早 ×0.4"""
    if age_days <= 1.0 / 24:
        return 1.5
    if age_days <= 1.0:
        return 1.25
    if age_days <= 7.0:
        return 1.0
    if age_days <= 30.0:
        return 0.7
    return 0.4


_rec_seq_lock = threading.Lock()


_rec_seq_state = {}


def _rec_recent_pushed(viewer_id, now):
    """返回该用户 3 小时内已推送过的歌曲 id 集合（数据库持久化，顺带清理该用户过期记录）。"""
    key = viewer_id or "anon"
    c = db()
    try:
        c.execute("DELETE FROM recommend_push_history WHERE uid=? AND pushed_at <= ?",
                  (key, now - REC_PUSH_WINDOW))
        rows = c.execute(
            "SELECT track_id FROM recommend_push_history WHERE uid=? AND pushed_at > ?",
            (key, now - REC_PUSH_WINDOW)).fetchall()
        c.commit()
    finally:
        c.close()
    return {r[0] for r in rows}


def _rec_remember_pushed(viewer_id, track_ids, now):
    """记录一批刚刚推送的歌曲到数据库（覆盖时间戳），供 3 小时内去重。
    顺带清理全表过期记录，防止表无限膨胀。"""
    if not track_ids:
        return
    key = viewer_id or "anon"
    c = db()
    try:
        c.execute("DELETE FROM recommend_push_history WHERE pushed_at <= ?",
                  (now - REC_PUSH_WINDOW,))
        c.executemany(
            "INSERT OR REPLACE INTO recommend_push_history(uid, track_id, pushed_at)"
            " VALUES(?,?,?)",
            [(key, tid, now) for tid in track_ids])
        c.commit()
    finally:
        c.close()


def _rec_next_seq(viewer_id, bucket, now, fresh=False):
    """返回 (seq, rnd)：时间桶 + 会话内批次轮换。

    同桶主批（seq=0）由 (user, bucket) 种子确定 → 可复现；
    会话内连续请求 seq 递增 → 每批结果不同（不固定同一批）；
    距上次请求超时 / 跨桶 / fresh 会话 → seq 归零（回到该桶稳定主批）。
    """
    key = "%s|%d" % (viewer_id or "anon", bucket)
    with _rec_seq_lock:
        if len(_rec_seq_state) > 5000:
            for k, v in list(_rec_seq_state.items()):
                if now - v[0] > max(REC_SESSION_IDLE * 4, 3600):
                    _rec_seq_state.pop(k, None)
        st = _rec_seq_state.get(key)
        if fresh or st is None or now - st[0] > REC_SESSION_IDLE:
            # 冷启动/下拉刷新：按当前分钟轮换批次起点，避免每次打开 App 第一首都是同一首
            seq = int(now // 60) % 6
        else:
            seq = st[1] + 1
        _rec_seq_state[key] = [now, seq]
    rnd = random.Random("%s|%d|%d" % (viewer_id or "anon", bucket, seq))
    return seq, rnd


def _rec_pieces(s):
    """歌名/专辑关键词片段（去括号、按常见分隔符切分）"""
    s = re.sub(r"[（(【\[].*?[)）】\]]", "", s or "")
    return [p.strip() for p in re.split(r"[·\-–/、，,]", s) if len(p.strip()) >= 2]


def _rec_sim(a, b):
    """两首歌的相似度 0..1（MMR 多样性用）：
    歌手一致 0.7，专辑一致 0.3，歌名关键词有重合 0.2"""
    sim = 0.0
    if a["artist"] and a["artist"] == b["artist"]:
        sim += 0.7
    if a["album"] and a["album"] == b["album"]:
        sim += 0.3
    ka, kb = set(_rec_pieces(a["title"])), set(_rec_pieces(b["title"]))
    if ka and kb and (ka & kb):
        sim += 0.2
    return min(sim, 1.0)


def _rec_title_key(title):
    """歌名相似度比较用的规范化键：
    转小写、去空格、去括号及括号内容（(Live)/(伴奏)/remix 等版本后缀），
    让《晴天》与《晴天 (Live)》规整为同一键，按相似度拦截。"""
    t = (title or "").strip().lower()
    t = re.sub(r"[（(][^）)]*[)）]", "", t)
    return re.sub(r"\s+", "", t)


def _rec_title_sim(a, b):
    """两首歌「歌名相似度」0..1（规范化后字符级相似，SequenceMatcher）。
    空歌名不参与歌名相似约束（返回 0），避免空串误伤。"""
    ka, kb = _rec_title_key(a["title"]), _rec_title_key(b["title"])
    if not ka or not kb:
        return 0.0
    return difflib.SequenceMatcher(None, ka, kb).ratio()


def _rec_reason(sources):
    """从召回来源集合推导推荐理由标签：按「可解释性」优先级取一路——
    常听歌手 > 同风格 > 相似歌曲 > 新歌 > 热门 > 为你探索
    （不用权重：行为相似路常因歌手关键词命中而覆盖歌手路，权重优先会让"常听歌手"几乎不出现）"""
    _labels = {"artist": "常听歌手", "genre": "同风格", "behavior": "相似歌曲",
               "fresh": "新歌", "hot": "热门", "explore": "为你探索"}
    for s in ("artist", "genre", "behavior", "fresh", "hot", "explore"):
        if s in sources:
            return _labels[s]
    return "推荐"


def build_recommendations(c, viewer_id, exclude=None, fresh=False, rnd=None, pushed=None):
    """多路召回 → 加权融合 → MMR 重排，返回推荐 (歌曲id, 推荐理由) 列表（≤20，去重、排除本人上传与 exclude）。

    exclude: 已推荐过的歌曲 id 集合（推荐流无限续推时防重复推荐同一批）。
    fresh: 长时间重开 App 的「新鲜会话」标记——加大随机扰动并提高探索路权重，
           让重新开始的一批推荐明显不同于上次（不固定重复同一批）。
    rnd: 批次随机源（random.Random 实例，种子=用户|时间桶|批次序号）——
         同一时间桶内的主批稳定可复现，会话内连续获取轮换不同批；
         不传时回退全局 random（兼容直接调用场景）。
    pushed: 3 小时内已推送过的歌曲 id 集合——本次推荐直接排除，不重复推送。
    viewer_id 为空/未登录时：无行为画像，走「热度 + 新歌 + 随机探索」三路兜底。
    """
    now = time.time()
    rnd = rnd or random
    # 新鲜重开：随机扰动 ×3、探索路权重 ×2，结果带随机性又不脱离行为画像
    noise = REC_NOISE * 3 if fresh else REC_NOISE
    w_explore = REC_WEIGHTS["explore"] * 2.0 if fresh else REC_WEIGHTS["explore"]
    exclude_self = {r[0] for r in c.execute(
        "SELECT id FROM tracks WHERE user_id=?", (viewer_id or "",)).fetchall()}
    if exclude:
        exclude_self |= set(exclude)

    # 候选池：tid -> {score, sources, artist, album, title, genre}
    cand = {}

    def _add(tid, score, source, artist="", album="", title="", genre=""):
        if not tid or tid in exclude_self:
            return
        if pushed and tid in pushed:   # 3 小时内已推送过：跳过，不重复推
            return
        it = cand.setdefault(tid, {"score": 0.0, "sources": set(),
                                   "artist": artist or "", "album": album or "",
                                   "title": title or "", "genre": genre or ""})
        it["score"] += score
        it["sources"].add(source)

    # ---------- 0) 行为画像：事件打分 + 高分歌 → 关键词 / 风格 / 常听歌手 ----------
    base = {}
    kw_list = []
    genre_set = {}
    artist_hist = {}
    avoid = set()
    if viewer_id:
        evs = c.execute(
            "SELECT track_id,event,value,meta,created FROM behavior_events"
            " WHERE user_id=? ORDER BY created DESC LIMIT 800", (viewer_id,)).fetchall()
        lst = {}
        for tid, event, value, meta, created in evs:
            age_days = max(now - float(created or now), 0) / 86400.0
            decay = _rec_age_weight(age_days)
            if event == "listen":
                try:
                    m = json.loads(meta or "{}")
                except Exception:
                    m = {}
                frac = float(m.get("fraction") or 0)
                try:
                    plays = int(float(m.get("plays") or 0))
                except (TypeError, ValueError):
                    plays = 0
                a = lst.setdefault(tid, {"sec": 0.0, "frac": 0.0, "plays": 0, "decay": decay})
                a["sec"] += max(float(value or 0), 0.0)
                a["frac"] = max(a["frac"], frac)
                a["plays"] = max(a["plays"], plays)
                a["decay"] = max(a["decay"], decay)
            else:
                w = {"like": 3.0 if float(value or 0) > 0 else -1.0,
                     "comment_open": 0.4, "comment": 2.0, "share": 2.0,
                     "search": 1.0, "skip": -0.5}.get(event)
                if w is None:
                    continue
                base[tid] = base.get(tid, 0.0) + w * decay
        for tid, a in lst.items():
            if a["frac"] >= 0.5 or a["plays"] >= 1:
                w = 2.0 + min(a["sec"], 300.0) / 300.0
                if a["plays"] >= 2:
                    w += 0.5
                if a["frac"] >= 0.9:
                    w += 0.5
                base[tid] = base.get(tid, 0.0) + w * a["decay"]
        # 已强互动的歌曲不重复推荐（只用它提取特征）
        avoid = {tid for tid, sc in base.items() if sc >= 2.0}
        top = sorted(base.items(), key=lambda kv: -kv[1])[:6]
        for tid, sc in top:
            title = artist = album = genre = ""
            # 优先用行为事件里的歌曲信息快照（歌被下架/删除也能提取特征）
            _ti = c.execute(
                "SELECT track_info FROM behavior_events WHERE user_id=? AND track_id=?"
                " AND track_info!='' ORDER BY created DESC LIMIT 1", (viewer_id, tid)).fetchone()
            if _ti and _ti[0]:
                try:
                    _info = json.loads(_ti[0])
                    title = _info.get("title") or ""
                    artist = _info.get("artist") or ""
                    album = _info.get("album") or ""
                except Exception:
                    pass
            if not title and not artist and not album:
                row = c.execute("SELECT title,artist,album,genre FROM tracks WHERE id=?", (tid,)).fetchone()
                if not row:
                    row = c.execute("SELECT title,artist,album,genre FROM collected_tracks WHERE id=?", (tid,)).fetchone()
                if not row:
                    continue
                title, artist, album, genre = row
            for kw in (_rec_pieces(title)
                       + ([artist] if artist and len(artist) >= 2 else [])
                       + ([album] if album and len(album) >= 2 else [])):
                if kw and kw not in ("未知歌手", "未命名"):
                    kw_list.append((kw, sc))
            if artist and len(artist) >= 2:
                artist_hist[artist] = artist_hist.get(artist, 0.0) + sc
            if genre:
                # 泛标签黑名单：这类标签信息量为零，不进风格召回池
                _GENDER_BL = {"流行", "DJ", "dj", "国语", "华语", "普通话", "国语流行",
                              "其他", "未知", "未分类", "Pop", "pop"}
                for g in genre.split(","):
                    g = g.strip()
                    if g and g not in _GENDER_BL:
                        genre_set[g] = genre_set.get(g, 0.0) + sc
        # 用户主动搜索过的关键词也进入相似召回池
        skws = c.execute(
            "SELECT meta FROM behavior_events WHERE user_id=? AND event='search'"
            " ORDER BY created DESC LIMIT 50", (viewer_id,)).fetchall()
        for (meta_s,) in skws:
            try:
                _kw = str(json.loads(meta_s or "{}").get("kw") or "").strip()
            except Exception:
                _kw = ""
            if len(_kw) >= 2:
                kw_list.append((_kw, 1.0))

    seen_kw, dedup = set(), []
    for kw, sc in kw_list:
        k = kw.lower()
        if k in seen_kw:
            continue
        seen_kw.add(k)
        dedup.append((kw, sc))

    def _rows(where_sql, args, limit):
        """上传 + 采集两张表统一查候选（offline=0，排除本人上传）"""
        return c.execute(
            "SELECT id,title,artist,album,COALESCE(genre,'') FROM ("
            " SELECT id,title,artist,album,genre FROM tracks WHERE offline=0 AND user_id!=?"
            " UNION ALL"
            " SELECT id,title,artist,album,genre FROM collected_tracks WHERE offline=0"
            ") WHERE " + where_sql + " LIMIT ?",
            ([viewer_id or ""] + list(args) + [limit])).fetchall()

    # ---------- 路 1：行为相似召回（关键词 + 风格精确匹配，排除已强互动） ----------
    # 停用词/短词误伤率高：2字打4折、3字打7折，4字以上满分；纯停用词直接跳过
    _STOP_KWS = {"你", "我", "他", "她", "的", "了", "在", "是", "和", "就", "不", "人",
                 "这", "那", "一", "上", "下", "中", "里", "着", "也", "都", "要", "会",
                 "对", "与", "及", "或", "而", "从", "到", "为", "什么", "怎么", "我们",
                 "你们", "他们", "可以", "就是", "一个", "没有", "知道", "时候", "自己"}
    for kw, sc in dedup[:8]:
        if kw in _STOP_KWS or len(kw) < 2:
            continue
        kw_bonus = 0.4 if len(kw) <= 2 else (0.7 if len(kw) == 3 else 1.0)
        like = "%" + kw + "%"
        for rid, rtitle, rartist, ralbum, rgenre in _rows(
                "(title LIKE ? OR artist LIKE ? OR album LIKE ?)", [like, like, like],
                REC_LIMITS["behavior"]):
            if rid in avoid:
                continue
            _add(rid, sc * REC_WEIGHTS["behavior"] * kw_bonus, "behavior",
                 rartist, ralbum, rtitle, rgenre)
    for g, sc in sorted(genre_set.items(), key=lambda x: -x[1])[:5]:
        like = "%" + g + "%"
        for rid, rtitle, rartist, ralbum, rgenre in _rows(
                "genre LIKE ?", [like], REC_LIMITS["genre"]):
            if rid in avoid:
                continue
            _add(rid, sc * REC_WEIGHTS["genre"], "genre",
                 rartist, ralbum, rtitle, rgenre)

    # ---------- 路 2：常听歌手召回（行为里听得最多的歌手，整池召回） ----------
    for artist, sc in sorted(artist_hist.items(), key=lambda x: -x[1])[:5]:
        for rid, rtitle, rartist, ralbum, rgenre in _rows(
                "artist = ?", [artist], REC_LIMITS["artist"]):
            if rid in avoid:
                continue
            _add(rid, sc * REC_WEIGHTS["artist"], "artist",
                 rartist, ralbum, rtitle, rgenre)

    # ---------- 路 3：全局热度召回（大众口味兜底，权重较低） ----------
    hot = c.execute(
        "SELECT id,title,artist,album,COALESCE(genre,'') FROM ("
        " SELECT id,title,artist,album,genre,play_count,like_count,share_count FROM tracks"
        " WHERE offline=0 AND user_id!=?"
        " UNION ALL"
        " SELECT id,title,artist,album,genre,play_count,like_count,share_count FROM collected_tracks"
        " WHERE offline=0"
        ") ORDER BY (play_count + like_count*3 + share_count*5) DESC LIMIT ?",
        (viewer_id or "", REC_HOT_TOP)).fetchall()
    for rank, (rid, rtitle, rartist, ralbum, rgenre) in enumerate(hot):
        if rank >= REC_LIMITS["hot"]:
            break
        if rid in avoid:
            continue
        _add(rid, max(0.0, 1.0 - rank / float(REC_HOT_TOP)) * REC_WEIGHTS["hot"],
             "hot", rartist, ralbum, rtitle, rgenre)

    # ---------- 路 4：新歌新鲜度召回（最近 REC_FRESH_DAYS 天入库，权重中等） ----------
    fresh = c.execute(
        "SELECT id,title,artist,album,COALESCE(genre,'') FROM ("
        " SELECT id,title,artist,album,genre,created FROM tracks WHERE offline=0 AND user_id!=?"
        " UNION ALL"
        " SELECT id,title,artist,album,genre,created FROM collected_tracks WHERE offline=0"
        ") WHERE created >= ? ORDER BY created DESC LIMIT ?",
        (viewer_id or "", now - REC_FRESH_DAYS * 86400.0, REC_LIMITS["fresh"])).fetchall()
    for rid, rtitle, rartist, ralbum, rgenre in fresh:
        if rid in avoid:
            continue
        _add(rid, REC_WEIGHTS["fresh"], "fresh", rartist, ralbum, rtitle, rgenre)

    # ---------- 路 5：随机探索召回（保证新内容被看到，权重最低） ----------
    # 候选池按批次种子洗牌截断（替代 SQL RANDOM()）：同批次可复现、不同批次轮换
    explore = c.execute(
        "SELECT id,title,artist,album,COALESCE(genre,'') FROM ("
        " SELECT id,title,artist,album,genre FROM tracks WHERE offline=0 AND user_id!=?"
        " UNION ALL"
        " SELECT id,title,artist,album,genre FROM collected_tracks WHERE offline=0"
        ") ORDER BY id LIMIT ?",
        (viewer_id or "", REC_EXPLORE_POOL)).fetchall()
    explore = list(explore)
    rnd.shuffle(explore)
    for rid, rtitle, rartist, ralbum, rgenre in explore[:REC_LIMITS["explore"]]:
        if rid in cand or rid in avoid:
            continue
        _add(rid, w_explore, "explore", rartist, ralbum, rtitle, rgenre)

    # ---------- MMR 重排（相关分 − 与已选歌的相似度；同歌手/同风格设上限） ----------
    pool = [(tid, it) for tid, it in cand.items()]
    ranked = []
    used_artist = {}
    used_genre = {}
    while len(ranked) < REC_BUDGET and pool:
        best_i, best_score = -1, -1e18
        for i, (tid, it) in enumerate(pool):
            if it["artist"] and used_artist.get(it["artist"], 0) >= REC_MAX_PER_ARTIST:
                continue
            if it["genre"] and used_genre.get(it["genre"], 0) >= REC_MAX_PER_GENRE:
                continue
            # 歌名相似硬约束：与任一已选歌歌名相似度 ≥ 阈值（80%）则跳过，
            # 同一批推荐不推送歌名高度相似的歌（90% 相似更不会同批出现）
            if ranked and any(_rec_title_sim(it, r) >= REC_TITLE_SIM_THRESHOLD for _, r in ranked):
                continue
            div = max((_rec_sim(it, r) for _, r in ranked), default=0.0) if ranked else 0.0
            s = REC_MMR_LAMBDA * it["score"] - (1.0 - REC_MMR_LAMBDA) * div \
                + rnd.uniform(0, noise)
            if s > best_score:
                best_score, best_i = s, i
        if best_i < 0:
            break
        tid, it = pool.pop(best_i)
        ranked.append((tid, it))
        if it["artist"]:
            used_artist[it["artist"]] = used_artist.get(it["artist"], 0) + 1
        if it["genre"]:
            used_genre[it["genre"]] = used_genre.get(it["genre"], 0) + 1
    # 返回 (歌曲id, 推荐理由标签) 对；前端据此展示「为什么推荐这首歌」
    return [(tid, _rec_reason(it["sources"])) for tid, it in ranked]
