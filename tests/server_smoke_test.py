#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""server.py 冒烟测试（可独立运行，也可接入 CI）：
覆盖注册/登录/token/旧哈希迁移/上传魔数/Range 边界/鉴权（兼容+严格模式）/限流/路径穿越。

用法：
    python3 tests/server_smoke_test.py                 # 默认端口 18788，临时数据目录
    python3 tests/server_smoke_test.py --port 18788 --root /tmp/music_test/data
"""
import os
import sys
import json
import time
import struct
import socket
import base64
import shutil
import tempfile
import argparse
import urllib.request
import urllib.error
import urllib.parse
import subprocess
import hashlib
import sqlite3

SERVER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "server.py")
PASS = 0
FAIL = 0


def check(name, cond, extra=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  [PASS] {name}")
    else:
        FAIL += 1
        print(f"  [FAIL] {name} {extra}")


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


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def req_no_redirect(base, method, path, headers=None):
    """不跟随重定向的请求（用于验证 302 及其 Location）。"""
    r = urllib.request.Request(base + path, headers=headers or {}, method=method)
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        resp = opener.open(r, timeout=10)
        return resp.status, resp.read(), dict(resp.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers)


def multipart(fields, files):
    boundary = "----testboundaryXyZ"
    body = b""
    for k, v in fields.items():
        body += f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode()
    for k, (fn, data, ctype) in files.items():
        body += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"; "
                 f"filename=\"{fn}\"\r\nContent-Type: {ctype}\r\n\r\n").encode() + data + b"\r\n"
    body += f"--{boundary}--\r\n".encode()
    return body, f"multipart/form-data; boundary={boundary}"


def make_wav(path, seconds=1):
    sr = 8000
    n = sr * seconds
    data = b"\x00\x80" * n
    fmt = struct.pack("<4sIHHIIHH", b"fmt ", 16, 1, 1, sr, sr * 2, 2, 16)
    data_chunk = struct.pack("<4sI", b"data", len(data)) + data
    riff = struct.pack("<4sI4s", b"RIFF", 36 + len(data), b"WAVE")
    with open(path, "wb") as f:
        f.write(riff + fmt + data_chunk)


def start_server(root, port, strict=False):
    os.makedirs(root, exist_ok=True)
    env = {**os.environ, "MUSIC_ROOT": root, "MUSIC_PORT": str(port)}
    if strict:
        env["MUSIC_AUTH_STRICT"] = "1"
        env["MUSIC_SIGN_STRICT"] = "1"
    p = subprocess.Popen(["python3", SERVER], env=env,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(20):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/api/health", timeout=1)
            return p
        except Exception:
            time.sleep(0.2)
    p.kill()
    raise RuntimeError("server failed to start")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=18788)
    ap.add_argument("--root", default=None)
    args = ap.parse_args()
    port = args.port
    root = args.root or tempfile.mkdtemp(prefix="music_test_")
    strict_port = port + 1
    strict_root = root + "_strict"

    proc = start_server(root, port)
    strict_proc = start_server(strict_root, strict_port, strict=True)
    try:
        run_all(port, root, strict_port, strict_root)
    finally:
        proc.terminate()
        strict_proc.terminate()
        shutil.rmtree(root, ignore_errors=True)
        shutil.rmtree(strict_root, ignore_errors=True)

    print(f"\n===== 结果: {PASS} 通过, {FAIL} 失败 =====")
    sys.exit(1 if FAIL else 0)


def run_all(port, root, strict_port, strict_root):
    BASE = f"http://127.0.0.1:{port}"
    req = make_req(BASE)

    print("== 1. 健康检查 ==")
    s, body, _ = req("GET", "/api/health")
    check("health 200", s == 200)
    check("health json", json.loads(body).get("ok") is True, body[:100])

    print("== 2. 注册（账号由后端自动生成 6 位数字）==")
    body, ct = multipart({"password": "secret123",
                          "name": "测试用户", "gender": "保密", "age": "18",
                          "signature": "hello"}, {})
    s, body, _ = req("POST", "/api/register", body, {"Content-Type": ct})
    u = json.loads(body)
    check("register 200", s == 200, body[:200])
    check("register 返回 token", bool(u.get("token")), body[:200])
    acc = u.get("account", "")
    check("register 账号为6位数字", len(acc) == 6 and acc.isdigit(), body[:200])
    token = u.get("token", "")
    uid = u.get("id", "")
    AUTH = {"Authorization": f"Bearer {token}"}

    print("== 3. 弱密码拒绝 ==")
    body, ct = multipart({"password": "123"}, {})
    s, body, _ = req("POST", "/api/register", body, {"Content-Type": ct})
    check("弱密码 400", s == 400, body[:100])

    print("== 4. 登录（新 token）==")
    body, ct = multipart({"account": acc, "password": "secret123"}, {})
    s, body, _ = req("POST", "/api/login", body, {"Content-Type": ct})
    u2 = json.loads(body)
    check("login 200 且新 token", s == 200 and u2.get("token") and u2["token"] != token, body[:100])

    print("== 5. 错误密码 401 ==")
    body, ct = multipart({"account": acc, "password": "wrongpass"}, {})
    s, body, _ = req("POST", "/api/login", body, {"Content-Type": ct})
    check("错误密码 401", s == 401)

    print("== 6. 旧版哈希（v1 120000 轮）自动迁移 ==")
    salt = "a" * 32
    h = hashlib.pbkdf2_hmac("sha256", b"legacy123", bytes.fromhex(salt), 120000).hex()
    legacy = f"{salt}${h}"
    db_path = os.path.join(root, "tracks.db")
    conn = sqlite3.connect(db_path)
    conn.execute("INSERT OR IGNORE INTO users(id,account,password_hash,name,avatar,created) "
                 "VALUES('legacy_uid','legacy_user',?,'旧用户','',0)", (legacy,))
    conn.commit()
    conn.close()
    body, ct = multipart({"account": "legacy_user", "password": "legacy123"}, {})
    s, body, _ = req("POST", "/api/login", body, {"Content-Type": ct})
    check("旧哈希登录成功", s == 200, body[:100])
    conn = sqlite3.connect(db_path)
    new_hash = conn.execute("SELECT password_hash FROM users WHERE account='legacy_user'").fetchone()[0]
    conn.close()
    check("旧哈希已迁移为 v2(三段)", new_hash.count("$") == 2, new_hash)

    print("== 7. 上传合法 WAV ==")
    wav_path = tempfile.mktemp(suffix=".wav")
    make_wav(wav_path, 1)
    with open(wav_path, "rb") as f:
        wav_data = f.read()
    body, ct = multipart({"title": "测试歌曲", "artist": "测试歌手", "album": "测试专辑"},
                         {"file": ("song.wav", wav_data, "audio/wav")})
    s, body, _ = req("POST", "/api/upload", body, {"Content-Type": ct, **AUTH})
    up = json.loads(body)
    check("上传 200", s == 200, body[:200])
    tid = up.get("id", "")
    check("时长解析 >0", up.get("dur", 0) > 0, body[:200])

    print("== 8. 上传伪装 mp3（魔数校验）==")
    fake = b"NOTAUDIO" * 100
    body, ct = multipart({"title": "假歌"}, {"file": ("fake.mp3", fake, "audio/mpeg")})
    s, body, _ = req("POST", "/api/upload", body, {"Content-Type": ct, **AUTH})
    check("伪 mp3 400", s == 400, f"s={s} {body[:100]}")

    print("== 9. 未登录上传 401 ==")
    body, ct = multipart({"title": "匿名"}, {"file": ("song.wav", wav_data, "audio/wav")})
    s, body, _ = req("POST", "/api/upload", body, {"Content-Type": ct})
    check("匿名上传 401", s == 401, body[:100])
    s, body, _ = req("POST", "/api/upload")
    check("空 body 上传 400", s == 400, f"s={s} {body[:100]}")

    print("== 10. 歌曲列表 ==")
    s, body, _ = req("GET", "/api/tracks", headers=AUTH)
    tracks = json.loads(body)
    check("tracks 200 且含新歌", s == 200 and any(t["id"] == tid for t in tracks), body[:100])
    check("tracks 返回 isLiked", all("isLiked" in t for t in tracks))

    print("== 10.5 搜索相关流 tracks?q= ==")
    # 测试歌曲 title=测试歌曲 / artist=测试歌手，q=测试 应命中
    s, body, _ = req("GET", "/api/tracks?q=%E6%B5%8B%E8%AF%95", headers=AUTH)
    tracks_q = json.loads(body)
    check("tracks?q= 200", s == 200, f"s={s}")
    check("相关歌曲（歌名/歌手匹配）在结果中", any(t["id"] == tid for t in tracks_q), body[:100])
    check("相关流 isLiked 字段完整", all("isLiked" in t for t in tracks_q))
    # 完全不存在的关键词：无相关歌曲时补全随机（接口不报错、仍返回列表）
    s, body, _ = req("GET", "/api/tracks?q=%E4%B8%8D%E5%AD%98%E5%9C%A8%E7%9A%84%E8%AF%8D", headers=AUTH)
    tracks_none = json.loads(body)
    check("无相关歌曲时补全随机返回", s == 200 and isinstance(tracks_none, list)
          and len(tracks_none) > 0, f"s={s} {body[:100]}")

    print("== 10.6 个性化推荐（多路召回 + MMR 重排）==")
    # 预置 5 首不同歌手的采集歌种子数据（归属非当前测试用户，验证排除本人上传）
    conn = sqlite3.connect(os.path.join(root, "tracks.db"))
    _now = time.time()
    for r in [
        ("rec_1", "晴天", "周杰伦", "叶惠美", "", 240, "gd", "gd_1", "", 0, _now, "rec_owner", 50, 20, 5, "", 0, "流行"),
        ("rec_2", "七里香", "周杰伦", "七里香", "", 250, "gd", "gd_2", "", 0, _now, "rec_owner", 30, 15, 3, "", 0, "流行"),
        ("rec_3", "海阔天空", "Beyond", "乐与怒", "", 300, "gd", "gd_3", "", 0, _now - 100, "rec_owner", 40, 10, 2, "", 0, "摇滚"),
        ("rec_4", "后来", "刘若英", "我等你", "", 280, "gd", "gd_4", "", 0, _now - 200, "rec_owner", 20, 8, 1, "", 0, "流行"),
        ("rec_5", "平凡之路", "朴树", "猎户星座", "", 260, "gd", "gd_5", "", 0, _now - 300, "rec_owner", 10, 5, 1, "", 0, "民谣"),
    ]:
        conn.execute(
            "INSERT OR IGNORE INTO collected_tracks"
            "(id,title,artist,album,cover,duration,source,source_id,play_url,size,created,"
            "user_id,play_count,like_count,share_count,lrc,offline,genre)"
            " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", r)
    conn.commit()
    conn.close()
    s, body, _ = req("GET", "/api/recommend", headers=AUTH)
    rec = json.loads(body)
    check("recommend 200", s == 200, f"s={s} {body[:100]}")
    check("recommend 非空（多路召回兜底）", isinstance(rec, list) and len(rec) >= 1, body[:100])
    check("recommend 返回列表且<=20", isinstance(rec, list) and len(rec) <= 20, body[:100])
    check("recommend 无重复歌曲", len({t["id"] for t in rec}) == len(rec), body[:100])
    check("recommend 不含本人上传", all(t["userId"] != uid for t in rec), body[:100])
    check("recommend 字段完整", all(all(k in t for k in ("id", "title", "artist", "album",
          "created", "durText", "playCount", "likeCount")) for t in rec), body[:100])
    check("recommend 带推荐理由标签", all("reason" in t and t["reason"] for t in rec), body[:100])
    check("recommend 多歌手多样性（MMR 重排）",
          len({t.get("artist") for t in rec if t.get("artist")}) >= 2,
          f"artists={sorted({t.get('artist') for t in rec if t.get('artist')})}")
    # 未登录：热度 + 新歌 + 随机三路兜底，同样返回非空且无重复
    s, body, _ = req("GET", "/api/recommend")
    rec2 = json.loads(body)
    check("未登录 recommend 非空", s == 200 and isinstance(rec2, list) and len(rec2) >= 1,
          f"s={s} {body[:100]}")
    check("未登录 recommend 无重复", len({t["id"] for t in rec2}) == len(rec2), body[:100])
    # exclude：推荐流无限续推防重复——已推荐过的歌曲不再出现在下一批
    _rec_ids = [t["id"] for t in rec]
    _excl_q = urllib.parse.quote(",".join(_rec_ids))
    s, body, _ = req("GET", f"/api/recommend?exclude={_excl_q}", headers=AUTH)
    rec3 = json.loads(body)
    check("recommend exclude 排除已推荐", s == 200 and isinstance(rec3, list)
          and all(t["id"] not in set(_rec_ids) for t in rec3), f"s={s} {body[:100]}")

    print("== 11. 流式 Range ==")
    s, body, hdrs = req("GET", f"/api/stream/{tid}", headers={"Range": "bytes=0-99"})
    check("Range 206", s == 206 and len(body) == 100, f"s={s} len={len(body)}")
    check("Content-Range 正确", hdrs.get("Content-Range", "").startswith("bytes 0-99/"), hdrs)
    s, body, hdrs = req("GET", f"/api/stream/{tid}", headers={"Range": "bytes=-50"})
    check("suffix range 206 50字节", s == 206 and len(body) == 50, f"s={s} len={len(body)}")
    s, body, hdrs = req("GET", f"/api/stream/{tid}", headers={"Range": "bytes=999999-"})
    check("越界 range 416", s == 416, f"s={s}")
    check("416 带 Content-Range */", "bytes */" in hdrs.get("Content-Range", ""), hdrs)
    s, body, hdrs = req("GET", f"/api/stream/{tid}", headers={"Range": "bytes=abc"})
    check("非法 range 回退 200", s == 200, f"s={s}")
    s, body, hdrs = req("GET", f"/api/stream/{tid}")
    check("全量 200", s == 200 and len(body) > 100, f"s={s}")

    print("== 11.5 流签名 URL ==")
    s, body, _ = req("GET", f"/api/stream-url/{tid}")
    sign = json.loads(body)
    check("stream-url 200 返回 sig/exp", s == 200 and sign.get("sig") and sign.get("exp"), body[:100])
    s, body, _ = req("GET", f"/api/stream/{tid}?exp={sign['exp']}&sig={sign['sig']}",
                     headers={"Range": "bytes=0-9"})
    check("带签名 206", s == 206 and len(body) == 10, f"s={s}")
    s, body, _ = req("GET", f"/api/stream/{tid}?exp={int(time.time())-120}&sig={sign['sig']}")
    check("过期签名 403", s == 403, f"s={s}")
    s, body, _ = req("GET", f"/api/stream/{tid}?exp={sign['exp']}&sig=deadbeefdeadbeefdeadbeefdeadbeef")
    check("错误签名 403", s == 403, f"s={s}")
    s, body, _ = req("GET", f"/api/stream/{tid}")
    check("兼容模式无签名 200", s == 200, f"s={s}")
    s, body, _ = req("GET", "/api/stream-url/not_exist_id")
    check("stream-url 不存在歌曲 404", s == 404, f"s={s}")

    print("== 12. 路径穿越 ==")
    s, body, _ = req("GET", "/api/stream/..%2F..%2Fetc%2Fpasswd")
    check("路径穿越 404", s == 404, f"s={s}")
    s, body, _ = req("GET", "/api/cover/../../etc/passwd")
    check("cover 路径穿越 404", s == 404, f"s={s}")

    print("== 13. 点赞 / 评论 / 分享 / 播放 ==")
    s, body, _ = req("POST", f"/api/like/{tid}", {"userId": uid}, AUTH)
    like = json.loads(body)
    check("点赞 200 liked=true", s == 200 and like.get("liked") is True, body[:100])
    s, body, _ = req("POST", f"/api/like/{tid}", {"userId": uid}, AUTH)
    like = json.loads(body)
    check("取消赞 liked=false", like.get("liked") is False)
    s, body, _ = req("POST", f"/api/comment/{tid}", {"userId": uid, "userName": "测试用户",
                                                     "content": "非常好听！"}, AUTH)
    check("评论 200", s == 200, body[:100])
    s, body, _ = req("GET", f"/api/comments/{tid}")
    comments = json.loads(body)
    check("评论列表含新评论", any(c["content"] == "非常好听！" for c in comments), body[:100])
    s, body, _ = req("POST", f"/api/share/{tid}", None, AUTH)
    check("分享 200", s == 200 and json.loads(body).get("shareCount", 0) >= 1, body[:100])
    s, body, _ = req("POST", f"/api/play/{tid}", None, AUTH)
    check("播放量+1", s == 200 and json.loads(body).get("playCount", 0) >= 1, body[:100])

    print("== 14. 鉴权边界 ==")
    s, body, _ = req("POST", f"/api/like/{tid}", {}, AUTH)
    check("token 但缺 userId 点赞 200", s == 200, f"s={s}")
    s, body, _ = req("POST", f"/api/like/{tid}", {"userId": uid})
    check("兼容模式：userId-only 点赞 200", s == 200, f"s={s}")
    s, body, _ = req("POST", f"/api/like/{tid}", {})
    check("完全无身份点赞 401", s == 401, f"s={s}")
    s, body, _ = req("POST", f"/api/comment/{tid}", {"userId": uid, "userName": "x", "content": "hi"})
    check("兼容模式：userId-only 评论 200", s == 200, f"s={s}")
    s, body, _ = req("POST", f"/api/comment/{tid}", {})
    check("完全无身份评论 401", s == 401, f"s={s}")

    print("== 14.5 评论控制字符过滤 ==")
    s, body, _ = req("POST", f"/api/comment/{tid}", {"userId": uid, "userName": "x",
                                                     "content": "hi\x00\x01world"}, AUTH)
    check("控制字符评论 200", s == 200, body[:100])

    print("== 15. 严格模式（MUSIC_AUTH_STRICT=1）==")
    BASE_S = f"http://127.0.0.1:{strict_port}"
    req_s = make_req(BASE_S)
    body, ct = multipart({"account": "strict_user", "password": "secret123", "name": "严格"}, {})
    s, body, _ = req_s("POST", "/api/register", body, {"Content-Type": ct})
    su = json.loads(body)
    strict_token = su.get("token", "")
    wav2 = tempfile.mktemp(suffix=".wav")
    make_wav(wav2, 1)
    with open(wav2, "rb") as f:
        wav2_data = f.read()
    body, ct = multipart({"title": "严格歌"}, {"file": ("s.wav", wav2_data, "audio/wav")})
    s, body, _ = req_s("POST", "/api/upload", body, {"Content-Type": ct,
                                                  "Authorization": f"Bearer {strict_token}"})
    strict_tid = json.loads(body).get("id", "")
    check("严格模式：带 token 上传 200", s == 200, body[:100])
    s, body, _ = req_s("POST", f"/api/like/{strict_tid}", {"userId": su.get("id", "")})
    check("严格模式：userId-only 点赞 401", s == 401, f"s={s}")
    s, body, _ = req_s("POST", f"/api/like/{strict_tid}", {},
                    {"Authorization": f"Bearer {strict_token}"})
    check("严格模式：token 点赞 200", s == 200, f"s={s}")
    s, body, _ = req_s("POST", f"/api/like/{strict_tid}", {"userId": su.get("id", "")})
    check("严格模式：伪装 userId 点赞 401", s == 401, f"s={s}")
    s, body, _ = req_s("GET", "/api/tracks")
    check("严格模式：tracks 免鉴权可读", s == 200, f"s={s}")
    s, body, _ = req_s("GET", f"/api/stream/{strict_tid}")
    check("严格模式：无签名流 403", s == 403, f"s={s}")
    s, body, _ = req_s("GET", f"/api/stream-url/{strict_tid}")
    ss = json.loads(body)
    s, body, _ = req_s("GET", f"/api/stream/{strict_tid}?exp={ss['exp']}&sig={ss['sig']}")
    check("严格模式：带签名流 200", s == 200, f"s={s}")

    print("== 16. 图片魔数校验 ==")
    body, ct = multipart({"account": "img_user", "password": "secret123", "name": "图"},
                         {"avatar": ("a.jpg", b"NOTJPEGDATA", "image/jpeg")})
    s, body, _ = req("POST", "/api/register", body, {"Content-Type": ct})
    check("伪图片头像注册 400", s == 400, f"s={s} {body[:100]}")

    print("== 16.5 分享 H5 页面（汽水风格短链 + OG 卡片）==")
    s, body, _ = req("GET", f"/api/share-url/{tid}")
    st = json.loads(body)
    check("share-url 200 返回 token+code", s == 200 and st.get("token") and st.get("code"), body[:100])
    check("短码为 8 位 base62", len(st.get("code", "")) == 8 and st["code"].isalnum(), st.get("code"))
    s2, body2, _ = req("GET", f"/api/share-url/{tid}")
    st2 = json.loads(body2)
    check("share-url 幂等（同 token 同 code）", st2.get("token") == st.get("token") and st2.get("code") == st.get("code"))
    s, body, hdrs = req_no_redirect(BASE, "GET", f"/s/{st['code']}/")
    check("短链 302 跳转落地页", s == 302 and "/music/api/share/" in hdrs.get("Location", ""), f"s={s} loc={hdrs.get('Location')}")
    s, page, hdrs = req("GET", f"/api/share/{st['token']}")
    html = page.decode("utf-8", "ignore")
    check("share 页面 200 text/html", s == 200 and "text/html" in hdrs.get("Content-Type", ""), f"s={s} ct={hdrs.get('Content-Type')}")
    check("OG 卡片 og:title 为《歌名》@流萤音乐", "og:title" in html and "《测试歌曲》@流萤音乐" in html, html[:300])
    check("OG 卡片 og:site_name 流萤音乐", 'og:site_name" content="流萤音乐"' in html)
    check("分享页含播放器", "playbtn" in html and "stream-url" in html)
    s, body, _ = req("GET", "/s/badcode1/")
    check("短链无效 code 404", s == 404, f"s={s}")
    s, body, _ = req("GET", "/api/share/bad_token_123")
    check("share 无效 token 404", s == 404, f"s={s}")

    print("== 17. 官方通知管理（发布→用户通知→删除级联清理）==")
    ADMIN = {"X-Admin-Token": "liuying-admin-8f3a"}   # 测试环境 admin_pwd 文件不存在，走默认值
    s, body, _ = req("GET", "/api/admin/official-messages", headers=ADMIN)
    om0 = json.loads(body)
    check("admin 官方通知列表 200", s == 200 and isinstance(om0.get("list"), list), body[:100])
    s, body, _ = req("GET", "/api/admin/official-messages")
    check("官方通知列表无 admin token 401", s == 401, f"s={s}")
    s, body, _ = req("POST", "/api/admin/official-message",
                     {"content": "冒烟测试官方通知"}, ADMIN)
    om1 = json.loads(body)
    omid = om1.get("id", "")
    check("发布官方通知 200 返回 id", s == 200 and omid, body[:100])
    s, body, _ = req("GET", "/api/official-messages")
    oml = json.loads(body)
    check("用户端官方通知列表含新消息", s == 200 and any(m["id"] == omid for m in oml.get("list", [])), body[:100])
    s, body, _ = req("GET", "/api/notifications", headers=AUTH)
    nl0 = json.loads(body)
    check("用户通知含官方类型", any(n["type"] == "official" for n in nl0.get("list", [])), body[:100])
    s, body, _ = req("DELETE", f"/api/admin/official-message/{omid}", headers=ADMIN)
    check("删除官方通知 200", s == 200 and json.loads(body).get("ok") is True, body[:100])
    s, body, _ = req("GET", "/api/official-messages")
    oml = json.loads(body)
    check("删除后用户端列表不再含该消息", all(m["id"] != omid for m in oml.get("list", [])), body[:100])
    s, body, _ = req("GET", "/api/notifications", headers=AUTH)
    nl0 = json.loads(body)
    check("删除后用户通知级联清理", all(n.get("content") != "冒烟测试官方通知" for n in nl0.get("list", [])), body[:100])
    s, body, _ = req("DELETE", f"/api/admin/official-message/{omid}", headers=ADMIN)
    check("重复删除 404", s == 404, f"s={s}")
    s, body, _ = req("DELETE", f"/api/admin/official-message/{omid}")
    check("无 token 删除 401", s == 401, f"s={s}")

    print("== 18. 互动通知（点赞/评论/分享 → 上传者收通知）==")
    body, ct = multipart({"account": "user2", "password": "secret456", "name": "二号用户"}, {})
    s, body, _ = req("POST", "/api/register", body, {"Content-Type": ct})
    u2 = json.loads(body)
    u2token = u2.get("token", "")
    check("注册二号用户 200 返回 token", s == 200 and u2token, body[:100])
    AUTH2 = {"Authorization": f"Bearer {u2token}"}
    s, body, _ = req("POST", "/api/notifications/read", None)
    check("未登录标记已读 401", s == 401, f"s={s}")
    s, body, _ = req("POST", "/api/notifications/read", None, AUTH)
    check("标记通知已读 200", s == 200, f"s={s}")
    s, body, _ = req("POST", f"/api/like/{tid}", {"userId": u2.get("id")}, AUTH2)
    check("二号用户点赞 200 liked=true", s == 200 and json.loads(body).get("liked") is True, body[:100])
    s, body, _ = req("POST", f"/api/comment/{tid}", {"userId": u2.get("id"), "userName": "二号用户",
                                                     "content": "好听"}, AUTH2)
    check("二号用户评论 200", s == 200, body[:100])
    s, body, _ = req("POST", f"/api/share/{tid}", None, AUTH2)
    check("二号用户分享 200", s == 200, body[:100])
    s, body, _ = req("GET", "/api/notifications", headers=AUTH)
    nl1 = json.loads(body)
    types1 = [n.get("type") for n in nl1.get("list", [])]
    check("上传者收到点赞通知", "like" in types1, str(types1))
    check("上传者收到评论通知", "comment" in types1, str(types1))
    check("上传者收到分享通知", "share" in types1, str(types1))
    check("未读数 ≥3", nl1.get("unread", 0) >= 3, body[:100])
    s, body, _ = req("POST", "/api/notifications/read", None, AUTH)
    check("再次标记已读 200", s == 200, f"s={s}")
    s, body, _ = req("GET", "/api/notifications", headers=AUTH)
    nl2 = json.loads(body)
    check("已读后 unread=0", nl2.get("unread") == 0, body[:100])
    check("已读后 isRead=1", all(n.get("isRead") == 1 for n in nl2.get("list", [])), body[:100])

    print("== 19. 行为埋点上报 ==")
    evs = [{"trackId": tid, "event": "listen", "value": 30,
            "meta": {"fraction": 0.5, "plays": 1, "seconds": 30}},
           {"trackId": tid, "event": "skip", "value": 0, "meta": {"fraction": 0.1}}]
    s, body, _ = req("POST", "/api/behavior", {"events": evs}, AUTH)
    beh = json.loads(body)
    check("行为上报 200 count=2", s == 200 and beh.get("count") == 2, body[:100])
    s, body, _ = req("POST", "/api/behavior", {"events": []}, AUTH)
    check("空 events 400", s == 400, f"s={s}")
    s, body, _ = req("POST", "/api/behavior", {"events": evs})
    check("未登录行为上报 401", s == 401, f"s={s}")
    conn0 = sqlite3.connect(db_path)
    n_beh = conn0.execute("SELECT COUNT(*) FROM behavior_events WHERE event='listen'").fetchone()[0]
    conn0.close()
    check("behavior_events 落库 listen 记录", n_beh >= 1, f"n={n_beh}")

    print("== 20. admin 管理接口鉴权 ==")
    s, body, _ = req("GET", "/api/admin/stats")
    check("admin stats 无 token 401", s == 401, f"s={s}")
    s, body, _ = req("GET", "/api/admin/stats", headers=ADMIN)
    st = json.loads(body)
    check("admin stats 200 含计数", s == 200 and st.get("ok") is True and "users" in st, body[:100])
    s, body, _ = req("GET", "/api/admin/users")
    check("admin users 无 token 401", s == 401, f"s={s}")
    s, body, _ = req("GET", "/api/admin/users", headers=ADMIN)
    us = json.loads(body)
    check("admin users 200 含注册用户", s == 200 and any(u.get("account") == acc
                                                          for u in us.get("list", [])), body[:100])

    print("== 21. WebSocket 握手与鉴权 ==")
    WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    def ws_handshake(path):
        sock = socket.create_connection(("127.0.0.1", port), timeout=5)
        key = base64.b64encode(os.urandom(16)).decode()
        sock.sendall((f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
                      f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
                      f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        resp = sock.recv(4096).decode("utf-8", "ignore")
        accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        sock.close()
        return resp, accept
    resp, accept = ws_handshake(f"/api/ws?token={u2token}")
    check("ws 有效 token 握手 101", resp.startswith("HTTP/1.1 101"), resp[:100])
    check("ws Sec-WebSocket-Accept 校验正确", accept in resp, resp[:200])
    resp, _ = ws_handshake("/api/ws")
    check("ws 无 token 401", resp.startswith("HTTP/1.1 401"), resp[:100])
    resp, _ = ws_handshake("/api/ws?token=bad_token_xyz")
    check("ws 错误 token 401", resp.startswith("HTTP/1.1 401"), resp[:100])
    resp, _ = ws_handshake("/api/ws?token=" + u2token)
    check("ws 带 token 再次握手 101", resp.startswith("HTTP/1.1 101"), resp[:100])
    def ws_pingpong(path):
        sock = socket.create_connection(("127.0.0.1", port), timeout=5)
        key = base64.b64encode(os.urandom(16)).decode()
        sock.sendall((f"GET {path} HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n"
                      f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
                      f"Sec-WebSocket-Version: 13\r\n\r\n").encode())
        resp = sock.recv(4096)
        if not resp.startswith(b"HTTP/1.1 101"):
            sock.close()
            return False
        payload = b"hi"
        mask = b"\x11\x22\x33\x44"
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        sock.sendall(bytes([0x89, 0x80 | len(payload)]) + mask + masked)
        sock.settimeout(5)
        data = sock.recv(1024)
        sock.close()
        return bool(data) and data[0] & 0x0F == 0xA
    check("ws ping→pong 帧回包", ws_pingpong(f"/api/ws?token={u2token}"))
    # WS 实时行为上报（即时通讯通道）：{"type":"behavior","events":[...]} → 实时落库
    def ws_send_text(path, payload_json):
        sock = socket.create_connection(("127.0.0.1", port), timeout=5)
        key = base64.b64encode(os.urandom(16)).decode()
        sock.sendall((f"GET {path} HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n"
                      f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
                      f"Sec-WebSocket-Version: 13\r\n\r\n").encode())
        resp = sock.recv(4096)
        if not resp.startswith(b"HTTP/1.1 101"):
            sock.close()
            return False
        mask = b"\x11\x22\x33\x44"
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload_json))
        sock.sendall(bytes([0x81, 0x80 | len(payload_json)]) + mask + masked)
        sock.close()
        return True
    ok = ws_send_text(f"/api/ws?token={u2token}", json.dumps({
        "type": "behavior",
        "events": [{"trackId": "ws_t1", "event": "listen", "value": 5}]}).encode())
    check("ws behavior 消息发送成功", ok)
    time.sleep(0.6)
    _cu = sqlite3.connect(os.path.join(root, "tracks.db"))
    _u2 = _cu.execute("SELECT user_id FROM tokens WHERE token=?", (u2token,)).fetchone()
    _n = _cu.execute("SELECT COUNT(*) FROM behavior_events WHERE user_id=?"
                     " AND track_id='ws_t1' AND event='listen'", (_u2[0] if _u2 else "",)).fetchone()[0]
    _cu.close()
    check("ws 行为上报实时落库", _n >= 1, f"n={_n}")

    print("== 22. 限流（登录连续 12 次）==")
    codes = []
    for i in range(12):
        body, ct = multipart({"account": acc, "password": "wrongpass"}, {})
        s, _, _ = req("POST", "/api/login", body, {"Content-Type": ct})
        codes.append(s)
    check("登录限流触发 429", 429 in codes, str(codes))


if __name__ == "__main__":
    main()
