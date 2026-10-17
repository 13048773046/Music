# -*- coding: utf-8 -*-
"""流萤音乐 · 后端模块化包（由线上 server.py 机械重放，函数体零改写）。"""
import os
import re
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
from server.config import ADMIN_PWD_FILE, SITE_CONFIG_FILE, _SITE_CONFIG_DEFAULTS, COLLECT_KEY
from server.database import db

__all__ = ['RATE', 'RATE_LIMITS', 'RateLimiter', '_B62', '_admin_token', '_fmt_dur', '_ingest_behavior', '_notif_unread', '_read_site_config', '_ssl_ctx', '_track_info', '_track_owner', '_write_site_config', 'client_ip', 'gen_short_code', 'hash_password', 'is_legacy_hash', 'issue_token', 'parse_page', 'public_user', 'rate_key', 'rate_limit', 'resolve_token', 'safe_file_path', 'sign_stream', 'verify_password', 'verify_stream']

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
              gender,age,background_image,signature,ip_address,city"""
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
        "city": row[11] or "" if len(row) > 11 else "",
    }
    if token:
        out["token"] = token
    return out


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
    "comment_image": (30, 3600),  # 评论图片上传 30 次/小时
    "stream":    (300, 60),   # 流请求（含签名签发）300 次/分
    "share_url": (60, 60),    # 分享 token 签发/分享页 60 次/分
    "collect":   (60, 60),    # 采集歌曲列表 60 次/分
    "collect_add": (20, 60),  # 采集入库 20 次/分
    "behavior":  (120, 60),   # 用户行为上报 120 次/分
    "recommend": (30, 60),    # 个性化推荐 30 次/分
    "weather":   (60, 60),    # 天气快照 60 次/分（M2）
    "ai_comment": (5, 60),    # AI 乐评生成 5 次/分
}


def _notif_unread(c, uid):
    """该用户当前未读通知数（调用时需持有数据库连接 c）。"""
    row = c.execute("SELECT COUNT(*) FROM notifications WHERE user_id=? AND is_read=0",
                    (uid,)).fetchone()
    return row[0] if row else 0


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


def _read_site_config():
    """读官网配置 + 实时歌曲总数；文件不存在时用默认值。轮播图(banners)以数据库为准（持久化）。"""
    cfg = dict(_SITE_CONFIG_DEFAULTS)
    file_banners = []
    try:
        with open(SITE_CONFIG_FILE, "r", encoding="utf-8") as f:
            saved = json.load(f)
        if isinstance(saved, dict):
            for k, v in saved.items():
                if k in _SITE_CONFIG_DEFAULTS and k != "banners":
                    cfg[k] = v
            if isinstance(saved.get("banners"), list):
                file_banners = saved["banners"]
    except Exception:
        pass
    # 轮播图：数据库优先（重启/重开不丢失）；旧文件有而数据库空时迁移一次
    try:
        c = db()
        try:
            rows = c.execute("SELECT name,title,link FROM banners ORDER BY sort,id").fetchall()
            if rows:
                cfg["banners"] = [{"name": r[0], "title": r[1] or "", "link": r[2] or ""} for r in rows]
            elif file_banners:
                for i, b in enumerate(file_banners[:50]):
                    if not isinstance(b, dict):
                        continue
                    name = str(b.get("name") or "").strip()
                    if not re.fullmatch(r"banner_[0-9a-f]{32}\.(?:jpg|jpeg|png|webp)", name):
                        continue
                    c.execute("INSERT OR IGNORE INTO banners(name,title,link,sort) VALUES(?,?,?,?)",
                              (name, str(b.get("title") or "")[:60], str(b.get("link") or "")[:300], i))
                c.commit()
                cfg["banners"] = [{"name": r[0], "title": r[1] or "", "link": r[2] or ""}
                                  for r in c.execute("SELECT name,title,link FROM banners ORDER BY sort,id").fetchall()]
        finally:
            c.close()
    except Exception:
        cfg["banners"] = []
    # 实时歌曲总数（用户上传 + 采集，排除 offline）
    try:
        c = db()
        n1 = c.execute("SELECT COUNT(*) FROM tracks WHERE offline=0").fetchone()[0]
        n2 = c.execute("SELECT COUNT(*) FROM collected_tracks WHERE offline=0").fetchone()[0]
        c.close()
        cfg["track_total"] = int(n1 or 0) + int(n2 or 0)
    except Exception:
        cfg["track_total"] = 0
    return cfg


def _write_site_config(patch):
    cfg = dict(_SITE_CONFIG_DEFAULTS)
    try:
        with open(SITE_CONFIG_FILE, "r", encoding="utf-8") as f:
            saved = json.load(f)
        if isinstance(saved, dict):
            for k, v in saved.items():
                if k in _SITE_CONFIG_DEFAULTS and k != "banners":
                    cfg[k] = v
    except Exception:
        pass
    for k, v in (patch or {}).items():
        if k not in _SITE_CONFIG_DEFAULTS:
            continue
        if k == "banners":
            # 官网轮播图：校验后全量写入数据库（动态数量、持久化），文件字段不再作为存储源
            banners = []
            if isinstance(v, list):
                for b in v[:50]:
                    if not isinstance(b, dict):
                        continue
                    name = str(b.get("name") or "").strip()
                    if not re.fullmatch(r"banner_[0-9a-f]{32}\.(?:jpg|jpeg|png|webp)", name):
                        continue
                    banners.append({
                        "name": name,
                        "title": str(b.get("title") or "")[:60],
                        "link": str(b.get("link") or "")[:300],
                    })
            try:
                c = db()
                try:
                    c.execute("DELETE FROM banners")
                    for i, b in enumerate(banners):
                        c.execute("INSERT INTO banners(name,title,link,sort) VALUES(?,?,?,?)",
                                  (b["name"], b["title"], b["link"], i))
                    c.commit()
                finally:
                    c.close()
            except Exception:
                pass
            cfg[k] = banners
        elif isinstance(v, str):
            cfg[k] = v.strip()
    with open(SITE_CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
    return cfg


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
