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
import sqlite3
import time
import uuid
import hashlib
import hmac
import mimetypes
import secrets
import logging
import socket
import struct
import urllib.parse
import threading
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
                       ("ip_address", "TEXT DEFAULT ''")]:
        if _col not in ucols:
            c.execute("ALTER TABLE users ADD COLUMN %s %s" % (_col, _ddl))
    tcols = [r[1] for r in c.execute("PRAGMA table_info(tracks)")]
    for _col, _ddl in [("user_id", "TEXT DEFAULT ''"),
                       ("play_count", "INTEGER DEFAULT 0"),
                       ("like_count", "INTEGER DEFAULT 0"),
                       ("share_count", "INTEGER DEFAULT 0")]:
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
}

# 采集入库接口密钥（音乐源采集器调用 POST /api/collect/add 时携带）
COLLECT_KEY = os.environ.get("COLLECT_KEY", "liuying-collect-7f3a9c2e")


def rate_key(handler, name, extra=""):
    return (name, client_ip(handler), extra)


def rate_limit(handler, name, extra=""):
    limit, window = RATE_LIMITS[name]
    return RATE.allow(rate_key(handler, name, extra), limit, window)


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
                c.close()
                fp = safe_file_path(row[0] if row else "")
                if not fp:
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
            if u.path in ("/", "/api/health"):
                self._json(200, {"ok": True, "service": "music",
                                 "time": time.strftime("%Y-%m-%d %H:%M:%S")})
                return

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
                        base_sql + """ WHERE t.title LIKE ? OR t.artist LIKE ? OR t.album LIKE ?
                                       OR COALESCE(u.name,'') LIKE ?
                                       GROUP BY t.id ORDER BY RANDOM() LIMIT 10""",
                        (viewer_id, like, like, like, like)).fetchall()
                    if len(rows) < 10:
                        ids = [r[0] for r in rows]
                        need = 10 - len(rows)
                        if ids:
                            ph = ",".join("?" * len(ids))
                            extra = c.execute(
                                base_sql + (" WHERE t.id NOT IN (%s)"
                                            " GROUP BY t.id ORDER BY RANDOM() LIMIT ?" % ph),
                                tuple([viewer_id] + ids + [need])).fetchall()
                        else:
                            extra = c.execute(
                                base_sql + " GROUP BY t.id ORDER BY RANDOM() LIMIT ?",
                                (viewer_id, need)).fetchall()
                        rows = rows + extra
                else:
                    rows = c.execute(
                        base_sql + " GROUP BY t.id ORDER BY RANDOM() LIMIT 10",
                        (viewer_id,)).fetchall()
                c.close()
                self._json(200, [{"id": r[0], "title": r[1], "artist": r[2], "album": r[3],
                                  "cover": r[4], "fname": r[5], "size": r[6], "dur": r[7],
                                  "durText": _fmt_dur(r[7]), "created": r[8],
                                  "playCount": r[9] or 0, "likeCount": r[10] or 0,
                                  "shareCount": r[11] or 0,
                                  "userId": r[12] or "", "userName": r[14] or "",
                                  "hasLyric": bool(r[13]),
                                  "commentCount": r[15] or 0,
                                  "isLiked": bool(r[16])} for r in rows])
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

            # 搜索：按歌名/歌手模糊匹配
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
                                    WHERE t.title LIKE ? OR t.artist LIKE ?
                                    GROUP BY t.id
                                    ORDER BY t.play_count DESC
                                    LIMIT 50""", (viewer_id, like, like)).fetchall()
                c.close()
                self._json(200, [{"id": r[0], "title": r[1], "artist": r[2], "album": r[3],
                                  "cover": r[4], "fname": r[5], "size": r[6], "dur": r[7],
                                  "durText": _fmt_dur(r[7]), "created": r[8],
                                  "playCount": r[9] or 0, "likeCount": r[10] or 0,
                                  "shareCount": r[11] or 0,
                                  "userId": r[12] or "", "userName": r[14] or "",
                                  "hasLyric": bool(r[13]),
                                  "commentCount": r[15] or 0,
                                  "isLiked": bool(r[16])} for r in rows])
                return

            if u.path.startswith("/api/cover/"):
                tid = u.path.rsplit("/", 1)[-1]
                c = db()
                row = c.execute("SELECT cover FROM tracks WHERE id=?", (tid,)).fetchone()
                c.close()
                fp = safe_file_path(row[0] if row else "")
                if not fp:
                    self._err(404, "no cover")
                    return
                self._serve_file(fp)
                return

            if u.path.startswith("/api/lyric/"):
                tid = u.path.rsplit("/", 1)[-1]
                c = db()
                row = c.execute("SELECT lrc FROM tracks WHERE id=?", (tid,)).fetchone()
                c.close()
                fp = safe_file_path(row[0] if row else "")
                if not fp:
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
                    row = c.execute("SELECT 1 FROM tracks WHERE id=?", (tid,)).fetchone()
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
                c.close()
                fp = safe_file_path(row[0] if row else "")
                if not fp:
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
                    cur = c.execute(
                        """INSERT OR IGNORE INTO collected_tracks
                           (id,title,artist,album,cover,duration,source,source_id,play_url,size,created,user_id,lrc)
                           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                        (tid, title, (it.get("artist") or "").strip(), (it.get("album") or "").strip(),
                         it.get("cover") or "", float(it.get("duration") or 0), src, sid,
                         it.get("play_url") or "", float(it.get("size") or 0), now, owner, it.get("lrc") or ""))
                    if cur.rowcount and cur.rowcount > 0:
                        ins += 1
                    else:
                        skip += 1
                c.commit()
                c.close()
                self._json(200, {"ok": True, "inserted": ins, "skipped": skip, "owner": owner})
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
                    account = (fields.get("account") or "").strip()
                    password = fields.get("password") or ""
                    name = (fields.get("name") or "").strip()[:MAX_NAME] or account
                    gender = (fields.get("gender") or "").strip()[:8]
                    signature = (fields.get("signature") or "").strip()[:100]
                    try:
                        age = int(fields.get("age") or 0)
                    except Exception:
                        age = 0
                    age = max(0, min(age, 150))
                    if not account or not password:
                        self._err(400, "账号和密码不能为空")
                        return
                    if len(account) > 40:
                        self._err(400, "账号过长")
                        return
                    if len(password) < 6 or len(password) > 64:
                        self._err(400, "密码长度需在 6-64 位之间")
                        return
                    c = db()
                    dup = c.execute("SELECT 1 FROM users WHERE account=?", (account,)).fetchone()
                    if dup:
                        c.close()
                        self._err(409, "账号已被注册")
                        return
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
                                     gender,age,background_image,signature,ip_address
                                     FROM users WHERE account=?""",
                                    (account,)).fetchone()
                    if not row or not verify_password(password, row[2]):
                        c.close()
                        self._err(401, "账号或密码错误")
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
                    c.close()
                    self._json(200, public_user(row))
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
                        liked = False
                    else:
                        c.execute("INSERT OR IGNORE INTO likes(user_id,track_id,created) VALUES(?,?,?)",
                                  (uid, tid, time.time()))
                        c.execute("UPDATE tracks SET like_count=like_count+1 WHERE id=?", (tid,))
                        liked = True
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
                    c.commit()
                    row = c.execute("SELECT share_count FROM tracks WHERE id=?", (tid,)).fetchone()
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
                    c.commit()
                    c.close()
                    self._json(200, {"id": cid})
                except Exception as e:
                    self._internal_error(e)
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
                c.close()
                self._json(200, {"id": tid, "title": title, "cover": cover_fname,
                                 "dur": dur, "durText": _fmt_dur(dur)})
            except Exception as e:
                self._internal_error(e)
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
