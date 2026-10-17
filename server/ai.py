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
from server.config import AI_CFG_FILE, AI_API_BASE_DEFAULT, AI_MODEL_DEFAULT, AI_UID

__all__ = ['_ai_cfg', '_ai_generate_comment', '_ai_uid',
           '_ai_auto_settings', '_ai_auto_run', '_ai_comment_stats',
           '_ai_save_config', 'start_ai_worker']

def _ai_cfg():
    """读取 AI 接入配置：优先 ai_config.json（权限 600），环境变量兜底。密钥不写入代码/日志。"""
    cfg = {}
    try:
        if os.path.exists(AI_CFG_FILE):
            with open(AI_CFG_FILE, encoding="utf-8") as f:
                cfg = json.loads(f.read() or "{}")
    except Exception:
        cfg = {}
    cfg.setdefault("base", os.environ.get("AI_API_BASE", "https://ws-5usvd1tklaq38lj3.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"))
    cfg.setdefault("key", os.environ.get("AI_API_KEY", ""))
    cfg.setdefault("model", os.environ.get("AI_MODEL", "qwen-turbo"))
    return cfg


def _ai_generate_comment(title, artist, album, genre):
    """按歌曲歌名/作者（专辑、曲风）调用 qwen-turbo 生成乐评。返回纯文本或 None（失败）。"""
    cfg = _ai_cfg()
    if not cfg.get("key"):
        return None
    sys_prompt = ("你是流萤音乐的 AI 乐评人。为给定歌曲写一段贴合歌曲本身的短乐评，"
                  "像懂音乐的朋友在分享感受：可以写听感、情绪、画面感或对歌词/旋律的理解。"
                  "要求：中文，60~120 字，真诚不浮夸，不堆砌辞藻，不编造歌手名以外的信息，"
                  "不要使用感叹号刷屏，不要出现\"AI\"\"机器人\"等字样，结尾不要加话题标签。")
    facts = "歌曲名：%s\n歌手：%s" % (title or "未知", artist or "未知")
    if album:
        facts += "\n专辑：%s" % album
    if genre:
        facts += "\n曲风：%s" % genre
    body = {
        "model": cfg["model"],
        "messages": [
            {"role": "system", "content": sys_prompt},
            {"role": "user", "content": facts}
        ],
        "temperature": 0.9,
        "max_tokens": 300
    }
    req = urllib.request.Request(
        cfg["base"].rstrip("/") + "/chat/completions",
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer %s" % cfg["key"]},
        method="POST")
    try:
        with urllib.request.urlopen(req, timeout=40) as r:
            d = json.loads(r.read().decode("utf-8"))
        text = (d.get("choices") or [{}])[0].get("message", {}).get("content", "") or ""
        text = text.strip().strip('"').strip("“”")
        if not text or len(text) < 10:
            return None
        return text
    except Exception:
        return None


def _ai_uid():
    return "ai_liuying_comment"


# ---------------- AI 主动乐评（定时自动评论 + 后台管理） ----------------

_AI_WORKER_STARTED = False


def _ai_auto_settings():
    """合并 网站管理页动态配置（ai_comment_cfg 表，优先）+ config.py 默认值。"""
    cfg = {}
    try:
        c = db()
        try:
            for k, v in c.execute("SELECT key, value FROM ai_comment_cfg").fetchall():
                cfg[k] = v
        finally:
            c.close()
    except Exception:
        cfg = {}

    def _int(name, default):
        try:
            return int(cfg.get(name) or default)
        except Exception:
            return default

    return {
        "enabled": cfg.get("enabled", "1") != "0",
        "interval": max(60, _int("interval", AI_AUTO_INTERVAL)),
        "count": max(1, min(10, _int("count", AI_AUTO_COUNT))),
        "max_per_track": max(1, _int("max_per_track", AI_AUTO_MAX_PER_TRACK)),
        "skip_days": max(1, _int("skip_days", AI_AUTO_SKIP_DAYS)),
    }


def _ai_save_config(base=None, key=None, model=None):
    """保存 AI 接口接入配置到 ai_config.json（权限 600）。空值表示保持原值。"""
    cfg = _ai_cfg()
    if base is not None and str(base).strip():
        cfg["base"] = str(base).strip()
    if key is not None and str(key).strip():
        cfg["key"] = str(key).strip()
    if model is not None and str(model).strip():
        cfg["model"] = str(model).strip()
    tmp = AI_CFG_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, AI_CFG_FILE)
    try:
        os.chmod(AI_CFG_FILE, 0o600)
    except Exception:
        pass
    return cfg


