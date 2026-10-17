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

from server.config import DB, log

__all__ = ['db']

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
                       ("ip_address", "TEXT DEFAULT ''"),
                       ("banned", "INTEGER DEFAULT 0"),
                       ("ban_reason", "TEXT DEFAULT ''"),
                       ("is_ai", "INTEGER DEFAULT 0")]:
        if _col not in ucols:
            c.execute("ALTER TABLE users ADD COLUMN %s %s" % (_col, _ddl))
    # AI 乐评账号（透明标识：主页/评论展示 AI 标签；不可登录，仅供 AI 评论发布）
    c.execute("""INSERT OR IGNORE INTO users(id,account,password_hash,name,avatar,created,is_ai,signature)
                 VALUES('ai_liuying_comment','000000','','AI 乐评','',0,1,'我是流萤 AI 乐评人，为你解析每首歌里的情绪与故事')""")
    tcols = [r[1] for r in c.execute("PRAGMA table_info(tracks)")]
    for _col, _ddl in [("user_id", "TEXT DEFAULT ''"),
                       ("play_count", "INTEGER DEFAULT 0"),
                       ("like_count", "INTEGER DEFAULT 0"),
                       ("share_count", "INTEGER DEFAULT 0"),
                       ("offline", "INTEGER DEFAULT 0"),
                       ("offline_reason", "TEXT DEFAULT ''"),
                       ("genre", "TEXT DEFAULT ''")]:
        if _col not in tcols:
            c.execute("ALTER TABLE tracks ADD COLUMN %s %s" % (_col, _ddl))
    c.execute("""CREATE TABLE IF NOT EXISTS likes(
        user_id TEXT, track_id TEXT, created REAL,
        PRIMARY KEY(user_id, track_id))""")
    c.execute("""CREATE TABLE IF NOT EXISTS comments(
        id TEXT PRIMARY KEY, track_id TEXT, user_id TEXT,
        user_name TEXT, content TEXT, created REAL)""")
    # 评论图片列（存 JSON 数组：服务端生成的文件名 cmt_xxx，经 /api/comment-image/ 访问）
    cmt_cols = [r[1] for r in c.execute("PRAGMA table_info(comments)")]
    if "images" not in cmt_cols:
        c.execute("ALTER TABLE comments ADD COLUMN images TEXT DEFAULT ''")
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
    ccols = [r[1] for r in c.execute("PRAGMA table_info(collected_tracks)")]
    for _col, _ddl in [("offline", "INTEGER DEFAULT 0"),
                       ("offline_reason", "TEXT DEFAULT ''"),
                       ("genre", "TEXT DEFAULT ''")]:
        if _col not in ccols:
            c.execute("ALTER TABLE collected_tracks ADD COLUMN %s %s" % (_col, _ddl))
    # 用户行为事件表（个性化推荐数据源）
    # event: like / comment_open / comment / share / listen
    # value: listen=累计收听秒数，like=1/0，其余 0
    # meta: JSON，如 {"fraction": 收听进度0~1, "plays": 本次会话播放次数}
    c.execute("""CREATE TABLE IF NOT EXISTS behavior_events(
        id TEXT PRIMARY KEY, user_id TEXT, track_id TEXT,
        event TEXT, value REAL DEFAULT 0, meta TEXT DEFAULT '',
        track_info TEXT DEFAULT '',
        created REAL)""")
    bev_cols = [r[1] for r in c.execute("PRAGMA table_info(behavior_events)")]
    if "track_info" not in bev_cols:
        c.execute("ALTER TABLE behavior_events ADD COLUMN track_info TEXT DEFAULT ''")
    c.execute("CREATE INDEX IF NOT EXISTS idx_bev_user ON behavior_events(user_id, created)")
    # 公告通知表：App 启动时从底部弹窗展示最新公告
    c.execute("""CREATE TABLE IF NOT EXISTS announcements(
        id TEXT PRIMARY KEY, title TEXT, content TEXT,
        version TEXT DEFAULT '', active INTEGER DEFAULT 1,
        show_once INTEGER DEFAULT 0,
        type TEXT DEFAULT 'announcement',
        force_update INTEGER DEFAULT 0,
        download_url TEXT DEFAULT '',
        created REAL)""")
    ann_cols = [r[1] for r in c.execute("PRAGMA table_info(announcements)")]
    for col, default in [("show_once","0"),("type","'announcement'"),("force_update","0"),("download_url","''")]:
        if col not in ann_cols:
            c.execute("ALTER TABLE announcements ADD COLUMN %s TEXT DEFAULT %s" % (col, default))
    # 通知表：互动通知（点赞/评论/分享）+ 官方通知记录；comment_id 用于评论通知点击定位
    c.execute("""CREATE TABLE IF NOT EXISTS notifications(
        id TEXT PRIMARY KEY, user_id TEXT, type TEXT,
        title TEXT DEFAULT '', content TEXT DEFAULT '',
        from_user_id TEXT DEFAULT '', from_user_name TEXT DEFAULT '',
        track_id TEXT DEFAULT '', track_title TEXT DEFAULT '',
        is_read INTEGER DEFAULT 0, created REAL)""")
    ncols = [r[1] for r in c.execute("PRAGMA table_info(notifications)")]
    if "comment_id" not in ncols:
        c.execute("ALTER TABLE notifications ADD COLUMN comment_id TEXT DEFAULT ''")
    # 官方消息表：聊天记录样式展示
    c.execute("""CREATE TABLE IF NOT EXISTS official_messages(
        id TEXT PRIMARY KEY, content TEXT DEFAULT '', created REAL,
        sender_name TEXT DEFAULT '流萤音乐官方')""")
    # ===== 性能优化：补缺失索引 =====
    # 通知列表按用户+时间倒序查询
    c.execute("CREATE INDEX IF NOT EXISTS idx_notif_user ON notifications(user_id, created DESC)")
    c.execute("CREATE INDEX IF NOT EXISTS idx_notif_unread ON notifications(user_id, is_read)")
    # 评论按歌曲+时间倒序查询
    c.execute("CREATE INDEX IF NOT EXISTS idx_comment_track ON comments(track_id, created DESC)")
    c.execute("CREATE INDEX IF NOT EXISTS idx_comment_user ON comments(user_id, created DESC)")
    # 用户上传歌曲按时间倒序
    c.execute("CREATE INDEX IF NOT EXISTS idx_tracks_user ON tracks(user_id, created DESC)")
    # 采集歌曲按用户+时间
    c.execute("CREATE INDEX IF NOT EXISTS idx_collected_user ON collected_tracks(user_id, created DESC)")
    # 点赞列表按用户+时间
    c.execute("CREATE INDEX IF NOT EXISTS idx_likes_user ON likes(user_id, created DESC)")

    # ===== 新增功能表 =====
    # 播放历史表
    c.execute("""CREATE TABLE IF NOT EXISTS play_history(
        id TEXT PRIMARY KEY, user_id TEXT, track_id TEXT,
        track_title TEXT DEFAULT '', track_artist TEXT DEFAULT '',
        track_cover TEXT DEFAULT '', source TEXT DEFAULT 'upload',
        created REAL)""")
    c.execute("CREATE INDEX IF NOT EXISTS idx_history_user ON play_history(user_id, created DESC)")

    # 搜索历史表
    c.execute("""CREATE TABLE IF NOT EXISTS search_history(
        id TEXT PRIMARY KEY, user_id TEXT, keyword TEXT, created REAL)""")
    c.execute("CREATE INDEX IF NOT EXISTS idx_search_user ON search_history(user_id, created DESC)")

    # 歌单表
    c.execute("""CREATE TABLE IF NOT EXISTS playlists(
        id TEXT PRIMARY KEY, user_id TEXT, name TEXT,
        cover TEXT DEFAULT '', description TEXT DEFAULT '',
        track_count INTEGER DEFAULT 0, created REAL)""")
    c.execute("CREATE INDEX IF NOT EXISTS idx_playlist_user ON playlists(user_id, created DESC)")

    # 歌单-歌曲关联表
    c.execute("""CREATE TABLE IF NOT EXISTS playlist_tracks(
        playlist_id TEXT, track_id TEXT,
        track_title TEXT DEFAULT '', track_artist TEXT DEFAULT '',
        track_cover TEXT DEFAULT '', source TEXT DEFAULT 'upload',
        sort INTEGER DEFAULT 0, created REAL,
        PRIMARY KEY(playlist_id, track_id))""")
    c.execute("CREATE INDEX IF NOT EXISTS idx_pltrack_playlist ON playlist_tracks(playlist_id, sort)")

    # 评论图片字段迁移
    cmt_cols = [r[1] for r in c.execute("PRAGMA table_info(comments)")]
    if "images" not in cmt_cols:
        c.execute("ALTER TABLE comments ADD COLUMN images TEXT DEFAULT ''")
    if "like_count" not in cmt_cols:
        c.execute("ALTER TABLE comments ADD COLUMN like_count INTEGER DEFAULT 0")
    if "is_ai" not in cmt_cols:
        c.execute("ALTER TABLE comments ADD COLUMN is_ai INTEGER DEFAULT 0")

    # 评论点赞表
    c.execute("""CREATE TABLE IF NOT EXISTS comment_likes(
        user_id TEXT, comment_id TEXT, created REAL,
        PRIMARY KEY(user_id, comment_id))""")

    # 通知软删除字段
    notif_cols = [r[1] for r in c.execute("PRAGMA table_info(notifications)")]
    if "is_deleted" not in notif_cols:
        c.execute("ALTER TABLE notifications ADD COLUMN is_deleted INTEGER DEFAULT 0")

    # 关注关系表
    c.execute("""CREATE TABLE IF NOT EXISTS follows(
        follower_id TEXT, following_id TEXT, created REAL,
        PRIMARY KEY(follower_id, following_id))""")
    c.execute("CREATE INDEX IF NOT EXISTS idx_follow_follower ON follows(follower_id)")
    c.execute("CREATE INDEX IF NOT EXISTS idx_follow_following ON follows(following_id)")

    # 通知类型加 follow 支持（复用 notifications 表，type='follow'）

    # 推荐推送去重历史（按用户记录 3 小时内推送过的歌曲，窗口过期惰性清理）
    c.execute("""CREATE TABLE IF NOT EXISTS recommend_push_history(
        uid TEXT NOT NULL, track_id TEXT NOT NULL, pushed_at REAL NOT NULL,
        PRIMARY KEY(uid, track_id))""")
    c.execute("CREATE INDEX IF NOT EXISTS idx_push_uid_ts ON recommend_push_history(uid, pushed_at)")

    # AI 主动乐评：动态配置表（key→value，网站管理页可改，DB 优先于 config.py 默认值）
    c.execute("""CREATE TABLE IF NOT EXISTS ai_comment_cfg(
        key TEXT PRIMARY KEY, value TEXT DEFAULT '')""")

    # AI 主动乐评执行记录（run_type: auto=定时/manual=手动；status: ok/fail）
    c.execute("""CREATE TABLE IF NOT EXISTS ai_comment_logs(
        id TEXT PRIMARY KEY, run_type TEXT DEFAULT 'auto', track_id TEXT, track_title TEXT,
        status TEXT DEFAULT 'ok', comment_id TEXT DEFAULT '', reason TEXT DEFAULT '', created REAL)""")
    c.execute("CREATE INDEX IF NOT EXISTS idx_ai_log_created ON ai_comment_logs(created)")

    # 回填历史 AI 乐评的 is_ai 标识（早期被动评论未写该列）
    c.execute("UPDATE comments SET is_ai=1 WHERE user_id=? AND is_ai=0", ("ai_liuying_comment",))

    c.commit()
    return c
