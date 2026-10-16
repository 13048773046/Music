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

__all__ = ['_ai_cfg', '_ai_generate_comment', '_ai_uid']

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