def _ai_auto_run(run_type="auto", count=None, force=False):
    """主动乐评一轮：挑歌 → 生成 → 发布 → 通知 → 记日志。

    - enabled 关闭时跳过；后台手动触发可 force=True 强制执行。
    - 候选 = tracks(offline=0) + collected(play_url 非空)；
      排除：已有 AI 乐评 >= max_per_track 的歌、近 skip_days 已自动评过的歌。
    - 返回 {"ok":bool, "ran":n, "ok_count":n, "fail_count":n, "comments":[...]}。
    """
    cfg = _ai_auto_settings()
    if not cfg["enabled"] and not force:
        return {"ok": True, "ran": 0, "ok_count": 0, "fail_count": 0,
                "comments": [], "skipped": "disabled"}
    n = max(1, min(10, int(count or cfg["count"])))
    c = db()
    try:
        now = time.time()
        rows = []
        rows += c.execute("SELECT id,title,artist,album,genre FROM tracks WHERE offline=0").fetchall()
        rows += c.execute("SELECT id,title,artist,album,genre FROM collected_tracks WHERE play_url!=''").fetchall()
        if not rows:
            return {"ok": True, "ran": 0, "ok_count": 0, "fail_count": 0,
                    "comments": [], "skipped": "no_tracks"}
        # 近 skip_days 已自动评论过的歌（ok 记录）不再选
        skip_ts = now - cfg["skip_days"] * 86400
        recent = set(r[0] for r in c.execute(
            "SELECT track_id FROM ai_comment_logs WHERE status='ok' AND created>=?",
            (skip_ts,)).fetchall())
        # 已有 AI 乐评达到单曲上限的歌不再选
        full = {}
        for tid, cnt in c.execute(
                "SELECT track_id, COUNT(*) FROM comments WHERE user_id=? GROUP BY track_id",
                (_ai_uid(),)).fetchall():
            if cnt >= cfg["max_per_track"]:
                full[tid] = True
        cand = [r for r in rows if r[0] not in recent and r[0] not in full]
        random.shuffle(cand)
        pick = cand[:n]
        results = []
        for tid, title, artist, album, genre in pick:
            log_id = uuid.uuid4().hex
            text = _ai_generate_comment(title, artist, album, genre)
            if not text:
                c.execute("INSERT INTO ai_comment_logs(id,run_type,track_id,track_title,status,reason,created) "
                          "VALUES(?,?,?,?,?,?,?)",
                          (log_id, run_type, tid, title or "", "fail", "generate_failed", now))
                results.append({"trackId": tid, "trackTitle": title or "",
                                "status": "fail", "reason": "generate_failed"})
                continue
            cid = uuid.uuid4().hex
            c.execute("""INSERT INTO comments(id,track_id,user_id,user_name,content,images,created,is_ai)
                         VALUES(?,?,?,?,?,?,?,1)""",
                      (cid, tid, _ai_uid(), "AI 乐评", text, "[]", now))
            # 通知歌曲上传者（AI 评论了你的歌曲）
            owner_id, owner_title = _track_owner(c, tid)
            if owner_id:
                c.execute("""INSERT INTO notifications(id,user_id,type,title,content,from_user_id,from_user_name,track_id,track_title,is_read,created)
                             VALUES(?,?,?,?,?,?,?,?,?,?,?)""",
                          (uuid.uuid4().hex, owner_id, "comment", "收到 AI 乐评",
                           "AI 乐评评论了你的歌曲《%s》" % (owner_title or title or ""),
                           _ai_uid(), "AI 乐评", tid, owner_title or title or "", 0, now))
            c.execute("INSERT INTO ai_comment_logs(id,run_type,track_id,track_title,status,comment_id,created) "
                      "VALUES(?,?,?,?,?,?,?)",
                      (log_id, run_type, tid, title or "", "ok", cid, now))
            results.append({"trackId": tid, "trackTitle": title or "",
                            "status": "ok", "commentId": cid})
        c.commit()
        return {"ok": True, "ran": len(pick),
                "ok_count": sum(1 for r in results if r["status"] == "ok"),
                "fail_count": sum(1 for r in results if r["status"] == "fail"),
                "comments": results}
    finally:
        c.close()


def _ai_comment_stats():
    """网站管理页展示的状态汇总。"""
    cfg = _ai_auto_settings()
    c = db()
    try:
        last = c.execute("SELECT created FROM ai_comment_logs ORDER BY created DESC LIMIT 1").fetchone()
        ok_total = c.execute("SELECT COUNT(*) FROM ai_comment_logs WHERE status='ok'").fetchone()[0]
        fail_total = c.execute("SELECT COUNT(*) FROM ai_comment_logs WHERE status='fail'").fetchone()[0]
        today = time.time() - 86400
        ok_today = c.execute(
            "SELECT COUNT(*) FROM ai_comment_logs WHERE status='ok' AND created>=?", (today,)).fetchone()[0]
        ai_total = c.execute("SELECT COUNT(*) FROM comments WHERE user_id=?",
                             (_ai_uid(),)).fetchone()[0]
    finally:
        c.close()
    return {"enabled": cfg["enabled"], "interval": cfg["interval"], "count": cfg["count"],
            "max_per_track": cfg["max_per_track"], "skip_days": cfg["skip_days"],
            "lastRun": last[0] if last else 0,
            "okTotal": ok_total, "failTotal": fail_total, "okToday": ok_today,
            "aiCommentTotal": ai_total, "keyConfigured": bool(_ai_cfg().get("key"))}


def _ai_auto_worker():
    """定时主动乐评 daemon 线程：按 interval 循环，任何异常都不中断。"""
    while True:
        try:
            _ai_auto_run("auto")
        except Exception:
            pass
        try:
            time.sleep(max(60, _ai_auto_settings()["interval"]))
        except Exception:
            time.sleep(3600)


def start_ai_worker():
    """服务入口调用：启动主动乐评后台线程（幂等，测试可重复调用）。"""
    global _AI_WORKER_STARTED
    if _AI_WORKER_STARTED:
        return
    _AI_WORKER_STARTED = True
    t = threading.Thread(target=_ai_auto_worker, daemon=True, name="ai-comment-auto")
    t.start()
