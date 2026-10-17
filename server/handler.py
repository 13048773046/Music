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
from server.ws import *
from server.recommend import *
from server.qishui import *
from server.media import *
from server.ai import *

__all__ = ['H']

_TEMPLATE_CACHE = {}


def _render_template(name):
    """读取 server/templates/<name>（带简单缓存）。"""
    t = _TEMPLATE_CACHE.get(name)
    if t is None:
        with open(os.path.join(TEMPLATE_DIR, name), encoding="utf-8") as f:
            t = f.read()
        _TEMPLATE_CACHE[name] = t
    return t


class H(BaseHTTPRequestHandler):
    timeout = SOCKET_TIMEOUT
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        # BaseHTTPRequestHandler 默认往 stderr 打，这里统一走 logging（结构化）
        try:
            log.info("req %s %s %s", self.client_address[0], self.command,
                     self.path.split("?", 1)[0])
        except Exception:
            pass

    # ---- 工具 ----

    def _json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def _err(self, code, msg):
        self._json(code, {"err": msg})

    def _send_html(self, html):
        body = html.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _internal_error(self, e):
        log.error("internal error: %s %s", self.path, e, exc_info=DEBUG)
        self._err(500, "服务器内部错误" if not DEBUG else "internal error: %s" % e)

    def _share_page(self, title, author, tid, cover, short_code=""):
        """分享 H5 页面：深黑灰极简单曲页（封面/歌名/作者 + 播放暂停/进度条）。
        播放走服务端签名流 URL（隐藏真实流地址），页面不暴露明文音频链接。
        含社交卡片预览（OG 标签，微信/QQ/Telegram 读取）与短链跳转入口。"""
        tid_js = json.dumps(tid, ensure_ascii=False)
        cover_js = json.dumps(cover or "", ensure_ascii=False)
        og_title = "《%s》@流萤音乐" % (title or "")
        og_image = ("%s/api/cover/%s" % (PUBLIC_BASE, tid)) if cover else ""
        og_url = ("https://%s/s/%s/" % (urllib.parse.urlsplit(PUBLIC_BASE).netloc, short_code)) if short_code else ""
        meta_og = (
            '<meta property="og:title" content="%s">\n'
            '<meta property="og:type" content="website">\n'
            '<meta property="og:site_name" content="流萤音乐">\n'
            '<meta property="og:description" content="%s - 流萤音乐">\n'
            '%s'
            '<meta name="twitter:card" content="summary_large_image">'
        ) % (html_escape(og_title), html_escape(author or ""),
             '<meta property="og:image" content="%s">\n' % og_image if og_image else "")
        if og_url:
            meta_og += '\n<meta property="og:url" content="%s">' % og_url
        html = _render_template("share_player.html").replace("__META_OG__", meta_og)
        return (html.replace("__TID__", tid_js)
                    .replace("__COVER__", cover_js)
                    .replace("__TITLE__", json.dumps(title or "", ensure_ascii=False))
                    .replace("__AUTHOR__", json.dumps(author or "", ensure_ascii=False))).encode()

    def _serve_file(self, fp, cacheable=True):
        size = os.path.getsize(fp)
        ctype = mimetypes.guess_type(fp)[0] or "application/octet-stream"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(size))
        if cacheable:
            self.send_header("Cache-Control", "public, max-age=86400")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        try:
            with open(fp, "rb") as f:
                while True:
                    chunk = f.read(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass

    # ---- 身份解析：token 优先，兼容旧客户端 userId/account ----

    def auth_user(self, c, fields=None, allow_account=False):
        """返回 (uid, authed_via_token)。uid 为 None 表示未识别身份。"""
        uid = resolve_token(c, self.headers.get("Authorization", ""))
        if uid:
            return uid, True
        if AUTH_STRICT:
            return None, False
        if fields:
            legacy = (fields.get("userId") or "").strip()
            if legacy:
                return legacy, False
            if allow_account:
                acc = (fields.get("account") or "").strip()
                if acc:
                    row = c.execute("SELECT id FROM users WHERE account=?", (acc,)).fetchone()
                    if row:
                        return row[0], False
        return None, False

    # ---- Range 解析：返回 None=全量 / False=忽略Range / True=416 / (start,end)=206 ----

    def _parse_range(self, size):
        rng = self.headers.get("Range")
        if not rng:
            return None
        if not rng.startswith("bytes="):
            return False
        spec = rng[6:].split(",", 1)[0].strip()
        if "-" not in spec:
            return False
        a, b = spec.split("-", 1)
        try:
            start = int(a) if a else None
            end = int(b) if b else None
        except ValueError:
            return False
        if start is None:
            # 后缀范围：最后 N 字节
            n = end
            if n is None or n <= 0:
                return False
            start = max(size - n, 0)
            end = size - 1
        else:
            if start >= size:
                return True            # 起始越界 → 416
            end = size - 1 if end is None else min(end, size - 1)
            if end < start:
                return False
        return (start, end)

    # ---- CORS ----

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type,Authorization")
        self.send_header("Access-Control-Max-Age", "86400")
        self.end_headers()

    def do_HEAD(self):
        try:
            u = urllib.parse.urlparse(self.path)
            if u.path.startswith("/api/stream/"):
                # 与 GET 一致的签名校验
                q = urllib.parse.parse_qs(u.query)
                exp_s = (q.get("exp") or [""])[0]
                sig = (q.get("sig") or [""])[0]
                if exp_s or sig:
                    if not verify_stream(u.path.rsplit("/", 1)[-1], exp_s, sig):
                        self._err(403, "stream link expired or invalid")
                        return
                elif SIGN_STRICT:
                    self._err(403, "stream link expired or invalid")
                    return
                tid = u.path.rsplit("/", 1)[-1]
                c = db()
                row = c.execute("SELECT fname FROM tracks WHERE id=?", (tid,)).fetchone()
                # 采集歌曲：302 到第三方播放地址（HEAD 与 GET 一致）
                crow = c.execute("SELECT play_url FROM collected_tracks WHERE id=?", (tid,)).fetchone()
                c.close()
                fp = safe_file_path(row[0] if row else "")
                if not fp:
                    if crow and crow[0]:
                        self.send_response(302)
                        self.send_header("Location", crow[0])
                        self.send_header("Cache-Control", "no-store")
                        self.send_header("Access-Control-Allow-Origin", "*")
                        self.end_headers()
                        return
                    self._err(404, "not found")
                    return
                size = os.path.getsize(fp)
                ctype = mimetypes.guess_type(fp)[0] or "audio/mpeg"
                self.send_response(200)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(size))
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                return
            self._err(404, "unknown")
        except Exception as e:
            self._internal_error(e)

    # ---- GET ----

    def do_GET(self):
        try:
            u = urllib.parse.urlparse(self.path)
            # WebSocket 实时通知推送：GET /api/ws?token=xxx（需 Upgrade 头）
            if u.path == "/api/ws":
                _ws_handshake(self, u)
                return

            if u.path in ("/", "/api/health"):
                self._json(200, {"ok": True, "service": "music",
                                 "time": time.strftime("%Y-%m-%d %H:%M:%S")})
                return

            # 官网公开配置：网站名/下载链接 + 实时歌曲总数（无需登录）
            if u.path == "/api/site-config":
                self._json(200, _read_site_config())
                return

            # 公告通知：App 启动时请求最新一条 active 公告（type=announcement）
            if u.path == "/api/announcement":
                c = db()
                row = c.execute("SELECT id, title, content, version, show_once FROM announcements"
                                " WHERE active=1 AND type='announcement' ORDER BY created DESC LIMIT 1").fetchone()
                c.close()
                if not row:
                    self._json(200, {"id": "", "title": "", "content": "", "version": "", "showOnce": 0})
                    return
                self._json(200, {"id": row[0], "title": row[1], "content": row[2],
                                 "version": row[3] or "", "showOnce": row[4] or 0})
                return

            # 检查更新：返回最新一条 active 更新通知（type=update）
            if u.path == "/api/check-update":
                c = db()
                row = c.execute("SELECT id, title, content, version, force_update, download_url FROM announcements"
                                " WHERE active=1 AND type='update' ORDER BY created DESC LIMIT 1").fetchone()
                c.close()
                if not row:
                    self._json(200, {"hasUpdate": False})
                    return
                self._json(200, {"hasUpdate": True, "id": row[0], "title": row[1],
                                 "content": row[2], "version": row[3] or "",
                                 "forceUpdate": row[4] or 0, "downloadUrl": row[5] or ""})
                return

            # 我的统计：总听歌时长（秒）、听过的歌曲数
            if u.path == "/api/my-stats":
                c = db()
                uid = resolve_token(c, self.headers.get("Authorization", ""))
                if not uid:
                    c.close()
                    self._json(200, {"totalSeconds": 0, "trackCount": 0})
                    return
                row = c.execute("SELECT COALESCE(SUM(value),0) FROM behavior_events"
                                " WHERE user_id=? AND event='listen'", (uid,)).fetchone()
                total_sec = int(row[0]) if row else 0
                row2 = c.execute("SELECT COUNT(DISTINCT track_id) FROM behavior_events"
                                " WHERE user_id=? AND event='listen'", (uid,)).fetchone()
                track_cnt = int(row2[0]) if row2 else 0
                c.close()
                self._json(200, {"totalSeconds": total_sec, "trackCount": track_cnt})
                return

            # ===== 播放历史列表 =====
            if u.path == "/api/history":
                c = db()
                uid = resolve_token(c, self.headers.get("Authorization", ""))
                if not uid:
                    c.close()
                    self._json(200, {"list": [], "total": 0, "hasMore": False})
                    return
                qs = urllib.parse.parse_qs(u.query)
                page, page_size = parse_page(qs)
                total = c.execute("SELECT COUNT(*) FROM play_history WHERE user_id=?", (uid,)).fetchone()[0]
                if page is None:
                    rows = c.execute("SELECT id, track_id, track_title, track_artist, track_cover, source, created FROM play_history WHERE user_id=? ORDER BY created DESC LIMIT 100", (uid,)).fetchall()
                else:
                    rows = c.execute("SELECT id, track_id, track_title, track_artist, track_cover, source, created FROM play_history WHERE user_id=? ORDER BY created DESC LIMIT ? OFFSET ?",
                                    (uid, page_size, (page - 1) * page_size)).fetchall()
                c.close()
                lst = [{"id": r[0], "trackId": r[1], "title": r[2], "artist": r[3], "cover": r[4], "source": r[5], "created": r[6]} for r in rows]
                self._json(200, {"list": lst, "total": total, "hasMore": bool(page is not None and page * page_size < total)})
                return

            # ===== 搜索历史列表 =====
            if u.path == "/api/search/history":
                c = db()
                uid = resolve_token(c, self.headers.get("Authorization", ""))
                if not uid:
                    c.close()
                    self._json(200, {"list": []})
                    return
                rows = c.execute("SELECT id, keyword, created FROM search_history WHERE user_id=? ORDER BY created DESC LIMIT 20", (uid,)).fetchall()
                c.close()
                self._json(200, {"list": [{"id": r[0], "keyword": r[1], "created": r[2]} for r in rows]})
                return

            # ===== 我的歌单列表 =====
            if u.path == "/api/playlists":
                c = db()
                uid = resolve_token(c, self.headers.get("Authorization", ""))
                if not uid:
                    c.close()
                    self._json(200, {"list": []})
                    return
                rows = c.execute("SELECT id, name, cover, description, track_count, created FROM playlists WHERE user_id=? ORDER BY created DESC", (uid,)).fetchall()
                c.close()
                self._json(200, {"list": [{"id": r[0], "name": r[1], "cover": r[2] or "", "description": r[3] or "", "trackCount": r[4] or 0, "created": r[5]} for r in rows]})
                return

            # ===== 歌单详情（含歌曲列表） =====
            if u.path.startswith("/api/playlists/") and u.path.endswith("/tracks"):
                pid = u.path.split("/")[3]
                c = db()
                uid = resolve_token(c, self.headers.get("Authorization", ""))
                if not uid:
                    c.close()
                    self._err(401, "unauthorized"); return
                # 验证歌单属于当前用户
                pl = c.execute("SELECT id, name, cover, description, track_count, created FROM playlists WHERE id=? AND user_id=?", (pid, uid)).fetchone()
                if not pl:
                    c.close()
                    self._err(404, "playlist not found"); return
                rows = c.execute("SELECT track_id, track_title, track_artist, track_cover, source, created FROM playlist_tracks WHERE playlist_id=? ORDER BY sort DESC, created DESC", (pid,)).fetchall()
                c.close()
                lst = [{"id": r[0], "trackId": r[0], "title": r[1], "artist": r[2], "cover": r[3], "source": r[4], "created": r[5]} for r in rows]
                self._json(200, {"playlist": {"id": pl[0], "name": pl[1], "cover": pl[2] or "", "description": pl[3] or "", "trackCount": pl[4] or 0, "created": pl[5]}, "list": lst})
                return

            # ===== 用户主页信息 =====
            if u.path.startswith("/api/user/") and u.path.endswith("/profile"):
                target_uid = u.path.split("/")[3]
                c = db()
                # 当前登录用户（判断是否已关注）
                me_uid = resolve_token(c, self.headers.get("Authorization", ""))
                # 用户基本信息
                urow = c.execute("SELECT id, account, name, avatar, signature, created, gender, age, is_ai FROM users WHERE id=?", (target_uid,)).fetchone()
                if not urow:
                    c.close()
                    self._err(404, "user not found"); return
                # 上传歌曲数
                track_count = c.execute("SELECT COUNT(*) FROM tracks WHERE user_id=? AND offline=0", (target_uid,)).fetchone()[0]
                # 获赞总数
                like_count = c.execute("SELECT COALESCE(SUM(like_count),0) FROM tracks WHERE user_id=?", (target_uid,)).fetchone()[0]
                # 粉丝数（关注我的人数）
                follower_count = c.execute("SELECT COUNT(*) FROM follows WHERE following_id=?", (target_uid,)).fetchone()[0]
                # 关注数（我关注的人数）
                following_count = c.execute("SELECT COUNT(*) FROM follows WHERE follower_id=?", (target_uid,)).fetchone()[0]
                # 互关数（互相关注的人数）
                mutual_count = 0
                if me_uid:
                    mutual_count = c.execute("""SELECT COUNT(*) FROM follows f1
                                                INNER JOIN follows f2 ON f1.follower_id=f2.following_id AND f1.following_id=f2.follower_id
                                                WHERE f1.follower_id=?""", (me_uid,)).fetchone()[0]
                # 当前用户是否已关注该用户
                is_following = False
                if me_uid and me_uid != target_uid:
                    exist = c.execute("SELECT follower_id FROM follows WHERE follower_id=? AND following_id=?", (me_uid, target_uid)).fetchone()
                    is_following = bool(exist)
                c.close()
                self._json(200, {
                    "userId": urow[0], "account": urow[1], "name": urow[2],
                    "avatar": urow[3] or "", "signature": urow[4] or "",
                    "created": urow[5], "gender": urow[6] or "", "age": urow[7] or 0,
                    "trackCount": track_count, "likeCount": like_count,
                    "followerCount": follower_count, "followingCount": following_count,
                    "mutualCount": mutual_count, "isFollowing": is_following,
                    "isAi": bool(urow[8])
                })
                return

            # ===== 用户上传的歌曲列表 =====
            if u.path.startswith("/api/user/") and u.path.endswith("/tracks"):
                target_uid = u.path.split("/")[3]
                c = db()
                rows = c.execute("""SELECT id,title,artist,album,cover,fname,size,dur,created,
                                    play_count,like_count,share_count,user_id,lrc
                                    FROM tracks WHERE user_id=? AND offline=0
                                    ORDER BY created DESC LIMIT 50""", (target_uid,)).fetchall()
                c.close()
                lst = [{"id": r[0], "title": r[1], "artist": r[2] or "", "album": r[3] or "",
                        "cover": r[4] or "", "fname": r[5] or "",
                        "size": int(r[6]) if r[6] is not None else 0,
                        "dur": r[7], "created": r[8],
                        "playCount": r[9] or 0, "likeCount": r[10] or 0,
                        "shareCount": r[11] or 0, "userId": r[12] or "",
                        "hasLyric": bool(r[13])} for r in rows]
                self._json(200, {"list": lst})
                return

            # 我的上传歌曲列表（支持分页：page/pageSize，不传 page 时全量返回兼容旧客户端）
            if u.path == "/api/my-tracks":
                c = db()
                uid = resolve_token(c, self.headers.get("Authorization", ""))
                if not uid:
                    c.close()
                    self._json(200, {"list": [], "total": 0, "hasMore": False})
                    return
                qs = urllib.parse.parse_qs(u.query)
                page, page_size = parse_page(qs)
                sel = """SELECT t.id,t.title,t.artist,t.album,t.cover,t.fname,t.size,t.dur,t.created,
                         t.play_count,t.like_count,t.share_count,t.user_id,t.lrc,
                         COALESCE(u.name,''),
                         (SELECT COUNT(*) FROM comments cm WHERE cm.track_id=t.id),
                         MAX(CASE WHEN l.user_id IS NOT NULL THEN 1 ELSE 0 END)
                         FROM tracks t
                         LEFT JOIN users u ON u.id=t.user_id
                         LEFT JOIN likes l ON l.track_id=t.id AND l.user_id=?
                         WHERE t.user_id=? AND t.offline=0
                         GROUP BY t.id ORDER BY t.created DESC"""
                args = [uid, uid]
                total = c.execute("SELECT COUNT(*) FROM tracks WHERE user_id=? AND offline=0",
                                  (uid,)).fetchone()[0]
                if page is None:
                    rows = c.execute(sel, args).fetchall()
                else:
                    rows = c.execute(sel + " LIMIT ? OFFSET ?",
                                     args + [page_size, (page - 1) * page_size]).fetchall()
                c.close()
                lst = [{"id": r[0], "title": r[1], "artist": r[2], "album": r[3] or "",
                        "cover": r[4] or "", "fname": r[5] or "",
                        "size": int(r[6]) if r[6] is not None else 0,
                        "dur": r[7], "durText": _fmt_dur(r[7]), "created": r[8],
                        "playCount": r[9] or 0, "likeCount": r[10] or 0,
                        "shareCount": r[11] or 0, "userId": r[12] or "",
                        "userName": r[14] or "", "hasLyric": bool(r[13]),
                        "commentCount": r[15] or 0, "isLiked": bool(r[16])} for r in rows]
                self._json(200, {"list": lst, "total": total,
                                 "hasMore": bool(page is not None and page * page_size < total)})
                return

            # 我点赞的歌曲列表（上传+采集合并，按点赞时间倒序；支持分页）
            if u.path == "/api/my-likes":
                c = db()
                uid = resolve_token(c, self.headers.get("Authorization", ""))
                if not uid:
                    c.close()
                    self._json(200, {"list": [], "total": 0, "hasMore": False})
                    return
                qs = urllib.parse.parse_qs(u.query)
                page, page_size = parse_page(qs)
                # 归属账号昵称（采集歌曲统一展示用，与 /api/tracks 口径一致）
                uname = ""
                urow = c.execute(
                    "SELECT name FROM users WHERE id=(SELECT user_id FROM collected_tracks"
                    " WHERE user_id!='' LIMIT 1)").fetchone()
                if urow:
                    uname = urow[0]
                # 上传歌曲点赞子查询（is_liked 恒为 1：行本身来自当前用户的点赞记录）
                sub1 = """SELECT t.id,t.title,t.artist,t.album,t.cover,t.fname,t.size,t.dur,t.created,
                          t.play_count,t.like_count,t.share_count,t.user_id,t.lrc,
                          COALESCE(u.name,''),
                          (SELECT COUNT(*) FROM comments cm WHERE cm.track_id=t.id),
                          1 AS is_liked, l.created AS lc
                          FROM likes l JOIN tracks t ON t.id=l.track_id
                          LEFT JOIN users u ON u.id=t.user_id
                          WHERE l.user_id=? AND t.offline=0"""
                # 采集歌曲点赞子查询（cover 返回占位 "1"，字段结构与上传分支对齐）
                sub2 = """SELECT c.id,c.title,c.artist,c.album,'1','',0,c.duration,c.created,
                          c.play_count,c.like_count,c.share_count,c.user_id,c.lrc,
                          ?, 0, 1, l.created AS lc
                          FROM likes l JOIN collected_tracks c ON c.id=l.track_id
                          WHERE l.user_id=? AND c.offline=0"""
                total1 = c.execute("""SELECT COUNT(*) FROM likes l JOIN tracks t ON t.id=l.track_id
                                      WHERE l.user_id=? AND t.offline=0""", (uid,)).fetchone()[0]
                total2 = c.execute("""SELECT COUNT(*) FROM likes l JOIN collected_tracks c
                                      ON c.id=l.track_id WHERE l.user_id=? AND c.offline=0""", (uid,)).fetchone()[0]
                total = total1 + total2
                args = [uid, uname, uid]
                if page is None:
                    rows = c.execute(sub1 + " UNION ALL " + sub2, args).fetchall()
                else:
                    rows = c.execute("SELECT * FROM (" + sub1 + " UNION ALL " + sub2
                                     + ") ORDER BY lc DESC LIMIT ? OFFSET ?",
                                     args + [page_size, (page - 1) * page_size]).fetchall()
                c.close()
                lst = [{"id": r[0], "title": r[1], "artist": r[2], "album": r[3] or "",
                        "cover": r[4] or "", "fname": r[5] or "",
                        "size": int(r[6]) if r[6] is not None else 0,
                        "dur": r[7], "durText": _fmt_dur(r[7]), "created": r[8],
                        "playCount": r[9] or 0, "likeCount": r[10] or 0,
                        "shareCount": r[11] or 0, "userId": r[12] or "",
                        "userName": r[14] or "", "hasLyric": bool(r[13]),
                        "commentCount": r[15] or 0, "isLiked": bool(r[16])} for r in rows]
                self._json(200, {"list": lst, "total": total,
                                 "hasMore": bool(page is not None and page * page_size < total)})
                return

            # 我评论过的歌曲列表（支持分页）
            if u.path == "/api/my-comments":
                c = db()
                uid = resolve_token(c, self.headers.get("Authorization", ""))
                if not uid:
                    c.close()
                    self._json(200, {"list": [], "total": 0, "hasMore": False})
                    return
                qs = urllib.parse.parse_qs(u.query)
                page, page_size = parse_page(qs)
                sel = """SELECT c.track_id, c.content, c.created,
                         COALESCE((SELECT title FROM tracks WHERE id=c.track_id),
                                  (SELECT title FROM collected_tracks WHERE id=c.track_id)),
                         COALESCE((SELECT artist FROM tracks WHERE id=c.track_id),
                                  (SELECT artist FROM collected_tracks WHERE id=c.track_id))
                         FROM comments c WHERE c.user_id=? ORDER BY c.created DESC"""
                total = c.execute("SELECT COUNT(*) FROM comments WHERE user_id=?",
                                  (uid,)).fetchone()[0]
                if page is None:
                    rows = c.execute(sel, (uid,)).fetchall()
                else:
                    rows = c.execute(sel + " LIMIT ? OFFSET ?",
                                     (uid, page_size, (page - 1) * page_size)).fetchall()
                c.close()
                lst = [{"trackId": r[0], "content": r[1], "created": r[2],
                        "title": r[3] or "", "artist": r[4] or ""} for r in rows]
                self._json(200, {"list": lst, "total": total,
                                 "hasMore": bool(page is not None and page * page_size < total)})
                return

            # ---------- 采集控制台 H5 页面 ----------
            if u.path == "/collect.html":
                html = _render_template("collect.html")
                body = html.encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                self.wfile.write(body)
                return

            # ---------- 采集控制台 API ----------
            # 汽水音乐（qs）代理：转发到本地音源桥 8789
            if u.path in ("/api/collect/qs-status", "/api/collect/qs-qr", "/api/collect/qs-poll",
                          "/api/collect/qs-sms-send", "/api/collect/qs-sms-login",
                          "/api/collect/qs-cookie-import"):
                import urllib.request as _ur
                if u.path == "/api/collect/qs-poll":
                    _tk = (urllib.parse.parse_qs(u.query).get("token") or [""])[0]
                    _bp = "/qs/poll?token=" + urllib.parse.quote(_tk)
                elif u.path == "/api/collect/qs-sms-send":
                    _mb = (urllib.parse.parse_qs(u.query).get("mobile") or [""])[0]
                    _bp = "/qs/sms/send?mobile=" + urllib.parse.quote(_mb)
                elif u.path == "/api/collect/qs-sms-login":
                    _ps = urllib.parse.parse_qs(u.query)
                    _mb = (_ps.get("mobile") or [""])[0]
                    _cd = (_ps.get("code") or [""])[0]
                    _bp = "/qs/sms/login?mobile=" + urllib.parse.quote(_mb) + "&code=" + urllib.parse.quote(_cd)
                elif u.path == "/api/collect/qs-cookie-import":
                    _ck = (urllib.parse.parse_qs(u.query).get("cookie") or [""])[0]
                    _bp = "/qs/cookie/import?cookie=" + urllib.parse.quote(_ck)
                elif u.path.endswith("qs-status"):
                    _bp = "/qs/status"
                else:
                    _bp = "/qs/qr"
                try:
                    with _ur.urlopen("http://127.0.0.1:8789" + _bp, timeout=15) as _r:
                        _qsd = json.loads(_r.read().decode())
                    self._json(200, _qsd)
                except Exception as _e:
                    self._json(200, {"ok": False, "err": "汽水音乐服务异常:" + str(_e)})
                return
            if u.path == "/api/collect/status":
                import subprocess
                try:
                    out = subprocess.check_output(["pgrep", "-f", "collect_v3.py"])
                    is_run = bool(out.strip())
                except Exception:
                    is_run = False
                c = db()
                total = c.execute("SELECT COUNT(*) FROM collected_tracks").fetchone()[0]
                recent = c.execute("SELECT title, artist FROM collected_tracks ORDER BY created DESC LIMIT 50").fetchall()
                c.close()
                run_data = {"started": None, "collected": []}
                try:
                    with open("/www/wwwroot/music/source-bridge/collect_run.json", "r", encoding="utf-8") as _rf:
                        run_data = json.load(_rf)
                except Exception:
                    pass
                if not isinstance(run_data, dict):
                    run_data = {"started": None, "collected": []}
                run_songs = run_data.get("collected") or []
                tgt, st_total = None, total
                try:
                    with open("/www/wwwroot/music/source-bridge/collect_target.json", "r", encoding="utf-8") as _tf:
                        _tj = json.load(_tf)
                    if isinstance(_tj, dict):
                        tgt = int(_tj.get("target") or 0)
                        st_total = int(_tj.get("start_total") or total)
                except Exception:
                    pass
                completed = max(0, total - st_total) if tgt is not None else 0
                achieved = (tgt is not None) and (completed >= tgt)
                self._json(200, {"ok": True, "running": is_run, "total": total,
                                  "recent": [{"title": r[0], "artist": r[1] or ""} for r in recent],
                                  "run_count": len(run_songs),
                                  "run_skipped": run_data.get("skipped", 0),
                                  "run_songs": [{"title": str(s.get("title", "")), "artist": str(s.get("artist", "") or ""), "audio": bool(s.get("audio"))} for s in run_songs],
                                  "started": run_data.get("started"),
                                  "target": tgt, "completed": completed,
                                  "remaining": max(0, (tgt - completed) if tgt is not None else 0),
                                  "achieved": achieved})
                return

            # ---------- 采集搜索代理（前端 H5 搜索歌名） ----------
            if u.path == "/api/collect/search":
                q = urllib.parse.parse_qs(u.query)
                src_p = (q.get("source") or ["wy"])[0]
                kw_p = (q.get("kw") or [""])[0].strip()
                page_p = (q.get("page") or ["1"])[0]
                limit_p = (q.get("limit") or ["15"])[0]
                if not kw_p:
                    self._json(200, {"ok": False, "err": "kw required"}); return
                try:
                    br_url = "http://127.0.0.1:8789/search?source=" + urllib.parse.quote(src_p) + \
                             "&kw=" + urllib.parse.quote(kw_p) + "&page=" + urllib.parse.quote(page_p) + \
                             "&limit=" + urllib.parse.quote(limit_p)
                    with urllib.request.urlopen(br_url, timeout=25) as _r:
                        _data = json.loads(_r.read().decode())
                    self._json(200, _data); return
                except Exception as e:
                    self._json(200, {"ok": False, "err": str(e)}); return

            # ---------- 汽水音乐分享链接：解析预览（H5 专用，不下载不入库） ----------
            if u.path == "/api/collect/parse-share":
                q = urllib.parse.parse_qs(u.query)
                share_url = (q.get("url") or [""])[0].strip()
                if not share_url:
                    self._json(200, {"ok": False, "err": "url required"}); return
                if not rate_limit(self, "collect", extra="parse_share"):
                    self._err(429, "请求过于频繁，请稍后再试"); return
                try:
                    m = _qishui_parse_share(share_url)
                    c = db()
                    dup = c.execute("SELECT title FROM collected_tracks WHERE source='qs' AND source_id=?", (m["track_id"],)).fetchone()
                    c.close()
                    self._json(200, {"ok": True, "track": m, "exists": bool(dup), "exists_title": (dup[0] if dup else "")})
                    return
                except Exception as e:
                    self._json(200, {"ok": False, "err": "解析失败：" + str(e)}); return

            # ---------- 汽水音乐分享链接采集页（H5） ----------
            if u.path == "/share.html":
                share_html = _render_template("share_collect.html")
                self._send_html(share_html)
                return

            # ---------- 后台管理 API ----------
            ADMIN_TOKEN = _admin_token()
            def _admin_auth(self):
                return self.headers.get("X-Admin-Token", "").strip() == ADMIN_TOKEN

            if u.path == "/admin.html":
                admin_html = _render_template("admin.html")
                body=admin_html.encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type","text/html; charset=utf-8")
                self.send_header("Content-Length",str(len(body)))
                self.send_header("Access-Control-Allow-Origin","*")
                self.end_headers();self.wfile.write(body);return

            if u.path == "/api/admin/stats":
                if not _admin_auth(self): self._err(401,"unauthorized"); return
                c=db()
                users=c.execute("SELECT COUNT(*) FROM users").fetchone()[0]
                tracks=c.execute("SELECT COUNT(*) FROM tracks").fetchone()[0]
                coll=c.execute("SELECT COUNT(*) FROM collected_tracks").fetchone()[0]
                plays=c.execute("SELECT COALESCE(SUM(play_count),0) FROM tracks").fetchone()[0] + c.execute("SELECT COALESCE(SUM(play_count),0) FROM collected_tracks").fetchone()[0]
                c.close()
                self._json(200,{"ok":True,"users":users,"tracks":tracks,"collected":coll,"plays":plays});return

            if u.path == "/api/admin/users":
                if not _admin_auth(self): self._err(401,"unauthorized"); return
                c=db()
                rows=c.execute("""SELECT u.id,u.account,u.name,u.avatar,u.gender,u.age,u.signature,u.ip_address,u.banned,u.ban_reason,u.created,
                                  (SELECT COUNT(*) FROM tracks t WHERE t.user_id=u.id)
                                  FROM users u ORDER BY u.created DESC""").fetchall()
                c.close()
                self._json(200,{"ok":True,"list":[{"id":r[0],"account":r[1] or "","name":r[2] or "","avatar":r[3] or "","gender":r[4] or "","age":r[5] or 0,"signature":r[6] or "","ip":r[7] or "","banned":r[8] or 0,"ban_reason":r[9] or "","created":r[10] or 0,"track_count":r[11]} for r in rows]});return

            if u.path == "/api/admin/tracks":
                if not _admin_auth(self): self._err(401,"unauthorized"); return
                qs = urllib.parse.parse_qs(u.query)
                page = max(1, int((qs.get("page") or ["1"])[0]))
                size = min(100, max(5, int((qs.get("size") or ["20"])[0])))
                c=db()
                total = c.execute("SELECT COUNT(*) FROM tracks").fetchone()[0]
                rows=c.execute("""SELECT t.id,t.title,t.artist,t.dur,t.size,t.play_count,t.created,t.user_id,t.offline,t.offline_reason,COALESCE(u.name,'')
                                  FROM tracks t LEFT JOIN users u ON u.id=t.user_id
                                  ORDER BY t.created DESC LIMIT ? OFFSET ?""",(size,(page-1)*size)).fetchall()
                c.close()
                self._json(200,{"ok":True,"total":total,"page":page,"size":size,"list":[{"id":r[0],"title":r[1] or "","artist":r[2] or "","dur":r[3] or 0,"size":r[4] or 0,"play_count":r[5] or 0,"created":r[6] or 0,"uname":r[10],"offline":r[8] or 0,"offline_reason":r[9] or ""} for r in rows]});return

            if u.path == "/api/admin/collected":
                if not _admin_auth(self): self._err(401,"unauthorized"); return
                qs = urllib.parse.parse_qs(u.query)
                page = max(1, int((qs.get("page") or ["1"])[0]))
                size = min(100, max(5, int((qs.get("size") or ["20"])[0])))
                c=db()
                total = c.execute("SELECT COUNT(*) FROM collected_tracks").fetchone()[0]
                rows=c.execute("""SELECT id,title,artist,source,duration,play_url,play_count,created,offline,offline_reason
                                  FROM collected_tracks ORDER BY created DESC LIMIT ? OFFSET ?""",(size,(page-1)*size)).fetchall()
                c.close()
                self._json(200,{"ok":True,"total":total,"page":page,"size":size,"list":[{"id":r[0],"title":r[1] or "","artist":r[2] or "","source":r[3] or "","duration":r[4] or 0,"has_local":bool(r[5] and not str(r[5]).startswith("http")),"play_count":r[6] or 0,"created":r[7] or 0,"offline":r[8] or 0,"offline_reason":r[9] or ""} for r in rows]});return

            if u.path == "/api/admin/comments":
                if not _admin_auth(self): self._err(401,"unauthorized"); return
                qs = urllib.parse.parse_qs(u.query)
                page = max(1, int((qs.get("page") or ["1"])[0]))
                size = min(100, max(5, int((qs.get("size") or ["20"])[0])))
                tid = (qs.get("track_id") or [""])[0]
                c = db()
                where, args = "", []
                if tid:
                    where = " WHERE cm.track_id=?"; args.append(tid)
                total = c.execute("SELECT COUNT(*) FROM comments cm" + where, args).fetchone()[0]
                rows = c.execute("""SELECT cm.id,cm.track_id,cm.user_name,cm.content,cm.created,
                                    COALESCE(t.title,'(已删除)')
                                    FROM comments cm LEFT JOIN tracks t ON t.id=cm.track_id
                                    """ + where + " ORDER BY cm.created DESC LIMIT ? OFFSET ?",
                                    tuple(args + [size, (page-1)*size])).fetchall()
                c.close()
                self._json(200, {"ok":True,"total":total,"page":page,"size":size,
                    "list":[{"id":r[0],"track_id":r[1],"user":r[2] or "","content":r[3] or "","created":r[4] or 0,"track_title":r[5]} for r in rows]});return

            # ---------- AI 接口配置（网站管理：AI key/base/model，写 ai_config.json 即时生效） ----------
            if u.path == "/api/admin/ai-config":
                if not _admin_auth(self): self._err(401, "unauthorized"); return
                if self.command == "GET":
                    cfg = _ai_cfg()
                    key = cfg.get("key") or ""
                    masked = (key[:4] + "****" + key[-4:]) if len(key) > 8 else ("已配置" if key else "")
                    self._json(200, {"ok": True, "base": cfg.get("base", ""),
                                     "model": cfg.get("model", ""),
                                     "keyMasked": masked, "hasKey": bool(key)})
                    return
                if self.command == "POST":
                    try:
                        ln = int(self.headers.get("Content-Length") or 0)
                        body = json.loads(self.rfile.read(ln).decode("utf-8") or "{}") if ln else {}
                    except Exception:
                        body = {}
                    _ai_save_config(base=body.get("base"), key=body.get("key"), model=body.get("model"))
                    self._json(200, {"ok": True, "saved": True}); return
                self._err(400, "bad request"); return

            # ---------- AI 乐评账号形象（名称/签名/头像，网站管理） ----------
            if u.path == "/api/admin/ai-profile":
                if not _admin_auth(self): self._err(401, "unauthorized"); return
                p = _ai_profile()
                self._json(200, {"ok": True, **p}); return

            # ---------- AI 主动乐评管理（网站管理：状态/配置/手动触发/删除） ----------
            if u.path.startswith("/api/admin/ai-comment"):
                if not _admin_auth(self): self._err(401, "unauthorized"); return
                seg = u.path[len("/api/admin/ai-comment"):]
                if u.path == "/api/admin/ai-comment":
                    if self.command == "GET":
                        stats = _ai_comment_stats()
                        c = db()
                        try:
                            logs = c.execute(
                                "SELECT id,run_type,track_id,track_title,status,comment_id,reason,created "
                                "FROM ai_comment_logs ORDER BY created DESC LIMIT 50").fetchall()
                        finally:
                            c.close()
                        stats["logs"] = [{"id": r[0], "runType": r[1], "trackId": r[2],
                                          "trackTitle": r[3], "status": r[4], "commentId": r[5],
                                          "reason": r[6], "created": r[7]} for r in logs]
                        self._json(200, {"ok": True, **stats}); return
                    if self.command == "POST":
                        try:
                            ln = int(self.headers.get("Content-Length") or 0)
                            body = json.loads(self.rfile.read(ln).decode("utf-8") or "{}") if ln else {}
                        except Exception:
                            body = {}
                        c = db()
                        try:
                            for k in ("enabled", "interval", "count", "max_per_track", "skip_days"):
                                if k in body:
                                    c.execute("INSERT OR REPLACE INTO ai_comment_cfg(key,value) VALUES(?,?)",
                                              (k, str(body[k])))
                            c.commit()
                        finally:
                            c.close()
                        self._json(200, {"ok": True, "settings": _ai_auto_settings()}); return
                    self._err(400, "bad request"); return
                if seg == "/run" and self.command == "POST":
                    try:
                        ln = int(self.headers.get("Content-Length") or 0)
                        body = json.loads(self.rfile.read(ln).decode("utf-8") or "{}") if ln else {}
                    except Exception:
                        body = {}
                    res = _ai_auto_run("manual", count=body.get("count"),
                                       force=bool(body.get("force", False)))
                    self._json(200, {"ok": True, **res}); return
                if seg.startswith("/") and len(seg) > 1 and self.command == "DELETE":
                    cid = seg[1:]
                    c = db()
                    try:
                        c.execute("DELETE FROM comments WHERE id=? AND user_id=?", (cid, _ai_uid()))
                        c.commit()
                    finally:
                        c.close()
                    self._json(200, {"ok": True}); return
                self._err(400, "bad request"); return

            if u.path == "/api/tracks":
                if not rate_limit(self, "tracks"):
                    self._err(429, "请求过于频繁，请稍后再试")
                    return
                c = db()
                qs = urllib.parse.parse_qs(u.query)
                viewer_id = (qs.get("userId", [""])[0] or "").strip()
                # token 优先识别查看者（新客户端）；无 token 回退 userId 参数（旧客户端）
                tok_uid = resolve_token(c, self.headers.get("Authorization", ""))
                if tok_uid:
                    viewer_id = tok_uid
                # 可选 q 参数：构建「相关歌曲流」——按歌名/歌手/专辑/上传者昵称匹配，
                # 命中歌曲随机取 10 首；不足 10 首时用全量随机补足（无相关即全随机）。
                # 不传 q 时保持原有全量随机 10 首行为。
                keyword = (qs.get("q", [""])[0] or "").strip()
                base_sql = """SELECT t.id,t.title,t.artist,t.album,t.cover,t.fname,t.size,t.dur,t.created,
                              t.play_count,t.like_count,t.share_count,t.user_id,t.lrc,
                              COALESCE(u.name,''),
                              (SELECT COUNT(*) FROM comments cm WHERE cm.track_id=t.id),
                              MAX(CASE WHEN l.user_id IS NOT NULL THEN 1 ELSE 0 END)
                              FROM tracks t
                              LEFT JOIN users u ON u.id=t.user_id
                              LEFT JOIN likes l ON l.track_id=t.id AND l.user_id=?"""
                if keyword:
                    like = "%" + keyword + "%"
                    rows = c.execute(
                        base_sql + """ WHERE t.offline=0 AND (t.title LIKE ? OR t.artist LIKE ? OR t.album LIKE ?
                                       OR COALESCE(u.name,'') LIKE ?)
                                       GROUP BY t.id ORDER BY RANDOM() LIMIT 10""",
                        (viewer_id, like, like, like, like)).fetchall()
                    if len(rows) < 10:
                        ids = [r[0] for r in rows]
                        need = 10 - len(rows)
                        if ids:
                            ph = ",".join("?" * len(ids))
                            extra = c.execute(
                                base_sql + (" WHERE t.offline=0 AND t.id NOT IN (%s)"
                                            " GROUP BY t.id ORDER BY RANDOM() LIMIT ?" % ph),
                                tuple([viewer_id] + ids + [need])).fetchall()
                        else:
                            extra = c.execute(
                                base_sql + " WHERE t.offline=0 GROUP BY t.id ORDER BY RANDOM() LIMIT ?",
                                (viewer_id, need)).fetchall()
                        rows = rows + extra
                else:
                    rows = c.execute(
                        base_sql + " WHERE t.offline=0 GROUP BY t.id ORDER BY RANDOM() LIMIT 10",
                        (viewer_id,)).fetchall()
                # ---- 合并采集歌曲（collected_tracks）----
                # 前端零改动：采集歌曲与用户上传歌曲通过同一个 /api/tracks 下发，
                # 字段结构与 tracks 完全一致；cover 返回占位 "1" 让前端拼出
                # /api/cover/{id}，再由后端 302 到第三方封面，不暴露第三方直链。
                collect_cols = """id,title,artist,album,cover,duration,size,created,
                                  play_count,like_count,share_count,user_id,lrc"""
                if keyword:
                    like = "%" + keyword + "%"
                    crows = c.execute(
                        "SELECT " + collect_cols + """ FROM collected_tracks
                            WHERE offline=0 AND (title LIKE ? OR artist LIKE ? OR album LIKE ?)
                            ORDER BY RANDOM() LIMIT 10""",
                        (like, like, like)).fetchall()
                    if len(crows) < 10:
                        cids = [r[0] for r in crows]
                        need = 10 - len(crows)
                        if cids:
                            ph = ",".join("?" * len(cids))
                            crows = crows + c.execute(
                                "SELECT " + collect_cols + (" FROM collected_tracks"
                                    " WHERE offline=0 AND id NOT IN (%s) ORDER BY RANDOM() LIMIT ?" % ph),
                                tuple(cids + [need])).fetchall()
                        else:
                            crows = crows + c.execute(
                                "SELECT " + collect_cols + " FROM collected_tracks WHERE offline=0"
                                " ORDER BY RANDOM() LIMIT ?", (need,)).fetchall()
                else:
                    crows = c.execute(
                        "SELECT " + collect_cols + " FROM collected_tracks WHERE offline=0"
                        " ORDER BY RANDOM() LIMIT 10").fetchall()
                # 采集歌曲归属账号昵称（列表展示用）
                uname = ""
                urow = c.execute(
                    "SELECT name FROM users WHERE id=(SELECT user_id FROM collected_tracks"
                    " WHERE user_id!='' LIMIT 1)").fetchone()
                if urow:
                    uname = urow[0]
                merged = [{"id": r[0], "title": r[1], "artist": r[2], "album": r[3],
                           "cover": "1", "fname": "",
                           "size": int(r[6]) if r[6] is not None else 0,   # App 端 size 为 Int?，浮点会导致整个列表解码失败
                           "dur": r[5],
                           "durText": _fmt_dur(r[5]), "created": r[7],
                           "playCount": r[8] or 0, "likeCount": r[9] or 0,
                           "shareCount": r[10] or 0,
                           "userId": r[11] or "", "userName": uname,
                           "hasLyric": bool(r[12]),
                           "commentCount": 0, "isLiked": False} for r in crows]
                # 用户上传歌曲输出
                merged += [{"id": r[0], "title": r[1], "artist": r[2], "album": r[3],
                            "cover": r[4], "fname": r[5], "size": r[6], "dur": r[7],
                            "durText": _fmt_dur(r[7]), "created": r[8],
                            "playCount": r[9] or 0, "likeCount": r[10] or 0,
                            "shareCount": r[11] or 0,
                            "userId": r[12] or "", "userName": r[14] or "",
                            "hasLyric": bool(r[13]),
                            "commentCount": r[15] or 0,
                            "isLiked": bool(r[16])} for r in rows]
                random.shuffle(merged)
                c.close()
                self._json(200, merged)
                return

            # 单曲详情（通知点击跳转播放用：按 id 精确查，用户上传表 + 采集表都覆盖；
            # /api/tracks 无参数时只随机返回 10 首，无法保证命中通知里的那首歌）
            if u.path.startswith("/api/track/"):
                if not rate_limit(self, "tracks"):
                    self._err(429, "请求过于频繁，请稍后再试")
                    return
                tid = u.path.rsplit("/", 1)[-1]
                c = db()
                tok_uid = resolve_token(c, self.headers.get("Authorization", ""))
                viewer_id = tok_uid or ""
                row = c.execute(
                    """SELECT t.id,t.title,t.artist,t.album,t.cover,t.fname,t.size,t.dur,t.created,
                              t.play_count,t.like_count,t.share_count,t.user_id,t.lrc,
                              COALESCE(u.name,''),
                              (SELECT COUNT(*) FROM comments cm WHERE cm.track_id=t.id),
                              MAX(CASE WHEN l.user_id IS NOT NULL THEN 1 ELSE 0 END)
                              FROM tracks t LEFT JOIN users u ON u.id=t.user_id
                              LEFT JOIN likes l ON l.track_id=t.id AND l.user_id=?
                              WHERE t.id=? AND t.offline=0 GROUP BY t.id""",
                    (viewer_id, tid)).fetchone()
                if row:
                    out = {"id": row[0], "title": row[1], "artist": row[2], "album": row[3],
                           "cover": row[4], "fname": row[5], "size": row[6], "dur": row[7],
                           "durText": _fmt_dur(row[7]), "created": row[8],
                           "playCount": row[9] or 0, "likeCount": row[10] or 0,
                           "shareCount": row[11] or 0, "userId": row[12] or "",
                           "userName": row[14] or "", "hasLyric": bool(row[13]),
                           "commentCount": row[15] or 0, "isLiked": bool(row[16])}
                else:
                    crow = c.execute(
                        """SELECT id,title,artist,album,cover,duration,size,created,
                                  play_count,like_count,share_count,user_id,lrc
                           FROM collected_tracks WHERE id=? AND offline=0""",
                        (tid,)).fetchone()
                    if not crow:
                        c.close()
                        self._err(404, "not found")
                        return
                    uname = ""
                    urow = c.execute("SELECT name FROM users WHERE id=?", (crow[11] or "",)).fetchone()
                    if urow:
                        uname = urow[0]
                    out = {"id": crow[0], "title": crow[1], "artist": crow[2], "album": crow[3],
                           "cover": "1", "fname": "",
                           "size": int(crow[6]) if crow[6] is not None else 0,
                           "dur": crow[5], "durText": _fmt_dur(crow[5]), "created": crow[7],
                           "playCount": crow[8] or 0, "likeCount": crow[9] or 0,
                           "shareCount": crow[10] or 0, "userId": crow[11] or "",
                           "userName": uname, "hasLyric": bool(crow[12]),
                           "commentCount": 0, "isLiked": False}
                c.close()
                self._json(200, out)
                return

            # 采集歌曲列表（独立表 collected_tracks，与用户上传 tracks 分开）
            if u.path == "/api/collect/list":
                if not rate_limit(self, "collect"):
                    self._err(429, "请求过于频繁，请稍后再试")
                    return
                qs = urllib.parse.parse_qs(u.query)
                page = max(1, int(qs.get("page", ["1"])[0] or 1))
                limit = min(50, max(1, int(qs.get("limit", ["20"])[0] or 20)))
                keyword = (qs.get("q", [""])[0] or "").strip()
                c = db()
                where = ""
                args = []
                if keyword:
                    like = "%" + keyword + "%"
                    where = " WHERE title LIKE ? OR artist LIKE ? OR album LIKE ?"
                    args = [like, like, like]
                total = c.execute("SELECT COUNT(*) FROM collected_tracks" + where, args).fetchone()[0]
                rows = c.execute(
                    "SELECT id,title,artist,album,cover,duration,source,source_id,play_url,created,user_id,play_count,like_count,share_count,lrc FROM collected_tracks"
                    + where + " ORDER BY created DESC LIMIT ? OFFSET ?",
                    args + [limit, (page - 1) * limit]).fetchall()
                c.close()
                self._json(200, {"total": total, "page": page, "limit": limit,
                                 "list": [{"id": r[0], "title": r[1], "artist": r[2], "album": r[3],
                                           "cover": r[4], "dur": r[5] or 0, "durText": _fmt_dur(r[5] or 0),
                                           "source": r[6], "sourceId": r[7], "playUrl": r[8],
                                           "created": r[9], "userId": r[10] or "",
                                           "playCount": r[11] or 0, "likeCount": r[12] or 0,
                                           "shareCount": r[13] or 0, "hasLyric": bool(r[14])} for r in rows]})
                return

            # 用户点赞的歌曲列表（我的喜欢：用户上传 + 采集歌曲混合，字段与 /api/tracks 一致）
            if u.path == "/api/likes":
                if not rate_limit(self, "tracks"):
                    self._err(429, "请求过于频繁，请稍后再试")
                    return
                qs = urllib.parse.parse_qs(u.query)
                viewer_id = (qs.get("userId", [""])[0] or "").strip()
                c = db()
                tok_uid = resolve_token(c, self.headers.get("Authorization", ""))
                if tok_uid:
                    viewer_id = tok_uid
                if not viewer_id:
                    c.close()
                    self._json(200, [])
                    return
                like_rows = c.execute(
                    "SELECT track_id FROM likes WHERE user_id=? ORDER BY created DESC LIMIT 300",
                    (viewer_id,)).fetchall()
                if not like_rows:
                    c.close()
                    self._json(200, [])
                    return
                ids = [r[0] for r in like_rows]
                ph = ",".join("?" * len(ids))
                # 用户上传歌曲
                rows = c.execute(
                    """SELECT t.id,t.title,t.artist,t.album,t.cover,t.fname,t.size,t.dur,t.created,
                       t.play_count,t.like_count,t.share_count,t.user_id,t.lrc,
                       COALESCE(u.name,''),
                       (SELECT COUNT(*) FROM comments cm WHERE cm.track_id=t.id), 1
                       FROM tracks t
                       LEFT JOIN users u ON u.id=t.user_id
                       WHERE t.offline=0 AND t.id IN (%s) GROUP BY t.id""" % ph, ids).fetchall()
                # 采集歌曲（字段与上传一致：cover 占位、size 强转 int）
                crows = c.execute(
                    "SELECT id,title,artist,album,cover,duration,size,created,"
                    " play_count,like_count,share_count,user_id,lrc"
                    " FROM collected_tracks WHERE offline=0 AND id IN (%s)" % ph, ids).fetchall()
                uname = ""
                urow = c.execute("SELECT name FROM users WHERE id=(SELECT user_id FROM collected_tracks"
                                 " WHERE user_id!='' LIMIT 1)").fetchone()
                if urow:
                    uname = urow[0]
                merged = [{"id": r[0], "title": r[1], "artist": r[2], "album": r[3],
                           "cover": "1", "fname": "",
                           "size": int(r[6]) if r[6] is not None else 0,
                           "dur": r[5], "durText": _fmt_dur(r[5]), "created": r[7],
                           "playCount": r[8] or 0, "likeCount": r[9] or 0,
                           "shareCount": r[10] or 0,
                           "userId": r[11] or "", "userName": uname,
                           "hasLyric": bool(r[12]), "commentCount": 0, "isLiked": True} for r in crows]
                merged += [{"id": r[0], "title": r[1], "artist": r[2], "album": r[3],
                            "cover": r[4], "fname": r[5], "size": r[6], "dur": r[7],
                            "durText": _fmt_dur(r[7]), "created": r[8],
                            "playCount": r[9] or 0, "likeCount": r[10] or 0,
                            "shareCount": r[11] or 0,
                            "userId": r[12] or "", "userName": r[14] or "",
                            "hasLyric": bool(r[13]), "commentCount": r[15] or 0,
                            "isLiked": True} for r in rows]
                # 保持点赞时间倒序（新点赞的在前）
                order = {rid: i for i, rid in enumerate(ids)}
                merged.sort(key=lambda x: order.get(x["id"], 999))
                c.close()
                self._json(200, merged)
                return

            # 搜索：按歌名/歌手模糊匹配（用户上传 + 采集歌曲统一返回，App 端无差别）
            if u.path == "/api/search":
                qs = urllib.parse.parse_qs(u.query)
                keyword = (qs.get("q", [""])[0] or "").strip()
                if not keyword:
                    self._json(200, [])
                    return
                viewer_id = (qs.get("userId", [""])[0] or "").strip()
                c = db()
                tok_uid = resolve_token(c, self.headers.get("Authorization", ""))
                if tok_uid:
                    viewer_id = tok_uid
                like = "%" + keyword + "%"
                rows = c.execute("""SELECT t.id,t.title,t.artist,t.album,t.cover,t.fname,t.size,t.dur,t.created,
                                    t.play_count,t.like_count,t.share_count,t.user_id,t.lrc,
                                    COALESCE(u.name,''),
                                    (SELECT COUNT(*) FROM comments cm WHERE cm.track_id=t.id),
                                    MAX(CASE WHEN l.user_id IS NOT NULL THEN 1 ELSE 0 END)
                                    FROM tracks t
                                    LEFT JOIN users u ON u.id=t.user_id
                                    LEFT JOIN likes l ON l.track_id=t.id AND l.user_id=?
                                    WHERE t.offline=0 AND (t.title LIKE ? OR t.artist LIKE ?)
                                    GROUP BY t.id
                                    ORDER BY t.play_count DESC
                                    LIMIT 50""", (viewer_id, like, like)).fetchall()
                # 采集歌曲同样参与搜索（字段结构与上传歌曲完全一致）
                crows = c.execute("""SELECT id,title,artist,album,cover,duration,size,created,
                                     play_count,like_count,share_count,user_id,lrc
                                     FROM collected_tracks
                                     WHERE offline=0 AND (title LIKE ? OR artist LIKE ?)
                                     ORDER BY play_count DESC
                                     LIMIT 50""", (like, like)).fetchall()
                uname = ""
                urow = c.execute(
                    "SELECT name FROM users WHERE id=(SELECT user_id FROM collected_tracks"
                    " WHERE user_id!='' LIMIT 1)").fetchone()
                if urow:
                    uname = urow[0]
                c.close()
                out = [{"id": r[0], "title": r[1], "artist": r[2], "album": r[3],
                        "cover": "1", "fname": "",
                        "size": int(r[6]) if r[6] is not None else 0,
                        "dur": r[5], "durText": _fmt_dur(r[5]),
                        "created": r[7],
                        "playCount": r[8] or 0, "likeCount": r[9] or 0,
                        "shareCount": r[10] or 0,
                        "userId": r[11] or "", "userName": uname,
                        "hasLyric": bool(r[12]),
                        "commentCount": 0, "isLiked": False} for r in crows]
                out += [{"id": r[0], "title": r[1], "artist": r[2], "album": r[3],
                         "cover": r[4], "fname": r[5], "size": r[6], "dur": r[7],
                         "durText": _fmt_dur(r[7]), "created": r[8],
                         "playCount": r[9] or 0, "likeCount": r[10] or 0,
                         "shareCount": r[11] or 0,
                         "userId": r[12] or "", "userName": r[14] or "",
                         "hasLyric": bool(r[13]),
                         "commentCount": r[15] or 0,
                         "isLiked": bool(r[16])} for r in rows]
                out.sort(key=lambda x: -(x["playCount"] or 0))
                self._json(200, out[:50])
                return

            # 官方通知列表（用户端）
            if u.path == "/api/official-messages":
                c = db()
                rows = c.execute("SELECT id, content, created, sender_name FROM official_messages ORDER BY created DESC LIMIT 100").fetchall()
                c.close()
                self._json(200, {"list": [{"id": r[0], "content": r[1], "created": r[2], "sender": r[3]} for r in rows]})
                return

            # 用户通知列表
            if u.path == "/api/notifications":
                c = db()
                tok_uid = resolve_token(c, self.headers.get("Authorization", ""))
                if not tok_uid:
                    c.close()
                    self._json(200, {"list": [], "unread": 0, "hasMore": False})
                    return
                # 分页支持：page（从1开始）、size（默认20，最大50）
                qs = urllib.parse.parse_qs(u.query)
                page = max(1, int(qs.get("page", ["1"])[0] or "1"))
                size = min(50, max(1, int(qs.get("size", ["20"])[0] or "20")))
                offset = (page - 1) * size
                rows = c.execute("SELECT id, type, title, content, from_user_id, from_user_name, track_id, track_title, comment_id, is_read, created FROM notifications WHERE user_id=? AND is_deleted=0 ORDER BY created DESC LIMIT ? OFFSET ?",
                                (tok_uid, size, offset)).fetchall()
                unread = c.execute("SELECT COUNT(*) FROM notifications WHERE user_id=? AND is_read=0 AND is_deleted=0", (tok_uid,)).fetchone()[0]
                total = c.execute("SELECT COUNT(*) FROM notifications WHERE user_id=? AND is_deleted=0", (tok_uid,)).fetchone()[0]
                has_more = (offset + len(rows)) < total
                c.close()
                self._json(200, {"list": [{"id": r[0], "type": r[1], "title": r[2], "content": r[3], "fromUserId": r[4], "fromUser": r[5], "trackId": r[6], "trackTitle": r[7], "commentId": r[8], "isRead": r[9], "created": r[10]} for r in rows], "unread": unread, "hasMore": has_more, "total": total})
                return

            # 后台：官方通知列表
            if u.path == "/api/admin/official-messages":
                admin_token = self.headers.get("X-Admin-Token", "").strip()
                if admin_token != _admin_token():
                    self._err(401, "unauthorized"); return
                c = db()
                rows = c.execute("SELECT id, content, created, sender_name FROM official_messages ORDER BY created DESC LIMIT 200").fetchall()
                c.close()
                self._json(200, {"list": [{"id": r[0], "content": r[1], "created": r[2], "sender": r[3]} for r in rows]})
                return

            # 天气×心情场景快照（M2）：前端"今日心情卡片"用；失败返回 {ok:false}，绝不 5xx（前端静默降级）
            if u.path == "/api/weather":
                if not rate_limit(self, "weather"):
                    self._err(429, "请求过于频繁，请稍后再试")
                    return
                qs = urllib.parse.parse_qs(u.query)
                try:
                    _lat_s = (qs.get("lat", [""])[0] or "").strip()
                    _lng_s = (qs.get("lng", [""])[0] or "").strip()
                    if not _lat_s or not _lng_s:
                        self._json(200, {"ok": False, "error": "missing lat/lng"})
                        return
                    _lat, _lng = float(_lat_s), float(_lng_s)
                    _hour_s = (qs.get("hour", [""])[0] or "").strip()
                    _hour = int(_hour_s) if _hour_s.isdigit() and 0 <= int(_hour_s) <= 23 else None
                    _wx = _fetch_weather(_lat, _lng)
                    if not _wx:
                        self._json(200, {"ok": False, "error": "weather unavailable"})
                        return
                    _scene = _scene_for(_wx.get("code"), _wx.get("temp"), _hour)
                    self._json(200, {"ok": True,
                                     "temp": _wx.get("temp"), "code": _wx.get("code"),
                                     "hour": _hour if _hour is not None else int(time.localtime().tm_hour),
                                     "scene": _scene.get("key") if _scene else None,
                                     "sceneLabel": _scene.get("label") if _scene else None})
                except Exception:
                    self._json(200, {"ok": False, "error": "invalid params"})
                return

            if u.path == "/api/recommend":
                if not rate_limit(self, "recommend"):
                    self._err(429, "请求过于频繁，请稍后再试")
                    return
                qs = urllib.parse.parse_qs(u.query)
                viewer_id = (qs.get("userId", [""])[0] or "").strip()
                c = db()
                tok_uid = resolve_token(c, self.headers.get("Authorization", ""))
                if tok_uid:
                    viewer_id = tok_uid
                # exclude：已推荐过的歌曲 id（逗号分隔）——推荐流无限续推防重复
                _excl = set()
                _ex_s = (qs.get("exclude", [""])[0] or "").strip()
                if _ex_s:
                    _excl = {x for x in _ex_s.split(",") if x}
                # fresh：长时间重开 App 的新鲜会话——加大随机扰动/探索权重，重开不固定重复
                _fresh = (qs.get("fresh", ["0"])[0] or "").strip() in ("1", "true")
                # source：来源标记——"discover"（发现页猜你喜欢）不参与 3 小时推送去重，
                # 不排除已推歌也不记录本次推送（去重只对播放页首页推荐流生效）
                _source = (qs.get("source", [""])[0] or "").strip()
                _now = time.time()
                # M2 场景上下文：前端传 lat/lng（可选 hour）→ 取天气（TTL 缓存）+ 时段 → 心情场景。
                # 任何异常/缺参 → scene=None（静默降级，推荐照常，不影响主流程）
                _scene = None
                try:
                    _lat_s = (qs.get("lat", [""])[0] or "").strip()
                    _lng_s = (qs.get("lng", [""])[0] or "").strip()
                    _hour_s = (qs.get("hour", [""])[0] or "").strip()
                    if _lat_s and _lng_s:
                        _lat, _lng = float(_lat_s), float(_lng_s)
                        _hour = int(_hour_s) if _hour_s.isdigit() and 0 <= int(_hour_s) <= 23 else None
                        _wx = _fetch_weather(_lat, _lng)
                        _scene = _scene_for(_wx.get("code") if _wx else None,
                                            _wx.get("temp") if _wx else None, _hour)
                except Exception:
                    _scene = None
                # 3 小时推送去重：取该用户 3 小时内已推送过的歌，本次不再推送
                # （仅播放页首页推荐流；发现页猜你喜欢不受限）
                _pushed = set()
                if _source != "discover":
                    _pushed = _rec_recent_pushed(viewer_id, _now)
                # 批次轮换：时间桶（同桶主批稳定可复现）+ 会话内序号递增（每次获取不同批）
                _bucket = int(_now // REC_BUCKET_SECONDS)
                _seq, _rnd = _rec_next_seq(viewer_id, _bucket, _now, fresh=_fresh)
                log.info("recommend uid=%s bucket=%d seq=%d fresh=%s pushed=%d",
                         viewer_id or "-", _bucket, _seq, _fresh, len(_pushed))
                # 多路召回 + 加权融合 + MMR 重排（算法见 build_recommendations）
                rec_pairs = build_recommendations(c, viewer_id, exclude=_excl, fresh=_fresh, rnd=_rnd,
                                                  pushed=_pushed, scene=_scene)
                chosen = [tid for tid, _ in rec_pairs]
                reason_map = dict(rec_pairs)
                if not chosen:
                    c.close()
                    self._json(200, [])
                    return
                # 5) 组装输出（与 /api/tracks 同一格式，采集/上传无差别）
                ph = ",".join("?" * len(chosen))
                trows = c.execute("""SELECT t.id,t.title,t.artist,t.album,t.cover,t.fname,t.size,t.dur,t.created,
                                     t.play_count,t.like_count,t.share_count,t.user_id,t.lrc,
                                     COALESCE(u.name,''),
                                     (SELECT COUNT(*) FROM comments cm WHERE cm.track_id=t.id),
                                     MAX(CASE WHEN l.user_id IS NOT NULL THEN 1 ELSE 0 END)
                                     FROM tracks t
                                     LEFT JOIN users u ON u.id=t.user_id
                                     LEFT JOIN likes l ON l.track_id=t.id AND l.user_id=?
                                     WHERE t.id IN (%s) GROUP BY t.id""" % ph,
                                   tuple([viewer_id] + chosen)).fetchall()
                crows = c.execute("""SELECT id,title,artist,album,cover,duration,size,created,
                                     play_count,like_count,share_count,user_id,lrc
                                     FROM collected_tracks WHERE id IN (%s)""" % ph, chosen).fetchall()
                uname = ""
                urow = c.execute(
                    "SELECT name FROM users WHERE id=(SELECT user_id FROM collected_tracks"
                    " WHERE user_id!='' LIMIT 1)").fetchone()
                if urow:
                    uname = urow[0]
                c.close()
                merged = [{"id": r[0], "title": r[1], "artist": r[2], "album": r[3],
                           "cover": "1", "fname": "",
                           "size": int(r[6]) if r[6] is not None else 0,
                           "dur": r[5], "durText": _fmt_dur(r[5]), "created": r[7],
                           "playCount": r[8] or 0, "likeCount": r[9] or 0,
                           "shareCount": r[10] or 0,
                           "userId": r[11] or "", "userName": uname,
                           "hasLyric": bool(r[12]),
                           "reason": reason_map.get(r[0], "推荐"),
                           "commentCount": 0, "isLiked": False} for r in crows]
                merged += [{"id": r[0], "title": r[1], "artist": r[2], "album": r[3],
                            "cover": r[4], "fname": r[5], "size": r[6], "dur": r[7],
                            "durText": _fmt_dur(r[7]), "created": r[8],
                            "playCount": r[9] or 0, "likeCount": r[10] or 0,
                            "shareCount": r[11] or 0,
                            "userId": r[12] or "", "userName": r[14] or "",
                            "hasLyric": bool(r[13]),
                            "reason": reason_map.get(r[0], "推荐"),
                            "commentCount": r[15] or 0,
                            "isLiked": bool(r[16])} for r in trows]
                order = {tid: i for i, tid in enumerate(chosen)}
                merged.sort(key=lambda x: order.get(x["id"], 999))
                # 记录本次推送的歌曲：3 小时内不再重复推送（滑动窗口自然过期）
                # 仅播放页首页推荐流记录；发现页猜你喜欢不占用去重窗口
                if _source != "discover":
                    _rec_remember_pushed(viewer_id, chosen, _now)
                self._json(200, merged)
                return

            if u.path.startswith("/api/cover/"):
                tid = u.path.rsplit("/", 1)[-1]
                c = db()
                row = c.execute("SELECT cover FROM tracks WHERE id=?", (tid,)).fetchone()
                crow = c.execute("SELECT cover FROM collected_tracks WHERE id=?", (tid,)).fetchone()
                c.close()
                fp = safe_file_path(row[0] if row else "")
                if not fp and crow:
                    fp = safe_file_path(crow[0] or "")
                if not fp:
                    # 采集歌曲封面：优先服务本地下载的 files/{id}_cover.jpg（手机端可直接加载）
                    local = safe_file_path(tid + "_cover.jpg")
                    if local and os.path.exists(local):
                        self._serve_file(cover_small(local, tid))
                        return
                    # 本地封面缺失：保留第三方直链 302 兜底（仅当 cover 为 http 地址）
                    if crow and crow[0] and str(crow[0]).startswith("http"):
                        self.send_response(302)
                        self.send_header("Location", crow[0])
                        self.send_header("Cache-Control", "no-store")
                        self.send_header("Access-Control-Allow-Origin", "*")
                        self.end_headers()
                        return
                    self._err(404, "no cover")
                    return
                self._serve_file(cover_small(fp, tid))
                return

            if u.path.startswith("/api/lyric/"):
                tid = u.path.rsplit("/", 1)[-1]
                c = db()
                row = c.execute("SELECT lrc FROM tracks WHERE id=?", (tid,)).fetchone()
                # 采集歌曲歌词：库内 lrc 文本直接返回（非文件路径）
                crow = c.execute("SELECT lrc FROM collected_tracks WHERE id=?", (tid,)).fetchone()
                c.close()
                fp = safe_file_path(row[0] if row else "")
                if not fp:
                    if crow and crow[0]:
                        data = crow[0].encode("utf-8")
                        self.send_response(200)
                        self.send_header("Content-Type", "text/plain; charset=utf-8")
                        self.send_header("Access-Control-Allow-Origin", "*")
                        self.send_header("Content-Length", str(len(data)))
                        self.end_headers()
                        self.wfile.write(data)
                        return
                    self._err(404, "no lyric")
                    return
                with open(fp, "rb") as f:
                    data = f.read()
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return

            if u.path.startswith("/api/avatar/"):
                uid_ = u.path.rsplit("/", 1)[-1]
                c = db()
                row = c.execute("SELECT avatar FROM users WHERE id=?", (uid_,)).fetchone()
                c.close()
                fp = safe_file_path(row[0] if row else "")
                if not fp:
                    self._err(404, "no avatar")
                    return
                self._serve_file(fp)
                return

            if u.path.startswith("/api/background/"):
                uid_ = u.path.rsplit("/", 1)[-1]
                c = db()
                row = c.execute("SELECT background_image FROM users WHERE id=?", (uid_,)).fetchone()
                c.close()
                fp = safe_file_path(row[0] if row else "")
                if not fp:
                    self._err(404, "no background")
                    return
                self._serve_file(fp)
                return

            if u.path.startswith("/api/comment-image/"):
                name = u.path.rsplit("/", 1)[-1]
                # 白名单：只允许本服务评论图片上传接口生成的文件名（防目录穿越/任意文件读取）
                if not re.fullmatch(r"cmt_[0-9a-f]{32}\.(?:jpg|jpeg|png|webp)", name):
                    self._err(404, "no image")
                    return
                fp = safe_file_path(name)
                if not fp or not os.path.exists(fp):
                    self._err(404, "no image")
                    return
                self._serve_file(fp)
                return

            if u.path.startswith("/api/comments/"):
                tid = u.path.rsplit("/", 1)[-1]
                c = db()
                rows = c.execute("""SELECT id,user_id,user_name,content,images,created
                                    FROM comments WHERE track_id=? ORDER BY created DESC LIMIT 200""",
                                 (tid,)).fetchall()
                # AI 标识：评论者是否为 AI 乐评账号（透明标识）
                ai_ids = set()
                user_ids = {r[1] for r in rows if r[1]}
                if user_ids:
                    for (i,) in c.execute(
                            "SELECT id FROM users WHERE id IN (%s) AND is_ai=1" %
                            ",".join("?" * len(user_ids)), tuple(user_ids)).fetchall():
                        ai_ids.add(i)
                c.close()
                def _parse_images(raw):
                    if not raw:
                        return []
                    try:
                        v = json.loads(raw)
                        return v if isinstance(v, list) else []
                    except Exception:
                        return []
                self._json(200, [{"id": r[0], "userId": r[1], "userName": r[2],
                                  "content": r[3], "images": _parse_images(r[4]),
                                  "created": r[5], "isAi": r[1] in ai_ids} for r in rows])
                return

            # 流签名签发：GET /api/stream-url/{id} → {"sig","exp"}，前端拼接到流 URL
            if u.path.startswith("/api/stream-url/"):
                if not rate_limit(self, "stream"):
                    self._err(429, "请求过于频繁，请稍后再试")
                    return
                tid = u.path.rsplit("/", 1)[-1]
                c = db()
                exists = c.execute("SELECT 1 FROM tracks WHERE id=?", (tid,)).fetchone()
                if not exists:
                    # 采集歌曲同样签发签名（播放链路见 /api/stream 分支）
                    exists = c.execute("SELECT 1 FROM collected_tracks WHERE id=?", (tid,)).fetchone()
                c.close()
                if not exists:
                    self._err(404, "not found")
                    return
                exp = int(time.time()) + STREAM_SIGN_TTL
                self._json(200, {"sig": sign_stream(tid, exp), "exp": exp})
                return

            # 分享 token 签发：GET /api/share-url/{id} → {"token","code"}（一首歌固定，链接隐藏歌曲 ID）
            if u.path.startswith("/api/share-url/"):
                if not rate_limit(self, "share_url"):
                    self._err(429, "请求过于频繁，请稍后再试")
                    return
                tid = u.path.rsplit("/", 1)[-1]
                c = db()
                row = c.execute("SELECT token, short_code FROM share_tokens WHERE track_id=?", (tid,)).fetchone()
                if not row:
                    # 先查上传歌曲，再查采集歌曲（两类歌曲都支持分享短链）
                    row = c.execute("SELECT 1 FROM tracks WHERE id=?", (tid,)).fetchone()
                    if not row:
                        row = c.execute("SELECT 1 FROM collected_tracks WHERE id=?", (tid,)).fetchone()
                    if not row:
                        c.close()
                        self._err(404, "not found")
                        return
                    for _ in range(5):
                        tok = secrets.token_hex(6)          # 12 位随机，不可反推歌曲 ID
                        code = gen_short_code()             # 8 位短码（汽水风格短链）
                        try:
                            c.execute("INSERT INTO share_tokens(token, track_id, created, short_code) VALUES(?,?,?,?)",
                                      (tok, tid, time.time(), code))
                            c.commit()
                            row = (tok, code)
                            break
                        except sqlite3.IntegrityError:
                            continue
                elif not row[1]:
                    code = gen_short_code()
                    c.execute("UPDATE share_tokens SET short_code=? WHERE token=?", (code, row[0]))
                    c.commit()
                    row = (row[0], code)
                token, code = row
                c.close()
                self._json(200, {"token": token, "code": code})
                return

            # 短链：GET /s/{code}/ → 302 跳转落地页（汽水音乐风格，nginx /s/ 反代）
            if u.path.startswith("/s/"):
                if not rate_limit(self, "share_url"):
                    self._err(429, "请求过于频繁，请稍后再试")
                    return
                code = u.path.strip("/").rsplit("/", 1)[-1]
                c = db()
                row = c.execute("SELECT token FROM share_tokens WHERE short_code=?", (code,)).fetchone()
                c.close()
                if not row:
                    self._err(404, "not found")
                    return
                self.send_response(302)
                self.send_header("Location", "/music/api/share/%s" % row[0])
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                return

            # 分享 H5 页面：GET /api/share/{token} → 深黑灰极简单曲页（封面/歌名/作者 + 播放暂停/进度条）
            if u.path.startswith("/api/share/"):
                if not rate_limit(self, "share_url"):
                    self._err(429, "请求过于频繁，请稍后再试")
                    return
                token = u.path.rsplit("/", 1)[-1]
                c = db()
                row = c.execute("SELECT track_id, short_code FROM share_tokens WHERE token=?", (token,)).fetchone()
                if not row:
                    c.close()
                    self._err(404, "not found")
                    return
                tid, short_code = row
                tr = c.execute("""SELECT id, title, artist, cover, lrc, user_id,
                                  COALESCE((SELECT name FROM users WHERE id=tracks.user_id), '')
                                  FROM tracks WHERE id=?""", (tid,)).fetchone()
                if not tr:
                    # 采集歌曲：从 collected_tracks 取标题/歌手/封面
                    tr = c.execute("SELECT id, title, artist, cover, lrc, user_id, '' FROM collected_tracks WHERE id=?", (tid,)).fetchone()
                c.close()
                if not tr:
                    self._err(404, "not found")
                    return
                _, title, artist, cover, _lrc, _uid, uname = tr
                author = uname or artist or "未知歌手"
                page = self._share_page(title, author, tid, cover, short_code)
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(page)))
                self.send_header("Cache-Control", "no-store")
                self.send_header("X-Content-Type-Options", "nosniff")
                self.end_headers()
                self.wfile.write(page)
                return

            if u.path.startswith("/api/stream/"):
                # 签名校验：带签名参数必须通过；无签名在 SIGN_STRICT=1 时拒绝（默认兼容旧客户端）
                q = urllib.parse.parse_qs(u.query)
                exp_s = (q.get("exp") or [""])[0]
                sig = (q.get("sig") or [""])[0]
                if exp_s or sig:
                    if not verify_stream(u.path.rsplit("/", 1)[-1], exp_s, sig):
                        self._err(403, "stream link expired or invalid")
                        return
                elif SIGN_STRICT:
                    self._err(403, "stream link expired or invalid")
                    return
                if not rate_limit(self, "stream"):
                    self._err(429, "请求过于频繁，请稍后再试")
                    return
                tid = u.path.rsplit("/", 1)[-1]
                c = db()
                row = c.execute("SELECT fname FROM tracks WHERE id=?", (tid,)).fetchone()
                crow = c.execute("SELECT play_url FROM collected_tracks WHERE id=?", (tid,)).fetchone()
                c.close()
                fp = safe_file_path(row[0] if row else "")
                # 采集歌曲：已下载到本地时 play_url 存本地文件名，走本地流式播放（同 tracks）
                if not fp and crow and crow[0] and not str(crow[0]).startswith("http"):
                    local = safe_file_path(str(crow[0]))
                    if local and os.path.exists(local):
                        fp = local
                if not fp:
                    # 未下载的采集歌曲：保留第三方直链 302 兜底
                    if crow and crow[0] and str(crow[0]).startswith("http"):
                        self.send_response(302)
                        self.send_header("Location", crow[0])
                        self.send_header("Cache-Control", "no-store")
                        self.send_header("Access-Control-Allow-Origin", "*")
                        self.end_headers()
                        return
                    self._err(404, "not found")
                    return
                size = os.path.getsize(fp)
                ctype = mimetypes.guess_type(fp)[0] or "audio/mpeg"
                rng = self._parse_range(size)
                if rng is True:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{size}")
                    self.send_header("Access-Control-Allow-Origin", "*")
                    self.end_headers()
                    return
                if rng:
                    start, end = rng
                    length = end - start + 1
                    self.send_response(206)
                    self.send_header("Content-Type", ctype)
                    self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
                    self.send_header("Content-Length", str(length))
                    self.send_header("Accept-Ranges", "bytes")
                    self.send_header("Access-Control-Allow-Origin", "*")
                    self.end_headers()
                    try:
                        with open(fp, "rb") as f:
                            f.seek(start)
                            remain = length
                            while remain > 0:
                                chunk = f.read(min(65536, remain))
                                if not chunk:
                                    break
                                self.wfile.write(chunk)
                                remain -= len(chunk)
                    except (BrokenPipeError, ConnectionResetError):
                        pass
                    return
                self.send_response(200)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(size))
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                try:
                    with open(fp, "rb") as f:
                        while True:
                            chunk = f.read(65536)
                            if not chunk:
                                break
                            self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return

            self._err(404, "unknown")
        except (socket.timeout, TimeoutError):
            self._err(408, "request timeout")
        except Exception as e:
            self._internal_error(e)

    # ---- multipart 解析（带旧客户端兼容修复） ----

    def _parse_multipart(self, length):
        ctype = self.headers.get("Content-Type", "")
        if not ctype.startswith("multipart/form-data"):
            return None, None
        boundary = ctype.split("boundary=")[-1].encode()
        data = self.rfile.read(length)
        parts = data.split(b"--" + boundary)
        fields, files = {}, {}
        for p in parts:
            if b"Content-Disposition" not in p:
                continue
            head, _, body = p.partition(b"\r\n\r\n")
            head = head.decode("utf-8", "ignore")
            name = None
            if 'name="' in head:
                name = head.split('name="')[1].split('"')[0]
            fn = None
            if 'filename="' in head:
                fn = head.split('filename="')[1].split('"')[0]
            body = body.rstrip(b"\r\n")
            # 兼容：旧版客户端 Content-Disposition 后多写了 CRLF，
            # 导致 Content-Type 头混进文件二进制；剥掉残留头。
            if fn and body.startswith(b"Content-Type:"):
                idx = body.find(b"\r\n\r\n")
                if idx != -1:
                    body = body[idx + 4:]
            if fn:
                files[name] = (fn, body)
            elif name:
                fields[name] = body.decode("utf-8", "ignore")
        return fields, files

    # ---- POST ----

    def do_POST(self):
        try:
            u = urllib.parse.urlparse(self.path)
            length = int(self.headers.get("Content-Length", 0))

            # ---------- AI 乐评管理（网站管理）POST ----------
            if u.path == "/api/admin/ai-config":
                if self.headers.get("X-Admin-Token", "").strip() != _admin_token():
                    self._err(401, "unauthorized"); return
                try:
                    body = json.loads(self.rfile.read(length).decode("utf-8") or "{}") if length else {}
                except Exception:
                    body = {}
                _ai_save_config(base=body.get("base"), key=body.get("key"), model=body.get("model"))
                self._json(200, {"ok": True, "saved": True}); return
            if u.path == "/api/admin/ai-comment":
                if self.headers.get("X-Admin-Token", "").strip() != _admin_token():
                    self._err(401, "unauthorized"); return
                try:
                    body = json.loads(self.rfile.read(length).decode("utf-8") or "{}") if length else {}
                except Exception:
                    body = {}
                c = db()
                try:
                    for k in ("enabled", "interval", "count", "max_per_track", "skip_days"):
                        if k in body:
                            c.execute("INSERT OR REPLACE INTO ai_comment_cfg(key,value) VALUES(?,?)",
                                      (k, str(body[k])))
                    c.commit()
                finally:
                    c.close()
                self._json(200, {"ok": True, "settings": _ai_auto_settings()}); return
            if u.path == "/api/admin/ai-comment/run":
                if self.headers.get("X-Admin-Token", "").strip() != _admin_token():
                    self._err(401, "unauthorized"); return
                try:
                    body = json.loads(self.rfile.read(length).decode("utf-8") or "{}") if length else {}
                except Exception:
                    body = {}
                res = _ai_auto_run("manual", count=body.get("count"),
                                   force=bool(body.get("force", False)))
                self._json(200, {"ok": True, **res}); return

            # ---------- AI 乐评账号形象更新（名称/签名/头像，multipart，网站管理） ----------
            if u.path == "/api/admin/ai-profile":
                if self.headers.get("X-Admin-Token", "").strip() != _admin_token():
                    self._err(401, "unauthorized"); return
                try:
                    fields, files = self._parse_multipart(length)
                except Exception:
                    self._err(400, "need multipart"); return
                c = db()
                try:
                    name = (fields.get("name") or "").strip()[:MAX_NAME] or "AI 乐评"
                    signature = (fields.get("signature") or "").strip()[:100]
                    avatar_fname = None
                    av = files.get("avatar")
                    if av and av[1]:
                        aext = os.path.splitext(av[0])[1].lower()
                        if aext not in (".jpg", ".jpeg", ".png", ".webp", ".heic"):
                            aext = ".jpg"
                        if not image_magic_ok(av[1], aext):
                            c.close()
                            self._err(400, "头像文件格式校验失败")
                            return
                        avatar_fname = _ai_uid() + "_avatar" + aext
                        with open(os.path.join(FILES, avatar_fname), "wb") as f:
                            f.write(av[1])
                    if avatar_fname:
                        c.execute("UPDATE users SET name=?,signature=?,avatar=? WHERE id=?",
                                  (name, signature, avatar_fname, _ai_uid()))
                    else:
                        c.execute("UPDATE users SET name=?,signature=? WHERE id=?",
                                  (name, signature, _ai_uid()))
                    c.commit()
                finally:
                    c.close()
                p = _ai_profile()
                self._json(200, {"ok": True, **p}); return

            # ---------- 关注/取关用户 ----------
            if u.path.startswith("/api/user/") and u.path.endswith("/follow"):
                target_uid = u.path.split("/")[3]
                c = db()
                uid = resolve_token(c, self.headers.get("Authorization", ""))
                if not uid:
                    c.close()
                    self._err(401, "unauthorized"); return
                if target_uid == uid:
                    c.close()
                    self._err(400, "cannot follow yourself"); return
                # 检查目标用户是否存在
                target = c.execute("SELECT id, name FROM users WHERE id=?", (target_uid,)).fetchone()
                if not target:
                    c.close()
                    self._err(404, "user not found"); return
                # 切换关注状态
                existing = c.execute("SELECT follower_id FROM follows WHERE follower_id=? AND following_id=?", (uid, target_uid)).fetchone()
                if existing:
                    # 取消关注
                    c.execute("DELETE FROM follows WHERE follower_id=? AND following_id=?", (uid, target_uid))
                    is_following = False
                else:
                    # 关注
                    c.execute("INSERT INTO follows(follower_id, following_id, created) VALUES(?,?,?)",
                              (uid, target_uid, time.time()))
                    is_following = True
                    # 检查是否互关（对方也关注了我）
                    mutual = c.execute("SELECT follower_id FROM follows WHERE follower_id=? AND following_id=?", (target_uid, uid)).fetchone()
                    # 获取关注者信息
                    me = c.execute("SELECT name FROM users WHERE id=?", (uid,)).fetchone()
                    my_name = me[0] if me else "有人"
                    # 发通知给被关注者
                    notif_id = uuid.uuid4().hex
                    if mutual:
                        # 互关了，通知"回关了你"
                        content = f"{my_name}回关了你"
                    else:
                        # 新关注，通知"关注了你"
                        content = f"{my_name}关注了你"
                    c.execute("""INSERT INTO notifications(id, user_id, type, title, content, from_user_id, from_user_name, track_id, track_title, is_read, created)
                                 VALUES(?,?,?,?,?,?,?,?,?,?,?)""",
                              (notif_id, target_uid, "follow", "新粉丝",
                               content, uid, my_name, "", "", 0, time.time()))
                    # WebSocket 推送
                    ws_push(target_uid, {
                        "kind": "notification",
                        "notification": {"id": notif_id, "type": "follow",
                                         "title": "新粉丝",
                                         "content": content,
                                         "fromUserId": uid, "fromUser": my_name,
                                         "trackId": "", "trackTitle": "",
                                         "isRead": 0, "created": time.time()},
                        "unread": _notif_unread(c, target_uid)})
                c.commit()
                c.close()
                self._json(200, {"ok": True, "isFollowing": is_following})
                return

            # ---------- 记录播放历史 ----------
            if u.path == "/api/history":
                c = db()
                uid = resolve_token(c, self.headers.get("Authorization", ""))
                if not uid:
                    c.close()
                    self._err(401, "unauthorized"); return
                try:
                    raw = self.rfile.read(min(length, 8192))
                    data = json.loads(raw.decode("utf-8") or "{}")
                except Exception:
                    c.close()
                    self._err(400, "bad json"); return
                tid = (data.get("trackId") or "").strip()
                if tid:
                    # 同一首歌1分钟内重复播放，只更新时间不新增记录
                    recent = c.execute("SELECT id FROM play_history WHERE user_id=? AND track_id=? AND created > ? ORDER BY created DESC LIMIT 1",
                                     (uid, tid, time.time() - 60)).fetchone()
                    if recent:
                        c.execute("UPDATE play_history SET created=? WHERE id=?", (time.time(), recent[0]))
                    else:
                        c.execute("""INSERT INTO play_history(id, user_id, track_id, track_title, track_artist, track_cover, source, created)
                                     VALUES(?,?,?,?,?,?,?,?)""",
                                  (uuid.uuid4().hex, uid, tid,
                                   data.get("title") or "", data.get("artist") or "",
                                   data.get("cover") or "", data.get("source") or "upload", time.time()))
                c.commit()
                c.close()
                self._json(200, {"ok": True})
                return

            # ---------- 记录搜索历史 ----------
            if u.path == "/api/search/history":
                c = db()
                uid = resolve_token(c, self.headers.get("Authorization", ""))
                if not uid:
                    c.close()
                    self._err(401, "unauthorized"); return
                try:
                    raw = self.rfile.read(min(length, 4096))
                    data = json.loads(raw.decode("utf-8") or "{}")
                except Exception:
                    c.close()
                    self._err(400, "bad json"); return
                kw = (data.get("keyword") or "").strip()
                if kw:
                    # 同关键词1分钟内不重复记录
                    recent = c.execute("SELECT id FROM search_history WHERE user_id=? AND keyword=? AND created > ? ORDER BY created DESC LIMIT 1",
                                     (uid, kw, time.time() - 60)).fetchone()
                    if recent:
                        c.execute("UPDATE search_history SET created=? WHERE id=?", (time.time(), recent[0]))
                    else:
                        c.execute("INSERT INTO search_history(id, user_id, keyword, created) VALUES(?,?,?,?)",
                                  (uuid.uuid4().hex, uid, kw, time.time()))
                    # 最多保留20条
                    c.execute("""DELETE FROM search_history WHERE user_id=? AND id NOT IN
                                 (SELECT id FROM search_history WHERE user_id=? ORDER BY created DESC LIMIT 20)""",
                              (uid, uid))
                c.commit()
                c.close()
                self._json(200, {"ok": True})
                return

            # ---------- 创建歌单 ----------
            if u.path == "/api/playlists":
                c = db()
                uid = resolve_token(c, self.headers.get("Authorization", ""))
                if not uid:
                    c.close()
                    self._err(401, "unauthorized"); return
                try:
                    raw = self.rfile.read(min(length, 4096))
                    data = json.loads(raw.decode("utf-8") or "{}")
                except Exception:
                    c.close()
                    self._err(400, "bad json"); return
                name = (data.get("name") or "").strip()
                if not name:
                    c.close()
                    self._err(400, "name required"); return
                pid = uuid.uuid4().hex
                c.execute("""INSERT INTO playlists(id, user_id, name, cover, description, track_count, created)
                             VALUES(?,?,?,?,?,?,?)""",
                          (pid, uid, name, data.get("cover") or "", data.get("description") or "", 0, time.time()))
                c.commit()
                c.close()
                self._json(200, {"ok": True, "playlistId": pid})
                return

            # ---------- 添加歌曲到歌单 ----------
            if u.path.startswith("/api/playlists/") and u.path.endswith("/tracks"):
                pid = u.path.split("/")[3]
                c = db()
                uid = resolve_token(c, self.headers.get("Authorization", ""))
                if not uid:
                    c.close()
                    self._err(401, "unauthorized"); return
                pl = c.execute("SELECT id FROM playlists WHERE id=? AND user_id=?", (pid, uid)).fetchone()
                if not pl:
                    c.close()
                    self._err(404, "playlist not found"); return
                try:
                    raw = self.rfile.read(min(length, 8192))
                    data = json.loads(raw.decode("utf-8") or "{}")
                except Exception:
                    c.close()
                    self._err(400, "bad json"); return
                tid = (data.get("trackId") or "").strip()
                if tid:
                    # 检查是否已存在
                    existing = c.execute("SELECT 1 FROM playlist_tracks WHERE playlist_id=? AND track_id=?", (pid, tid)).fetchone()
                    if not existing:
                        cover = data.get("cover") or ""
                        c.execute("""INSERT INTO playlist_tracks(playlist_id, track_id, track_title, track_artist, track_cover, source, created)
                                     VALUES(?,?,?,?,?,?,?)""",
                                  (pid, tid, data.get("title") or "", data.get("artist") or "",
                                   cover, data.get("source") or "upload", time.time()))
                        c.execute("UPDATE playlists SET track_count=track_count+1 WHERE id=?", (pid,))
                        # 自动更新歌单封面：用最新添加的歌曲封面
                        if cover:
                            c.execute("UPDATE playlists SET cover=? WHERE id=?", (cover, pid))
                c.commit()
                c.close()
                self._json(200, {"ok": True})
                return

            # ---------- 点赞评论 ----------
            if u.path.startswith("/api/comments/") and u.path.endswith("/like"):
                cid = u.path.split("/")[3]
                c = db()
                uid = resolve_token(c, self.headers.get("Authorization", ""))
                if not uid:
                    c.close()
                    self._err(401, "unauthorized"); return
                # 检查评论是否存在
                comment = c.execute("SELECT id, like_count FROM comments WHERE id=?", (cid,)).fetchone()
                if not comment:
                    c.close()
                    self._err(404, "comment not found"); return
                # 检查是否已点赞
                liked = c.execute("SELECT user_id FROM comment_likes WHERE user_id=? AND comment_id=?", (uid, cid)).fetchone()
                if liked:
                    # 取消点赞
                    c.execute("DELETE FROM comment_likes WHERE user_id=? AND comment_id=?", (uid, cid))
                    new_count = max(0, (comment[1] or 0) - 1)
                else:
                    # 点赞
                    c.execute("INSERT INTO comment_likes(user_id, comment_id, created) VALUES(?,?,?)", (uid, cid, time.time()))
                    new_count = (comment[1] or 0) + 1
                c.execute("UPDATE comments SET like_count=? WHERE id=?", (new_count, cid))
                c.commit()
                c.close()
                self._json(200, {"ok": True, "liked": not liked, "likeCount": new_count})
                return

            # ---------- 后台管理：编辑 / 上下架 ----------
            ADMIN_TOKEN = _admin_token()

            # 官网展示配置保存：网站名/下载链接/副标题
            if u.path == "/api/admin/site-config":
                if self.headers.get("X-Admin-Token", "").strip() != ADMIN_TOKEN:
                    self._err(401, "unauthorized"); return
                try:
                    raw = self.rfile.read(min(int(self.headers.get("Content-Length",0)), 8 * 1024))
                    data = json.loads(raw.decode("utf-8") or "{}")
                except Exception:
                    self._err(400, "bad json"); return
                cfg = _write_site_config(data)
                self._json(200, {"ok": True, "config": cfg})
                return

            if u.path == "/api/admin/announcement":
                if self.headers.get("X-Admin-Token", "").strip() != ADMIN_TOKEN:
                    self._err(401, "unauthorized"); return
                try:
                    raw = self.rfile.read(min(int(self.headers.get("Content-Length",0)), 8 * 1024))
                    data = json.loads(raw.decode("utf-8") or "{}")
                except Exception:
                    self._err(400, "bad json"); return
                title = (data.get("title") or "").strip()
                content = (data.get("content") or "").strip()
                if not title or not content:
                    self._err(400, "title and content required"); return
                c = db()
                aid = secrets.token_hex(6)
                show_once = 1 if str(data.get("showOnce") or "0") in ("1", "true", "yes") else 0
                atype = data.get("type") or "announcement"
                force_update = 1 if str(data.get("forceUpdate") or "0") in ("1", "true", "yes") else 0
                download_url = data.get("downloadUrl") or ""
                c.execute("INSERT INTO announcements(id,title,content,version,show_once,type,force_update,download_url,active,created) VALUES(?,?,?,?,?,?,?,?,1,?)",
                          (aid, title, content, data.get("version") or "", show_once, atype, force_update, download_url, time.time()))
                c.commit()
                c.close()
                self._json(200, {"ok": True, "id": aid}); return

            if u.path == "/api/admin/update":
                if self.headers.get("X-Admin-Token", "").strip() != ADMIN_TOKEN:
                    self._err(401, "unauthorized"); return
                try:
                    raw = self.rfile.read(min(int(self.headers.get("Content-Length",0)), 8 * 1024 * 1024))
                    data = json.loads(raw.decode("utf-8") or "{}")
                except Exception:
                    self._err(400, "bad json"); return
                typ = data.get("type") or ""
                rid = data.get("id") or ""
                fields = data.get("fields") or {}
                if typ not in ("track","collected","user") or not rid:
                    self._err(400, "bad params"); return
                c = db()
                try:
                    def _save_img(tid, val, kind):
                        """保存图片到 files/{tid}_{kind}_{ts}{ext}，返回本地文件名；失败返回 None"""
                        if not val: return None
                        val = str(val).strip()
                        if not val: return None
                        # base64 data URI
                        if val.startswith("data:image/"):
                            try:
                                hdr, b64 = val.split(",", 1)
                                ext = ""
                                m = re.search(r"image/(\w+)", hdr)
                                if m: ext = "." + m.group(1).lower()
                                if ext not in (".jpg", ".jpeg", ".png", ".webp", ".heic"): ext = ".jpg"
                                data = base64.b64decode(b64)
                                if len(data) > 3 * 1024 * 1024: return None
                                if not image_magic_ok(data, ext): return None
                                fn = "%s_%s_%d%s" % (tid, kind, int(time.time()), ext)
                                with open(os.path.join(FILES, fn), "wb") as f:
                                    f.write(data)
                                return fn
                            except Exception:
                                return None
                        # http 链接：下载到本地
                        if val.startswith("http"):
                            try:
                                req = urllib.request.Request(val, headers={"User-Agent": "Mozilla/5.0"})
                                with urllib.request.urlopen(req, timeout=15, context=_ssl_ctx()) as r:
                                    img = r.read()
                                if not img or len(img) < 500: return None
                                ext = ".jpg"
                                if not image_magic_ok(img, ".jpg"):
                                    if image_magic_ok(img, ".png"): ext = ".png"
                                    elif image_magic_ok(img, ".webp"): ext = ".webp"
                                fn = "%s_%s_%d%s" % (tid, kind, int(time.time()), ext)
                                with open(os.path.join(FILES, fn), "wb") as f:
                                    f.write(img)
                                return fn
                            except Exception:
                                return None
                        return None

                    if typ == "track":
                        sets, vals = [], []
                        if "title" in fields: sets.append("title=?"); vals.append(str(fields["title"]).strip())
                        if "artist" in fields: sets.append("artist=?"); vals.append(str(fields["artist"]).strip())
                        if "user_id" in fields: sets.append("user_id=?"); vals.append(str(fields["user_id"]).strip())
                        if "cover" in fields:
                            cf = _save_img(rid, fields.get("cover"), "cover")
                            if cf is not None:
                                sets.append("cover=?"); vals.append(cf)
                        if sets:
                            vals.append(rid)
                            c.execute("UPDATE tracks SET "+",".join(sets)+" WHERE id=?", vals)
                    elif typ == "collected":
                        sets, vals = [], []
                        if "title" in fields: sets.append("title=?"); vals.append(str(fields["title"]).strip())
                        if "artist" in fields: sets.append("artist=?"); vals.append(str(fields["artist"]).strip())
                        if "cover" in fields:
                            cf = _save_img(rid, fields.get("cover"), "cover")
                            if cf is not None:
                                sets.append("cover=?"); vals.append(cf)
                        if sets:
                            vals.append(rid)
                            c.execute("UPDATE collected_tracks SET "+",".join(sets)+" WHERE id=?", vals)
                    elif typ == "user":
                        sets, vals = [], []
                        field_map = {"name":"name","account":"account",
                                     "gender":"gender","age":"age","signature":"signature"}
                        for k, col in field_map.items():
                            if k in fields:
                                sets.append(f"{col}=?")
                                vals.append(str(fields[k]).strip())
                        if "avatar" in fields:
                            af = _save_img(rid, fields.get("avatar"), "avatar")
                            if af is not None:
                                sets.append("avatar=?"); vals.append(af)
                        if "password" in fields and str(fields["password"]).strip():
                            sets.append("password_hash=?")
                            vals.append(hash_password(str(fields["password"]).strip()))
                        if sets:
                            vals.append(rid)
                            c.execute("UPDATE users SET "+",".join(sets)+" WHERE id=?", vals)
                    c.commit()
                finally:
                    c.close()
                self._json(200, {"ok": True}); return

            if u.path == "/api/admin/offline":
                if self.headers.get("X-Admin-Token", "").strip() != ADMIN_TOKEN:
                    self._err(401, "unauthorized"); return
                try:
                    raw = self.rfile.read(min(int(self.headers.get("Content-Length",0)), 65536))
                    data = json.loads(raw.decode("utf-8") or "{}")
                except Exception:
                    self._err(400, "bad json"); return
                typ = data.get("type") or ""
                rid = data.get("id") or ""
                reason = str(data.get("reason") or "").strip()
                action = data.get("action") or "off"  # off / on
                if typ not in ("track","collected") or not rid:
                    self._err(400, "bad params"); return
                tbl = {"track":"tracks","collected":"collected_tracks"}.get(typ)
                if not tbl:
                    self._err(400, "bad type"); return
                c = db()
                try:
                    if action == "off":
                        c.execute(f"UPDATE {tbl} SET offline=1, offline_reason=? WHERE id=?", (reason, rid))
                    else:
                        c.execute(f"UPDATE {tbl} SET offline=0, offline_reason='' WHERE id=?", (rid,))
                    c.commit()
                    # 实时数据事件：歌曲下架/恢复 → 全局列表更新（广播在线用户）
                    ws_broadcast({"kind": "event", "event": "track_list", "reason": "offline"})
                finally:
                    c.close()
                self._json(200, {"ok": True}); return

            if u.path == "/api/admin/ban":
                if self.headers.get("X-Admin-Token", "").strip() != ADMIN_TOKEN:
                    self._err(401, "unauthorized"); return
                try:
                    raw = self.rfile.read(min(int(self.headers.get("Content-Length",0)), 65536))
                    data = json.loads(raw.decode("utf-8") or "{}")
                except Exception:
                    self._err(400, "bad json"); return
                rid = data.get("id") or ""
                reason = str(data.get("reason") or "").strip()
                action = data.get("action") or "ban"  # ban / unban
                if not rid:
                    self._err(400, "bad params"); return
                c = db()
                try:
                    if action == "ban":
                        c.execute("UPDATE users SET banned=1, ban_reason=? WHERE id=?", (reason, rid))
                    else:
                        c.execute("UPDATE users SET banned=0, ban_reason='' WHERE id=?", (rid,))
                    c.commit()
                finally:
                    c.close()
                self._json(200, {"ok": True}); return

            if u.path == "/api/admin/change_pwd":
                if self.headers.get("X-Admin-Token", "").strip() != _admin_token():
                    self._err(401, "unauthorized"); return
                try:
                    raw = self.rfile.read(min(int(self.headers.get("Content-Length",0)), 65536))
                    data = json.loads(raw.decode("utf-8") or "{}")
                except Exception:
                    self._err(400, "bad json"); return
                old = str(data.get("old") or "").strip()
                pwd = str(data.get("pwd") or "").strip()
                if old != _admin_token():
                    self._err(400, "当前密码不正确"); return
                if len(pwd) < 6 or len(pwd) > 64:
                    self._err(400, "新密码长度需在 6-64 位之间"); return
                try:
                    with open(ADMIN_PWD_FILE, "w", encoding="utf-8") as _f:
                        _f.write(pwd)
                except Exception:
                    self._err(500, "密码保存失败"); return
                self._json(200, {"ok": True}); return

            ADMIN_TOKEN = _admin_token()
            if u.path.startswith("/api/admin/del/"):
                if self.headers.get("X-Admin-Token", "").strip() != ADMIN_TOKEN:
                    self._err(401, "unauthorized"); return
                parts = u.path.split("/")
                # /api/admin/del/<type>/<id>
                typ = parts[3] if len(parts) > 3 else ""
                tid = parts[4] if len(parts) > 4 else ""
                c = db()
                try:
                    if typ == "track":
                        row = c.execute("SELECT fname FROM tracks WHERE id=?", (tid,)).fetchone()
                        c.execute("DELETE FROM tracks WHERE id=?", (tid,))
                        c.execute("DELETE FROM likes WHERE track_id=?", (tid,))
                        c.execute("DELETE FROM comments WHERE track_id=?", (tid,))
                        c.commit()
                        if row and row[0]:
                            fp = safe_file_path(row[0])
                            if fp and os.path.exists(fp):
                                try: os.remove(fp)
                                except Exception: pass
                        # 实时数据事件：删除歌曲 → 全局列表更新（广播在线用户）
                        ws_broadcast({"kind": "event", "event": "track_list", "reason": "delete"})
                    elif typ == "collected":
                        row = c.execute("SELECT play_url FROM collected_tracks WHERE id=?", (tid,)).fetchone()
                        c.execute("DELETE FROM collected_tracks WHERE id=?", (tid,))
                        c.commit()
                        if row and row[0] and not str(row[0]).startswith("http"):
                            fp = safe_file_path(row[0])
                            if fp and os.path.exists(fp):
                                try: os.remove(fp)
                                except Exception: pass
                        # 实时数据事件：删除采集歌曲 → 全局列表更新
                        ws_broadcast({"kind": "event", "event": "track_list", "reason": "delete"})
                    elif typ == "user":
                        c.execute("DELETE FROM users WHERE id=?", (tid,))
                        c.commit()
                    elif typ == "comment":
                        c.execute("DELETE FROM comments WHERE id=?", (tid,))
                        c.commit()
                    else:
                        self._err(400, "bad type"); return
                finally:
                    c.close()
                self._json(200, {"ok": True}); return

            # ---------- 采集控制台：开始/停止（支持自定义目标） ----------
            if u.path == "/api/collect/start":
                import subprocess
                try:
                    subprocess.check_output(["pgrep", "-f", "collect_v3.py"])
                    self._json(200, {"ok": True, "running": True, "msg": "已在采集中"})
                    return
                except Exception:
                    pass
                # 解析目标参数（表单 body 优先，其次 query）
                try:
                    raw = self.rfile.read(min(length, 4096)) if length > 0 else b""
                    qs = raw.decode("utf-8") or u.query
                    _params = urllib.parse.parse_qs(qs)
                except Exception:
                    _params = {}
                new_tgt = None
                try:
                    if _params.get("target"):
                        _t = int(str(_params["target"][0]).strip())
                        if _t > 0: new_tgt = _t
                except Exception:
                    new_tgt = None
                c = db()
                cur = c.execute("SELECT COUNT(*) FROM collected_tracks").fetchone()[0]
                c.close()
                tgt_file = "/www/wwwroot/music/source-bridge/collect_target.json"
                tgt, start_total = None, cur
                try:
                    with open(tgt_file, "r", encoding="utf-8") as _tf:
                        _tj = json.load(_tf)
                    if isinstance(_tj, dict):
                        tgt = int(_tj.get("target") or 0)
                        start_total = int(_tj.get("start_total") or cur)
                except Exception:
                    pass
                # 解析新参数：平台/模式/关键词
                _VALID_PLATS = ("kw","wy","kg","tx","gd","qs","soda","gm_migu","gm_fivesing",
                                "gm_joox","gm_kugou","gm_kuwo","gm_qq","dy","wy_hot","qq_hot")
                _plats = [x for x in str(_params.get("platforms", ["gd,soda"])[0]).split(",") if x in _VALID_PLATS]
                if not _plats: _plats = ["gd","soda"]
                _mode = str(_params.get("mode", ["search"])[0]).strip()
                if _mode not in ("search","hot"): _mode = "search"
                _kws = [x for x in str(_params.get("keywords", [""])[0]).split(",") if x.strip()]
                if new_tgt is not None:
                    # 重设目标：上次目标未达成则延续起点（已完成数带入新目标）；已达成/无目标则从当前重新累计
                    prev_done = (tgt is not None) and (cur - start_total >= tgt)
                    # 清理/删歌后总数可能低于旧基线，此时基线失效，从当前重新累计
                    if cur < start_total:
                        base = cur
                    else:
                        base = start_total if (not prev_done and tgt is not None) else cur
                    tgt, start_total = new_tgt, base
                    try:
                        with open(tgt_file, "w", encoding="utf-8") as _tf:
                            json.dump({"target": tgt, "start_total": start_total, "updated": time.time(),
                                       "platforms": _plats, "mode": _mode, "keywords": _kws}, _tf)
                    except Exception:
                        pass
                else:
                    # 未设置目标：沿用上次目标；无目标/已达成/基线失效则开启新一轮
                    done = (tgt is not None) and (cur - start_total >= tgt)
                    if tgt is None or done or cur < start_total:
                        tgt, start_total = 500, cur
                    # 把当前平台/模式/关键词刷进配置（无论是否重设目标）
                    try:
                        with open(tgt_file, "r", encoding="utf-8") as _tf:
                            _old = json.load(_tf)
                        if not isinstance(_old, dict): _old = {}
                    except Exception:
                        _old = {}
                    _old["target"] = tgt
                    _old["start_total"] = start_total
                    _old["updated"] = time.time()
                    _old["platforms"] = _plats
                    _old["mode"] = _mode
                    _old["keywords"] = _kws
                    try:
                        with open(tgt_file, "w", encoding="utf-8") as _tf:
                            json.dump(_old, _tf)
                    except Exception:
                        pass
                remaining = tgt - (cur - start_total)
                if remaining <= 0:
                    # 已完成数已覆盖新目标：视为已达成，不启动采集
                    try:
                        with open("/www/wwwroot/music/source-bridge/collect_run.json", "w", encoding="utf-8") as _sf:
                            json.dump({"started": None, "collected": []}, _sf)
                    except Exception:
                        pass
                    self._json(200, {"ok": True, "running": False,
                                     "target": tgt, "start_total": start_total,
                                     "completed": max(0, cur - start_total), "remaining": 0,
                                     "achieved": True, "msg": "目标已完成"})
                    return
                try:
                    with open("/www/wwwroot/music/source-bridge/collect_run.json", "w", encoding="utf-8") as _sf:
                        json.dump({"started": None, "collected": []}, _sf)
                except Exception:
                    pass
                logf = open("/www/wwwroot/music/source-bridge/collect_v3.log", "ab")
                subprocess.Popen(["python3", "/www/wwwroot/music/source-bridge/collect_v3.py", "--target", str(remaining)],
                                 stdout=logf, stderr=subprocess.STDOUT,
                                 cwd="/www/wwwroot/music/source-bridge", stdin=subprocess.DEVNULL)
                self._json(200, {"ok": True, "running": True,
                                 "target": tgt, "start_total": start_total,
                                 "completed": max(0, cur - start_total), "remaining": max(0, remaining)})
                return

            if u.path == "/api/collect/stop":
                import subprocess
                subprocess.run(["pkill", "-f", "collect_v3.py"])
                time.sleep(0.5)
                self._json(200, {"ok": True, "running": False})
                return

            # 发布官方通知
            if u.path == "/api/admin/official-message":
                if self.headers.get("X-Admin-Token", "").strip() != _admin_token():
                    self._err(401, "unauthorized"); return
                try:
                    raw = self.rfile.read(min(int(self.headers.get("Content-Length",0)), 16*1024))
                    data = json.loads(raw.decode("utf-8") or "{}")
                except Exception:
                    self._err(400, "bad json"); return
                msg_content = (data.get("content") or "").strip()
                if not msg_content:
                    self._err(400, "content required"); return
                import time as _t
                msg_id = secrets.token_hex(8)
                c = db()
                c.execute("INSERT INTO official_messages(id, content, created, sender_name) VALUES(?,?,?,?)",
                          (msg_id, msg_content, _t.time(), "流萤音乐官方"))
                # 给所有用户生成通知
                all_users = c.execute("SELECT id FROM users").fetchall()
                for u in all_users:
                    notif_id = secrets.token_hex(8)
                    c.execute("INSERT INTO notifications(id, user_id, type, title, content, is_read, created) VALUES(?,?,?,?,?,?,?)",
                              (notif_id, u[0], "official", "官方通知", msg_content, 0, _t.time()))
                    # 实时推送（WebSocket）：给每个在线用户推送官方通知
                    ws_push(u[0], {
                        "kind": "notification",
                        "notification": {"id": notif_id, "type": "official",
                                         "title": "官方通知", "content": msg_content,
                                         "fromUserId": "", "fromUser": "流萤音乐官方",
                                         "trackId": "", "trackTitle": "",
                                         "isRead": 0, "created": _t.time()},
                        "unread": _notif_unread(c, u[0])})
                c.commit()
                c.close()
                self._json(200, {"ok": True, "id": msg_id})
                return

            # 标记通知已读（支持按类型：all全部 / interactive互动 / official官方）
            if u.path == "/api/notifications/read":
                c = db()
                tok_uid = resolve_token(c, self.headers.get("Authorization", ""))
                if not tok_uid:
                    c.close()
                    self._err(401, "unauthorized"); return
                qs = urllib.parse.parse_qs(u.query)
                ntype = (qs.get("type", ["all"])[0] or "all").strip()
                if ntype == "interactive":
                    # 互动通知：点赞/评论/分享类
                    c.execute("UPDATE notifications SET is_read=1 WHERE user_id=? AND type IN ('like','comment','share')", (tok_uid,))
                elif ntype == "official":
                    # 官方通知：系统公告类
                    c.execute("UPDATE notifications SET is_read=1 WHERE user_id=? AND type NOT IN ('like','comment','share')", (tok_uid,))
                else:
                    # 默认全部已读
                    c.execute("UPDATE notifications SET is_read=1 WHERE user_id=?", (tok_uid,))
                c.commit()
                c.close()
                self._json(200, {"ok": True})
                return

