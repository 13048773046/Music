#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""流萤音乐后端（企业级加固版）
纯标准库，监听 127.0.0.1:8788（由 Nginx 反代对外）。

相对旧版的主要加固：
1. 身份鉴权：登录/注册签发 Bearer Token（30 天有效），写操作与上传必须带有效身份；
   兼容旧客户端：无 token 时回退 userId/account 参数，可通过 MUSIC_AUTH_STRICT=1 强制仅 token。
2. 密码安全：PBKDF2-HMAC-SHA256（210000 轮，盐随机），旧 120000 轮哈希自动迁移升级。
3. 上传安全：音频/图片魔数校验（不再只信扩展名）、文件大小限制、存储名服务端生成（防路径穿越）。
4. 文件服务安全：所有静态文件路径做 basename + 目录边界校验。
5. Range 请求：单段 range 边界修复（416 / suffix / 越界），支持 HEAD。
6. 并发与写入：SQLite WAL + busy_timeout，ThreadingHTTPServer 多线程安全。
7. 限流防刷：按 IP+接口 滑动窗口限流（登录/注册/上传/播放/点赞/评论/分享/列表）。
8. 统一错误响应：不向客户端泄露内部异常细节；内部错误写日志。
9. 结构化访问日志：时间 / IP / 方法 / 路径 / 状态 / 耗时。
10. 慢速攻击防护：连接级 socket 超时（60s），读取超时返回 408。

配置（环境变量，均可选）：
    MUSIC_ROOT        数据根目录（默认 /www/wwwroot/music）
    MUSIC_AUTH_STRICT 1 时仅接受 Bearer Token（旧客户端将失效）
    MUSIC_DEBUG       1 时把内部异常明文返回（仅本地排查用）
