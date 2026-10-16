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

__all__ = ['WS_CLIENTS', 'WS_GUID', 'WS_LOCK', 'WS_STATS_THROTTLE', '_ws_frame', '_ws_handshake', '_ws_recv_exact', '_ws_refresh_recommend', '_ws_serve', 'ws_broadcast', 'ws_push', 'ws_register', 'ws_unregister']

WS_LOCK = threading.Lock()


WS_CLIENTS = {}          # user_id -> set(sock)


WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


WS_STATS_THROTTLE = {}   # uid -> 上次推送 stats/recommend 时间（行为上报节流，防止高频推送）


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
