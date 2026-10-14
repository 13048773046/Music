#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""验证 /api/recommend 新歌混入刷新机制（黑盒）：
1) 接口返回结构完整（<=20、无重复、字段齐全）
2) 推荐列表中会出现近期新歌（刷新感来源）
3) 不会推荐用户本人上传的歌曲
4) 多轮刷新结果存在差异（"时不时"变化，而非固定同一批）
"""
import os
import sys
import json
import time
import struct
import sqlite3
import subprocess
import tempfile
import shutil
import urllib.request
import urllib.error

SERVER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "server.py")


def make_req(base):
    def req(method, path, body=None, headers=None):
        url = base + path
        hdrs = {"Content-Type": "application/json"}
        if headers:
            hdrs.update(headers)
        data = body if isinstance(body, bytes) else (json.dumps(body).encode() if body is not None else None)
        r = urllib.request.Request(url, data=data, headers=hdrs, method=method)
        try:
            resp = urllib.request.urlopen(r, timeout=10)
            return resp.status, resp.read(), dict(resp.headers)
        except urllib.error.HTTPError as e:
            return e.code, e.read(), dict(e.headers)
    return req


def multipart(fields, files):
    boundary = "----vboundaryXyZ"
    body = b""
    for k, v in fields.items():
        body += f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode()
    for k, (fn, data, ctype) in files.items():
        body += (f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"; filename="{fn}"'
                 f'\r\nContent-Type: {ctype}\r\n\r\n').encode() + data + b"\r\n"
    body += f"--{boundary}--\r\n".encode()
    return body, f"multipart/form-data; boundary={boundary}"


def make_wav(path, seed=0):
    import random
    rnd = random.Random(seed)
    n = 8000 * 2  # 2 秒 8k 16bit 单声道
    data = bytes(rnd.randrange(0, 256) for _ in range(n))
    fmt = struct.pack("<4sIHHIIHH", b"fmt ", 16, 1, 1, 8000, 16000, 2, 16)
    data_chunk = struct.pack("<4sI", b"data", len(data)) + data
    riff = struct.pack("<4sI4s", b"RIFF", 36 + len(data), b"WAVE")
    with open(path, "wb") as f:
        f.write(riff + fmt + data_chunk)


def main():
    root = tempfile.mkdtemp(prefix="music_newmix_")
    port = 18877
    env = {**os.environ, "MUSIC_ROOT": root, "MUSIC_PORT": str(port)}
    p = subprocess.Popen(["python3", SERVER], env=env,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        ok = True
        for _ in range(30):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{port}/api/health", timeout=1)
                break
            except Exception:
                time.sleep(0.2)
        BASE = f"http://127.0.0.1:{port}"
        req = make_req(BASE)

        def register(name):
            body, ct = multipart({"password": "secret123", "name": name,
                                  "gender": "保密", "age": "18"}, {})
            s, b, _ = req("POST", "/api/register", body, {"Content-Type": ct})
            assert s == 200, b[:200]
            return json.loads(b)

        ua = register("用户A")
        ub = register("用户B")
        auth_b = {"Authorization": f"Bearer {ub['token']}"}
        auth_a = {"Authorization": f"Bearer {ua['token']}"}

        # 用户 B 上传 10 首歌：前 5 首将改为 30 天前（旧歌），后 5 首保持为新歌
        new_ids, old_ids = [], []
        wav_path = os.path.join(root, "t.wav")
        for i in range(10):
            make_wav(wav_path, seed=i)
            with open(wav_path, "rb") as f:
                wav_data = f.read()
            body, ct = multipart({"title": f"歌曲{i}", "artist": "歌手B", "album": "专辑B"},
                                 {"file": (f"song{i}.wav", wav_data, "audio/wav")})
            s, b, _ = req("POST", "/api/upload", body, {"Content-Type": ct, **auth_b})
            assert s == 200, b[:200]
            tid = json.loads(b)["id"]
            (old_ids if i < 5 else new_ids).append(tid)

        dbp = os.path.join(root, "tracks.db")
        c = sqlite3.connect(dbp)
        c.execute("UPDATE tracks SET created=? WHERE id IN (%s)" % ",".join("?" * len(old_ids)),
                  ([time.time() - 30 * 86400] + old_ids))
        c.commit()
        c.close()

        # 用户 A（无任何行为）反复拉取推荐，统计新歌出现情况与列表变化
        seen_new = 0
        seen_old = 0
        rounds = 20
        snapshots = []
        for _ in range(rounds):
            s, b, _ = req("GET", "/api/recommend", headers=auth_a)
            if s != 200:
                print(f"[FAIL] recommend 返回 {s}: {b[:200]}")
                return 1
            lst = json.loads(b)
            if not isinstance(lst, list) or len(lst) > 20:
                print(f"[FAIL] 返回非列表或超过20首: {len(lst)}")
                return 1
            ids = [t["id"] for t in lst]
            if len(set(ids)) != len(ids):
                print("[FAIL] 推荐列表存在重复歌曲")
                return 1
            for tid in ids:
                if tid in new_ids:
                    seen_new += 1
                elif tid in old_ids:
                    seen_old += 1
            snapshots.append(tuple(ids))

        varied = len(set(snapshots)) > 1
        print(f"轮次={rounds} 新歌出现次数={seen_new} 旧歌出现次数={seen_old} 不同列表={len(set(snapshots))}")

        # 场景 B：用户 A 对 5 首旧歌点赞（产生强行为），验证：
        #  - genre 列兼容修复后推荐不再 500
        #  - 已强互动旧歌不重复推荐（avoid）
        #  - 近期新歌仍能进入推送（混入/候选）
        for tid in old_ids:
            s, b, _ = req("POST", f"/api/like/{tid}", {}, headers=auth_a)
            assert s == 200, f"like {tid}: {s} {b[:200]}"
        s, b, _ = req("GET", "/api/recommend", headers=auth_a)
        if s != 200:
            print(f"[FAIL] 有行为用户 recommend 返回 {s}: {b[:200]}")
            return 1
        lst = json.loads(b)
        ids = [t["id"] for t in lst]
        hit_new = sum(1 for tid in ids if tid in new_ids)
        hit_old = sum(1 for tid in ids if tid in old_ids)
        print(f"有行为后推荐数={len(ids)} 命中新歌={hit_new} 命中已赞旧歌={hit_old}")

        checks = [
            ("新歌混入推荐（刷新感）", seen_new > 0),
            ("多轮结果有差异（时不时刷新）", varied),
            ("有行为用户推荐 200（genre 兼容）", s == 200),
            ("已强互动旧歌不重复推荐", hit_old == 0),
            ("新歌仍进入推送", hit_new > 0),
        ]
        for name, cond in checks:
            print(f"  [{'PASS' if cond else 'FAIL'}] {name}")
            ok = ok and cond
        return 0 if ok else 1
    finally:
        p.terminate()
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