"""
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
import secrets
import logging
import socket
import struct
import urllib.parse
import urllib.request
import re
import base64
import threading
import difflib
from html import escape as html_escape
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ---------------- 配置 ----------------

ROOT = os.environ.get("MUSIC_ROOT", "/www/wwwroot/music")
FILES = os.path.join(ROOT, "files")
DB = os.path.join(ROOT, "tracks.db")
PORT = int(os.environ.get("MUSIC_PORT", "8788"))
MAX_UPLOAD = 100 * 1024 * 1024        # 单曲音频上限 100MB
MAX_PROFILE = 8 * 1024 * 1024         # 注册/改资料请求上限 8MB
MAX_COMMENT = 200                     # 评论最大字符
MAX_NAME = 40                         # 昵称/歌手/标题最大长度
TOKEN_TTL = 30 * 24 * 3600            # token 有效期 30 天
PBKDF2_ITER = 210000                  # 新密码哈希迭代次数
LEGACY_ITER = 120000                  # 旧哈希迭代次数（自动迁移）
AUTH_STRICT = os.environ.get("MUSIC_AUTH_STRICT", "0") == "1"
DEBUG = os.environ.get("MUSIC_DEBUG", "0") == "1"
SOCKET_TIMEOUT = 60
STREAM_SIGN_TTL = 1800                # 签名流 URL 有效期 30 分钟（防链接泄露/盗链）
SIGN_STRICT = os.environ.get("MUSIC_SIGN_STRICT", "0") == "1"  # 1 时仅接受签名流请求
PUBLIC_BASE = os.environ.get("MUSIC_PUBLIC_URL", "https://www.dbmt999.asia/music").rstrip("/")

# 流签名密钥：优先环境变量 MUSIC_SIGN_SECRET，否则读取/生成持久化密钥（重启不失效）
SIGN_SECRET = os.environ.get("MUSIC_SIGN_SECRET", "")
if not SIGN_SECRET:
    _secret_file = os.path.join(ROOT, ".sign_secret")
    try:
        if os.path.exists(_secret_file):
            _s = open(_secret_file, encoding="utf-8").read().strip()
            if _s:
                SIGN_SECRET = _s
        if not SIGN_SECRET:
            SIGN_SECRET = secrets.token_hex(32)
            with open(_secret_file, "w", encoding="utf-8") as f:
                f.write(SIGN_SECRET)
    except OSError:
        SIGN_SECRET = secrets.token_hex(32)

os.makedirs(FILES, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("music")


# ---------------- 数据库 ----------------

def db():
    c = sqlite3.connect(DB, timeout=10)
    c.execute("PRAGMA journal_mode=WAL")        # 读写并发，避免锁库
    c.execute("PRAGMA busy_timeout=5000")
    c.execute("PRAGMA synchronous=NORMAL")
    c.execute("""CREATE TABLE IF NOT EXISTS tracks(
        id TEXT PRIMARY KEY, title TEXT, artist TEXT, album TEXT,
        fname TEXT, size INTEGER, dur REAL, created REAL)""")
    cols = [r[1] for r in c.execute("PRAGMA table_info(tracks)")]
    if "cover" not in cols:
        c.execute("ALTER TABLE tracks ADD COLUMN cover TEXT DEFAULT ''")
    if "lrc" not in cols:
        c.execute("ALTER TABLE tracks ADD COLUMN lrc TEXT DEFAULT ''")
    c.execute("""CREATE TABLE IF NOT EXISTS users(
        id TEXT PRIMARY KEY, account TEXT UNIQUE, password_hash TEXT,
        name TEXT, avatar TEXT, created REAL)""")
    ucols = [r[1] for r in c.execute("PRAGMA table_info(users)")]
    for _col, _ddl in [("gender", "TEXT DEFAULT ''"),
                       ("age", "INTEGER DEFAULT 0"),
                       ("background_image", "TEXT DEFAULT ''"),
                       ("signature", "TEXT DEFAULT ''"),
                       ("ip_address", "TEXT DEFAULT ''"),
                       ("banned", "INTEGER DEFAULT 0"),
                       ("ban_reason", "TEXT DEFAULT ''")]:
        if _col not in ucols:
            c.execute("ALTER TABLE users ADD COLUMN %s %s" % (_col, _ddl))
    tcols = [r[1] for r in c.execute("PRAGMA table_info(tracks)")]
    for _col, _ddl in [("user_id", "TEXT DEFAULT ''"),
                       ("play_count", "INTEGER DEFAULT 0"),
                       ("like_count", "INTEGER DEFAULT 0"),
                       ("share_count", "INTEGER DEFAULT 0"),
                       ("offline", "INTEGER DEFAULT 0"),
                       ("offline_reason", "TEXT DEFAULT ''"),
                       ("genre", "TEXT DEFAULT ''")]:
        if _col not in tcols:
            c.execute("ALTER TABLE tracks ADD COLUMN %s %s" % (_col, _ddl))
    c.execute("""CREATE TABLE IF NOT EXISTS likes(
        user_id TEXT, track_id TEXT, created REAL,
        PRIMARY KEY(user_id, track_id))""")
    c.execute("""CREATE TABLE IF NOT EXISTS comments(
        id TEXT PRIMARY KEY, track_id TEXT, user_id TEXT,
        user_name TEXT, content TEXT, created REAL)""")
    c.execute("""CREATE TABLE IF NOT EXISTS tokens(
        token TEXT PRIMARY KEY, user_id TEXT, created REAL, expires REAL)""")
    # 顺手清理过期 token（每次建连时轻量执行）
    c.execute("DELETE FROM tokens WHERE expires < ?", (time.time(),))
    c.execute("""CREATE TABLE IF NOT EXISTS share_tokens(
        token TEXT PRIMARY KEY, track_id TEXT, created REAL)""")
    scols = [r[1] for r in c.execute("PRAGMA table_info(share_tokens)")]
    if "short_code" not in scols:
        c.execute("ALTER TABLE share_tokens ADD COLUMN short_code TEXT DEFAULT ''")
    # 采集歌曲表：与用户上传表 tracks 分开，只存歌曲信息+上游播放地址，不落盘音频
    c.execute("""CREATE TABLE IF NOT EXISTS collected_tracks(
        id TEXT PRIMARY KEY, title TEXT, artist TEXT, album TEXT,
        cover TEXT, duration REAL, source TEXT, source_id TEXT,
        play_url TEXT, size REAL, created REAL, user_id TEXT,
        play_count INTEGER DEFAULT 0, like_count INTEGER DEFAULT 0,
        share_count INTEGER DEFAULT 0, lrc TEXT DEFAULT '',
        UNIQUE(source, source_id))""")
    ccols = [r[1] for r in c.execute("PRAGMA table_info(collected_tracks)")]
    for _col, _ddl in [("offline", "INTEGER DEFAULT 0"),
                       ("offline_reason", "TEXT DEFAULT ''"),
                       ("genre", "TEXT DEFAULT ''")]:
        if _col not in ccols:
            c.execute("ALTER TABLE collected_tracks ADD COLUMN %s %s" % (_col, _ddl))
    # 用户行为事件表（个性化推荐数据源）
    # event: like / comment_open / comment / share / listen
    # value: listen=累计收听秒数，like=1/0，其余 0
    # meta: JSON，如 {"fraction": 收听进度0~1, "plays": 本次会话播放次数}
    c.execute("""CREATE TABLE IF NOT EXISTS behavior_events(
        id TEXT PRIMARY KEY, user_id TEXT, track_id TEXT,
        event TEXT, value REAL DEFAULT 0, meta TEXT DEFAULT '',
        track_info TEXT DEFAULT '',
        created REAL)""")
    bev_cols = [r[1] for r in c.execute("PRAGMA table_info(behavior_events)")]
    if "track_info" not in bev_cols:
        c.execute("ALTER TABLE behavior_events ADD COLUMN track_info TEXT DEFAULT ''")
    c.execute("CREATE INDEX IF NOT EXISTS idx_bev_user ON behavior_events(user_id, created)")
    # 公告通知表：App 启动时从底部弹窗展示最新公告
    c.execute("""CREATE TABLE IF NOT EXISTS announcements(
        id TEXT PRIMARY KEY, title TEXT, content TEXT,
        version TEXT DEFAULT '', active INTEGER DEFAULT 1,
        show_once INTEGER DEFAULT 0,
        type TEXT DEFAULT 'announcement',
        force_update INTEGER DEFAULT 0,
        download_url TEXT DEFAULT '',
        created REAL)""")
    ann_cols = [r[1] for r in c.execute("PRAGMA table_info(announcements)")]
    for col, default in [("show_once","0"),("type","'announcement'"),("force_update","0"),("download_url","''")]:
        if col not in ann_cols:
            c.execute("ALTER TABLE announcements ADD COLUMN %s TEXT DEFAULT %s" % (col, default))
    # 通知表：互动通知（点赞/评论/分享）+ 官方通知记录；comment_id 用于评论通知点击定位
    c.execute("""CREATE TABLE IF NOT EXISTS notifications(
        id TEXT PRIMARY KEY, user_id TEXT, type TEXT,
        title TEXT DEFAULT '', content TEXT DEFAULT '',
        from_user_id TEXT DEFAULT '', from_user_name TEXT DEFAULT '',
        track_id TEXT DEFAULT '', track_title TEXT DEFAULT '',
        is_read INTEGER DEFAULT 0, created REAL)""")
    ncols = [r[1] for r in c.execute("PRAGMA table_info(notifications)")]
    if "comment_id" not in ncols:
        c.execute("ALTER TABLE notifications ADD COLUMN comment_id TEXT DEFAULT ''")
    # 官方消息表：聊天记录样式展示
    c.execute("""CREATE TABLE IF NOT EXISTS official_messages(
        id TEXT PRIMARY KEY, content TEXT DEFAULT '', created REAL,
        sender_name TEXT DEFAULT '流萤音乐官方')""")
    c.commit()
    return c


def client_ip(handler):
    """经 nginx 反代，优先取 X-Forwarded-For 第一段，其次 X-Real-IP。"""
    xff = handler.headers.get("X-Forwarded-For", "")
    if xff:
        return xff.split(",")[0].strip()
    xri = handler.headers.get("X-Real-IP", "")
    if xri:
        return xri.strip()
    return handler.client_address[0] if handler.client_address else ""


def public_user(row, token=None):
    """users 行 → 对外资料 JSON（不含密码哈希，可附带新签发 token）。
    row 顺序: id,account,password_hash,name,avatar,created,
              gender,age,background_image,signature,ip_address"""
    out = {
        "id": row[0],
        "account": row[1],
        "name": row[3] or "",
        "avatar": row[4] or "",
        "created": row[5] or 0,
        "gender": row[6] or "",
        "age": row[7] or 0,
        "background": row[8] or "",
        "signature": row[9] or "",
        "ip": row[10] or "",
    }
    if token:
        out["token"] = token
    return out


# ---------------- 密码哈希（v1 兼容，v2 自动迁移） ----------------

def hash_password(pw):
    salt = os.urandom(16).hex()
    h = hashlib.pbkdf2_hmac("sha256", pw.encode("utf-8"),
                            bytes.fromhex(salt), PBKDF2_ITER).hex()
    return f"{salt}${PBKDF2_ITER}${h}"


def verify_password(pw, stored):
    """兼容两种存储格式：
    v2: salt$iter$hash    v1(旧): salt$hash（120000 轮）"""
    try:
        parts = stored.split("$")
        if len(parts) == 3:
            salt, iters_s, h = parts
            iters = int(iters_s)
        elif len(parts) == 2:
            salt, h = parts
            iters = LEGACY_ITER
        else:
            return False
        if iters <= 0 or iters > 10_000_000:
            return False
        test = hashlib.pbkdf2_hmac("sha256", pw.encode("utf-8"),
                                   bytes.fromhex(salt), iters).hex()
        return hmac.compare_digest(h, test)
    except Exception:
        return False


def is_legacy_hash(stored):
    return isinstance(stored, str) and len(stored.split("$")) == 2


# ---------------- Token 签发 / 校验 ----------------

def issue_token(c, uid):
    tok = secrets.token_urlsafe(32)
    now = time.time()
    c.execute("INSERT INTO tokens(token,user_id,created,expires) VALUES(?,?,?,?)",
              (tok, uid, now, now + TOKEN_TTL))
    return tok


def resolve_token(c, auth_header):
    """Authorization: Bearer <token> → user_id 或 None"""
    if not auth_header:
        return None
    scheme, _, tok = auth_header.partition(" ")
    if scheme.lower() != "bearer" or not tok.strip():
        return None
    row = c.execute(
        "SELECT user_id FROM tokens WHERE token=? AND expires>?",
        (tok.strip(), time.time())).fetchone()
    return row[0] if row else None


# ---------------- 限流（内存滑动窗口，按 IP+接口） ----------------

class RateLimiter:
    def __init__(self):
        self._lock = threading.Lock()
        self._hits = {}

    def allow(self, key, limit, window):
        now = time.time()
        with self._lock:
            dq = self._hits.setdefault(key, deque())
            while dq and now - dq[0] > window:
                dq.popleft()
            if len(dq) >= limit:
                return False
            dq.append(now)
            return True


RATE = RateLimiter()

RATE_LIMITS = {
    "tracks":    (60, 60),    # 列表 60 次/分
    "play":      (120, 60),   # 播放上报 120 次/分（切歌频繁）
    "like":      (60, 60),
    "comment":   (30, 60),
    "share":     (30, 60),
    "login":     (10, 60),
    "register":  (5, 60),
    "upload":    (30, 3600),  # 上传 30 次/小时
    "stream":    (300, 60),   # 流请求（含签名签发）300 次/分
    "share_url": (60, 60),    # 分享 token 签发/分享页 60 次/分
    "collect":   (60, 60),    # 采集歌曲列表 60 次/分
    "collect_add": (20, 60),  # 采集入库 20 次/分
    "behavior":  (120, 60),   # 用户行为上报 120 次/分
    "recommend": (30, 60),    # 个性化推荐 30 次/分
}

# 采集入库接口密钥（音乐源采集器调用 POST /api/collect/add 时携带）
COLLECT_KEY = os.environ.get("COLLECT_KEY", "liuying-collect-7f3a9c2e")


# ---------------- WebSocket 实时通知推送（RFC6455 服务端，纯标准库） ----------------
WS_LOCK = threading.Lock()
WS_CLIENTS = {}          # user_id -> set(sock)
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
WS_STATS_THROTTLE = {}   # uid -> 上次推送 stats/recommend 时间（行为上报节流，防止高频推送）


def _notif_unread(c, uid):
    """该用户当前未读通知数（调用时需持有数据库连接 c）。"""
    row = c.execute("SELECT COUNT(*) FROM notifications WHERE user_id=? AND is_read=0",
                    (uid,)).fetchone()
    return row[0] if row else 0


def _ws_frame(payload, opcode=1):
    """构造服务端→客户端 WebSocket 数据帧（不掩码）。"""
    n = len(payload)
    header = bytearray([0x80 | opcode])
    if n < 126:
        header.append(n)
    elif n < 65536:
        header.append(126)
        header += struct.pack(">H", n)
    else:
        header.append(127)
        header += struct.pack(">Q", n)
    return bytes(header) + payload


def ws_register(uid, sock):
    with WS_LOCK:
        WS_CLIENTS.setdefault(uid, set()).add(sock)


def ws_unregister(uid, sock):
    with WS_LOCK:
        s = WS_CLIENTS.get(uid)
        if s:
            s.discard(sock)
            if not s:
                WS_CLIENTS.pop(uid, None)


def ws_push(uid, payload):
    """向指定用户的全部在线连接推送 JSON 对象（新通知实时送达）。"""
    with WS_LOCK:
        socks = list(WS_CLIENTS.get(uid, ()))
    if not socks:
        return
    frame = _ws_frame(json.dumps(payload, ensure_ascii=False).encode("utf-8"))
    dead = []
    for s in socks:
        try:
            s.sendall(frame)
        except Exception:
            dead.append(s)
    if dead:
        with WS_LOCK:
            for d in dead:
                for uid2, st in list(WS_CLIENTS.items()):
                    if d in st:
                        st.discard(d)
                        if not st:
                            WS_CLIENTS.pop(uid2, None)


def ws_broadcast(payload):
    """向所有在线连接广播（官方通知发布用）。"""
    with WS_LOCK:
        socks = set()
        for st in WS_CLIENTS.values():
            socks |= set(st)
    if not socks:
        return
    frame = _ws_frame(json.dumps(payload, ensure_ascii=False).encode("utf-8"))
    dead = []
    for s in socks:
        try:
            s.sendall(frame)
        except Exception:
            dead.append(s)
    if dead:
        with WS_LOCK:
            for d in dead:
                for uid2, st in list(WS_CLIENTS.items()):
                    if d in st:
                        st.discard(d)
                        if not st:
                            WS_CLIENTS.pop(uid2, None)


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


def _ingest_behavior(c, uid, evs, now):
    """批量落库行为事件（校验 + 歌曲信息快照），返回 (写入条数, 是否含收听)。
    供 HTTP /api/behavior 与 WebSocket behavior 消息共用。"""
    ALLOW = ("like", "comment_open", "comment", "share", "listen", "search", "skip")
    ins, has_listen = 0, False
    for it in evs:
        tid = str(it.get("trackId") or "").strip()
        ev = str(it.get("event") or "").strip()
        if not tid and ev != "search":
            continue
        if ev not in ALLOW:
            continue
        if ev == "listen":
            has_listen = True
        try:
            val = float(it.get("value") or 0)
        except Exception:
            val = 0.0
        meta = it.get("meta")
        if isinstance(meta, dict):
            meta_s = json.dumps(meta, ensure_ascii=False)[:500]
        elif isinstance(meta, str):
            meta_s = meta[:500]
        else:
            meta_s = ""
        # 歌曲信息快照：推荐时直接用它找「类似的歌」，即使歌曲日后下架/删除也不影响推荐
        tinfo = ""
        if tid:
            _tr = c.execute("SELECT title,artist,album FROM tracks WHERE id=?", (tid,)).fetchone()
            if not _tr:
                _tr = c.execute("SELECT title,artist,album FROM collected_tracks WHERE id=?", (tid,)).fetchone()
            if _tr:
                tinfo = json.dumps({"title": _tr[0] or "", "artist": _tr[1] or "",
                                    "album": _tr[2] or ""}, ensure_ascii=False)[:500]
        c.execute("""INSERT INTO behavior_events(id,user_id,track_id,event,value,meta,track_info,created)
                     VALUES(?,?,?,?,?,?,?,?)""",
                  (uuid.uuid4().hex, uid, tid, ev, val, meta_s, tinfo, now))
        ins += 1
    return ins, has_listen


def _ws_refresh_recommend(c, uid, has_listen):
    """行为变化后节流推送：15s 内合并多次上报，避免高频推送；
    推送 recommend 事件驱动前端刷新「猜你喜欢」，收听时附带听歌时长统计。"""
    _now = time.time()
    _last = WS_STATS_THROTTLE.get(uid, 0)
    if _now - _last < 15:
        return
    WS_STATS_THROTTLE[uid] = _now
    if has_listen:
        _r1 = c.execute("SELECT COALESCE(SUM(value),0) FROM behavior_events"
                        " WHERE user_id=? AND event='listen'", (uid,)).fetchone()
        _r2 = c.execute("SELECT COUNT(DISTINCT track_id) FROM behavior_events"
                        " WHERE user_id=? AND event='listen'", (uid,)).fetchone()
        ws_push(uid, {"kind": "event", "event": "stats",
                      "totalSeconds": int(_r1[0]) if _r1 else 0,
                      "trackCount": int(_r2[0]) if _r2 else 0})
    ws_push(uid, {"kind": "event", "event": "recommend"})


def _ws_recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def _ws_serve(handler, uid):
    """握手完成后进入帧循环：响应 ping/pong/close，连接断开自动清理。"""
    sock = handler.connection
    ws_register(uid, sock)
    try:
        while True:
            head = _ws_recv_exact(sock, 2)
            if head is None:
                break
            b0, b1 = head[0], head[1]
            opcode = b0 & 0x0F
            masked = b1 & 0x80
            length = b1 & 0x7F
            if length == 126:
                ext = _ws_recv_exact(sock, 2)
                if ext is None:
                    break
                length = struct.unpack(">H", ext)[0]
            elif length == 127:
                ext = _ws_recv_exact(sock, 8)
                if ext is None:
                    break
                length = struct.unpack(">Q", ext)[0]
            if length > 16 * 1024 * 1024:
                break
            # WebSocket 协议：mask key（4 字节）位于 payload 之前；
            # 若先读 payload 再读 mask，会把 mask key 误读进 payload 导致解密乱码
            if masked:
                mask = _ws_recv_exact(sock, 4)
                if mask is None:
                    break
            payload = b""
            while len(payload) < length:
                chunk = sock.recv(min(length - len(payload), 65536))
                if not chunk:
                    payload = None
                    break
                payload += chunk
            if payload is None:
                break
            if masked:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if opcode == 0x8:      # close → 回 close 帧后断开
                try:
                    sock.sendall(_ws_frame(b"", opcode=8))
                except Exception:
                    pass
                break
            elif opcode == 0x9:    # ping → pong（保活）
                try:
                    sock.sendall(_ws_frame(payload, opcode=0xA))
                except Exception:
                    break
            elif opcode == 0xA:    # pong
                continue
            elif opcode in (0x1, 0x2):  # text/binary：客户端业务消息
                # 实时行为上报（即时通讯通道）：{"type":"behavior","events":[...]}
                # 与 HTTP /api/behavior 共用落库逻辑；落库后节流推送 recommend 事件，
                # 前端收到即刷新「猜你喜欢」，实现行为一变、推荐实时更新
                try:
                    _msg = json.loads(payload.decode("utf-8") or "{}")
                except Exception as _e:
                    log.info("ws behavior json err %s", _e)
                    _msg = None
                if isinstance(_msg, dict) and _msg.get("type") == "behavior":
                    _evs = _msg.get("events")
                    if isinstance(_evs, list) and _evs and len(_evs) <= 30:
                        try:
                            _c = db()
                            _ins, _hl = _ingest_behavior(_c, uid, _evs, time.time())
                            if _ins:
                                _c.commit()
                                _ws_refresh_recommend(_c, uid, _hl)
                            log.info("ws behavior uid=%s ins=%d", uid, _ins)
                            _c.close()
                        except Exception as _e:
                            log.info("ws behavior ingest err %s", _e)
                continue
    except Exception:
        pass
    finally:
        ws_unregister(uid, sock)
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except Exception:
            pass
        try:
            sock.close()
        except Exception:
            pass


def _ws_handshake(handler, u):
    """GET /api/ws?token=xxx → 101 升级为 WebSocket；未鉴权返回 401。"""
    key = handler.headers.get("Sec-WebSocket-Key", "")
    if not key:
        handler._err(400, "missing websocket key")
        return
    qs = urllib.parse.parse_qs(u.query)
    tok = (qs.get("token", [""])[0] or "").strip()
    c = db()
    uid = None
    if tok:
        row = c.execute("SELECT user_id FROM tokens WHERE token=? AND expires>?",
                        (tok, time.time())).fetchone()
        uid = row[0] if row else None
    c.close()
    if not uid:
        try:
            handler.send_response(401)
            handler.send_header("Content-Type", "text/plain; charset=utf-8")
            handler.send_header("Content-Length", "13")
            handler.end_headers()
            handler.wfile.write(b"unauthorized")
        except Exception:
            pass
        return
    accept = base64.b64encode(
        hashlib.sha1((key + WS_GUID).encode()).digest()).decode("ascii")
    try:
        handler.wfile.write(
            b"HTTP/1.1 101 Switching Protocols\r\n"
            b"Upgrade: websocket\r\n"
            b"Connection: Upgrade\r\n"
            b"Sec-WebSocket-Accept: " + accept.encode("ascii") + b"\r\n\r\n")
        handler.wfile.flush()
    except Exception:
        return
    _ws_serve(handler, uid)


def _ssl_ctx():
    """优先使用系统 CA 证书（服务器 Python 环境证书链不完整会导致 https 下载失败），
    找不到 CA 文件时降级为不校验证书（仅用于封面图片下载，非敏感链路）。"""
    for cafile in ("/etc/pki/tls/certs/ca-bundle.crt",
                   "/etc/ssl/certs/ca-certificates.crt"):
        if os.path.exists(cafile):
            try:
                return ssl.create_default_context(cafile=cafile)
            except Exception:
                pass
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def rate_key(handler, name, extra=""):
    return (name, client_ip(handler), extra)


def rate_limit(handler, name, extra=""):
    limit, window = RATE_LIMITS[name]
    return RATE.allow(rate_key(handler, name, extra), limit, window)


def parse_page(qs, default_size=20, max_size=50):
    """解析列表分页参数：返回 (page, page_size)。

    - page 从 1 开始；page<1 或未传 → 返回 None，表示「不分页、全量返回」（兼容旧客户端）。
    - pageSize 默认 20，超上限 50 时截断。
    """
    try:
        page = int((qs.get("page", [""])[0] or "").strip() or 0)
    except (ValueError, TypeError):
        page = 0
    try:
        page_size = int((qs.get("pageSize", [""])[0] or "").strip() or default_size)
    except (ValueError, TypeError):
        page_size = default_size
    if page_size < 1:
        page_size = default_size
    if page_size > max_size:
        page_size = max_size
    return (page if page >= 1 else None), page_size


# ---------------- 流媒体签名 URL ----------------

def sign_stream(tid, exp):
    """HMAC-SHA256 签名：防链接被篡改/伪造，配合时效防永久盗链。"""
    return hmac.new(SIGN_SECRET.encode(), f"{tid}:{exp}".encode(), hashlib.sha256).hexdigest()[:32]


def verify_stream(tid, exp_s, sig):
    """校验流请求签名。返回 True 放行 / False 拒绝。"""
    if not exp_s.isdigit():
        return False
    exp = int(exp_s)
    if exp < int(time.time()) - 60:      # 允许 60s 时钟偏差，过期即拒绝
        return False
    if not sig or len(sig) != 32:
        return False
    return hmac.compare_digest(sig, sign_stream(tid, exp))


_B62 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"


def gen_short_code(n=8):
    """生成 n 位 base62 随机短码（汽水风格短链，如 iXbwY55P）。"""
    return "".join(secrets.choice(_B62) for _ in range(n))


# ---------------- 文件安全 ----------------

# 管理后台密码文件：默认随 ROOT（测试环境用临时 ROOT 时自动隔离），可用环境变量覆盖
ADMIN_PWD_FILE = os.environ.get("MUSIC_ADMIN_PWD_FILE", os.path.join(ROOT, "admin_pwd"))

def _admin_token():
    """管理后台密码：持久化文件优先，其次环境变量，最后默认值"""
    try:
        with open(ADMIN_PWD_FILE, "r", encoding="utf-8") as _f:
            _t = _f.read().strip()
        if _t:
            return _t
    except Exception:
        pass
    return os.environ.get("ADMIN_TOKEN", "liuying-admin-8f3a")


def safe_file_path(fname):
    """仅允许 FILES 目录内的文件，防路径穿越（纵深防御）。"""
    if not fname:
        return None
    name = os.path.basename(str(fname))
    real_files = os.path.realpath(FILES)
    p = os.path.realpath(os.path.join(real_files, name))
    if not (p == real_files or p.startswith(real_files + os.sep)):
        return None
    if not os.path.exists(p):
        return None
    return p


# ---------------- 汽水音乐分享链接解析（H5 采集：封面原图/歌词/音乐标签） ----------------

QISHUI_SHARE_UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) "
                   "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1")


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
    """汽水逐字歌词 sentences → 标准 LRC 文本（[mm:ss.xx] 文本），与库内格式一致。"""
    if not isinstance(sentences, list):
        return ""
    lines = []
    for s in sentences:
        if not isinstance(s, dict):
            continue
        ms = int(s.get("startMs") or 0)
        mm = ms // 60000
        ss = (ms // 1000) % 60
        xx = (ms % 1000) // 10
        words = s.get("words") or []
        if isinstance(words, list) and words:
            text = "".join(str(w.get("text", "")) for w in words if isinstance(w, dict))
        else:
            text = str(s.get("text", ""))
        if text:
            lines.append("[%02d:%02d.%02d] %s" % (mm, ss, xx, text))
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


# ---------------- 封面缩略图（移动端加载加速） ----------------

COVER_SMALL_MAX_SIDE = 600            # 缩略图长边最大像素
COVER_SMALL_QUALITY = 82              # JPEG 质量
COVER_SMALL_MIN_SIZE = 150 * 1024     # 超过 150KB 才压缩（小图直接原样返回）
_cover_small_lock = threading.Lock()  # 并发请求同一大图时只生成一次


def cover_small(fp, tid):
    """返回适合手机端加载的封面路径：大图压缩为 max_side JPEG 落盘缓存；失败/小图回退原图。

    采集歌曲封面多为数 MB 原图（见过 12MB），手机端直接加载要数秒；
    这里首次请求生成 600px/82 品质缩略图（约 20-60KB），之后命中缓存。
    Pillow 不可用时自动降级为原图，不影响功能。
    """
    try:
        from PIL import Image
    except Exception:
        return fp
    try:
        size = os.path.getsize(fp)
        if size <= COVER_SMALL_MIN_SIZE:
            return fp
        small = os.path.join(FILES, tid + "_cover_small.jpg")
        with _cover_small_lock:
            if os.path.exists(small) and os.path.getsize(small) > 0:
                if os.path.getmtime(small) + 2 >= os.path.getmtime(fp):
                    return small
            with Image.open(fp) as im:
                im = im.convert("RGB")
                w, h = im.size
                longest = max(w, h)
                if longest <= COVER_SMALL_MAX_SIDE:
                    return fp
                scale = COVER_SMALL_MAX_SIDE / float(longest)
                nw, nh = max(1, int(w * scale)), max(1, int(h * scale))
                resample = getattr(Image, "Resampling", Image).LANCZOS
                im = im.resize((nw, nh), resample)
                im.save(small, "JPEG", quality=COVER_SMALL_QUALITY,
                        optimize=True, progressive=True)
        if os.path.exists(small) and os.path.getsize(small) > 0:
            return small
    except Exception:
        pass
    return fp


# ---------------- 上传魔数校验 ----------------

def _head(data, n):
    return data[:n]


def audio_magic_ok(data, ext):
    """音频文件头校验（不支持只信扩展名）。ext 已小写。"""
    if ext == ".mp3":
        return _head(data, 3) == b"ID3" or (len(data) > 1 and data[0] == 0xFF and (data[1] & 0xE0) == 0xE0)
    if ext == ".flac":
        return _head(data, 4) == b"fLaC"
    if ext == ".wav":
        return _head(data, 4) == b"RIFF"
    if ext in (".m4a", ".mp4"):
        return len(data) >= 12 and _head(data, 4) == b"ftyp"
    if ext == ".ogg":
        return _head(data, 4) == b"OggS"
    if ext == ".aac":
        return len(data) > 1 and data[0] == 0xFF and (data[1] & 0xF0) == 0xF0
    return False


def image_magic_ok(data, ext):
    if ext in (".jpg", ".jpeg"):
        return _head(data, 3) == b"\xFF\xD8\xFF"
    if ext == ".png":
        return _head(data, 8) == b"\x89PNG\r\n\x1a\n"
    if ext == ".webp":
        return _head(data, 4) == b"RIFF" and _head(data, 8) == b"WEBP"
    if ext == ".heic":
        return len(data) >= 12 and _head(data, 4) == b"ftyp"
    return False


# ---------------- 音频时长解析（纯标准库 + mutagen 兜底） ----------------

def _dur_wav(path):
    try:
        with open(path, "rb") as f:
            hdr = f.read(12)
            if hdr[0:4] != b"RIFF" or hdr[8:12] != b"WAVE":
                return 0.0
            byte_rate = None
            data_size = 0
            while True:
                chunk = f.read(8)
                if len(chunk) < 8:
                    break
                cid, csize = chunk[0:4], struct.unpack("<I", chunk[4:8])[0]
                if cid == b"fmt ":
                    fmt = f.read(csize)
                    if len(fmt) >= 12:
                        byte_rate = struct.unpack("<I", fmt[8:12])[0]
                elif cid == b"data":
                    data_size = csize
                    f.seek(csize, 1)
                else:
                    f.seek(csize + (csize & 1), 1)
                if byte_rate and data_size:
                    break
        if byte_rate and byte_rate > 0 and data_size > 0:
            return round(data_size / byte_rate, 2)
    except Exception:
        pass
    return 0.0


def _dur_mp3(path):
    """简化 MP3 时长：跳过 ID3，统计有效帧平均比特率。"""
    try:
        with open(path, "rb") as f:
            data = f.read()
        off = 0
        if data[0:3] == b"ID3":
            sz = data[6:10]
            id3_size = (sz[0] << 21) | (sz[1] << 14) | (sz[2] << 7) | sz[3]
            off = 10 + id3_size
        bitrates = []
        i = off
        n = len(data)
        while i + 4 <= n:
            b = data[i:i+4]
            if b[0] == 0xFF and (b[1] & 0xE0) == 0xE0:
                ver = (b[1] >> 3) & 0x03
                layer = (b[1] >> 1) & 0x03
                br_idx = (b[2] >> 4) & 0x0F
                sr_idx = (b[2] >> 2) & 0x03
                if br_idx not in (0, 15) and sr_idx != 3 and layer != 0 and ver != 1:
                    tbl = None
                    if ver == 3:
                        if layer == 3:
                            tbl = [32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448]
                        elif layer == 2:
                            tbl = [32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384]
                        else:
                            tbl = [32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448]
                    else:
                        if layer == 3:
                            tbl = [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
                        else:
                            tbl = [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
                    kbps = tbl[br_idx - 1]
                    if ver != 3:
                        kbps //= 2
                    if layer == 3:
                        frame_len = (144000 * kbps) // (44100 if ver == 3 else 22050) + 1
                    else:
                        frame_len = (72000 * kbps) // (44100 if ver == 3 else 22050) + 1
                    if frame_len > 0:
                        bitrates.append((kbps, frame_len))
                        i += frame_len
                        continue
            i += 1
        if not bitrates:
            return 0.0
        avg_kbps = sum(k for k, _ in bitrates) / len(bitrates)
        dur = (n - off) * 8.0 / (avg_kbps * 1000.0)
        return round(dur, 2)
    except Exception:
        return 0.0


def audio_duration(path):
    ext = os.path.splitext(path)[1].lower()
    if ext == ".wav":
        return _dur_wav(path)
    if ext == ".mp3":
        return _dur_mp3(path)
    try:
        if ext in (".m4a", ".aac"):
            from mutagen.mp4 import MP4
            return MP4(path).info.length
        if ext == ".flac":
            from mutagen.flac import FLAC
            return FLAC(path).info.length
        if ext == ".ogg":
            from mutagen.oggvorbis import OggVorbis
            return OggVorbis(path).info.length
    except Exception:
        pass
    return 0.0


def _fmt_dur(d):
    if not d or d <= 0:
        return "--:--"
    m, s = int(d) // 60, int(d) % 60
    return f"{m}:{s:02d}"


def _track_info(c, tid):
    """歌曲信息快照 JSON（title/artist/album）：行为记录用，推荐时提取相似度关键词。
    优先用户上传表，其次采集表；查不到返回空字符串。"""
    if not tid:
        return ""
    try:
        row = c.execute("SELECT title,artist,album FROM tracks WHERE id=?", (tid,)).fetchone()
        if not row:
            row = c.execute("SELECT title,artist,album FROM collected_tracks WHERE id=?", (tid,)).fetchone()
        if not row:
            return ""
        return json.dumps({"title": row[0] or "", "artist": row[1] or "",
                           "album": row[2] or ""}, ensure_ascii=False)[:500]
    except Exception:
        return ""


def _track_owner(c, tid):
    """歌曲上传者 (user_id, title)：优先用户上传表，其次采集表；查不到返回 (None, None)。
    点赞/评论/分享通知与双表计数均依赖此函数，避免采集歌曲的 owner 收不到通知。"""
    if not tid:
        return None, None
    try:
        row = c.execute("SELECT user_id, title FROM tracks WHERE id=?", (tid,)).fetchone()
        if not row:
            row = c.execute("SELECT user_id, title FROM collected_tracks WHERE id=?", (tid,)).fetchone()
        if not row:
            return None, None
        return row[0], row[1]
    except Exception:
        return None, None


# ---------------- 个性化推荐（多路召回 + 加权融合 + MMR 重排） ----------------
# 相比旧版「单路行为关键词/genre 匹配 + 随机补齐」的升级：
#   1) 多路召回：行为相似 / 常听歌手 / 风格 / 全局热度 / 新歌新鲜度 / 随机探索
#   2) 加权融合：各路打分乘权重后叠加，再叠小随机扰动（保证探索）
#   3) MMR 重排：按「相关分 − 与已选歌的相似度」逐步选歌，并限制同歌手/同风格数量，
#      让最终 20 首既贴合口味又多样（主流音乐 App 推送形态）

REC_BUDGET = 20                # 最终推荐数量
REC_FRESH_DAYS = 14            # 新歌窗口：最近 N 天入库视为新歌
REC_MAX_PER_ARTIST = 3         # 重排后同一歌手最多保留几首
REC_MAX_PER_GENRE = 5          # 重排后同一风格最多保留几首
REC_MMR_LAMBDA = 0.7           # MMR 相关分权重（1−λ 为多样性权重）
REC_NOISE = 0.6                # 融合分随机扰动幅度（探索，避免结果完全固定；fresh 会话 ×3）
REC_TITLE_SIM_THRESHOLD = 0.8  # 歌名相似度阈值：与已选推荐歌名相似 ≥ 此值（如 80%）则跳过，
                               # 保证同一批推荐里不出现歌名高度相似的歌（90% 相似更不会同批推送）
REC_BUCKET_SECONDS = int(os.environ.get("MUSIC_REC_BUCKET", str(6 * 3600)))  # 时间桶：同桶主批稳定可复现，跨桶新主批
REC_SESSION_IDLE = int(os.environ.get("MUSIC_REC_IDLE", str(30 * 60)))        # 距上次请求超此时长视为新会话 → 批次归零
REC_EXPLORE_POOL = 120         # 探索路候选池大小（按批次种子洗牌截断，替代 SQL RANDOM()）
REC_LIMITS = {                 # 每路候选上限
    "behavior": 40, "artist": 30, "genre": 30,
    "hot": 20, "fresh": 10, "explore": 30,
}
REC_WEIGHTS = {                # 各路权重
    "behavior": 5.0, "artist": 4.0, "genre": 3.0,
    "hot": 1.2, "fresh": 2.0, "explore": 0.6,
}
REC_HOT_TOP = 60               # 热度路先取全局热度前 N 名再进入候选

# 推荐批次状态：key=f"{user_id}|{bucket}" → [last_ts, seq]
# 会话内连续获取批次序号递增（每次不同批）；距上次请求超 REC_SESSION_IDLE / 跨桶 / fresh → 归零回到主批
_rec_seq_lock = threading.Lock()
_rec_seq_state = {}


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
            seq = 0
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


def build_recommendations(c, viewer_id, exclude=None, fresh=False, rnd=None):
    """多路召回 → 加权融合 → MMR 重排，返回推荐 (歌曲id, 推荐理由) 列表（≤20，去重、排除本人上传与 exclude）。

    exclude: 已推荐过的歌曲 id 集合（推荐流无限续推时防重复推荐同一批）。
    fresh: 长时间重开 App 的「新鲜会话」标记——加大随机扰动并提高探索路权重，
           让重新开始的一批推荐明显不同于上次（不固定重复同一批）。
    rnd: 批次随机源（random.Random 实例，种子=用户|时间桶|批次序号）——
         同一时间桶内的主批稳定可复现，会话内连续获取轮换不同批；
         不传时回退全局 random（兼容直接调用场景）。
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
                plays = int(m.get("plays") or 0)
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
                for g in genre.split(","):
                    g = g.strip()
                    if g and g != "流行":
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
    for kw, sc in dedup[:8]:
        like = "%" + kw + "%"
        for rid, rtitle, rartist, ralbum, rgenre in _rows(
                "(title LIKE ? OR artist LIKE ? OR album LIKE ?)", [like, like, like],
                REC_LIMITS["behavior"]):
            if rid in avoid:
                continue
            _add(rid, sc * REC_WEIGHTS["behavior"], "behavior",
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


# ---------------- HTTP ----------------

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
        html = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#0b0b0d">
<title>流萤音乐</title>
""" + meta_og + """
<style>
*{margin:0;padding:0;box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{background:#0b0b0d;color:#f5f5f5;font-family:-apple-system,"PingFang SC","Helvetica Neue",sans-serif}
body{min-height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;
padding:28px calc(28px + env(safe-area-inset-left)) calc(40px + env(safe-area-inset-bottom)) calc(28px + env(safe-area-inset-right))}
.brand{font-size:12px;letter-spacing:2px;color:#6e6e73;margin-bottom:30px}
.brand b{color:#f5f5f5;font-weight:600}
.cover{width:min(70vw,300px);aspect-ratio:1/1;border-radius:16px;background:#17171a;overflow:hidden}
.cover img{width:100%;height:100%;object-fit:cover;display:block}
.title{margin-top:26px;font-size:20px;font-weight:700;text-align:center;max-width:82vw;
overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.artist{margin-top:9px;font-size:14px;color:#8e8e93;text-align:center;max-width:82vw;
overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.player{margin-top:34px;width:min(80vw,330px)}
.prow{display:flex;align-items:center;gap:10px}
.time{font-size:12px;color:#6e6e73;font-variant-numeric:tabular-nums;min-width:36px}
input[type=range]{flex:1;-webkit-appearance:none;appearance:none;height:4px;border-radius:2px;
background:linear-gradient(to right,#f5f5f5 var(--p,0%),#2c2c2e var(--p,0%));outline:none;touch-action:none}
input[type=range]::-webkit-slider-thumb{-webkit-appearance:none;width:14px;height:14px;border-radius:50%;
background:#f5f5f5;border:none}
.bwrap{display:flex;justify-content:center;margin-top:22px}
.playbtn{width:64px;height:64px;border-radius:50%;background:#f5f5f5;border:none;cursor:pointer;
display:flex;align-items:center;justify-content:center;transition:opacity .15s}
.playbtn:active{opacity:.7}
.playbtn svg{width:24px;height:24px;fill:#0b0b0d;display:block}
.err{display:none;margin-top:18px;font-size:13px;color:#ff453a;text-align:center;max-width:80vw}
</style>
</head>
<body>
<div class="brand">&#9835; <b>流萤音乐</b></div>
<div class="cover"><img id="cov" alt=""></div>
<div class="title" id="ttl"></div>
<div class="artist" id="art"></div>
<div class="player">
  <div class="prow">
    <span class="time" id="cur">0:00</span>
    <input type="range" id="seek" min="0" max="1000" value="0">
    <span class="time" id="dur">-:--</span>
  </div>
  <div class="bwrap">
    <button class="playbtn" id="pb" aria-label="播放">
      <svg id="pico" viewBox="0 0 24 24"><polygon points="7,4 20,12 7,20"/></svg>
    </button>
  </div>
  <div class="err" id="err"></div>
</div>
<script>
(function(){
  var TRACK_ID = __TID__;
  var COVER = __COVER__;
  var api = location.origin + location.pathname.split('/api/share/')[0] + '/api';
  var ttl = document.getElementById('ttl'), art = document.getElementById('art');
  var cov = document.getElementById('cov'), pb = document.getElementById('pb');
  var pico = document.getElementById('pico'), seek = document.getElementById('seek');
  var curEl = document.getElementById('cur'), durEl = document.getElementById('dur');
  var errEl = document.getElementById('err');
  var audio = new Audio(), playing = false, loaded = false;

  ttl.textContent = __TITLE__;
  art.textContent = __AUTHOR__;
  if (COVER) { cov.src = api + '/cover/' + TRACK_ID; }
  else { cov.remove(); }

  function fmt(s){ s = Math.max(0, Math.floor(s || 0)); var m = Math.floor(s/60); var ss = s%60;
    return m + ':' + (ss < 10 ? '0' : '') + ss; }
  function setIcon(play){ pico.innerHTML = play
    ? '<polygon points="7,4 20,12 7,20"/>'
    : '<rect x="6" y="4" width="4" height="16"/><rect x="14" y="4" width="4" height="16"/>';
    pb.setAttribute('aria-label', play ? '播放' : '暂停'); }
  function showErr(m){ errEl.textContent = m; errEl.style.display = 'block'; }
  function hideErr(){ errEl.style.display = 'none'; }
  function paint(){ var d = audio.duration || 0; var c = audio.currentTime || 0;
    var p = d > 0 ? (c/d*1000) : 0; seek.value = p;
    seek.style.setProperty('--p', (d > 0 ? c/d*100 : 0) + '%');
    curEl.textContent = fmt(c); durEl.textContent = d > 0 ? fmt(d) : '-:--'; }

  function loadStream(){
    return fetch(api + '/stream-url/' + TRACK_ID)
      .then(function(r){ if(!r.ok){ throw new Error('bad'); } return r.json(); })
      .then(function(j){ audio.src = api + '/stream/' + TRACK_ID + '?exp=' + j.exp + '&sig=' + j.sig; loaded = true; })
      .catch(function(){ showErr('加载失败，请稍后重试'); throw new Error('load'); });
  }

  pb.addEventListener('click', function(){
    if (playing) { audio.pause(); setIcon(true); playing = false; return; }
    hideErr();
    var start = loaded ? Promise.resolve() : loadStream();
    start.then(function(){ return audio.play(); })
      .then(function(){ playing = true; setIcon(false); })
      .catch(function(e){ if (e && e.message !== 'load') { showErr('无法播放，请检查网络后重试'); setIcon(true); playing = false; } });
  });

  audio.addEventListener('timeupdate', paint);
  audio.addEventListener('durationchange', paint);
  audio.addEventListener('loadedmetadata', paint);
  audio.addEventListener('ended', function(){ setIcon(true); playing = false; paint(); });
  audio.addEventListener('error', function(){ setIcon(true); playing = false; showErr('播放出错，请重试'); });

  var dragging = false;
  seek.addEventListener('input', function(){
    dragging = true;
    var d = audio.duration || 0;
    var p = Number(seek.value);
    seek.style.setProperty('--p', (d > 0 ? p/10 : 0) + '%');
    curEl.textContent = d > 0 ? fmt(p/1000*d) : fmt(0);
  });
  seek.addEventListener('change', function(){
    var d = audio.duration || 0;
    if (d > 0) { audio.currentTime = Number(seek.value)/1000*d; }
    dragging = false; paint();
  });
  audio.addEventListener('play', function(){ playing = true; setIcon(false); });
  audio.addEventListener('pause', function(){ if (dragging) return; playing = false; setIcon(true); });
})();

async function loadNotify(){
  const d=await api('/official-messages?admin=1');
  let h='<div class="topbar"><h1>官方通知管理</h1><button onclick="showNotifyModal()">+ 发布新通知</button></div>';
  h+='<div class="tablewrap"><table><tr><th>内容</th><th>发送时间</th><th>操作</th></tr>';
  if(!d.list||!d.list.length)h+='<tr><td colspan="3" class="empty">暂无官方通知</td></tr>';
  if(d.list)d.list.forEach(m=>{
    const t=new Date(m.created*1000);
    const ts=t.getFullYear()+'-'+String(t.getMonth()+1).padStart(2,'0')+'-'+String(t.getDate()).padStart(2,'0')+' '+String(t.getHours()).padStart(2,'0')+':'+String(t.getMinutes()).padStart(2,'0');
    h+='<tr><td style="max-width:400px;white-space:normal">'+esc(m.content)+'</td><td style="font-size:12px;color:#888">'+ts+'</td><td class="act"><button onclick="delNotify(\\''+m.id+'\\')">删除</button></td></tr>';
  });
  h+='</table></div>';
  h+='<div class="modal hidden" id="notifyModal"><div class="modal-box" style="max-width:500px;width:100%"><h3 style="margin-bottom:16px">发布官方通知</h3><textarea id="notifyContent" placeholder="输入通知内容..." style="width:100%;height:120px;padding:12px;border-radius:10px;border:1px solid #2a2a2e;background:#111;color:#fff;font-size:14px;box-sizing:border-box;resize:vertical"></textarea><div style="display:flex;gap:10px;margin-top:16px;justify-content:flex-end"><button onclick="hideNotifyModal()" style="padding:9px 18px;border:0;border-radius:8px;background:#2a2a2e;color:#aaa;cursor:pointer">取消</button><button onclick="publishNotify()" style="padding:9px 18px;border:0;border-radius:8px;background:#2a6df4;color:#fff;cursor:pointer">发布</button></div></div></div>';
  document.getElementById('content').innerHTML=h;
}
function showNotifyModal(){document.getElementById('notifyModal').classList.remove('hidden')}
function hideNotifyModal(){document.getElementById('notifyModal').classList.add('hidden')}
async function publishNotify(){
  const content=document.getElementById('notifyContent').value.trim();
  if(!content){alert('请输入通知内容');return}
  const r=await api('/official-message',{method:'POST',body:JSON.stringify({content:content})});
  if(r.ok){hideNotifyModal();loadNotify();}else{alert(r.err||'发布失败')}
}
async function delNotify(id){
  if(!confirm('确定删除这条通知？'))return;
  const r=await api('/official-message/'+id,{method:'DELETE'});
  if(r.ok)loadNotify();else alert(r.err||'删除失败')
}

</script>
</body>
</html>"""
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
                html = """<!doctype html>
<html lang="zh-CN"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>流萤音乐 · 采集控制台</title>
<style>
*{margin:0;padding:0;box-sizing:border-box;-webkit-tap-highlight-color:transparent}
body{background:#0f0f10;color:#eee;font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;min-height:100vh;padding:env(safe-area-inset-top) 0 env(safe-area-inset-bottom)}
.wrap{max-width:640px;margin:0 auto;padding:24px 18px}
h1{font-size:20px;font-weight:600;margin-bottom:4px}
.sub{color:#888;font-size:13px;margin-bottom:20px}
.btn{display:block;width:100%;padding:15px;border-radius:14px;border:0;font-size:16px;font-weight:600;cursor:pointer}
.btn:active{opacity:.8}
.btn.start{background:#2a2a2e;color:#fff}
.btn.stop{background:#c0392b;color:#fff}
.row2{display:flex;gap:10px;margin-bottom:12px}
.tgtrow{flex:1;display:flex;align-items:center;gap:10px;background:#1a1a1c;border-radius:14px;padding:10px 14px}
.tgtrow input{flex:1;min-width:0;background:#111;border:1px solid #2a2a2e;color:#fff;border-radius:10px;padding:10px;font-size:15px;outline:none}
.tgtrow input:disabled{opacity:.4}
.tgtlbl{font-size:12px;color:#888;flex-shrink:0}
.sec{margin:18px 0 8px;font-size:13px;color:#888}
.sec b{color:#eee}
.chips{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:6px}
.chip{background:#1a1a1c;color:#aaa;border:1px solid #2a2a2e;padding:8px 13px;border-radius:20px;font-size:13px;cursor:pointer;user-select:none}
.chip.on{background:#1e3a2a;color:#5cd68a;border-color:#2d5a3e}
.chip:disabled{opacity:.35;cursor:not-allowed}
.searchbox{display:flex;gap:8px;background:#1a1a1c;border-radius:14px;padding:8px;margin:10px 0 12px}
.searchbox input{flex:1;background:#111;border:1px solid #2a2a2e;color:#fff;border-radius:10px;padding:11px 12px;font-size:15px;outline:none;min-width:0}
.searchbox button{background:#2a6df4;color:#fff;border:0;border-radius:10px;padding:0 18px;font-size:14px;font-weight:600;cursor:pointer}
.runbox{background:#1a1a1c;border-radius:14px;padding:18px 16px;margin:16px 0;text-align:center}
.runbox .num{font-size:42px;font-weight:800;color:#5cd68a;line-height:1.1}
.runbox .lbl{font-size:13px;color:#888;margin-top:6px}
.runbox .st{font-size:11px;color:#555;margin-top:6px}
.list{background:#1a1a1c;border-radius:14px;overflow:hidden}
.row{padding:11px 14px;border-bottom:1px solid #262629;font-size:13px;display:flex;align-items:center;gap:8px}
.row:last-child{border-bottom:0}
.row .t{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.row .a{color:#777;font-size:11px;flex-shrink:0;max-width:90px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.row .dur{color:#555;font-size:11px;flex-shrink:0}
.row .collectbtn{background:#1e3a2a;color:#5cd68a;border:0;padding:6px 12px;border-radius:8px;font-size:12px;cursor:pointer;flex-shrink:0}
.row .collectbtn:disabled{opacity:.5}
.empty{padding:24px;text-align:center;color:#555;font-size:13px}
.tag{display:inline-block;background:#2a2a2e;color:#aaa;font-size:10px;padding:2px 7px;border-radius:5px;margin-left:6px}
.tag.on{background:#1e4d2b;color:#5cd68a}
.tag.no{background:#3a2a2a;color:#c9866e}
.tag.wy{background:#1e3a5f;color:#6fb1ff}
.tag.kw{background:#3a2a1e;color:#ffb36b}
.tag.kg{background:#3a1e3a;color:#d68fd6}
.tag.tx{background:#1e3a3a;color:#6fd6c8}
.custom-kw{display:flex;gap:8px;margin-top:8px}
.custom-kw input{flex:1;background:#111;border:1px solid #2a2a2e;color:#fff;border-radius:10px;padding:10px 12px;font-size:14px;outline:none;min-width:0}
.custom-kw button{background:#2a6df4;color:#fff;border:0;border-radius:10px;padding:0 16px;font-size:13px;font-weight:600;cursor:pointer;flex-shrink:0}
</style></head><body><div class="wrap">
<h1>流萤音乐 · 采集控制台</h1>
<div class="sub">选择平台与方式，自动入库；也可搜歌名单点采集</div>

<div class="row2">
  <div class="tgtrow"><input id="tgt" type="number" min="1" inputmode="numeric" placeholder="目标数量"><span class="tgtlbl">目标</span></div>
</div>

<div class="sec"><b>采集平台</b>（多选；默认勾选的可直接采集，G 后缀=聚合源，抖音BGM=抖音官方音乐榜热门配乐，网易云热歌/QQ热歌=全网热歌榜）</div>
<div class="chips" id="platChips">
  <div class="chip on" data-v="dy">抖音BGM</div>
  <div class="chip on" data-v="wy_hot">网易云热歌</div>
  <div class="chip on" data-v="qq_hot">QQ热歌</div>
  <div class="chip on" data-v="gd">网易云G</div>
  <div class="chip on" data-v="soda">汽水Soda</div>
  <div class="chip" data-v="gm_migu">咪咕G*</div>
  <div class="chip" data-v="gm_kugou">酷狗G*</div>
  <div class="chip" data-v="gm_kuwo">酷我G*</div>
  <div class="chip" data-v="gm_qq">QQG*</div>
  <div class="chip" data-v="qs">汽水登录版</div>
  <div class="chip" data-v="kw">酷我</div>
  <div class="chip" data-v="wy">网易云</div>
  <div class="chip" data-v="kg">酷狗</div>
  <div class="chip" data-v="tx">腾讯</div>
</div>
<div style="color:#666;font-size:11px;margin:4px 0 0 2px">* 标星 G 源搜索可用、取流需在 music-dl 设置页扫码登录对应平台 Cookie 后解锁</div>

<div class="sec"><b>采集方式</b></div>
<div class="chips" id="modeChips">
  <div class="chip on" data-v="search">关键词搜索</div>
  <div class="chip" data-v="hot">热门榜单</div>
</div>

<div class="sec" id="kwSec"><b>关键词</b>（多选，可自定义添加）</div>
<div class="chips" id="kwChips"></div>
<div class="custom-kw">
  <input id="customKwInput" placeholder="输入自定义关键词，回车添加" />
  <button id="addKwBtn">添加</button>
</div>

<button id="btn" class="btn start">开始采集</button>

<div class="runbox">
  <div class="num" id="runCount">0</div>
  <div class="lbl" id="runLbl">已完成 / 未设置目标</div>
  <div class="st" id="runState">尚未开始</div>
</div>

<div class="sec"><b>汽水音乐</b> <span id="qsState" class="tag no">未登录</span> <button id="qsBtn" style="margin-left:8px;padding:3px 10px;border:0;border-radius:6px;background:#1e3a2a;color:#5cd68a;cursor:pointer">扫码登录</button><span style="color:#555;font-size:11px;margin-left:8px">「汽水Soda」免登录即可搜索采集；登录版用于个人歌单/高音质</span></div>

<div class="sec"><b>搜索歌名，点采集入库</b></div>
<div class="searchbox">
  <input id="kwInput" placeholder="输入歌名 / 歌手" />
  <button id="searchBtn">搜索</button>
</div>
<div class="list" id="searchList"><div class="empty">输入歌名搜索，再点右侧「采集」</div></div>

<div class="sec"><b>本次采集歌曲</b> <span id="runNum" style="color:#555;font-weight:400"></span></div>
<div class="list" id="list"><div class="empty">点击开始采集或搜索歌名</div></div>
<div class="sec">库内共 <b id="total">0</b> 首 <span id="runstate" class="tag">空闲</span></div>
</div>
<script>
const KW_LIST=["抖音热歌","华语流行","热门新歌","2024流行","2025流行","2023热门","华语金曲","伤感流行","民谣","抖音神曲","网络热歌","粤语经典"];
const btn=document.getElementById('btn');
const list=document.getElementById('list');
const total=document.getElementById('total');
const runstate=document.getElementById('runstate');
const runCount=document.getElementById('runCount');
const runState=document.getElementById('runState');
const runNum=document.getElementById('runNum');
const runLbl=document.getElementById('runLbl');
const tgtInp=document.getElementById('tgt');
const platChips=document.getElementById('platChips');
const modeChips=document.getElementById('modeChips');
const kwChips=document.getElementById('kwChips');
const kwSec=document.getElementById('kwSec');
const kwInput=document.getElementById('kwInput');
const searchBtn=document.getElementById('searchBtn');
const searchList=document.getElementById('searchList');
const qsState=document.getElementById('qsState');
const qsBtn=document.getElementById('qsBtn');
let running=false, mode='search';

// 初始化关键词 chips（预设 + 从 localStorage 恢复的自定义）
const STORAGE_KEY='custom_keywords';
// 读取已保存的自定义关键词
let savedKws=[];
try{savedKws=JSON.parse(localStorage.getItem(STORAGE_KEY)||'[]');}catch(e){savedKws=[];}
// 预设关键词
KW_LIST.forEach(k=>{
  const d=document.createElement('div');
  d.className='chip on';d.textContent=k;d.dataset.v=k;
  kwChips.appendChild(d);
});
// 恢复自定义关键词
savedKws.forEach(k=>{
  const d=document.createElement('div');
  d.className='chip on';d.textContent=k;d.dataset.v=k;
  kwChips.appendChild(d);
});

// 自定义关键词添加
const customKwInput=document.getElementById('customKwInput');
const addKwBtn=document.getElementById('addKwBtn');
function addCustomKw(){
  const v=customKwInput.value.trim();
  if(!v)return;
  // 避免重复
  const exists=[...kwChips.querySelectorAll('.chip')].some(x=>x.dataset.v===v);
  if(exists){customKwInput.value='';return;}
  const d=document.createElement('div');
  d.className='chip on';d.textContent=v;d.dataset.v=v;
  kwChips.appendChild(d);
  // 绑定点击切换
  d.onclick=()=>{d.classList.toggle('on');saveKws();};
  customKwInput.value='';
  saveKws();
}
// 保存自定义关键词到 localStorage
function saveKws(){
  const all=[...kwChips.querySelectorAll('.chip')].map(x=>x.dataset.v);
  // 只保存不在预设列表里的自定义关键词
  const custom=all.filter(k=>!KW_LIST.includes(k));
  localStorage.setItem(STORAGE_KEY,JSON.stringify(custom));
}
addKwBtn.onclick=addCustomKw;
customKwInput.addEventListener('keydown',e=>{if(e.key==='Enter'){e.preventDefault();addCustomKw();}});
function sel(container,cb){
  container.querySelectorAll('.chip').forEach(c=>c.onclick=()=>{
    if(container===modeChips){
      container.querySelectorAll('.chip').forEach(x=>x.classList.remove('on'));
      c.classList.add('on');mode=c.dataset.v;
      kwSec.style.opacity=(mode==='search')?1:.3;
      kwChips.querySelectorAll('.chip').forEach(x=>x.disabled=(mode!=='search'));
    }else{
      c.classList.toggle('on');
      saveKws(); // 选中状态变化也保存
    }
    if(cb)cb();
  });
}
sel(platChips);sel(kwChips);sel(modeChips);
kwChips.querySelectorAll('.chip').forEach(x=>x.disabled=false);

function getPlats(){return [...platChips.querySelectorAll('.chip.on')].map(x=>x.dataset.v)}
function getKws(){return [...kwChips.querySelectorAll('.chip.on')].map(x=>x.dataset.v)}
function pad(n){return String(n).padStart(2,'0')}
function fmt(t){if(!t)return '';const d=new Date(t*1000);return pad(d.getMonth()+1)+'-'+pad(d.getDate())+' '+pad(d.getHours())+':'+pad(d.getMinutes())}
function esc(s){return String(s||'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}

async function load(){
  try{
    const r=await fetch('/music/api/collect/status');
    const d=await r.json();
    running=!!d.running;
    total.textContent=d.total||0;
    btn.className='btn '+(running?'stop':'start');
    btn.textContent=running?'停止采集':'开始采集';
    runstate.textContent=running?'采集中':'空闲';
    runstate.className='tag'+(running?' on':'');
    const songs=d.run_songs||[];
    const n=songs.length;
    const tgt=d.target||0, done=d.completed||0, rem=d.remaining||0, ach=!!d.achieved;
    const ar=songs.filter(x=>x.audio).length;
    runCount.textContent=tgt?done:0;
    runCount.style.color=ach?'#e8c46a':'#5cd68a';
    runLbl.textContent=tgt?('已完成 / 目标 '+tgt+' 首'):'已完成（未设置目标）';
    runNum.textContent=n?('本次 '+n+' 首 · 音频就绪 '+ar+'/'+n):'';
    tgtInp.disabled=running;
    platChips.querySelectorAll('.chip').forEach(c=>c.disabled=running);
    modeChips.querySelectorAll('.chip').forEach(c=>c.disabled=running);
    kwChips.querySelectorAll('.chip').forEach(c=>c.disabled=running||mode!=='search');
    let st;
    if(tgt){
      st=(ach?'目标已完成，可重新设置后开始新一轮':('目标 '+tgt+' · 已完成 '+done+'/'+tgt+' · 剩余 '+rem));
      if(running)st='采集中 · '+st;
      else if(n)st=(d.started?('上次运行 '+fmt(d.started)+' · '):'')+st;
    }else{
      st=running?'采集中…':(d.started?('上次运行 '+n+' 首，始于 '+fmt(d.started)):'尚未开始');
    }
    if(d.run_skipped)st+=' · 跳过 '+d.run_skipped;
    runState.textContent=st;
    if(n){
      list.innerHTML=songs.map((s,i)=>'<div class="row"><span class="t">'+esc(s.title)+'</span><span class="a">'+esc(s.artist||'')+'</span><span class="tag'+(s.audio?' on':' no')+'">'+(s.audio?'已下':'待补')+'</span></div>').join('');
    }else{
      list.innerHTML='<div class="empty">'+(running?'采集中，等待首批…':'点击开始采集或搜索歌名')+'</div>';
    }
  }catch(e){}
}

btn.onclick=async()=>{
  btn.disabled=true;
  try{
    const v=tgtInp.value.trim();
    const body=new URLSearchParams();
    if(v&&!running)body.set('target',v);
    body.set('platforms',getPlats().join(','));
    body.set('mode',mode);
    body.set('keywords',getKws().join(','));
    await fetch('/music/api/collect/'+(running?'stop':'start'),{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:body.toString()});
  }catch(e){alert('请求失败：'+e)}
  setTimeout(()=>{btn.disabled=false;load()},800);
};

// 搜索
searchBtn.onclick=async()=>{
  const kw=kwInput.value.trim();
  if(!kw){alert('请输入歌名');return}
  searchBtn.disabled=true;searchBtn.textContent='搜索中…';
  searchList.innerHTML='<div class="empty">搜索中…</div>';
  try{
    const plats=getPlats().length?getPlats():['wy'];
    const all=[];
    for(const p of plats){
      try{
        const r=await fetch('/music/api/collect/search?source='+p+'&kw='+encodeURIComponent(kw)+'&page=1&limit=15');
        const d=await r.json();
        if(d.ok&&d.list)d.list.forEach(s=>all.push(Object.assign({_p:p},s)));
      }catch(e){}
    }
    if(!all.length){searchList.innerHTML='<div class="empty">未找到结果</div>';return}
    searchList.innerHTML=all.map((s,i)=>{
      const p=s.source||s._p;
      return '<div class="row"><span class="tag '+p+'">'+p+'</span><span class="t">'+esc(s.name)+'</span><span class="a">'+esc(s.singer||'')+'</span><span class="dur">'+esc(s.interval||'')+'</span><button class="collectbtn" data-i="'+i+'">采集</button></div>';
    }).join('');
    searchList.querySelectorAll('.collectbtn').forEach(b=>b.onclick=async()=>{
      const s=all[+b.dataset.i];
      b.disabled=true;b.textContent='采集中…';
      try{
        const r=await fetch('/music/api/collect/one',{method:'POST',headers:{'Content-Type':'application/json'},
          body:JSON.stringify({source:s.source||s._p,songmid:s.songmid,name:s.name,singer:s.singer||'',album:s.albumName||'',interval:s.interval||'',img:s.img||''})});
        const d=await r.json();
        if(d.ok){b.textContent='已入库';b.style.background='#2a6df4';}
        else{alert(d.err||'采集失败');b.disabled=false;b.textContent='重试';}
      }catch(e){alert('失败:'+e);b.disabled=false;b.textContent='重试';}
      load();
    });
  }catch(e){searchList.innerHTML='<div class="empty">搜索失败</div>'}
  searchBtn.disabled=false;searchBtn.textContent='搜索';
};
kwInput.addEventListener('keydown',e=>{if(e.key==='Enter')searchBtn.click()});
load();setInterval(load,1500);

// 汽水音乐：登录状态 / 扫码登录
async function refreshQs(){
  try{
    const r=await fetch('/music/api/collect/qs-status');
    const d=await r.json();
    qsState.textContent=d.authed?'已登录':'未登录';
    qsState.className='tag'+(d.authed?' on':' no');
    qsBtn.style.display=d.authed?'none':'';
  }catch(e){}
}
qsBtn.onclick=async()=>{
  qsBtn.disabled=true;
  try{
    const r=await fetch('/music/api/collect/qs-qr');
    const d=await r.json();
    if(!d.ok){alert(d.err||'二维码生成失败');qsBtn.disabled=false;return}
    const box=document.createElement('div');
    box.style.cssText='position:fixed;inset:0;background:rgba(0,0,0,.75);display:flex;align-items:center;justify-content:center;z-index:99';
    const card=document.createElement('div');
    card.style.cssText='background:#1a1a1e;padding:24px;border-radius:14px;text-align:center;color:#fff;max-width:320px';
    card.innerHTML='<h3 style="margin:0 0 8px">汽水音乐扫码登录</h3><p style="color:#aaa;font-size:12px;margin:0 0 14px">打开「抖音」或「汽水音乐」App 扫码<br/>登录后服务器才能解析完整音频</p>';
    const img=document.createElement('img');
    img.src=d.qrcode;img.style.width='220px';img.style.height='220px';img.style.borderRadius='8px';
    card.appendChild(img);
    const tip=document.createElement('p');tip.id='qsTip';tip.style.cssText='color:#5cd68a;font-size:12px;margin:12px 0 0';
    tip.textContent='等待扫码…';card.appendChild(tip);
    const closeBtn=document.createElement('button');
    closeBtn.textContent='关闭';
    closeBtn.style.cssText='margin-top:12px;padding:8px 20px;border:0;border-radius:8px;background:#2a2a2e;color:#aaa;cursor:pointer';
    closeBtn.onclick=()=>document.body.removeChild(box);
    // —— 手机号登录表单（扫码被限备用）——
    const sep=document.createElement('div');
    sep.style.cssText='margin:14px 0 10px;color:#555;font-size:11px';
    sep.textContent='— 扫码失败？用手机号登录 —';card.appendChild(sep);
    const mobileInp=document.createElement('input');
    mobileInp.placeholder='手机号';mobileInp.type='tel';mobileInp.maxLength=11;
    mobileInp.style.cssText='width:100%;padding:10px 12px;margin-bottom:8px;border-radius:8px;border:1px solid #333;background:#0f0f12;color:#fff;font-size:14px';
    card.appendChild(mobileInp);
    const smsRow=document.createElement('div');smsRow.style.cssText='display:flex;gap:8px';
    const codeInp=document.createElement('input');
    codeInp.placeholder='短信验证码';codeInp.type='tel';codeInp.maxLength=6;
    codeInp.style.cssText='flex:1;padding:10px 12px;border-radius:8px;border:1px solid #333;background:#0f0f12;color:#fff;font-size:14px';
    const sendBtn=document.createElement('button');
    sendBtn.textContent='发送验证码';
    sendBtn.style.cssText='padding:10px 14px;border:0;border-radius:8px;background:#1e3a2a;color:#5cd68a;font-size:13px;cursor:pointer';
    smsRow.appendChild(codeInp);smsRow.appendChild(sendBtn);card.appendChild(smsRow);
    const loginBtn=document.createElement('button');
    loginBtn.textContent='手机号登录';
    loginBtn.style.cssText='width:100%;margin-top:8px;padding:10px;border:0;border-radius:8px;background:#5cd68a;color:#06210f;font-size:14px;font-weight:600;cursor:pointer';
    card.appendChild(loginBtn);
    sendBtn.onclick=async()=>{
      const m=mobileInp.value.trim();
      if(!/^1\d{10}$/.test(m)){tip.textContent='请输入正确的 11 位手机号';return}
      sendBtn.disabled=true;sendBtn.textContent='发送中…';
      try{
        const r=await fetch('/music/api/collect/qs-sms-send?mobile='+encodeURIComponent(m));
        const d=await r.json();
        tip.textContent=d.message||(d.ok?'验证码已发送':'发送失败');
        if(d.ok){let s=60;sendBtn.textContent=s+'s';const t=setInterval(()=>{s--;if(s<=0){clearInterval(t);sendBtn.disabled=false;sendBtn.textContent='重新发送'}else sendBtn.textContent=s+'s'},1000)}
        else{sendBtn.disabled=false;sendBtn.textContent='重发'}
      }catch(e){tip.textContent='请求失败';sendBtn.disabled=false;sendBtn.textContent='发送验证码'}
    };
    loginBtn.onclick=async()=>{
      const m=mobileInp.value.trim();const c=codeInp.value.trim();
      if(!/^1\d{10}$/.test(m)){tip.textContent='请输入正确的 11 位手机号';return}
      if(!/^\d{4,6}$/.test(c)){tip.textContent='请输入短信验证码';return}
      loginBtn.disabled=true;loginBtn.textContent='登录中…';
      try{
        const r=await fetch('/music/api/collect/qs-sms-login?mobile='+encodeURIComponent(m)+'&code='+encodeURIComponent(c));
        const d=await r.json();
        tip.textContent=d.message||(d.ok?'登录成功':'登录失败');
        if(d.ok){clearInterval(iv);refreshQs();setTimeout(()=>document.body.removeChild(box),1000)}
        else{loginBtn.disabled=false;loginBtn.textContent='手机号登录'}
      }catch(e){tip.textContent='请求失败';loginBtn.disabled=false;loginBtn.textContent='手机号登录'}
    };
    // —— Cookie 导入（服务器IP过不了风控时的最终通道）——
    const sep2=document.createElement('div');
    sep2.style.cssText='margin:14px 0 10px;color:#555;font-size:11px';
    sep2.textContent='— 以上都失败？粘贴 Cookie 登录 —';card.appendChild(sep2);
    const guide=document.createElement('p');
    guide.style.cssText='color:#777;font-size:11px;line-height:1.6;margin:0 0 8px;text-align:left';
    guide.textContent='电脑 Chrome 打开 qishui.com 登录抖音账号 → F12 → Network → 刷新页面点任意请求 → 请求头里 Cookie 整段复制，粘贴到下方：';
    card.appendChild(guide);
    const ckInp=document.createElement('textarea');
    ckInp.placeholder='粘贴 Cookie 整段（含 sessionid 等）';
    ckInp.style.cssText='width:100%;height:64px;padding:10px 12px;border-radius:8px;border:1px solid #333;background:#0f0f12;color:#fff;font-size:12px;resize:vertical';
    card.appendChild(ckInp);
    const ckBtn=document.createElement('button');
    ckBtn.textContent='导入 Cookie 登录';
    ckBtn.style.cssText='width:100%;margin-top:8px;padding:10px;border:0;border-radius:8px;background:#2a6df4;color:#fff;font-size:14px;font-weight:600;cursor:pointer';
    card.appendChild(ckBtn);
    ckBtn.onclick=async()=>{
      const ck=ckInp.value.trim();
      if(ck.length<20){tip.textContent='Cookie 内容太短，请完整复制';return}
      ckBtn.disabled=true;ckBtn.textContent='导入中…';
      try{
        const r=await fetch('/music/api/collect/qs-cookie-import?cookie='+encodeURIComponent(ck));
        const d=await r.json();
        tip.textContent=d.message||(d.ok?'登录成功':'登录失败');
        if(d.ok){clearInterval(iv);refreshQs();setTimeout(()=>document.body.removeChild(box),1200)}
        else{ckBtn.disabled=false;ckBtn.textContent='导入 Cookie 登录'}
      }catch(e){tip.textContent='请求失败';ckBtn.disabled=false;ckBtn.textContent='导入 Cookie 登录'}
    };
    card.appendChild(closeBtn);box.appendChild(card);document.body.appendChild(box);
    const iv=setInterval(async()=>{
      try{
        const r2=await fetch('/music/api/collect/qs-poll?token='+encodeURIComponent(d.token));
        const d2=await r2.json();
        if(d2.ok&&d2.authed){
          clearInterval(iv);tip.textContent='登录成功！';
          refreshQs();setTimeout(()=>document.body.removeChild(box),900);
        }else if(d2.status==='expired'){
          clearInterval(iv);tip.textContent=d2.message||'二维码已过期，请关闭后重新点扫码登录';
        }else if(d2.status==='failed'){
          clearInterval(iv);tip.textContent=d2.message||'登录失败，请关闭后重新扫码';
        }else if(d2.status==='scanned'){
          tip.textContent=d2.message||'已扫码，请在手机上确认登录';
        }else{
          tip.textContent='等待扫码…';
        }
      }catch(e){}
    },2500);
    setTimeout(()=>clearInterval(iv),120000);
  }catch(e){alert('请求失败：'+e)}
  qsBtn.disabled=false;
};
refreshQs();setInterval(refreshQs,15000);

async function loadNotify(){
  const d=await api('/official-messages?admin=1');
  let h='<div class="topbar"><h1>官方通知管理</h1><button onclick="showNotifyModal()">+ 发布新通知</button></div>';
  h+='<div class="tablewrap"><table><tr><th>内容</th><th>发送时间</th><th>操作</th></tr>';
  if(!d.list||!d.list.length)h+='<tr><td colspan="3" class="empty">暂无官方通知</td></tr>';
  if(d.list)d.list.forEach(m=>{
    const t=new Date(m.created*1000);
    const ts=t.getFullYear()+'-'+String(t.getMonth()+1).padStart(2,'0')+'-'+String(t.getDate()).padStart(2,'0')+' '+String(t.getHours()).padStart(2,'0')+':'+String(t.getMinutes()).padStart(2,'0');
    h+='<tr><td style="max-width:400px;white-space:normal">'+esc(m.content)+'</td><td style="font-size:12px;color:#888">'+ts+'</td><td class="act"><button onclick="delNotify(\\''+m.id+'\\')">删除</button></td></tr>';
  });
  h+='</table></div>';
  h+='<div class="modal hidden" id="notifyModal"><div class="modal-box" style="max-width:500px;width:100%"><h3 style="margin-bottom:16px">发布官方通知</h3><textarea id="notifyContent" placeholder="输入通知内容..." style="width:100%;height:120px;padding:12px;border-radius:10px;border:1px solid #2a2a2e;background:#111;color:#fff;font-size:14px;box-sizing:border-box;resize:vertical"></textarea><div style="display:flex;gap:10px;margin-top:16px;justify-content:flex-end"><button onclick="hideNotifyModal()" style="padding:9px 18px;border:0;border-radius:8px;background:#2a2a2e;color:#aaa;cursor:pointer">取消</button><button onclick="publishNotify()" style="padding:9px 18px;border:0;border-radius:8px;background:#2a6df4;color:#fff;cursor:pointer">发布</button></div></div></div>';
  document.getElementById('content').innerHTML=h;
}
function showNotifyModal(){document.getElementById('notifyModal').classList.remove('hidden')}
function hideNotifyModal(){document.getElementById('notifyModal').classList.add('hidden')}
async function publishNotify(){
  const content=document.getElementById('notifyContent').value.trim();
  if(!content){alert('请输入通知内容');return}
  const r=await api('/official-message',{method:'POST',body:JSON.stringify({content:content})});
  if(r.ok){hideNotifyModal();loadNotify();}else{alert(r.err||'发布失败')}
}
async function delNotify(id){
  if(!confirm('确定删除这条通知？'))return;
  const r=await api('/official-message/'+id,{method:'DELETE'});
  if(r.ok)loadNotify();else alert(r.err||'删除失败')
}

</script></body></html>
"""
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
                share_html = """<!doctype html>
<html lang="zh-CN"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>流萤音乐 · 汽水链接入库</title>
<style>
*{margin:0;padding:0;box-sizing:border-box;-webkit-tap-highlight-color:transparent}
body{background:#0f0f10;color:#eee;font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;min-height:100vh;padding:env(safe-area-inset-top) 0 env(safe-area-inset-bottom)}
.wrap{max-width:640px;margin:0 auto;padding:24px 18px}
h1{font-size:20px;font-weight:600;margin-bottom:4px}
.sub{color:#888;font-size:13px;margin-bottom:20px}
.box{background:#1a1a1c;border-radius:14px;padding:16px;margin-bottom:14px}
.inprow{display:flex;gap:8px}
.inprow input{flex:1;min-width:0;background:#111;border:1px solid #2a2a2e;color:#fff;border-radius:10px;padding:12px;font-size:14px;outline:none}
.btn{display:block;width:100%;padding:14px;border-radius:12px;border:0;font-size:15px;font-weight:600;cursor:pointer}
.btn:active{opacity:.8}
.btn.pri{background:#2a6df4;color:#fff}
.btn.sec{background:#2a2a2e;color:#fff}
.btn.green{background:#1e3a2a;color:#5cd68a}
.btn:disabled{opacity:.45;cursor:not-allowed}
.card{display:flex;gap:14px}
.card img{width:112px;height:112px;border-radius:12px;object-fit:cover;background:#222;flex-shrink:0}
.card .meta{flex:1;min-width:0}
.card .t{font-size:17px;font-weight:600;line-height:1.35;margin-bottom:4px}
.card .a{color:#aaa;font-size:13px;margin-bottom:6px}
.kv{display:flex;flex-wrap:wrap;gap:6px 14px;color:#888;font-size:12px;margin-top:8px}
.kv b{color:#ddd;font-weight:500}
.tag{display:inline-block;background:#1e3a5f;color:#6fb1ff;font-size:11px;padding:2px 9px;border-radius:12px;margin-top:6px}
.lrc{background:#111;border:1px solid #2a2a2e;border-radius:10px;padding:12px;max-height:260px;overflow:auto;font-size:13px;line-height:1.8;color:#bbb;white-space:pre-wrap;font-family:inherit}
.sec{font-size:13px;color:#888;margin:14px 0 8px}
.owner{display:flex;align-items:center;gap:8px;background:#111;border:1px solid #2a2a2e;border-radius:10px;padding:10px 12px;font-size:13px;color:#aaa}
.owner b{color:#5cd68a}
.note{color:#777;font-size:12px;margin-top:10px;line-height:1.6}
.ok{color:#5cd68a;font-size:13px;margin-top:10px}
.err{color:#e06c5c;font-size:13px;margin-top:10px}
.hidden{display:none}
.loading{color:#888;font-size:13px;margin-top:10px}
</style></head><body><div class="wrap">
<h1>流萤音乐 · 汽水链接入库</h1>
<div class="sub">粘贴汽水音乐分享链接，解析歌曲并入库（封面原图 / 歌词 / 音乐标签）</div>

<div class="box">
  <div class="inprow">
    <input id="url" type="url" placeholder="粘贴汽水音乐分享链接，如 https://qishui.douyin.com/s/xxxx/" />
    <button id="parseBtn" class="btn pri" style="width:auto;padding:0 22px;flex-shrink:0">解析</button>
  </div>
  <div class="loading hidden" id="loading">解析中，请稍候…</div>
  <div class="err hidden" id="err"></div>
</div>

<div id="result" class="hidden">
  <div class="box">
    <div class="card">
      <img id="cov" alt="封面" />
      <div class="meta">
        <div class="t" id="title"></div>
        <div class="a" id="artist"></div>
        <span class="tag" id="genre"></span>
        <div class="kv">
          <span>专辑：<b id="album"></b></span>
          <span>时长：<b id="dur"></b></span>
          <span>音质：<b id="size"></b></span>
        </div>
      </div>
    </div>
  </div>

  <div class="sec">歌词预览（<span id="lrcCnt">0</span> 行）</div>
  <div class="box"><div class="lrc" id="lrc"></div></div>

  <div class="sec">入库归属</div>
  <div class="owner" id="ownerRow"><span>归属账号：</span><b id="ownerAcc">3065751692</b><span id="ownerName"></span></div>
  <div class="note" id="dupNote"></div>

  <button id="saveBtn" class="btn green" style="margin-top:14px">确认入库（封面原图 + 歌词 + 音乐标签）</button>
  <div class="ok hidden" id="ok"></div>
  <div class="err hidden" id="saveErr"></div>
</div>

<div class="note">说明：<br>· 封面将保存原图（约 3000×3000），不保存缩略图；<br>· 歌词为标准 LRC 逐字歌词；<br>· 音乐标签（如「流行」）有则入库，无则留空；<br>· 入库后歌曲归属账号 3065751692，可在 App 内播放。</div>

<script>
const $=id=>document.getElementById(id);
const esc=s=>String(s||'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
let cur=null;
function fmtDur(s){if(!s)return '--:--';s=Number(s)||0;return String(Math.floor(s/60)).padStart(2,'0')+':'+String(s%60).padStart(2,'0')}
function fmtSize(n){if(!n)return '';n=Number(n)||0;return n>1048576?(n/1048576).toFixed(1)+'MB':Math.round(n/1024)+'KB'}
$('parseBtn').onclick=async()=>{
  const url=$('url').value.trim();
  if(!url){$('err').textContent='请输入汽水分享链接';$('err').classList.remove('hidden');return}
  $('err').classList.add('hidden');$('loading').classList.remove('hidden');$('result').classList.add('hidden');
  $('parseBtn').disabled=true;
  try{
    const r=await fetch('/music/api/collect/parse-share?url='+encodeURIComponent(url));
    const d=await r.json();
    if(!d.ok){$('err').textContent=d.err||'解析失败';$('err').classList.remove('hidden');return}
    cur=d.track;
    $('cov').src=cur.cover_original||cur.cover;
    $('title').textContent=cur.title;
    $('artist').textContent=cur.artist||'未知歌手';
    $('genre').textContent=cur.genre||'无标签';
    $('genre').style.display=cur.genre?'':'none';
    $('album').textContent=cur.album||'—';
    $('dur').textContent=fmtDur(cur.duration);
    $('size').textContent=fmtSize(cur.audio_size)||'—';
    $('lrc').textContent=cur.lyric_lrc||'（无歌词）';
    $('lrcCnt').textContent=(cur.lyric_lrc||'').split('\\n').filter(x=>x.trim()).length;
    $('ownerAcc').textContent='3065751692';
    $('ownerName').textContent='（夏梓璇）';
    $('dupNote').textContent=d.exists?('⚠ 库内已存在同名歌曲：'+d.exists_title+'，入库将自动跳过'):'';
    $('ok').classList.add('hidden');$('saveErr').classList.add('hidden');
    $('result').classList.remove('hidden');
  }catch(e){$('err').textContent='请求失败：'+e;$('err').classList.remove('hidden')}
  $('parseBtn').disabled=false;$('loading').classList.add('hidden');
};
$('url').addEventListener('keydown',e=>{if(e.key==='Enter')$('parseBtn').click()});
$('saveBtn').onclick=async()=>{
  if(!cur)return;
  $('saveBtn').disabled=true;$('saveBtn').textContent='入库中…';
  $('saveErr').classList.add('hidden');$('ok').classList.add('hidden');
  try{
    const r=await fetch('/music/api/collect/from-share',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({url:cur._share_url||$('url').value.trim()})});
    const d=await r.json();
    if(d.ok){
      $('ok').textContent='✅ 入库成功：'+d.title+'（归属 '+d.owner_account+'）'+(d.inserted?'':'（已存在，跳过）')+' ｜ 封面原图'+(d.cover?'✓':'✗')+' 音频'+(d.audio?'✓':'✗')+' 歌词'+(d.lyric_len>0?('✓ '+d.lyric_len+'行'):'✗')+' 标签'+(d.genre?'✓ '+d.genre:'—');
      $('ok').classList.remove('hidden');
    }else{
      $('saveErr').textContent=d.err||'入库失败';$('saveErr').classList.remove('hidden');
    }
  }catch(e){$('saveErr').textContent='请求失败：'+e;$('saveErr').classList.remove('hidden')}
  $('saveBtn').disabled=false;$('saveBtn').textContent='确认入库（封面原图 + 歌词 + 音乐标签）';
};
</script>
</div></body></html>"""
                self._send_html(share_html)
                return

            # ---------- 后台管理 API ----------
            ADMIN_TOKEN = _admin_token()
            def _admin_auth(self):
                return self.headers.get("X-Admin-Token", "").strip() == ADMIN_TOKEN

            if u.path == "/admin.html":
                admin_html = """<!doctype html>
<html lang="zh-CN"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>流萤音乐 · 后台管理</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{background:#0f0f10;color:#eee;font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;min-height:100vh}
.login{max-width:360px;margin:15vh auto;background:#1a1a1c;padding:30px;border-radius:16px}
.login h2{margin-bottom:18px;font-size:18px}
.login input{width:100%;padding:12px;border-radius:10px;border:1px solid #2a2a2e;background:#111;color:#fff;margin-bottom:12px;font-size:14px}
.login button{width:100%;padding:12px;border:0;border-radius:10px;background:#2a6df4;color:#fff;font-size:15px;cursor:pointer}
.app{display:flex;min-height:100vh}
.side{width:200px;background:#151517;padding:20px 0;flex-shrink:0}
.side h2{font-size:15px;padding:0 20px 18px;border-bottom:1px solid #262629;margin-bottom:10px}
.side button{display:block;width:100%;text-align:left;padding:11px 20px;background:none;border:0;color:#aaa;font-size:14px;cursor:pointer}
.side button.on{color:#fff;background:#222226;border-left:3px solid #2a6df4}
.main{flex:1;padding:24px 28px;overflow:auto;max-width:100%}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:14px;margin-bottom:24px}
.card{background:#1a1a1c;padding:18px;border-radius:12px}
.card .n{font-size:26px;font-weight:600;color:#fff}
.card .l{font-size:12px;color:#888;margin-top:4px}
.tablewrap{overflow-x:auto;-webkit-overflow-scrolling:touch;border-radius:12px}
table{width:100%;border-collapse:collapse;background:#1a1a1c;font-size:13px;min-width:560px}
th,td{padding:11px 14px;text-align:left;border-bottom:1px solid #262629;white-space:nowrap}
th{color:#888;font-weight:500;background:#1f1f22}
tr:last-child td{border-bottom:0}
td.act button{background:#3a1f1f;color:#e06c5c;border:0;padding:5px 10px;border-radius:6px;cursor:pointer;font-size:12px}
td.act button.ok{background:#1e3a2a;color:#5cd68a}
td.act button.gray{background:#2a2a2e;color:#ddd}
.tag{display:inline-block;padding:2px 8px;border-radius:5px;font-size:11px;background:#2a2a2e;color:#aaa}
.tag.wy{background:#1e3a5f;color:#6fb1ff}
.tag.kw{background:#3a2a1e;color:#ffb36b}
.tag.off{background:#3a1f1f;color:#e06c5c}
.tag.on{background:#1e3a2a;color:#5cd68a}
.thumb{width:36px;height:36px;border-radius:6px;object-fit:cover;background:#222;vertical-align:middle}
.empty{padding:30px;text-align:center;color:#555}
.topbar{display:flex;justify-content:space-between;align-items:center;margin-bottom:18px}
.topbar h1{font-size:18px}
.topbar button{background:#2a2a2e;color:#aaa;border:0;padding:7px 14px;border-radius:8px;cursor:pointer;font-size:12px}
.hidden{display:none}
.modal.hidden{display:none}
.modal{position:fixed;inset:0;background:rgba(0,0,0,.62);display:flex;align-items:center;justify-content:center;z-index:99;padding:18px}
.modal-box{background:#1a1a1c;border-radius:14px;width:100%;max-width:420px;max-height:84vh;overflow:auto;display:flex;flex-direction:column}
.modal-h{display:flex;justify-content:space-between;align-items:center;padding:14px 16px;border-bottom:1px solid #262629;font-size:15px;font-weight:600;flex-shrink:0}
.modal-h button{background:none;border:0;color:#888;font-size:20px;cursor:pointer;padding:0 6px}
.modal-b{padding:16px;overflow:auto}
.modal-f{display:flex;gap:10px;padding:14px 16px;border-top:1px solid #262629;flex-shrink:0}
.modal-f .mbtn{flex:1;padding:11px;border:0;border-radius:10px;background:#2a2a2e;color:#eee;font-size:14px;cursor:pointer}
.modal-f .m-save{background:#2a6df4;color:#fff}
.frow{margin-bottom:12px}
.frow label{display:block;font-size:12px;color:#888;margin-bottom:5px}
.frow input,.frow select,.frow textarea{width:100%;padding:10px;border-radius:8px;border:1px solid #2a2a2e;background:#111;color:#fff;font-size:14px;outline:none}
.frow textarea{resize:none}
.avrow{display:flex;align-items:center;gap:10px}
.avrow img{width:64px;height:64px;border-radius:10px;object-fit:cover;background:#222;flex-shrink:0}
.avrow button{padding:8px 12px;border:0;border-radius:8px;background:#2a2a2e;color:#ddd;font-size:13px;cursor:pointer}
.hint{font-size:11px;color:#666;margin-top:4px}
@media (max-width:768px){
  .app{flex-direction:column}
  .side{width:100%;padding:0;display:flex;overflow-x:auto;-webkit-overflow-scrolling:touch;border-bottom:1px solid #262629}
  .side h2{display:none}
  .side button{display:inline-block;width:auto;padding:13px 16px;border-left:0;border-bottom:3px solid transparent;white-space:nowrap}
  .side button.on{border-left:0;border-bottom:3px solid #2a6df4;background:transparent}
  .main{padding:14px 12px calc(20px + env(safe-area-inset-bottom))}
  .cards{grid-template-columns:repeat(2,1fr);gap:10px}
  .card{padding:14px}
  .card .n{font-size:22px}
  .topbar{margin-bottom:14px}
  .topbar h1{font-size:16px}
  table{font-size:12px;min-width:520px}
  th,td{padding:10px 12px}
  .login{margin:8vh 16px;padding:24px}
}
</style></head><body>
<div id="loginBox" class="login">
<h2>流萤音乐后台</h2>
<input id="pwd" type="password" placeholder="管理密码">
<button onclick="login()">登录</button>
</div>
<div id="appBox" class="app hidden">
<div class="side">
<h2>流萤音乐</h2>
<button data-t="dash" class="on" onclick="tab('dash')">仪表盘</button>
<button data-t="users" onclick="tab('users')">用户管理</button>
<button data-t="tracks" onclick="tab('tracks')">上传歌曲</button>
<button data-t="collected" onclick="tab('collected')">采集歌曲</button>
<button data-t="comments" onclick="tab('comments')">评论管理</button>
<button data-t="ann" onclick="tab('ann')">公告管理</button>
<button data-t="notify" onclick="tab('notify')">官方通知</button>
</div>
<div class="main">
<div class="topbar"><h1 id="title">仪表盘</h1><div><button style="margin-right:8px" onclick="changePwd()">修改密码</button><button onclick="logout()">退出</button></div></div>
<div id="content"></div>
</div>
</div>
<div id="modal" class="modal hidden">
<div class="modal-box">
<div class="modal-h"><span id="mTitle">编辑</span><button onclick="closeModal()">×</button></div>
<div id="mBody" class="modal-b"></div>
<div class="modal-f"><button class="mbtn" onclick="closeModal()">取消</button><button class="mbtn m-save" id="mSaveBtn" onclick="mSave()">保存</button></div>
</div>
</div>
<script>
let token=localStorage.getItem('admin_token')||'';
function h(){return token}
function esc(s){return String(s||'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
function fmtTime(ts){if(!ts)return '-';const d=new Date(ts*1000);return d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0')+'-'+String(d.getDate()).padStart(2,'0')}
function fmtDur(s){if(!s)return '-';s=Math.round(s);return Math.floor(s/60)+':'+String(s%60).padStart(2,'0')}
async function api(path, opts){
  opts=opts||{};opts.headers=Object.assign({'X-Admin-Token':h()},opts.headers||{});
  const r=await fetch('/music/api/admin'+path,opts);
  if(r.status===401){logout();throw new Error('未授权')}
  return r.json();
}
function login(){
  const pwd=document.getElementById('pwd').value.trim();
  token=pwd;localStorage.setItem('admin_token',token);
  document.getElementById('loginBox').classList.add('hidden');
  document.getElementById('appBox').classList.remove('hidden');
  loadDash();
}
function logout(){token='';localStorage.removeItem('admin_token');location.reload()}
function tab(t){
  document.querySelectorAll('.side button').forEach(b=>b.classList.toggle('on',b.dataset.t===t));
  const titles={dash:'仪表盘',users:'用户管理',tracks:'上传歌曲',collected:'采集歌曲',comments:'评论管理',ann:'公告管理',notify:'官方通知'};
  document.getElementById('title').textContent=titles[t];
  if(t==='dash')loadDash();if(t==='users')loadUsers();if(t==='tracks')loadTracks();if(t==='collected')loadCollected();if(t==='comments')loadComments();if(t==='ann')loadAnn();if(t==='notify')loadNotify();
}
let curPage={tracks:1,collected:1,comments:1};
let curTracks=[],curCols=[];
async function loadDash(){
  const d=await api('/stats');
  document.getElementById('content').innerHTML=
    '<div class="cards">'+
    '<div class="card"><div class="n">'+d.users+'</div><div class="l">用户总数</div></div>'+
    '<div class="card"><div class="n">'+d.tracks+'</div><div class="l">用户上传歌曲</div></div>'+
    '<div class="card"><div class="n">'+d.collected+'</div><div class="l">采集歌曲</div></div>'+
    '<div class="card"><div class="n">'+d.plays+'</div><div class="l">累计播放次数</div></div>'+
    '</div>';
}
async function loadUsers(){
  const d=await api('/users');
  let h='<div class="tablewrap"><table><tr><th>头像</th><th>昵称</th><th>账号</th><th>性别</th><th>年龄</th><th>签名</th><th>IP/地区</th><th>状态</th><th>操作</th></tr>';
  if(!d.list.length)h+='<tr><td colspan="9" class="empty">无用户</td></tr>';
  d.list.forEach(u=>{
    const av=u.avatar?'<img src="'+location.origin+'/music/api/avatar/'+u.id+'" style="width:36px;height:36px;border-radius:50%;object-fit:cover;background:#222" onerror="this.style.visibility=\\'hidden\\'">':'<div style="width:36px;height:36px;border-radius:50%;background:#2a2a2e;display:flex;align-items:center;justify-content:center;color:#888;font-size:14px">'+esc((u.name||'?')[0])+'</div>';
    const st=u.banned?'<span class="tag off" title="'+esc(u.ban_reason||'')+'">已封禁</span>':'<span class="tag on">正常</span>';
    h+='<tr><td>'+av+'</td><td>'+esc(u.name)+'</td><td>'+esc(u.account)+'</td><td>'+(esc(u.gender)||'-')+'</td><td>'+(u.age||'-')+'</td><td style="max-width:140px;overflow:hidden;text-overflow:ellipsis">'+esc(u.signature||'-')+'</td><td style="font-size:11px;color:#888">'+esc(u.ip||'-')+'</td><td>'+st+'</td><td class="act"><button class="gray" onclick="editUser(\\''+u.id+'\\')">编辑</button> '+(u.banned?'<button class="ok" onclick="unbanUser(\\''+u.id+'\\')">解封</button>':'<button onclick="banUser(\\''+u.id+'\\')">封禁</button>')+' <button onclick="delUser(\\''+u.id+'\\')">删除</button></td></tr>';
  });
  document.getElementById('content').innerHTML=h+'</table></div>';
}
async function loadComments(page){
  if(page)curPage.comments=page;else curPage.comments=1;
  const d=await api('/comments?page='+curPage.comments+'&size=20');
  let h='<div class="tablewrap"><table><tr><th>评论者</th><th>评论内容</th><th>所属歌曲</th><th>时间</th><th>操作</th></tr>';
  if(!d.list.length)h+='<tr><td colspan="5" class="empty">无评论</td></tr>';
  d.list.forEach(c=>{
    h+='<tr><td>'+esc(c.user)+'</td><td style="white-space:normal;max-width:260px">'+esc(c.content)+'</td><td>'+esc(c.track_title)+'</td><td style="font-size:11px;color:#888">'+fmtTime(c.created)+'</td><td class="act"><button onclick="delComment('+c.id+')">删除</button></td></tr>';
  });
  h+='</table></div>';
  h+=pager(curPage.comments,d.total,'loadComments');
  document.getElementById('content').innerHTML=h;
}
async function loadAnn(){
  const h=
  '<div style="max-width:600px">'+
  '<div style="background:#1a1a1c;padding:24px;border-radius:12px;margin-bottom:16px">'+
  '<h3 style="margin-bottom:16px;font-size:16px">发布新通知</h3>'+
  '<div style="margin-bottom:14px"><label style="display:block;font-size:13px;color:#888;margin-bottom:6px">类型</label>'+
  '<select id="annType" onchange="onAnnTypeChange()" style="width:100%;padding:10px 12px;border-radius:8px;border:1px solid #2a2a2e;background:#111;color:#fff;font-size:14px;box-sizing:border-box">'+
  '<option value="announcement">公告通知</option>'+
  '<option value="update">更新通知</option>'+
  '</select></div>'+
  '<div style="margin-bottom:14px"><label style="display:block;font-size:13px;color:#888;margin-bottom:6px">标题</label>'+
  '<input id="annTitle" placeholder="通知标题" style="width:100%;padding:10px 12px;border-radius:8px;border:1px solid #2a2a2e;background:#111;color:#fff;font-size:14px;box-sizing:border-box"></div>'+
  '<div style="margin-bottom:14px"><label style="display:block;font-size:13px;color:#888;margin-bottom:6px">内容</label>'+
  '<textarea id="annContent" rows="5" placeholder="通知内容" style="width:100%;padding:10px 12px;border-radius:8px;border:1px solid #2a2a2e;background:#111;color:#fff;font-size:14px;box-sizing:border-box;resize:vertical"></textarea></div>'+
  '<div style="margin-bottom:14px"><label style="display:block;font-size:13px;color:#888;margin-bottom:6px">版本号（可选）</label>'+
  '<input id="annVersion" placeholder="如 v1.2.0" style="width:100%;padding:10px 12px;border-radius:8px;border:1px solid #2a2a2e;background:#111;color:#fff;font-size:14px;box-sizing:border-box"></div>'+
  '<div id="updateFields" style="display:none">'+
  '<div style="margin-bottom:14px"><label style="display:block;font-size:13px;color:#888;margin-bottom:6px">下载链接</label>'+
  '<input id="annDownloadUrl" placeholder="https://..." style="width:100%;padding:10px 12px;border-radius:8px;border:1px solid #2a2a2e;background:#111;color:#fff;font-size:14px;box-sizing:border-box"></div>'+
  '<div style="margin-bottom:14px"><label style="display:flex;align-items:center;gap:8px;font-size:14px;color:#ccc;cursor:pointer">'+
  '<input type="checkbox" id="annForceUpdate" style="width:16px;height:16px"> 强制更新（用户不能取消，必须更新）</label></div>'+
  '</div>'+
  '<div style="margin-bottom:18px"><label style="display:flex;align-items:center;gap:8px;font-size:14px;color:#ccc;cursor:pointer">'+
  '<input type="checkbox" id="annShowOnce" style="width:16px;height:16px"> 只弹一次（用户点过确认后不再弹，直到内容更新）</label></div>'+
  '<button onclick="submitAnn()" style="width:100%;padding:12px;border:0;border-radius:10px;background:#2a6df4;color:#fff;font-size:15px;cursor:pointer">发布</button>'+
  '</div>'+
  '<div style="background:#1a1a1c;padding:20px;border-radius:12px;font-size:13px;color:#888;line-height:1.8">'+
  '<b style="color:#ccc">说明：</b><br>'+
  '• <b>公告通知</b>：普通公告，用户可关闭，半屏弹窗<br>'+
  '• <b>更新通知</b>：版本更新提示，可设置强制更新和下载链接<br>'+
  '• 强制更新：用户只能点"去更新"，不能取消<br>'+
  '• 非强制更新：用户可点"以后再说"取消<br>'+
  '• 最新一条通知会覆盖之前的，App 只展示最新一条'+
  '</div></div>';
  document.getElementById('content').innerHTML=h;
}
function onAnnTypeChange(){
  const t=document.getElementById('annType').value;
  document.getElementById('updateFields').style.display=(t==='update')?'block':'none';
}
async function submitAnn(){
  const title=document.getElementById('annTitle').value.trim();
  const content=document.getElementById('annContent').value.trim();
  const version=document.getElementById('annVersion').value.trim();
  const type=document.getElementById('annType').value;
  const showOnce=document.getElementById('annShowOnce').checked?1:0;
  const forceUpdate=document.getElementById('annForceUpdate').checked?1:0;
  const downloadUrl=document.getElementById('annDownloadUrl').value.trim();
  if(!title||!content){alert('请填写标题和内容');return;}
  if(type==='update'&&!downloadUrl){alert('更新通知需要填写下载链接');return;}
  try{
    const r=await fetch('/music/api/admin/announcement',{method:'POST',headers:{'Content-Type':'application/json','X-Admin-Token':token},body:JSON.stringify({title,content,version,type,showOnce,forceUpdate,downloadUrl})});
    if(r.ok){alert('发布成功');loadAnn();}
    else{alert('发布失败');}
  }catch(e){alert('网络错误');}
}
async function loadTracks(page){
  if(page)curPage.tracks=page;
  const d=await api('/tracks?page='+curPage.tracks+'&size=20');
  curTracks=d.list||[];
  let h='<div class="tablewrap"><table><tr><th>封面</th><th>标题</th><th>歌手</th><th>状态</th><th>上传者</th><th>播放</th><th>操作</th></tr>';
  if(!d.list.length)h+='<tr><td colspan="7" class="empty">无歌曲</td></tr>';
  d.list.forEach(t=>{
    const st=t.offline?'<span class="tag off">已下架</span>':'<span class="tag on">在售</span>';
    h+='<tr><td><img class="thumb" src="'+location.origin+'/music/api/cover/'+t.id+'" onerror="this.style.visibility=\\'hidden\\'"></td><td>'+esc(t.title)+'</td><td>'+esc(t.artist)+'</td><td>'+st+'</td><td>'+esc(t.uname||'-')+'</td><td>'+t.play_count+'</td><td class="act"><button class="gray" onclick="editTrack(\\''+t.id+'\\')">编辑</button> '+(t.offline?'<button class="ok" onclick="onlineTrack('+t.id+')">上架</button>':'<button onclick="offlineTrack('+t.id+')">下架</button>')+' <button onclick="delTrack('+t.id+')">删除</button></td></tr>';
  });
  h+='</table></div>';
  h+=pager(curPage.tracks,d.total,'loadTracks');
  document.getElementById('content').innerHTML=h;
}
async function loadCollected(page){
  if(page)curPage.collected=page;
  const d=await api('/collected?page='+curPage.collected+'&size=20');
  curCols=d.list||[];
  let h='<div class="tablewrap"><table><tr><th>封面</th><th>标题</th><th>歌手</th><th>来源</th><th>状态</th><th>操作</th></tr>';
  if(!d.list.length)h+='<tr><td colspan="6" class="empty">无歌曲</td></tr>';
  d.list.forEach(t=>{
    const st=t.offline?'<span class="tag off">已下架</span>':'<span class="tag on">在售</span>';
    h+='<tr><td><img class="thumb" src="'+location.origin+'/music/api/cover/'+t.id+'" onerror="this.style.visibility=\\'hidden\\'"></td><td>'+esc(t.title)+'</td><td>'+esc(t.artist)+'</td><td><span class="tag '+t.source+'">'+t.source+'</span></td><td>'+st+'</td><td class="act"><button class="gray" onclick="editCol(\\''+t.id+'\\')">编辑</button> '+(t.offline?'<button class="ok" onclick="onlineCol('+t.id+')">上架</button>':'<button onclick="offlineCol('+t.id+')">下架</button>')+' <button onclick="delCol('+t.id+')">删除</button></td></tr>';
  });
  h+='</table></div>';
  h+=pager(curPage.collected,d.total,'loadCollected');
  document.getElementById('content').innerHTML=h;
}
function pager(page,total,fn){
  const pages=Math.ceil(total/20);
  let h='<div style="display:flex;justify-content:center;gap:10px;margin-top:16px;align-items:center">';
  h+='<button style="background:#2a2a2e;color:#fff;border:0;padding:8px 14px;border-radius:8px;cursor:pointer" onclick="'+fn+'('+(page>1?page-1:1)+')" '+(page<=1?'disabled':'')+'>上一页</button>';
  h+='<span style="color:#888;font-size:13px">第 '+page+' / '+pages+' 页（共'+total+'首）</span>';
  h+='<button style="background:#2a2a2e;color:#fff;border:0;padding:8px 14px;border-radius:8px;cursor:pointer" onclick="'+fn+'('+(page<pages?page+1:pages)+')" '+(page>=pages?'disabled':'')+'>下一页</button>';
  return h+'</div>';
}
// ---------- 模态框编辑 ----------
let mState={type:'user',id:'',fields:{},onSave:null};
function openModal(title,body,state){mState=state;document.getElementById('mTitle').textContent=title;document.getElementById('mBody').innerHTML=body;document.getElementById('modal').classList.remove('hidden');}
function closeModal(){document.getElementById('modal').classList.add('hidden');}
async function mSave(){const b=document.getElementById('mSaveBtn');b.disabled=true;try{await mState.onSave()}catch(e){alert('保存失败：'+e)}b.disabled=false;}
function pickImg(input,key){
  const f=input.files&&input.files[0];if(!f)return;
  if(f.size>3*1024*1024){alert('图片不能超过 3MB');input.value='';return}
  const r=new FileReader();
  r.onload=()=>{
    mState.fields[key]=r.result;
    const img=document.getElementById(key==='avatar'?'pvAvatar':'pvCover');
    if(img){img.style.visibility='visible';img.src=r.result}
  };
  r.readAsDataURL(f);
}
async function editUser(id){
  const u=(await api('/users')).list.find(x=>x.id===id);if(!u)return;
  openModal('编辑用户 · '+esc(u.account),'<div class="frow"><label>头像</label><div class="avrow"><img id="pvAvatar" src="'+location.origin+'/music/api/avatar/'+id+'"><button type="button" onclick="document.getElementById(\\'fiAvatar\\').click()">更换头像</button></div><input type="file" id="fiAvatar" accept="image/*" class="hidden" onchange="pickImg(this,\\'avatar\\')"><div class="hint">点击更换，支持 jpg/png/webp，≤3MB</div></div><div class="frow"><label>昵称</label><input id="fName" value="'+esc(u.name)+'"></div><div class="frow"><label>性别</label><select id="fGender"><option value="">保密</option><option value="男">男</option><option value="女">女</option></select></div><div class="frow"><label>年龄</label><input id="fAge" type="number" min="1" max="120" value="'+(u.age||'')+'"></div><div class="frow"><label>签名</label><textarea id="fSig" rows="2">'+esc(u.signature||'')+'</textarea></div><div class="frow"><label>新密码</label><input id="fPwd" type="password" placeholder="留空则不修改"><div class="hint">留空保持原密码不变</div></div>',
    {type:'user',id:id,fields:{avatar:null},onSave:saveUser});
  document.getElementById('fGender').value=u.gender||'';
}
async function saveUser(){
  const fd={};
  const nm=document.getElementById('fName').value.trim();
  const g=document.getElementById('fGender').value;
  const ag=document.getElementById('fAge').value.trim();
  const sg=document.getElementById('fSig').value.trim();
  const pw=document.getElementById('fPwd').value.trim();
  if(nm)fd.name=nm;
  if(g)fd.gender=g;
  if(ag)fd.age=ag;
  if(sg)fd.signature=sg;
  if(pw)fd.password=pw;
  if(mState.fields.avatar)fd.avatar=mState.fields.avatar;
  if(!Object.keys(fd).length){alert('没有可保存的修改');return}
  await api('/update',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({type:'user',id:mState.id,fields:fd})});
  closeModal();loadUsers();
}
async function editTrack(id){
  const t=curTracks.find(x=>x.id===id);if(!t)return;
  openModal('编辑歌曲 · 上传','<div class="frow"><label>封面</label><div class="avrow"><img id="pvCover" src="'+location.origin+'/music/api/cover/'+id+'"><button type="button" onclick="document.getElementById(\\'fiCover\\').click()">更换封面</button></div><input type="file" id="fiCover" accept="image/*" class="hidden" onchange="pickImg(this,\\'cover\\')"><div class="hint">点击更换，支持 jpg/png/webp，≤3MB</div></div><div class="frow"><label>歌曲名称</label><input id="fTitle" value="'+esc(t.title)+'"></div><div class="frow"><label>作者/歌手</label><input id="fArtist" value="'+esc(t.artist)+'"></div>',
    {type:'track',id:id,fields:{cover:null},onSave:saveTrack});
}
async function editCol(id){
  const t=curCols.find(x=>x.id===id);if(!t)return;
  openModal('编辑歌曲 · 采集','<div class="frow"><label>封面</label><div class="avrow"><img id="pvCover" src="'+location.origin+'/music/api/cover/'+id+'"><button type="button" onclick="document.getElementById(\\'fiCover\\').click()">更换封面</button></div><input type="file" id="fiCover" accept="image/*" class="hidden" onchange="pickImg(this,\\'cover\\')"><div class="hint">点击更换，支持 jpg/png/webp，≤3MB</div></div><div class="frow"><label>歌曲名称</label><input id="fTitle" value="'+esc(t.title)+'"></div><div class="frow"><label>作者/歌手</label><input id="fArtist" value="'+esc(t.artist)+'"></div>',
    {type:'collected',id:id,fields:{cover:null},onSave:saveTrack});
}
async function saveTrack(){
  const fd={};
  const nm=document.getElementById('fTitle').value.trim();
  const ar=document.getElementById('fArtist').value.trim();
  if(nm)fd.title=nm;
  if(ar)fd.artist=ar;
  if(mState.fields.cover)fd.cover=mState.fields.cover;
  if(!Object.keys(fd).length){alert('没有可保存的修改');return}
  await api('/update',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({type:mState.type,id:mState.id,fields:fd})});
  closeModal();
  if(mState.type==='track')loadTracks();else loadCollected();
}
async function banUser(id){const r=prompt('请输入封禁原因：');if(r===null)return;await api('/ban',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id:id,reason:r,action:'ban'})});loadUsers();}
async function unbanUser(id){await api('/ban',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id:id,action:'unban'})});loadUsers();}
async function delComment(id){if(!confirm('确认删除这条评论？'))return;await api('/del/comment/'+id,{method:'POST'});loadComments();}
async function offlineTrack(id){const r=prompt('请输入下架原因：');if(r===null)return;await api('/offline',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({type:'track',id:id,reason:r,action:'off'})});loadTracks();}
async function onlineTrack(id){await api('/offline',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({type:'track',id:id,action:'on'})});loadTracks();}
async function offlineCol(id){const r=prompt('请输入下架原因：');if(r===null)return;await api('/offline',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({type:'collected',id:id,reason:r,action:'off'})});loadCollected();}
async function onlineCol(id){await api('/offline',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({type:'collected',id:id,action:'on'})});loadCollected();}
async function delUser(id){if(!confirm('确认删除该用户？'))return;await api('/del/user/'+id,{method:'POST'});loadUsers();}
async function delTrack(id){const r=prompt('请输入删除原因：');if(r===null)return;if(!confirm('确认删除？原因：'+r))return;await api('/del/track/'+id,{method:'POST'});loadTracks();}
async function delCol(id){const r=prompt('请输入删除原因：');if(r===null)return;if(!confirm('确认删除？原因：'+r))return;await api('/del/collected/'+id,{method:'POST'});loadCollected();}
async function changePwd(){
  openModal('修改管理密码','<div class="frow"><label>当前密码</label><input id="pOld" type="password"></div><div class="frow"><label>新密码</label><input id="pNew" type="password" placeholder="6-64 位"></div><div class="frow"><label>确认新密码</label><input id="pNew2" type="password"></div>',{onSave:savePwd});
}
async function savePwd(){
  const o=document.getElementById('pOld').value.trim();
  const n=document.getElementById('pNew').value.trim();
  const n2=document.getElementById('pNew2').value.trim();
  if(!o||!n){alert('请填写完整');return}
  if(n!==n2){alert('两次新密码不一致');return}
  const r=await api('/change_pwd',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({old:o,pwd:n})});
  if(r&&r.ok){closeModal();alert('密码已修改，请用新密码重新登录');logout();}
  else{alert((r&&r.err)||'修改失败');}
}
if(token){document.getElementById('loginBox').classList.add('hidden');document.getElementById('appBox').classList.remove('hidden');loadDash();}

async function loadNotify(){
  const d=await api('/official-messages?admin=1');
  let h='<div class="topbar"><h1>官方通知管理</h1><button onclick="showNotifyModal()">+ 发布新通知</button></div>';
  h+='<div class="tablewrap"><table><tr><th>内容</th><th>发送时间</th><th>操作</th></tr>';
  if(!d.list||!d.list.length)h+='<tr><td colspan="3" class="empty">暂无官方通知</td></tr>';
  if(d.list)d.list.forEach(m=>{
    const t=new Date(m.created*1000);
    const ts=t.getFullYear()+'-'+String(t.getMonth()+1).padStart(2,'0')+'-'+String(t.getDate()).padStart(2,'0')+' '+String(t.getHours()).padStart(2,'0')+':'+String(t.getMinutes()).padStart(2,'0');
    h+='<tr><td style="max-width:400px;white-space:normal">'+esc(m.content)+'</td><td style="font-size:12px;color:#888">'+ts+'</td><td class="act"><button onclick="delNotify(\\''+m.id+'\\')">删除</button></td></tr>';
  });
  h+='</table></div>';
  h+='<div class="modal hidden" id="notifyModal"><div class="modal-box" style="max-width:500px;width:100%"><h3 style="margin-bottom:16px">发布官方通知</h3><textarea id="notifyContent" placeholder="输入通知内容..." style="width:100%;height:120px;padding:12px;border-radius:10px;border:1px solid #2a2a2e;background:#111;color:#fff;font-size:14px;box-sizing:border-box;resize:vertical"></textarea><div style="display:flex;gap:10px;margin-top:16px;justify-content:flex-end"><button onclick="hideNotifyModal()" style="padding:9px 18px;border:0;border-radius:8px;background:#2a2a2e;color:#aaa;cursor:pointer">取消</button><button onclick="publishNotify()" style="padding:9px 18px;border:0;border-radius:8px;background:#2a6df4;color:#fff;cursor:pointer">发布</button></div></div></div>';
  document.getElementById('content').innerHTML=h;
}
function showNotifyModal(){document.getElementById('notifyModal').classList.remove('hidden')}
function hideNotifyModal(){document.getElementById('notifyModal').classList.add('hidden')}
async function publishNotify(){
  const content=document.getElementById('notifyContent').value.trim();
  if(!content){alert('请输入通知内容');return}
  const r=await api('/official-message',{method:'POST',body:JSON.stringify({content:content})});
  if(r.ok){hideNotifyModal();loadNotify();}else{alert(r.err||'发布失败')}
}
async function delNotify(id){
  if(!confirm('确定删除这条通知？'))return;
  const r=await api('/official-message/'+id,{method:'DELETE'});
  if(r.ok)loadNotify();else alert(r.err||'删除失败')
}

</script></body></html>"""
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
                    self._json(200, {"list": [], "unread": 0})
                    return
                rows = c.execute("SELECT id, type, title, content, from_user_id, from_user_name, track_id, track_title, comment_id, is_read, created FROM notifications WHERE user_id=? ORDER BY created DESC LIMIT 100", (tok_uid,)).fetchall()
                unread = c.execute("SELECT COUNT(*) FROM notifications WHERE user_id=? AND is_read=0", (tok_uid,)).fetchone()[0]
                c.close()
                self._json(200, {"list": [{"id": r[0], "type": r[1], "title": r[2], "content": r[3], "fromUserId": r[4], "fromUser": r[5], "trackId": r[6], "trackTitle": r[7], "commentId": r[8], "isRead": r[9], "created": r[10]} for r in rows], "unread": unread})
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
                # 批次轮换：时间桶（同桶主批稳定可复现）+ 会话内序号递增（每次获取不同批）
                _bucket = int(time.time() // REC_BUCKET_SECONDS)
                _seq, _rnd = _rec_next_seq(viewer_id, _bucket, time.time(), fresh=_fresh)
                log.info("recommend uid=%s bucket=%d seq=%d fresh=%s",
                         viewer_id or "-", _bucket, _seq, _fresh)
                # 多路召回 + 加权融合 + MMR 重排（算法见 build_recommendations）
                rec_pairs = build_recommendations(c, viewer_id, exclude=_excl, fresh=_fresh, rnd=_rnd)
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

            if u.path.startswith("/api/comments/"):
                tid = u.path.rsplit("/", 1)[-1]
                c = db()
                rows = c.execute("""SELECT id,user_id,user_name,content,created
                                    FROM comments WHERE track_id=? ORDER BY created DESC LIMIT 200""",
                                 (tid,)).fetchall()
                c.close()
                self._json(200, [{"id": r[0], "userId": r[1], "userName": r[2],
                                  "content": r[3], "created": r[4]} for r in rows])
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

            # ---------- 后台管理：编辑 / 上下架 ----------
            ADMIN_TOKEN = _admin_token()
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

            # 标记通知已读
            if u.path == "/api/notifications/read":
                c = db()
                tok_uid = resolve_token(c, self.headers.get("Authorization", ""))
                if not tok_uid:
                    c.close()
                    self._err(401, "unauthorized"); return
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
                    c.execute("UPDATE tracks SET play_count=play_count+1 WHERE id=?", (tid,))
                    c.commit()
                    row = c.execute("SELECT play_count FROM tracks WHERE id=?", (tid,)).fetchone()
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
                            notif_id = uuid.uuid4().hex
                            from_user_name = c.execute("SELECT name FROM users WHERE id=?", (uid,)).fetchone()
                            uname = from_user_name[0] if from_user_name else "有人"
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
                    if not content:
                        c.close()
                        self._err(400, "评论内容不能为空")
                        return
                    # 过滤控制字符（防注入/异常渲染）
                    content = "".join(ch for ch in content if ch >= " " or ch == "\n").strip()
                    if not content:
                        c.close()
                        self._err(400, "评论内容不能为空")
                        return
                    cid = uuid.uuid4().hex
                    c.execute("""INSERT INTO comments(id,track_id,user_id,user_name,content,created)
                                 VALUES(?,?,?,?,?,?)""",
                              (cid, tid, uid, uname, content, time.time()))
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


if __name__ == "__main__":
    db().close()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    srv.daemon_threads = True
    log.info("music server on 127.0.0.1:%d root=%s strict_auth=%s",
             PORT, ROOT, AUTH_STRICT)
    srv.serve_forever()
