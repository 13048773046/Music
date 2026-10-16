#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""下载脚本 v2：对 play_url 为空的采集歌曲，bridge 取地址下载到本地，ID3 年份过滤 2020-2026。
不符合年份的删除记录和文件。"""
import sqlite3, urllib.request, ssl, os, time, json, re, urllib.parse

# 默认与历史线上完全一致；可用 MUSIC_ROOT / BRIDGE_PORT 覆盖（隔离演练用）。
ROOT = os.environ.get("MUSIC_ROOT", "/www/wwwroot/music")
DB = os.path.join(ROOT, "tracks.db")
FILES = os.path.join(ROOT, "files")
BRIDGE = "http://127.0.0.1:%d" % int(os.environ.get("BRIDGE_PORT", "8789"))
MIN_SIZE = 300 * 1024
YEAR_MIN, YEAR_MAX = 2020, 2026

def make_ctx():
    """按发行版探测 CA 证书路径（CentOS/Ubuntu/通用），全部失败则降级不校验（仅用于下载公开音频流）"""
    for cafile in ("/etc/pki/tls/certs/ca-bundle.crt",
                   "/etc/ssl/certs/ca-certificates.crt",
                   "/etc/ssl/ca-bundle.pem"):
        try:
            return ssl.create_default_context(cafile=cafile)
        except Exception:
            continue
    return ssl._create_unverified_context()

def br(path, params):
    url = BRIDGE + path + "?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.loads(r.read().decode())

def extract_year(fp):
    """从 mp3 ID3v2 标签提取发行年份，返回 None 表示未知（放行）"""
    try:
        with open(fp, "rb") as f:
            head = f.read(65536)
        if not head.startswith(b"ID3"):
            return None
        for tag in (b"TDRC", b"TYER"):
            i = head.find(tag)
            if i < 0: continue
            data = head[i+10:i+10+200]
            m = re.search(rb"(19|20)\d{2}", data)
            if m:
                return int(m.group(0))
        return None
    except Exception:
        return None

c = sqlite3.connect(DB, timeout=30)
rows = c.execute("SELECT id, source, source_id, title, artist FROM collected_tracks WHERE play_url='' OR play_url IS NULL").fetchall()
print("待下载:", len(rows), flush=True)

ok = dropped = fail = skip = 0
for tid, src, sid, title, artist in rows:
    local = os.path.join(FILES, tid + ".mp3")
    if os.path.exists(local) and os.path.getsize(local) > MIN_SIZE:
        skip += 1; continue
    # 取地址
    url = ""
    for attempt in range(2):
        try:
            r = br("/song", {"source": src, "songmid": sid, "name": title,
                             "singer": artist or "", "album": "", "interval": "0", "img": ""})
            url = r.get("url") or ""
            if url and not str(url).startswith("ERR"): break
        except Exception:
            pass
        time.sleep(2)
    if not url or str(url).startswith("ERR"):
        fail += 1
        c.execute("DELETE FROM collected_tracks WHERE id=?", (tid,))
        c.commit()
        print("[fail-url 删除] %s - %s" % (title, artist), flush=True)
        continue
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=60, context=make_ctx()) as r:
            data = r.read()
        if len(data) < MIN_SIZE:
            fail += 1
            c.execute("DELETE FROM collected_tracks WHERE id=?", (tid,))
            c.commit()
            print("[fail-size 删除] %s %dB" % (title, len(data)), flush=True)
            continue
        with open(local, "wb") as f:
            f.write(data)
        year = extract_year(local)
        if year is not None and (year < YEAR_MIN or year > YEAR_MAX):
            os.remove(local)
            c.execute("DELETE FROM collected_tracks WHERE id=?", (tid,))
            c.commit()
            dropped += 1
            print("[drop %d] %d年 %s - %s" % (dropped, year, title, artist), flush=True)
            continue
        c.execute("UPDATE collected_tracks SET play_url=? WHERE id=?", (tid + ".mp3", tid))
        c.commit()
        ok += 1
        ystr = str(year) if year else "未知"
        print("[+%d] %s年 | %s - %s %dKB" % (ok, ystr, title, artist, len(data)//1024), flush=True)
    except Exception as e:
        fail += 1
        c.execute("DELETE FROM collected_tracks WHERE id=?", (tid,))
        c.commit()
        print("[fail-dl 删除] %s %s" % (title, str(e)[:60]), flush=True)
    time.sleep(1.2)
c.close()
print("DONE ok=%d dropped=%d fail=%d skip=%d" % (ok, dropped, fail, skip), flush=True)
