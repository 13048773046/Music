#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""音乐后端：上传 / 列表 / 流式播放 / 音频时长解析。
纯标准库，监听 127.0.0.1:8788。兼容原 tracks.db 表结构。"""
import os, json, sqlite3, time, uuid, mimetypes, urllib.parse, struct
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = "/www/wwwroot/music"
FILES = os.path.join(ROOT, "files")
DB = os.path.join(ROOT, "tracks.db")
PORT = 8788
MAX_UPLOAD = 50 * 1024 * 1024  # 50MB

os.makedirs(FILES, exist_ok=True)


def db():
    c = sqlite3.connect(DB)
    c.execute("""CREATE TABLE IF NOT EXISTS tracks(
        id TEXT PRIMARY KEY, title TEXT, artist TEXT, album TEXT,
        fname TEXT, size INTEGER, dur REAL, created REAL)""")
    return c


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
            rows = c.execute("SELECT id,title,artist,album,fname,size,dur,created FROM tracks ORDER BY created DESC").fetchall()
            c.close()
            self._json(200, [{"id": r[0], "title": r[1], "artist": r[2], "album": r[3],
                              "fname": r[4], "size": r[5], "dur": r[6],
                              "durText": _fmt_dur(r[6]), "created": r[7]} for r in rows])
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
                with open(fp, "rb") as f:
                    f.seek(start)
                    remain = end - start + 1
                    while remain > 0:
                        chunk = f.read(min(65536, remain))
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        remain -= len(chunk)
            else:
                self.send_response(200)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(size))
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                with open(fp, "rb") as f:
                    while True:
                        chunk = f.read(65536)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
            return
        self._json(404, {"err": "unknown"})

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        if u.path != "/api/upload":
            self._json(404, {"err": "unknown"})
            return
        ctype = self.headers.get("Content-Type", "")
        if not ctype.startswith("multipart/form-data"):
            self._json(400, {"err": "need multipart"})
            return
        try:
            boundary = ctype.split("boundary=")[-1].encode()
            length = int(self.headers.get("Content-Length", 0))
            if length <= 0 or length > MAX_UPLOAD + 1024 * 1024:
                self._json(413, {"err": "too large"})
                return
            data = self.rfile.read(length)
            parts = data.split(b"--" + boundary)
            fields, filename, filedata = {}, None, None
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
                if fn:
                    filename = fn
                    filedata = body
                elif name:
                    fields[name] = body.decode("utf-8", "ignore")
            if not filedata or not filename:
                self._json(400, {"err": "no file"})
                return
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
            c = db()
            c.execute("INSERT INTO tracks(id,title,artist,album,fname,size,dur,created) VALUES(?,?,?,?,?,?,?,?)",
                      (tid, title, fields.get("artist", ""), fields.get("album", ""),
                       stored, len(filedata), dur, time.time()))
            c.commit()
            c.close()
            self._json(200, {"id": tid, "title": title, "dur": dur, "durText": _fmt_dur(dur)})
        except Exception as e:
            self._json(500, {"err": "internal error: %s" % e})


if __name__ == "__main__":
    db().close()
    print("music server on", PORT)
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