# ---------- 单首采集入库（H5 搜索后点采集按钮） ----------
            if u.path == "/api/collect/one":
                try:
                    raw = self.rfile.read(min(length, 65536)) if length > 0 else b""
                    data = json.loads(raw.decode("utf-8") or "{}")
                except Exception:
                    self._err(400, "bad json"); return
                _src = (data.get("source") or "wy").strip()
                _mid = (data.get("songmid") or "").strip()
                _name = (data.get("name") or "").strip()
                if not _mid or not _name:
                    self._err(400, "songmid/name required"); return
                _singer = (data.get("singer") or "").strip()
                _album = (data.get("album") or "").strip()
                _interval = data.get("interval") or ""
                _img = data.get("img") or ""
                c = db()
                _dup = c.execute("SELECT title FROM collected_tracks WHERE source=? AND source_id=?", (_src, _mid)).fetchone()
                if _dup:
                    c.close(); self._json(200, {"ok": False, "err": "已存在：" + _dup[0]}); return
                _tid = hashlib.md5((_src + ":" + _mid).encode()).hexdigest()
                try:
                    _br = ("http://127.0.0.1:8789/song?source=" + urllib.parse.quote(_src) +
                           "&songmid=" + urllib.parse.quote(_mid) +
                           "&name=" + urllib.parse.quote(_name) +
                           "&singer=" + urllib.parse.quote(_singer) +
                           "&album=" + urllib.parse.quote(_album) +
                           "&interval=" + urllib.parse.quote(str(_interval)) +
                           "&img=" + urllib.parse.quote(_img))
                    with urllib.request.urlopen(_br, timeout=60) as _r:
                        _info = json.loads(_r.read().decode())
                    if not _info.get("ok"):
                        c.close(); self._json(200, {"ok": False, "err": "音源解析失败"}); return
                    _url = str(_info.get("url") or "")
                    _lrc = _info.get("lyric") or ""
                    _pic = _info.get("pic") or _img
                except Exception as e:
                    c.close(); self._json(200, {"ok": False, "err": "音源错误:" + str(e)}); return
                # 下封面
                _cover = ""
                if _pic and str(_pic).startswith("http"):
                    try:
                        _req = urllib.request.Request(_pic, headers={"User-Agent": "Mozilla/5.0"})
                        with urllib.request.urlopen(_req, timeout=15, context=ssl._create_unverified_context()) as _r:
                            _imgdata = _r.read()
                        if len(_imgdata) > 500:
                            with open(os.path.join(FILES, _tid + "_cover.jpg"), "wb") as _f:
                                _f.write(_imgdata)
                            _cover = _tid + "_cover.jpg"
                    except Exception:
                        pass
                # 下音频
                _audio, _asize, _aok = "", 0, False
                if _url.startswith("http"):
                    try:
                        _req = urllib.request.Request(_url, headers={"User-Agent": "Mozilla/5.0"})
                        with urllib.request.urlopen(_req, timeout=60, context=ssl._create_unverified_context()) as _r:
                            _adata = _r.read()
                        if len(_adata) >= 300 * 1024:
                            with open(os.path.join(FILES, _tid + ".mp3"), "wb") as _f:
                                _f.write(_adata)
                            _audio = _tid + ".mp3"; _asize = len(_adata); _aok = True
                    except Exception:
                        pass
                _m = re.match(r"^(\d+):(\d{2})$", str(_interval or "").strip())
                _dur = int(_m.group(1)) * 60 + int(_m.group(2)) if _m else 0
                c.execute(
                    """INSERT OR IGNORE INTO collected_tracks
                       (id,title,artist,album,cover,duration,source,source_id,play_url,size,created,user_id,lrc)
                       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                    (_tid, _name, _singer, _album, _cover, _dur, _src, _mid,
                     _audio, _asize, time.time(),
                     "a334105a8a2f4401a19001ee4ce66929", _lrc))
                c.commit(); c.close()
                self._json(200, {"ok": True, "title": _name, "artist": _singer, "audio": _aok}); return

            # ---------- 音乐源采集入库（采集器批量写入 collected_tracks） ----------
            if u.path == "/api/collect/add":
                if not rate_limit(self, "collect_add"):
                    self._err(429, "请求过于频繁，请稍后再试")
                    return
                if self.headers.get("X-Collect-Key", "").strip() != COLLECT_KEY:
                    self._err(403, "forbidden")
                    return
                try:
                    raw = self.rfile.read(min(length, 2 * 1024 * 1024)) if length > 0 else b""
                    data = json.loads(raw.decode("utf-8") or "{}")
                except Exception:
                    self._err(400, "bad json")
                    return
                items = data.get("items") or []
                if not isinstance(items, list) or not items or len(items) > 50:
                    self._err(400, "items must be 1..50")
                    return
                # 自定义关键词标签（用户在采集H5里添加的关键词，逗号分隔）
                custom_genre = (data.get("keywords") or "").strip()
                c = db()
                # 归属：数据库中的唯一账号（仅当 users 表只有 1 个用户时）
                urows = c.execute("SELECT id FROM users ORDER BY created LIMIT 2").fetchall()
                owner = urows[0][0] if len(urows) == 1 else ""
                now = time.time()
                ins = skip = 0
                for it in items:
                    title = (it.get("title") or "").strip()
                    src = (it.get("source") or "").strip()
                    sid = (it.get("source_id") or "").strip()
                    if not title or not src or not sid:
                        continue
                    tid = hashlib.md5(("%s:%s" % (src, sid)).encode()).hexdigest()
                    # 封面：若为第三方 http 链接则下载到本地 files/{tid}_cover.jpg（手机端可直接加载），
                    # 下载失败则存空（App 显示占位封面）；已入库歌曲跳过下载。
                    cover_val = (it.get("cover") or "").strip()
                    local_cover = ""
                    if cover_val.startswith("http"):
                        try:
                            req = urllib.request.Request(cover_val, headers={"User-Agent": "Mozilla/5.0"})
                            with urllib.request.urlopen(req, timeout=10, context=_ssl_ctx()) as r:
                                img = r.read()
                            if img and len(img) >= 500:
                                with open(os.path.join(FILES, tid + "_cover.jpg"), "wb") as f:
                                    f.write(img)
                                local_cover = tid + "_cover.jpg"
                        except Exception:
                            local_cover = ""
                    elif cover_val:
                        local_cover = cover_val   # 已是本地文件名
                    # 播放链接不再采集入库（外部第三方直链时效短且手机端不可用）
                    cur = c.execute(
                        """INSERT OR IGNORE INTO collected_tracks
                           (id,title,artist,album,cover,duration,source,source_id,play_url,size,created,user_id,lrc,genre)
                           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                        (tid, title, (it.get("artist") or "").strip(), (it.get("album") or "").strip(),
                         local_cover, float(it.get("duration") or 0), src, sid,
                         "", float(it.get("size") or 0), now, owner, it.get("lrc") or "",
                         custom_genre))
                    if cur.rowcount and cur.rowcount > 0:
                        ins += 1
                    else:
                        skip += 1
                c.commit()
                # 实时数据事件：采集入库 → 全局歌曲列表更新（广播在线用户）
                if ins:
                    ws_broadcast({"kind": "event", "event": "track_list", "reason": "collect"})
                c.close()
                self._json(200, {"ok": True, "inserted": ins, "skipped": skip, "owner": owner})
                return

            # ---------- 汽水音乐分享链接入库（H5 专用：封面原图/歌词/音乐标签） ----------
            if u.path == "/api/collect/from-share":
                if not rate_limit(self, "collect_add", extra="from_share"):
                    self._err(429, "请求过于频繁，请稍后再试")
                    return
                try:
                    raw = self.rfile.read(min(length, 65536)) if length > 0 else b""
                    data = json.loads(raw.decode("utf-8") or "{}")
                except Exception:
                    self._err(400, "bad json"); return
                share_url = (data.get("url") or "").strip()
                if not share_url:
                    self._err(400, "url required"); return
                # 归属账号：默认账号 3065751692（夏梓璇）；可传 user_id 覆盖（须为有效用户）
                owner_id = (data.get("user_id") or "").strip() or "a334105a8a2f4401a19001ee4ce66929"
                try:
                    m = _qishui_parse_share(share_url)
                except Exception as e:
                    self._json(200, {"ok": False, "err": "解析失败：" + str(e)}); return
                if not m.get("track_id"):
                    self._json(200, {"ok": False, "err": "未解析到歌曲 ID"}); return
                c = db()
                if not c.execute("SELECT 1 FROM users WHERE id=?", (owner_id,)).fetchone():
                    c.close()
                    self._json(200, {"ok": False, "err": "归属账号不存在"}); return
                tid = hashlib.md5(("qs:" + m["track_id"]).encode()).hexdigest()
                dup = c.execute("SELECT title FROM collected_tracks WHERE id=?", (tid,)).fetchone()
                if dup:
                    acc = c.execute("SELECT account,name FROM users WHERE id=?", (owner_id,)).fetchone()
                    c.close()
                    self._json(200, {"ok": True, "inserted": 0, "title": m["title"], "artist": m["artist"],
                                     "owner_account": acc[0] if acc else owner_id, "cover": False,
                                     "audio": False, "lyric_len": 0, "genre": m.get("genre") or ""})
                    return
                # 下载封面：优先原图（~c5.jpg，3000x3000），失败回退缩略图
                local_cover = ""
                for cov in (m.get("cover_original"), m.get("cover")):
                    if cov and str(cov).startswith("http"):
                        try:
                            req = urllib.request.Request(cov, headers={"User-Agent": QISHUI_SHARE_UA})
                            with urllib.request.urlopen(req, timeout=20, context=_ssl_ctx()) as r:
                                img = r.read()
                            if img and len(img) >= 500 and image_magic_ok(img, ".jpg"):
                                with open(os.path.join(FILES, tid + "_cover.jpg"), "wb") as f:
                                    f.write(img)
                                local_cover = tid + "_cover.jpg"
                                break
                        except Exception:
                            continue
                # 下载音频：M4A 直链 → 存 {tid}.m4a（stream 按扩展名返回 audio/x-m4a）
                local_audio, audio_size = "", 0
                if m.get("audio_url") and str(m["audio_url"]).startswith("http"):
                    try:
                        req = urllib.request.Request(m["audio_url"], headers={"User-Agent": QISHUI_SHARE_UA})
                        with urllib.request.urlopen(req, timeout=120, context=_ssl_ctx()) as r:
                            adata = r.read()
                        if len(adata) >= 300 * 1024:
                            with open(os.path.join(FILES, tid + ".m4a"), "wb") as f:
                                f.write(adata)
                            local_audio = tid + ".m4a"
                            audio_size = len(adata)
                    except Exception:
                        pass
                genre = m.get("genre") or ""
                c.execute(
                    """INSERT OR IGNORE INTO collected_tracks
                       (id,title,artist,album,cover,duration,source,source_id,play_url,size,created,user_id,lrc,genre)
                       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                    (tid, m["title"], m["artist"], m["album"], local_cover, m["duration"],
                     "qs", m["track_id"], local_audio, audio_size, time.time(), owner_id,
                     m["lyric_lrc"], genre))
                c.commit()
                acc = c.execute("SELECT account,name FROM users WHERE id=?", (owner_id,)).fetchone()
                c.close()
                if local_audio:
                    ws_broadcast({"kind": "event", "event": "track_list", "reason": "collect"})
                self._json(200, {"ok": True, "inserted": 1, "title": m["title"], "artist": m["artist"],
                                 "owner_account": acc[0] if acc else owner_id, "cover": bool(local_cover),
                                 "audio": bool(local_audio),
                                 "lyric_len": len(m["lyric_lrc"].splitlines()) if m["lyric_lrc"] else 0,
                                 "genre": genre})
                return

            # ---------- 用户注册 ----------
            if u.path == "/api/register":
                if not rate_limit(self, "register"):
                    self._err(429, "注册过于频繁，请稍后再试")
                    return
                try:
                    if length <= 0 or length > MAX_PROFILE:
                        self._err(413, "too large")
                        return
                    fields, files = self._parse_multipart(length)
                    if fields is None:
                        self._err(400, "need multipart")
                        return
                    # 账号由后端自动生成 6 位数字（不再接受用户自定义账号）
                    password = fields.get("password") or ""
                    name = (fields.get("name") or "").strip()[:MAX_NAME]
                    gender = (fields.get("gender") or "").strip()[:8]
                    signature = (fields.get("signature") or "").strip()[:100]
                    try:
                        age = int(fields.get("age") or 0)
                    except Exception:
                        age = 0
                    age = max(0, min(age, 150))
                    if not password:
                        self._err(400, "密码不能为空")
                        return
                    if len(password) < 6 or len(password) > 64:
                        self._err(400, "密码长度需在 6-64 位之间")
                        return
                    c = db()
                    # 生成 6 位数字账号（100000-999999），冲突则重试
                    account = ""
                    for _ in range(50):
                        _cand = str(random.randint(100000, 999999))
                        if not c.execute("SELECT 1 FROM users WHERE account=?", (_cand,)).fetchone():
                            account = _cand
                            break
                    if not account:
                        c.close()
                        self._err(500, "账号生成失败，请重试")
                        return
                    name = name or ("用户" + account)
                    uid = uuid.uuid4().hex
                    avatar_fname = ""
                    avatar = files.get("avatar")
                    if avatar and avatar[1]:
                        aext = os.path.splitext(avatar[0])[1].lower()
                        if aext not in (".jpg", ".jpeg", ".png", ".webp", ".heic"):
                            aext = ".jpg"
                        if not image_magic_ok(avatar[1], aext):
                            c.close()
                            self._err(400, "头像文件格式校验失败")
                            return
                        avatar_fname = uid + "_avatar" + aext
                        with open(os.path.join(FILES, avatar_fname), "wb") as f:
                            f.write(avatar[1])
                    bg_fname = ""
                    bg = files.get("background")
                    if bg and bg[1]:
                        bext = os.path.splitext(bg[0])[1].lower()
                        if bext not in (".jpg", ".jpeg", ".png", ".webp", ".heic"):
                            bext = ".jpg"
                        if not image_magic_ok(bg[1], bext):
                            c.close()
                            self._err(400, "背景图文件格式校验失败")
                            return
                        bg_fname = uid + "_bg" + bext
                        with open(os.path.join(FILES, bg_fname), "wb") as f:
                            f.write(bg[1])
                    ip = client_ip(self)
                    c.execute("""INSERT INTO users(id,account,password_hash,name,avatar,created,
                                  gender,age,background_image,signature,ip_address)
                                 VALUES(?,?,?,?,?,?,?,?,?,?,?)""",
                              (uid, account, hash_password(password), name, avatar_fname, time.time(),
                               gender, age, bg_fname, signature, ip))
                    token = issue_token(c, uid)
                    c.commit()
                    row = c.execute("""SELECT id,account,password_hash,name,avatar,created,
                                      gender,age,background_image,signature,ip_address
                                      FROM users WHERE id=?""", (uid,)).fetchone()
                    c.close()
                    self._json(200, public_user(row, token))
                except Exception as e:
                    self._internal_error(e)
                return

            # ---------- 用户登录 ----------
            if u.path == "/api/login":
                if not rate_limit(self, "login"):
                    self._err(429, "登录尝试过于频繁，请稍后再试")
                    return
                try:
                    if length <= 0 or length > 64 * 1024:
                        self._err(413, "too large")
                        return
                    fields, files = self._parse_multipart(length)
                    if fields is None:
                        self._err(400, "need multipart")
                        return
                    account = (fields.get("account") or "").strip()
                    password = fields.get("password") or ""
                    c = db()
                    row = c.execute("""SELECT id,account,password_hash,name,avatar,created,
                                     gender,age,background_image,signature,ip_address,banned,ban_reason
                                     FROM users WHERE account=?""",
                                    (account,)).fetchone()
                    if not row or not verify_password(password, row[2]):
                        c.close()
                        self._err(401, "账号或密码错误")
                        return
                    if row[11]:
                        c.close()
                        self._err(403, "账号已被封禁：" + (row[12] or "联系管理员"))
                        return
                    # 旧版哈希（v1，120000 轮）自动迁移升级
                    if is_legacy_hash(row[2]):
                        c.execute("UPDATE users SET password_hash=? WHERE id=?",
                                  (hash_password(password), row[0]))
                    # 每次登录自动更新当前 IP
                    ip = client_ip(self)
                    c.execute("UPDATE users SET ip_address=? WHERE id=?", (ip, row[0]))
                    token = issue_token(c, row[0])
                    c.commit()
                    row = c.execute("""SELECT id,account,password_hash,name,avatar,created,
                                     gender,age,background_image,signature,ip_address
                                     FROM users WHERE id=?""", (row[0],)).fetchone()
                    c.close()
                    self._json(200, public_user(row, token))
                except Exception as e:
                    self._internal_error(e)
                return

            # ---------- 用户自助修改密码 ----------
            if u.path == "/api/change-password":
                try:
                    if length <= 0 or length > MAX_PROFILE:
                        self._err(413, "too large")
                        return
                    fields, files = self._parse_multipart(length)
                    if fields is None:
                        self._err(400, "need multipart")
                        return
                    c = db()
                    uid, via_token = self.auth_user(c, fields)
                    if not uid:
                        c.close()
                        self._err(401, "未登录或登录已过期")
                        return
                    old_pw = fields.get("old_password") or ""
                    new_pw = fields.get("new_password") or ""
                    if len(new_pw) < 6 or len(new_pw) > 64:
                        c.close()
                        self._err(400, "新密码长度需 6-64 位")
                        return
                    row = c.execute("SELECT password_hash FROM users WHERE id=?",
                                    (uid,)).fetchone()
                    if not row:
                        c.close()
                        self._err(404, "用户不存在")
                        return
                    if not verify_password(old_pw, row[0]):
                        c.close()
                        self._err(403, "旧密码不正确")
                        return
                    c.execute("UPDATE users SET password_hash=? WHERE id=?",
                              (hash_password(new_pw), uid))
                    c.close()
                    self._json(200, {"ok": True})
                    return
                except Exception as e:
                    self._internal_error(e)
                return

            # ---------- 用户资料更新 ----------
            if u.path == "/api/profile/update":
                try:
                    if length <= 0 or length > MAX_PROFILE:
                        self._err(413, "too large")
                        return
                    fields, files = self._parse_multipart(length)
                    if fields is None:
                        self._err(400, "need multipart")
                        return
                    c = db()
                    uid, via_token = self.auth_user(c, fields, allow_account=True)
                    if not uid:
                        c.close()
                        self._err(401, "未登录或登录已过期")
                        return
                    if not via_token:
                        log.warning("legacy auth profile/update uid=%s ip=%s", uid, client_ip(self))
                    name = (fields.get("name") or "").strip()[:MAX_NAME]
                    gender = (fields.get("gender") or "").strip()[:8]
                    signature = (fields.get("signature") or "").strip()[:100]
                    try:
                        age = int(fields.get("age") or 0)
                    except Exception:
                        age = 0
                    age = max(0, min(age, 150))
                    avatar_fname = None
                    av = files.get("avatar")
                    if av and av[1]:
                        aext = os.path.splitext(av[0])[1].lower()
                        if aext not in (".jpg", ".jpeg", ".png", ".webp", ".heic"):
                            aext = ".jpg"
                        if not image_magic_ok(av[1], aext):
                            c.close()
                            self._err(400, "头像文件格式校验失败")
                            return
                        avatar_fname = uid + "_avatar" + aext
                        with open(os.path.join(FILES, avatar_fname), "wb") as f:
                            f.write(av[1])
                    bg_fname = None
                    bg = files.get("background")
                    if bg and bg[1]:
                        bext = os.path.splitext(bg[0])[1].lower()
                        if bext not in (".jpg", ".jpeg", ".png", ".webp", ".heic"):
                            bext = ".jpg"
                        if not image_magic_ok(bg[1], bext):
                            c.close()
                            self._err(400, "背景图文件格式校验失败")
                            return
                        bg_fname = uid + "_bg" + bext
                        with open(os.path.join(FILES, bg_fname), "wb") as f:
                            f.write(bg[1])
                    ip = client_ip(self)
                    if avatar_fname and bg_fname:
                        c.execute("""UPDATE users SET name=?,gender=?,age=?,signature=?,
                                     avatar=?,background_image=?,ip_address=? WHERE id=?""",
                                  (name, gender, age, signature, avatar_fname, bg_fname, ip, uid))
                    elif avatar_fname:
                        c.execute("""UPDATE users SET name=?,gender=?,age=?,signature=?,
                                     avatar=?,ip_address=? WHERE id=?""",
                                  (name, gender, age, signature, avatar_fname, ip, uid))
                    elif bg_fname:
                        c.execute("""UPDATE users SET name=?,gender=?,age=?,signature=?,
                                     background_image=?,ip_address=? WHERE id=?""",
                                  (name, gender, age, signature, bg_fname, ip, uid))
                    else:
                        c.execute("""UPDATE users SET name=?,gender=?,age=?,signature=?,
                                     ip_address=? WHERE id=?""",
                                  (name, gender, age, signature, ip, uid))
                    c.commit()
                    row = c.execute("""SELECT id,account,password_hash,name,avatar,created,
                                      gender,age,background_image,signature,ip_address
                                      FROM users WHERE id=?""", (uid,)).fetchone()
                    _pub = public_user(row)
                    c.close()
                    # 实时数据事件：资料（头像/签名/昵称/背景）更新后推送，多端同步
                    ws_push(uid, {"kind": "event", "event": "profile", "user": _pub})
                    self._json(200, _pub)
                except Exception as e:
                    self._internal_error(e)
                return

            # ---------- 播放量 +1 ----------
            if u.path.startswith("/api/play/"):
                if not rate_limit(self, "play"):
                    self._err(429, "请求过于频繁，请稍后再试")
                    return
                try:
                    tid = u.path.rsplit("/", 1)[-1]
                    c = db()
                    uid, via_token = self.auth_user(c)
                    if not uid:
                        c.close()
                        self._err(401, "未登录或登录已过期")
                        return
                    # S1：采集歌播放计数同步自增（热度路需要采集歌计数；like/share 已同步，见 /api/like、/api/share）
                    c.execute("UPDATE tracks SET play_count=play_count+1 WHERE id=?", (tid,))
                    c.execute("UPDATE collected_tracks SET play_count=play_count+1 WHERE id=?", (tid,))
                    c.commit()
                    row = c.execute("SELECT play_count FROM tracks WHERE id=?", (tid,)).fetchone()
                    if not row:
                        row = c.execute("SELECT play_count FROM collected_tracks WHERE id=?", (tid,)).fetchone()
                    c.close()
                    self._json(200, {"playCount": row[0] if row else 0})
                except Exception as e:
                    self._internal_error(e)
                return

            # ---------- 点赞 / 取消 ----------
            if u.path.startswith("/api/like/"):
                if not rate_limit(self, "like"):
                    self._err(429, "请求过于频繁，请稍后再试")
                    return
                try:
                    tid = u.path.rsplit("/", 1)[-1]
                    try:
                        body = json.loads(self.rfile.read(length) or b"{}")
                    except Exception:
                        body = {}
                    c = db()
                    uid, via_token = self.auth_user(c, body)
                    if not uid:
                        c.close()
                        self._err(401, "未登录或登录已过期")
                        return
                    ex = c.execute("SELECT 1 FROM likes WHERE user_id=? AND track_id=?",
                                   (uid, tid)).fetchone()
                    if ex:
                        c.execute("DELETE FROM likes WHERE user_id=? AND track_id=?", (uid, tid))
                        c.execute("UPDATE tracks SET like_count=MAX(0,like_count-1) WHERE id=?", (tid,))
                        c.execute("UPDATE collected_tracks SET like_count=MAX(0,like_count-1) WHERE id=?", (tid,))
                        liked = False
                    else:
                        c.execute("INSERT OR IGNORE INTO likes(user_id,track_id,created) VALUES(?,?,?)",
                                  (uid, tid, time.time()))
                        c.execute("UPDATE tracks SET like_count=like_count+1 WHERE id=?", (tid,))
                        c.execute("UPDATE collected_tracks SET like_count=like_count+1 WHERE id=?", (tid,))
                        liked = True
                    c.execute("""INSERT INTO behavior_events(id,user_id,track_id,event,value,meta,track_info,created)
                                 VALUES(?,?,?,?,?,?,?,?)""",
                              (uuid.uuid4().hex, uid, tid, "like", 1.0 if liked else 0.0,
                               "", _track_info(c, tid), time.time()))
                    # 点赞通知：给歌曲上传者（用户上传表 + 采集表都覆盖）
                    if liked:
                        owner_id, owner_title = _track_owner(c, tid)
                        if owner_id and owner_id != uid:
                            from_user_name = c.execute("SELECT name FROM users WHERE id=?", (uid,)).fetchone()
                            uname = from_user_name[0] if from_user_name else "有人"
                            # 去重：10分钟内同一用户对同一首歌的未读点赞通知，不重复插入
                            ten_min_ago = time.time() - 600
                            existing = c.execute("""SELECT id FROM notifications
                                                   WHERE user_id=? AND from_user_id=? AND track_id=?
                                                   AND type='like' AND is_read=0 AND created > ?
                                                   ORDER BY created DESC LIMIT 1""",
                                                (owner_id, uid, tid, ten_min_ago)).fetchone()
                            if existing:
                                # 更新已有通知的时间和内容（聚合为"又赞了"）
                                notif_id = existing[0]
                                c.execute("""UPDATE notifications SET created=?, content=?, title=?
                                             WHERE id=?""",
                                          (time.time(), f"{uname}赞了你的歌曲《{owner_title}》",
                                           "收到新点赞", notif_id))
                            else:
                                # 首次点赞，插入新通知
                                notif_id = uuid.uuid4().hex
                                c.execute("""INSERT INTO notifications(id, user_id, type, title, content, from_user_id, from_user_name, track_id, track_title, is_read, created)
                                             VALUES(?,?,?,?,?,?,?,?,?,?,?)""",
                                          (notif_id, owner_id, "like", "收到新点赞",
                                           f"{uname}赞了你的歌曲《{owner_title}》",
                                           uid, uname, tid, owner_title, 0, time.time()))
                            # 实时推送（WebSocket）
                            ws_push(owner_id, {
                                "kind": "notification",
                                "notification": {"id": notif_id, "type": "like",
                                                 "title": "收到新点赞",
                                                 "content": f"{uname}赞了你的歌曲《{owner_title}》",
                                                 "fromUserId": uid, "fromUser": uname,
                                                 "trackId": tid, "trackTitle": owner_title,
                                                 "isRead": 0, "created": time.time()},
                                "unread": _notif_unread(c, owner_id)})
                    c.commit()
                    row = c.execute("SELECT like_count FROM tracks WHERE id=?", (tid,)).fetchone()
                    c.close()
                    self._json(200, {"liked": liked, "likeCount": row[0] if row else 0})
                except Exception as e:
                    self._internal_error(e)
                return

            # ---------- 分享 +1 ----------
            if u.path.startswith("/api/share/"):
                if not rate_limit(self, "share"):
                    self._err(429, "请求过于频繁，请稍后再试")
                    return
                try:
                    tid = u.path.rsplit("/", 1)[-1]
                    c = db()
                    uid, via_token = self.auth_user(c)
                    if not uid:
                        c.close()
                        self._err(401, "未登录或登录已过期")
                        return
                    c.execute("UPDATE tracks SET share_count=share_count+1 WHERE id=?", (tid,))
                    c.execute("UPDATE collected_tracks SET share_count=share_count+1 WHERE id=?", (tid,))
                    c.execute("""INSERT INTO behavior_events(id,user_id,track_id,event,value,meta,track_info,created)
                                 VALUES(?,?,?,?,?,?,?,?)""",
                              (uuid.uuid4().hex, uid, tid, "share", 1.0,
                               "", _track_info(c, tid), time.time()))
                    # 分享通知：给歌曲上传者（用户上传表 + 采集表都覆盖）
                    owner_id, owner_title = _track_owner(c, tid)
                    if owner_id and owner_id != uid:
                        notif_id = uuid.uuid4().hex
                        from_user = c.execute("SELECT name FROM users WHERE id=?", (uid,)).fetchone()
                        uname = from_user[0] if from_user else "有人"
                        c.execute("""INSERT INTO notifications(id, user_id, type, title, content, from_user_id, from_user_name, track_id, track_title, is_read, created)
                                     VALUES(?,?,?,?,?,?,?,?,?,?,?)""",
                                  (notif_id, owner_id, "share", "收到新分享",
                                   f"{uname}分享了你的歌曲《{owner_title}》",
                                   uid, uname, tid, owner_title, 0, time.time()))
                        # 实时推送（WebSocket）
                        ws_push(owner_id, {
                            "kind": "notification",
                            "notification": {"id": notif_id, "type": "share",
                                             "title": "收到新分享",
                                             "content": f"{uname}分享了你的歌曲《{owner_title}》",
                                             "fromUserId": uid, "fromUser": uname,
                                             "trackId": tid, "trackTitle": owner_title,
                                             "isRead": 0, "created": time.time()},
                            "unread": _notif_unread(c, owner_id)})
                    c.commit()
                    row = c.execute("SELECT share_count FROM tracks WHERE id=?", (tid,)).fetchone()
                    if not row:
                        row = c.execute("SELECT share_count FROM collected_tracks WHERE id=?", (tid,)).fetchone()
                    c.close()
                    self._json(200, {"shareCount": row[0] if row else 0})
                except Exception as e:
                    self._internal_error(e)
                return

            # ---------- 上传评论图片 ----------
            if u.path == "/api/upload-comment-image":
                if not rate_limit(self, "comment_image"):
                    self._err(429, "上传过于频繁，请稍后再试")
                    return
                try:
                    if length <= 0:
                        self._err(400, "empty body")
                        return
                    if length > MAX_COMMENT_IMAGE + 1024 * 1024:
                        self._err(413, "too large")
                        return
                    fields, files = self._parse_multipart(length)
                    if fields is None:
                        self._err(400, "need multipart")
                        return
                    c = db()
                    uid, via_token = self.auth_user(c, fields)
                    if not uid:
                        c.close()
                        self._err(401, "未登录或登录已过期")
                        return
                    img = files.get("image")
                    if not img or not img[0]:
                        c.close()
                        self._err(400, "no image")
                        return
                    fname, fdata = img
                    if len(fdata) > MAX_COMMENT_IMAGE:
                        c.close()
                        self._err(413, "too large")
                        return
                    cext = os.path.splitext(fname)[1].lower()
                    if cext not in (".jpg", ".jpeg", ".png", ".webp"):
                        c.close()
                        self._err(400, "unsupported image type")
                        return
                    if not image_magic_ok(fdata, cext):
                        c.close()
                        self._err(400, "图片文件格式校验失败")
                        return
                    stored = "cmt_" + uuid.uuid4().hex + cext
                    with open(os.path.join(FILES, stored), "wb") as f:
                        f.write(fdata)
                    c.close()
                    self._json(200, {"name": stored})
                except Exception as e:
                    self._internal_error(e)
                return

            # ---------- AI 乐评（生成并发布，透明 AI 账号身份） ----------
            if u.path.startswith("/api/ai-comment/"):
                if not rate_limit(self, "ai_comment"):
                    self._err(429, "AI 乐评生成过于频繁，请稍后再试")
                    return
                try:
                    tid = u.path.split("/")[3]
                    body = {}
                    try:
                        ln = int(self.headers.get("Content-Length") or 0)
                        if ln > 0 and ln < 65536:
                            body = json.loads(self.rfile.read(ln).decode("utf-8") or "{}")
                    except Exception:
                        body = {}
                    c = db()
                    uid, _via = self.auth_user(c, body)
                    if not uid:
                        c.close()
                        self._err(401, "未登录或登录已过期")
                        return
                    # 歌曲信息：用户上传表优先，其次采集表
                    row = c.execute("SELECT id,title,artist,album,cover,genre FROM tracks WHERE id=?", (tid,)).fetchone()
                    src = "tracks"
                    if not row:
                        row = c.execute("SELECT id,title,artist,album,cover,genre FROM collected_tracks WHERE id=?", (tid,)).fetchone()
                        src = "collected_tracks"
                    if not row:
                        c.close()
                        self._err(404, "歌曲不存在")
                        return
                    # 每首歌最多 2 条 AI 乐评，已有则直接返回（不重复生成）
                    existing = c.execute(
                        "SELECT id,content,created FROM comments WHERE track_id=? AND user_id=? ORDER BY created",
                        (tid, _ai_uid())).fetchall()
                    ai_name = _ai_display_name()
                    if len(existing) >= 2:
                        c.close()
                        self._json(200, {"ok": True, "comment": {
                            "id": existing[-1][0], "userId": _ai_uid(),
                            "userName": ai_name, "content": existing[-1][1],
                            "images": [], "created": existing[-1][2],
                            "isAi": True, "duplicate": True}})
                        return
                    text = _ai_generate_comment(row[1], row[2], row[3], row[5])
                    if not text:
                        c.close()
                        self._err(502, "AI 乐评生成失败，请稍后再试")
                        return
                    cid = uuid.uuid4().hex
                    now = time.time()
                    images = "[]"
                    if random.random() * 100 < MEME_PROB_PCT:
                        m = _fetch_meme_image()
                        if m:
                            images = json.dumps([m])
                    c.execute("""INSERT INTO comments(id,track_id,user_id,user_name,content,images,created,is_ai)
                                 VALUES(?,?,?,?,?,?,?,1)""",
                              (cid, tid, _ai_uid(), ai_name, text, images, now))
                    c.commit()
                    # 通知歌曲上传者（AI 评论了你的歌曲）
                    owner_id, owner_title = _track_owner(c, tid)
                    if owner_id and owner_id != uid:
                        c.execute("""INSERT INTO notifications(id, user_id, type, title, content, from_user_id, from_user_name, track_id, track_title, is_read, created)
                                     VALUES(?,?,?,?,?,?,?,?,?,?,?)""",
                                  (uuid.uuid4().hex, owner_id, "comment", "收到 AI 乐评",
                                   f"{ai_name} 评论了你的歌曲《{owner_title}》",
                                   _ai_uid(), ai_name, tid, owner_title, 0, now))
                    c.commit()
                    c.close()
                    self._json(200, {"ok": True, "comment": {
                        "id": cid, "userId": _ai_uid(), "userName": ai_name,
                        "content": text, "images": [], "created": now, "isAi": True}})
                except Exception as e:
                    self._internal_error(e)
                return

            # ---------- 发表评论 ----------
            if u.path.startswith("/api/comment/"):
                if not rate_limit(self, "comment"):
                    self._err(429, "评论过于频繁，请稍后再试")
                    return
                try:
                    tid = u.path.rsplit("/", 1)[-1]
                    try:
                        body = json.loads(self.rfile.read(length) or b"{}")
                    except Exception:
                        body = {}
                    c = db()
                    uid, via_token = self.auth_user(c, body)
                    if not uid:
                        c.close()
                        self._err(401, "未登录或登录已过期")
                        return
                    uname = (body.get("userName") or "").strip()[:20]
                    content = (body.get("content") or "").strip()[:MAX_COMMENT]
                    # 过滤控制字符（防注入/异常渲染）
                    content = "".join(ch for ch in content if ch >= " " or ch == "\n").strip()
                    # 评论图片：仅接受本服务上传接口生成的 cmt_ 文件（白名单正则，防路径/文件名注入）
                    images = body.get("images") or []
                    if isinstance(images, str):
                        images = [i.strip() for i in images.split(",") if i.strip()]
                    if not isinstance(images, list):
                        images = []
                    images = [i for i in images[:6]
                              if isinstance(i, str)
                              and re.fullmatch(r"cmt_[0-9a-f]{32}\.(?:jpg|jpeg|png|webp)", i)]
                    # 文字与图片至少有一项才能发布（支持纯图片评论）
                    if not content and not images:
                        c.close()
                        self._err(400, "评论内容不能为空")
                        return
                    cid = uuid.uuid4().hex
                    c.execute("""INSERT INTO comments(id,track_id,user_id,user_name,content,images,created)
                                 VALUES(?,?,?,?,?,?,?)""",
                              (cid, tid, uid, uname, content,
                               json.dumps(images, ensure_ascii=False), time.time()))
                    c.execute("""INSERT INTO behavior_events(id,user_id,track_id,event,value,meta,track_info,created)
                                 VALUES(?,?,?,?,?,?,?,?)""",
                              (uuid.uuid4().hex, uid, tid, "comment", 1.0,
                               "", _track_info(c, tid), time.time()))
                    # 评论通知：给歌曲上传者（用户上传表 + 采集表都覆盖）
                    owner_id, owner_title = _track_owner(c, tid)
                    if owner_id and owner_id != uid:
                        notif_id = uuid.uuid4().hex
                        c.execute("""INSERT INTO notifications(id, user_id, type, title, content, from_user_id, from_user_name, track_id, track_title, is_read, created, comment_id)
                                     VALUES(?,?,?,?,?,?,?,?,?,?,?,?)""",
                                  (notif_id, owner_id, "comment", "收到新评论",
                                   f"{uname}评论了你的歌曲《{owner_title}》：{content[:50]}",
                                   uid, uname, tid, owner_title, 0, time.time(), cid))
                        # 实时推送（WebSocket）
                        ws_push(owner_id, {
                            "kind": "notification",
                            "notification": {"id": notif_id, "type": "comment",
                                             "title": "收到新评论",
                                             "content": f"{uname}评论了你的歌曲《{owner_title}》：{content[:50]}",
                                             "fromUserId": uid, "fromUser": uname,
                                             "commentId": cid,
                                             "trackId": tid, "trackTitle": owner_title,
                                             "isRead": 0, "created": time.time()},
                            "unread": _notif_unread(c, owner_id)})
                    c.commit()
                    c.close()
                    self._json(200, {"id": cid})
                except Exception as e:
                    self._internal_error(e)
                return

            # ---------- 用户行为上报（点赞/打开评论/评论/分享/收听/搜索/跳过） ----------
            if u.path == "/api/behavior":
                if not rate_limit(self, "behavior"):
                    self._err(429, "请求过于频繁，请稍后再试")
                    return
                try:
                    raw = self.rfile.read(min(length, 256 * 1024)) if length > 0 else b""
                    data = json.loads(raw.decode("utf-8") or "{}")
                except Exception:
                    self._err(400, "bad json")
                    return
                c = db()
                uid, via_token = self.auth_user(c, data)
                if not uid:
                    c.close()
                    self._err(401, "未登录或登录已过期")
                    return
                evs = data.get("events") or []
                if not isinstance(evs, list) or not evs or len(evs) > 30:
                    c.close()
                    self._err(400, "events must be 1..30")
                    return
                now = time.time()
                ins, has_listen = _ingest_behavior(c, uid, evs, now)
                c.commit()
                # 实时数据事件：任意行为变化后节流推送个性化推荐刷新（15s），
                # 收听事件额外附带听歌时长统计；前端收到 recommend 事件自动刷新「猜你喜欢」
                if ins:
                    _ws_refresh_recommend(c, uid, has_listen)
                c.close()
                self._json(200, {"ok": True, "count": ins})
                return

            # ---------- 歌曲上传 ----------
            if u.path != "/api/upload":
                self._err(404, "unknown")
                return
            if not rate_limit(self, "upload"):
                self._err(429, "上传过于频繁，请稍后再试")
                return
            try:
                if length > MAX_UPLOAD + 1024 * 1024:
                    self._err(413, "too large")
                    return
                if length <= 0:
                    self._err(400, "empty body")
                    return
                fields, files = self._parse_multipart(length)
                if fields is None:
                    self._err(400, "need multipart")
                    return
                c = db()
                uid, via_token = self.auth_user(c, fields)
                if not uid:
                    c.close()
                    self._err(401, "未登录或登录已过期")
                    return
                audio = files.get("file")
                if not audio or not audio[0]:
                    c.close()
                    self._err(400, "no file")
                    return
                filename, filedata = audio
                if len(filedata) > MAX_UPLOAD:
                    c.close()
                    self._err(413, "too large")
                    return
                ext = os.path.splitext(filename)[1].lower()
                if ext not in (".mp3", ".wav", ".m4a", ".aac", ".flac", ".ogg"):
                    c.close()
                    self._err(400, "unsupported audio type")
                    return
                if not audio_magic_ok(filedata, ext):
                    c.close()
                    self._err(400, "音频文件内容校验失败")
                    return
                tid = uuid.uuid4().hex
                stored = tid + ext
                fp = os.path.join(FILES, stored)
                with open(fp, "wb") as f:
                    f.write(filedata)
                dur = audio_duration(fp)
                title = (fields.get("title") or os.path.splitext(filename)[0]).strip()[:MAX_NAME] or "未命名"
                cover_fname = ""
                cover = files.get("cover")
                if cover and cover[0]:
                    cfn, cdata = cover
                    cext = os.path.splitext(cfn)[1].lower()
                    if cext not in (".jpg", ".jpeg", ".png", ".webp", ".heic"):
                        cext = ".jpg"
                    if not image_magic_ok(cdata, cext):
                        c.close()
                        self._err(400, "封面文件格式校验失败")
                        return
                    cover_fname = tid + "_cover" + cext
                    cpath = os.path.join(FILES, cover_fname)
                    with open(cpath, "wb") as f:
                        f.write(cdata)
                lrc_fname = ""
                lrc_file = files.get("lrc")
                if lrc_file and lrc_file[0]:
                    _, ldata = lrc_file
                    if len(ldata) > 512 * 1024:
                        ldata = ldata[:512 * 1024]
                    lrc_fname = tid + ".lrc"
                    lpath = os.path.join(FILES, lrc_fname)
                    with open(lpath, "wb") as f:
                        f.write(ldata)
                c.execute("""INSERT INTO tracks(id,title,artist,album,cover,lrc,fname,size,dur,created,user_id)
                             VALUES(?,?,?,?,?,?,?,?,?,?,?)""",
                          (tid, title, (fields.get("artist") or "").strip()[:MAX_NAME],
                           (fields.get("album") or "").strip()[:MAX_NAME],
                           cover_fname, lrc_fname, stored, len(filedata), dur, time.time(), uid))
                c.commit()
                # 实时数据事件：我的作品列表更新 + 全局歌曲列表更新（广播在线用户）
                ws_push(uid, {"kind": "event", "event": "my_tracks", "action": "upload"})
                ws_broadcast({"kind": "event", "event": "track_list", "reason": "upload"})
                c.close()
                self._json(200, {"id": tid, "title": title, "cover": cover_fname,
                                 "dur": dur, "durText": _fmt_dur(dur)})
            except Exception as e:
                self._internal_error(e)
        except (socket.timeout, TimeoutError):
            self._err(408, "request timeout")
        except Exception as e:
            self._internal_error(e)

    # ---- DELETE（管理端删除类接口） ----

    def do_DELETE(self):
        try:
            u = urllib.parse.urlparse(self.path)

            # ---------- 删除 AI 乐评（网站管理） ----------
            if u.path.startswith("/api/admin/ai-comment/"):
                if self.headers.get("X-Admin-Token", "").strip() != _admin_token():
                    self._err(401, "unauthorized"); return
                cid = u.path[len("/api/admin/ai-comment/"):]
                if cid:
                    c = db()
                    try:
                        c.execute("DELETE FROM comments WHERE id=? AND user_id=?", (cid, _ai_uid()))
                        c.commit()
                    finally:
                        c.close()
                self._json(200, {"ok": True}); return

            # ---------- 清空搜索历史 ----------
            if u.path == "/api/search/history":
                c = db()
                uid = resolve_token(c, self.headers.get("Authorization", ""))
                if not uid:
                    c.close()
                    self._err(401, "unauthorized"); return
                c.execute("DELETE FROM search_history WHERE user_id=?", (uid,))
                c.commit()
                c.close()
                self._json(200, {"ok": True}); return

            # ---------- 从歌单删除歌曲 ----------
            if u.path.startswith("/api/playlists/") and "/tracks/" in u.path:
                parts = u.path.split("/")
                pid = parts[3]
                tid = parts[5]
                c = db()
                uid = resolve_token(c, self.headers.get("Authorization", ""))
                if not uid:
                    c.close()
                    self._err(401, "unauthorized"); return
                # 验证歌单属于当前用户
                pl = c.execute("SELECT id, cover FROM playlists WHERE id=? AND user_id=?", (pid, uid)).fetchone()
                if not pl:
                    c.close()
                    self._err(404, "playlist not found"); return
                old_cover = pl[1] or ""
                c.execute("DELETE FROM playlist_tracks WHERE playlist_id=? AND track_id=?", (pid, tid))
                c.execute("UPDATE playlists SET track_count=MAX(0, track_count-1) WHERE id=?", (pid,))
                # 如果删除的是当前封面对应的歌曲，更新封面为最新一首的封面
                if old_cover:
                    newest = c.execute("SELECT track_cover FROM playlist_tracks WHERE playlist_id=? AND track_cover != '' ORDER BY created DESC LIMIT 1", (pid,)).fetchone()
                    new_cover = newest[0] if newest else ""
                    c.execute("UPDATE playlists SET cover=? WHERE id=?", (new_cover, pid))
                c.commit()
                c.close()
                self._json(200, {"ok": True}); return

            # ---------- 软删除单条通知 ----------
            if u.path.startswith("/api/notifications/"):
                nid = u.path.rsplit("/", 1)[-1]
                c = db()
                uid = resolve_token(c, self.headers.get("Authorization", ""))
                if not uid:
                    c.close()
                    self._err(401, "unauthorized"); return
                c.execute("UPDATE notifications SET is_deleted=1 WHERE id=? AND user_id=?", (nid, uid))
                c.commit()
                c.close()
                self._json(200, {"ok": True}); return

            # 删除官方通知：DELETE /api/admin/official-message/<id>
            # 同时清理该通知在用户侧 notifications 表（type=official）里的关联记录，
            # 否则删除按钮点击后用户端仍残留已删通知。
            if u.path.startswith("/api/admin/official-message/"):
                if self.headers.get("X-Admin-Token", "").strip() != _admin_token():
                    self._err(401, "unauthorized"); return
                mid = u.path.rsplit("/", 1)[-1]
                c = db()
                row = c.execute("SELECT content FROM official_messages WHERE id=?", (mid,)).fetchone()
                if not row:
                    c.close()
                    self._err(404, "not found"); return
                content = row[0]
                c.execute("DELETE FROM official_messages WHERE id=?", (mid,))
                # 官方通知发布时按内容为每个用户生成一条 notifications 记录；
                # 无外键关联，按 type+content 匹配删除（官方通知内容一般唯一）。
                c.execute("DELETE FROM notifications WHERE type='official' AND content=?", (content,))
                c.commit()
                c.close()
                self._json(200, {"ok": True}); return

            self._err(404, "unknown")
        except (socket.timeout, TimeoutError):
            self._err(408, "request timeout")
        except Exception as e:
            self._internal_error(e)
