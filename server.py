#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""音乐后端：上传 / 列表 / 流式播放 / 音频时长解析 / 用户注册登录。
纯标准库，监听 127.0.0.1:8788。兼容原 tracks.db 表结构。"""
import os, json, sqlite3, time, uuid, hashlib, mimetypes, urllib.parse, struct
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = "/www/wwwroot/music"
FILES = os.path.join(ROOT, "files")
DB = os.path.join(ROOT, "tracks.db")
PORT = 8788
MAX_UPLOAD = 100 * 1024 * 1024

os.makedirs(FILES, exist_ok=True)


def db():
    c = sqlite3.connect(DB)
    c.execute("""CREATE TABLE IF NOT EXISTS tracks(
        id TEXT PRIMARY KEY, title TEXT, artist TEXT, album TEXT,
        fname TEXT, size INTEGER, dur REAL, created REAL)""")
    cols = [r[1] for r in c.execute("PRAGMA table_info(tracks)")]
    if "cover" not in cols:
        c.execute("ALTER TABLE tracks ADD COLUMN cover TEXT DEFAULT ''")
    c.execute("""CREATE TABLE IF NOT EXISTS users(
        id TEXT PRIMARY KEY, account TEXT UNIQUE, password_hash TEXT,
        name TEXT, avatar TEXT, created REAL)""")
    # 资料字段迁移（老库平滑加列）
    ucols = [r[1] for r in c.execute("PRAGMA table_info(users)")]
    for _col, _ddl in [("gender", "TEXT DEFAULT ''"),
                       ("age", "INTEGER DEFAULT 0"),
                       ("background_image", "TEXT DEFAULT ''"),
                       ("signature", "TEXT DEFAULT ''"),
                       ("ip_address", "TEXT DEFAULT ''")]:
        if _col not in ucols:
            c.execute("ALTER TABLE users ADD COLUMN %s %s" % (_col, _ddl))
    # 歌曲互动字段迁移
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


def public_user(row):
    """users 行 → 对外资料 JSON（不含密码哈希）。
    row 顺序: id,account,password_hash,name,avatar,created,
              gender,age,background_image,signature,ip_address"""
    return {
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


# ---------- 密码哈希（pbkdf2，纯标准库） ----------

def hash_password(pw):
    salt = os.urandom(16).hex()
    h = hashlib.pbkdf2_hmac("sha256", pw.encode("utf-8"),
                            bytes.fromhex(salt), 120000).hex()
    return salt + "$" + h


def verify_password(pw, stored):
    try:
        salt, h = stored.split("$", 1)
        test = hashlib.pbkdf2_hmac("sha256", pw.encode("utf-8"),
                                   bytes.fromhex(salt), 120000).hex()
        return h == test
    except Exception:
        return False


# ---------- 音频时长解析（纯标准库） ----------

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
        bitrates = []   # (kbps, frames)
        i = off
        n = len(data)
        while i + 4 <= n:
            b = data[i:i+4]
            if b[0] == 0xFF and (b[1] & 0xE0) == 0xE0:
                ver = (b[1] >> 3) & 0x03      # 3=MPEG1, 2=MPEG2, 0=MPEG2.5
                layer = (b[1] >> 1) & 0x03    # 1=Layer III, 2=Layer II, 3=Layer I
                br_idx = (b[2] >> 4) & 0x0F
                sr_idx = (b[2] >> 2) & 0x03
                if br_idx not in (0, 15) and sr_idx != 3 and layer != 0 and ver != 1:
                    tbl = None
                    if ver == 3:   # MPEG1
                        if layer == 3:
                            tbl = [32,64,96,128,160,192,224,256,288,320,352,384,416,448]
                        elif layer == 2:
                            tbl = [32,48,56,64,80,96,112,128,160,192,224,256,320,384]
                        else:
                            tbl = [32,64,96,128,160,192,224,256,288,320,352,384,416,448]
                    else:          # MPEG2 / 2.5
                        if layer == 3:
                            tbl = [8,16,24,32,40,48,56,64,80,96,112,128,144,160]
                        else:
                            tbl = [8,16,24,32,40,48,56,64,80,96,112,128,144,160]
                    kbps = tbl[br_idx - 1]
                    if ver != 3:
                        kbps //= 2
                    # 帧长（粗略，用于推进扫描）
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
    return 0.0


def _fmt_dur(d):
    if not d or d <= 0:
        return "--:--"
    m, s = int(d) // 60, int(d) % 60
    return f"{m}:{s:02d}"


# ---------- HTTP ----------

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

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
        # 客户端断开（切歌/锁屏暂停）时静默结束，不刷 BrokenPipeError 日志
        try:
            with open(fp, "rb") as f:
                while True:
                    chunk = f.read(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path in ("/", "/api/health"):
            self._json(200, {"ok": True, "service": "music", "port": PORT,
                             "time": time.strftime("%Y-%m-%d %H:%M:%S")})
            return
        if u.path == "/api/tracks":
            c = db()
            # 可选：当前登录用户 id，用于返回其对每首歌的点赞状态 isLiked
            qs = urllib.parse.parse_qs(u.query)
            viewer_id = (qs.get("userId", [""])[0] or "").strip()
            rows = c.execute("""SELECT t.id,t.title,t.artist,t.album,t.cover,t.fname,t.size,t.dur,t.created,
                                t.play_count,t.like_count,t.share_count,t.user_id,
                                COALESCE(u.name,''),
                                (SELECT COUNT(*) FROM comments cm WHERE cm.track_id=t.id),
                                MAX(CASE WHEN l.user_id IS NOT NULL THEN 1 ELSE 0 END)
                                FROM tracks t
                                LEFT JOIN users u ON u.id=t.user_id
                                LEFT JOIN likes l ON l.track_id=t.id AND l.user_id=?
                                GROUP BY t.id
                                ORDER BY t.created DESC""", (viewer_id,)).fetchall()
            c.close()
            self._json(200, [{"id": r[0], "title": r[1], "artist": r[2], "album": r[3],
                              "cover": r[4], "fname": r[5], "size": r[6], "dur": r[7],
                              "durText": _fmt_dur(r[7]), "created": r[8],
                              "playCount": r[9] or 0, "likeCount": r[10] or 0,
                              "shareCount": r[11] or 0,
                              "userId": r[12] or "", "userName": r[13] or "",
                              "commentCount": r[14] or 0,
                              "isLiked": bool(r[15])} for r in rows])
            return
        if u.path.startswith("/api/cover/"):
            tid = u.path.rsplit("/", 1)[-1]
            c = db()
            row = c.execute("SELECT cover FROM tracks WHERE id=?", (tid,)).fetchone()
            c.close()
            if not row or not row[0]:
                self._json(404, {"err": "no cover"})
                return
            fp = os.path.join(FILES, row[0])
            if not os.path.exists(fp):
                self._json(404, {"err": "cover missing"})
                return
            self._serve_file(fp)
            return
        if u.path.startswith("/api/avatar/"):
            uid = u.path.rsplit("/", 1)[-1]
            c = db()
            row = c.execute("SELECT avatar FROM users WHERE id=?", (uid,)).fetchone()
            c.close()
            if not row or not row[0]:
                self._json(404, {"err": "no avatar"})
                return
            fp = os.path.join(FILES, row[0])
            if not os.path.exists(fp):
                self._json(404, {"err": "avatar missing"})
                return
            self._serve_file(fp)
            return
        if u.path.startswith("/api/background/"):
            uid = u.path.rsplit("/", 1)[-1]
            c = db()
            row = c.execute("SELECT background_image FROM users WHERE id=?", (uid,)).fetchone()
            c.close()
            if not row or not row[0]:
                self._json(404, {"err": "no background"})
                return
            fp = os.path.join(FILES, row[0])
            if not os.path.exists(fp):
                self._json(404, {"err": "background missing"})
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
        if u.path.startswith("/api/stream/"):
            tid = u.path.rsplit("/", 1)[-1]
            c = db()
            row = c.execute("SELECT fname FROM tracks WHERE id=?", (tid,)).fetchone()
            c.close()
            if not row:
                self._json(404, {"err": "not found"})
                return
            fp = os.path.join(FILES, row[0])
            if not os.path.exists(fp):
                self._json(404, {"err": "file missing"})
                return
            size = os.path.getsize(fp)
            rng = self.headers.get("Range")
            ctype = mimetypes.guess_type(fp)[0] or "audio/mpeg"
            if rng:
                try:
                    rng = rng.replace("bytes=", "").split("-")
                    start = int(rng[0]) if rng[0] else 0
                    end = int(rng[1]) if len(rng) > 1 and rng[1] else size - 1
                except Exception:
                    start, end = 0, size - 1
                end = min(end, size - 1)
                self.send_response(206)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
                self.send_header("Content-Length", str(end - start + 1))
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                try:
                    with open(fp, "rb") as f:
                        f.seek(start)
                        remain = end - start + 1
                        while remain > 0:
                            chunk = f.read(min(65536, remain))
                            if not chunk:
                                break
                            self.wfile.write(chunk)
                            remain -= len(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    pass
            else:
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
        self._json(404, {"err": "unknown"})

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

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        length = int(self.headers.get("Content-Length", 0))

        # ---------- 用户注册 ----------
        if u.path == "/api/register":
            try:
                if length <= 0 or length > 5 * 1024 * 1024:
                    self._json(413, {"err": "too large"})
                    return
                fields, files = self._parse_multipart(length)
                if fields is None:
                    self._json(400, {"err": "need multipart"})
                    return
                account = (fields.get("account") or "").strip()
                password = fields.get("password") or ""
                name = (fields.get("name") or "").strip() or account
                gender = (fields.get("gender") or "").strip()[:8]
                signature = (fields.get("signature") or "").strip()[:100]
                try:
                    age = int(fields.get("age") or 0)
                except Exception:
                    age = 0
                age = max(0, min(age, 150))
                if not account or not password:
                    self._json(400, {"err": "账号和密码不能为空"})
                    return
                c = db()
                dup = c.execute("SELECT 1 FROM users WHERE account=?", (account,)).fetchone()
                if dup:
                    c.close()
                    self._json(409, {"err": "账号已被注册"})
                    return
                uid = uuid.uuid4().hex
                avatar_fname = ""
                avatar = files.get("avatar")
                if avatar and avatar[1]:
                    aext = os.path.splitext(avatar[0])[1].lower()
                    if aext not in (".jpg", ".jpeg", ".png", ".webp", ".heic"):
                        aext = ".jpg"
                    avatar_fname = uid + "_avatar" + aext
                    with open(os.path.join(FILES, avatar_fname), "wb") as f:
                        f.write(avatar[1])
                bg_fname = ""
                bg = files.get("background")
                if bg and bg[1]:
                    bext = os.path.splitext(bg[0])[1].lower()
                    if bext not in (".jpg", ".jpeg", ".png", ".webp", ".heic"):
                        bext = ".jpg"
                    bg_fname = uid + "_bg" + bext
                    with open(os.path.join(FILES, bg_fname), "wb") as f:
                        f.write(bg[1])
                ip = client_ip(self)
                c.execute("""INSERT INTO users(id,account,password_hash,name,avatar,created,
                              gender,age,background_image,signature,ip_address)
                             VALUES(?,?,?,?,?,?,?,?,?,?,?)""",
                          (uid, account, hash_password(password), name, avatar_fname, time.time(),
                           gender, age, bg_fname, signature, ip))
                c.commit()
                row = c.execute("""SELECT id,account,password_hash,name,avatar,created,
                                  gender,age,background_image,signature,ip_address
                                  FROM users WHERE id=?""", (uid,)).fetchone()
                c.close()
                self._json(200, public_user(row))
            except Exception as e:
                self._json(500, {"err": "internal error: %s" % e})
            return

        # ---------- 用户登录 ----------
        if u.path == "/api/login":
            try:
                if length <= 0 or length > 64 * 1024:
                    self._json(413, {"err": "too large"})
                    return
                fields, files = self._parse_multipart(length)
                if fields is None:
                    self._json(400, {"err": "need multipart"})
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
                    self._json(401, {"err": "账号或密码错误"})
                    return
                # 每次登录自动更新当前 IP
                ip = client_ip(self)
                c.execute("UPDATE users SET ip_address=? WHERE id=?", (ip, row[0]))
                c.commit()
                row = c.execute("""SELECT id,account,password_hash,name,avatar,created,
                                 gender,age,background_image,signature,ip_address
                                 FROM users WHERE id=?""", (row[0],)).fetchone()
                c.close()
                self._json(200, public_user(row))
            except Exception as e:
                self._json(500, {"err": "internal error: %s" % e})
            return

        # ---------- 用户资料更新 ----------
        if u.path == "/api/profile/update":
            try:
                if length <= 0 or length > 8 * 1024 * 1024:
                    self._json(413, {"err": "too large"})
                    return
                fields, files = self._parse_multipart(length)
                if fields is None:
                    self._json(400, {"err": "need multipart"})
                    return
                account = (fields.get("account") or "").strip()
                if not account:
                    self._json(400, {"err": "缺少账号"})
                    return
                c = db()
                row = c.execute("SELECT id FROM users WHERE account=?", (account,)).fetchone()
                if not row:
                    c.close()
                    self._json(404, {"err": "账号不存在"})
                    return
                uid = row[0]
                name = (fields.get("name") or "").strip() or account
                gender = (fields.get("gender") or "").strip()[:8]
                signature = (fields.get("signature") or "").strip()[:100]
                try:
                    age = int(fields.get("age") or 0)
                except Exception:
                    age = 0
                age = max(0, min(age, 150))
                # 可选：换头像
                avatar_fname = None
                av = files.get("avatar")
                if av and av[1]:
                    aext = os.path.splitext(av[0])[1].lower()
                    if aext not in (".jpg", ".jpeg", ".png", ".webp", ".heic"):
                        aext = ".jpg"
                    avatar_fname = uid + "_avatar" + aext
                    with open(os.path.join(FILES, avatar_fname), "wb") as f:
                        f.write(av[1])
                # 可选：换背景图
                bg_fname = None
                bg = files.get("background")
                if bg and bg[1]:
                    bext = os.path.splitext(bg[0])[1].lower()
                    if bext not in (".jpg", ".jpeg", ".png", ".webp", ".heic"):
                        bext = ".jpg"
                    bg_fname = uid + "_bg" + bext
                    with open(os.path.join(FILES, bg_fname), "wb") as f:
                        f.write(bg[1])
                if avatar_fname and bg_fname:
                    c.execute("""UPDATE users SET name=?,gender=?,age=?,signature=?,
                                 avatar=?,background_image=?,ip_address=? WHERE id=?""",
                              (name, gender, age, signature, avatar_fname, bg_fname,
                               client_ip(self), uid))
                elif avatar_fname:
                    c.execute("""UPDATE users SET name=?,gender=?,age=?,signature=?,
                                 avatar=?,ip_address=? WHERE id=?""",
                              (name, gender, age, signature, avatar_fname,
                               client_ip(self), uid))
                elif bg_fname:
                    c.execute("""UPDATE users SET name=?,gender=?,age=?,signature=?,
                                 background_image=?,ip_address=? WHERE id=?""",
                              (name, gender, age, signature, bg_fname,
                               client_ip(self), uid))
                else:
                    c.execute("""UPDATE users SET name=?,gender=?,age=?,signature=?,
                                 ip_address=? WHERE id=?""",
                              (name, gender, age, signature, client_ip(self), uid))
                c.commit()
                row = c.execute("""SELECT id,account,password_hash,name,avatar,created,
                                  gender,age,background_image,signature,ip_address
                                  FROM users WHERE id=?""", (uid,)).fetchone()
                c.close()
                self._json(200, public_user(row))
            except Exception as e:
                self._json(500, {"err": "internal error: %s" % e})
            return

        # ---------- 播放量 +1 ----------
        if u.path.startswith("/api/play/"):
            tid = u.path.rsplit("/", 1)[-1]
            c = db()
            c.execute("UPDATE tracks SET play_count=play_count+1 WHERE id=?", (tid,))
            c.commit()
            row = c.execute("SELECT play_count FROM tracks WHERE id=?", (tid,)).fetchone()
            c.close()
            self._json(200, {"playCount": row[0] if row else 0})
            return

        # ---------- 点赞 / 取消 ----------
        if u.path.startswith("/api/like/"):
            tid = u.path.rsplit("/", 1)[-1]
            try:
                body = json.loads(self.rfile.read(length) or b"{}")
            except Exception:
                body = {}
            uid = (body.get("userId") or "").strip()
            if not uid:
                self._json(400, {"err": "need userId"})
                return
            c = db()
            ex = c.execute("SELECT 1 FROM likes WHERE user_id=? AND track_id=?", (uid, tid)).fetchone()
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
            return

        # ---------- 分享 +1 ----------
        if u.path.startswith("/api/share/"):
            tid = u.path.rsplit("/", 1)[-1]
            c = db()
            c.execute("UPDATE tracks SET share_count=share_count+1 WHERE id=?", (tid,))
            c.commit()
            row = c.execute("SELECT share_count FROM tracks WHERE id=?", (tid,)).fetchone()
            c.close()
            self._json(200, {"shareCount": row[0] if row else 0})
            return

        # ---------- 发表评论 ----------
        if u.path.startswith("/api/comment/"):
            tid = u.path.rsplit("/", 1)[-1]
            try:
                body = json.loads(self.rfile.read(length) or b"{}")
            except Exception:
                body = {}
            uid = (body.get("userId") or "").strip()
            uname = (body.get("userName") or "").strip()[:20]
            content = (body.get("content") or "").strip()[:200]
            if not uid or not content:
                self._json(400, {"err": "need userId and content"})
                return
            cid = uuid.uuid4().hex
            c = db()
            c.execute("INSERT INTO comments(id,track_id,user_id,user_name,content,created) VALUES(?,?,?,?,?,?)",
                      (cid, tid, uid, uname, content, time.time()))
            c.commit()
            c.close()
            self._json(200, {"id": cid})
            return

        # ---------- 歌曲上传 ----------
        if u.path != "/api/upload":
            self._json(404, {"err": "unknown"})
            return
        try:
            if length <= 0 or length > MAX_UPLOAD + 1024 * 1024:
                self._json(413, {"err": "too large"})
                return
            fields, files = self._parse_multipart(length)
            if fields is None:
                self._json(400, {"err": "need multipart"})
                return
            audio = files.get("file")
            if not audio or not audio[0]:
                self._json(400, {"err": "no file"})
                return
            filename, filedata = audio
            if len(filedata) > MAX_UPLOAD:
                self._json(413, {"err": "too large"})
                return
            ext = os.path.splitext(filename)[1].lower()
            if ext not in (".mp3", ".wav", ".m4a", ".aac", ".flac", ".ogg"):
                self._json(400, {"err": "unsupported audio type"})
                return
            tid = uuid.uuid4().hex
            stored = tid + ext
            fp = os.path.join(FILES, stored)
            with open(fp, "wb") as f:
                f.write(filedata)
            dur = audio_duration(fp)
            title = (fields.get("title") or os.path.splitext(filename)[0]).strip() or "未命名"
            cover_fname = ""
            cover = files.get("cover")
            if cover and cover[0]:
                cfn, cdata = cover
                cext = os.path.splitext(cfn)[1].lower()
                if cext not in (".jpg", ".jpeg", ".png", ".webp", ".heic"):
                    cext = ".jpg"
                cover_fname = tid + "_cover" + cext
                cpath = os.path.join(FILES, cover_fname)
                with open(cpath, "wb") as f:
                    f.write(cdata)
            c = db()
            uploader_id = (fields.get("userId") or "").strip()
            c.execute("""INSERT INTO tracks(id,title,artist,album,cover,fname,size,dur,created,user_id)
                         VALUES(?,?,?,?,?,?,?,?,?,?)""",
                      (tid, title, fields.get("artist", ""), fields.get("album", ""),
                       cover_fname, stored, len(filedata), dur, time.time(), uploader_id))
            c.commit()
            c.close()
            self._json(200, {"id": tid, "title": title, "cover": cover_fname,
                             "dur": dur, "durText": _fmt_dur(dur)})
        except Exception as e:
            self._json(500, {"err": "internal error: %s" % e})


if __name__ == "__main__":
    db().close()
    print("music server on", PORT)
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
