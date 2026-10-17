#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""流萤音乐 · 统一配置层（架构规范化）

配置优先级（高 → 低）：
    1. 环境变量（MUSIC_ROOT / MUSIC_PORT / MUSIC_DEBUG / MUSIC_AUTH_STRICT /
       MUSIC_SIGN_STRICT / MUSIC_SIGN_SECRET / MUSIC_PUBLIC_URL / MUSIC_ADMIN_PWD_FILE /
       COLLECT_KEY / MUSIC_REC_BUCKET / MUSIC_REC_IDLE / MUSIC_CONFIG）
    2. config.json（由自动安装程序生成；放在部署根目录，或用 MUSIC_CONFIG 指定）
    3. 内置默认值（与历史线上行为一致）

设计要点：
    - 本模块是零内部依赖的“叶子模块”，其余模块统一从这里取常量与派生路径，
      彻底消除散落在各文件里的硬编码 /www/wwwroot/music。
    - 旧部署没有 config.json 也能运行（回退默认值 + 环境变量），平滑兼容。
"""
import os
import json
import logging
import secrets

# ---------------- 部署根与 config.json 定位 ----------------

# server/config.py 的上两级即部署根目录（<root>/server/config.py）
_PKG_PARENT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load_user_config():
    """读取 config.json（安装程序生成）。找不到或解析失败时静默回退空配置。"""
    cfg_path = os.environ.get("MUSIC_CONFIG", "") or os.path.join(_PKG_PARENT, "config.json")
    try:
        with open(cfg_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


_USER_CFG = _load_user_config()


def _cfg_str(key, env_name, default):
    """字符串配置：环境变量优先，其次 config.json，最后默认值。"""
    v = os.environ.get(env_name)
    if v is not None and v != "":
        return v
    v = _USER_CFG.get(key)
    if isinstance(v, str) and v != "":
        return v
    return default


def _cfg_int(key, env_name, default):
    v = os.environ.get(env_name)
    if v is not None and v != "":
        try:
            return int(v)
        except ValueError:
            pass
    v = _USER_CFG.get(key)
    if isinstance(v, int):
        return v
    return default


def _cfg_bool(env_name, default=False):
    return os.environ.get(env_name, "1" if default else "0") == "1"


def _cfg_path(key, default_subpath):
    """路径配置：优先 config.json 的 paths.<key>（绝对路径）；
    否则以 ROOT 拼接历史相对路径。"""
    paths = _USER_CFG.get("paths")
    if isinstance(paths, dict):
        v = paths.get(key)
        if isinstance(v, str) and v:
            return v
    return os.path.join(ROOT, default_subpath)


# ---------------- 基础路径与端口 ----------------

ROOT = _cfg_str("root", "MUSIC_ROOT", "/www/wwwroot/music")
FILES = _cfg_path("files", "files")
DB = _cfg_path("db", "tracks.db")
_ports_cfg = _USER_CFG.get("ports") if isinstance(_USER_CFG.get("ports"), dict) else {}
PORT = int(os.environ.get("MUSIC_PORT") or _ports_cfg.get("api")
           or _USER_CFG.get("port") or 8788)
BRIDGE_PORT = int(os.environ.get("BRIDGE_PORT") or _ports_cfg.get("bridge") or 8789)

# 音源桥 / 采集相关目录与文件（取代历史硬编码绝对路径）
BRIDGE_DIR = _cfg_path("bridge_dir", "source-bridge")
COLLECT_TARGET_FILE = _cfg_path("collect_target", "source-bridge/collect_target.json")
COLLECT_RUN_FILE = _cfg_path("collect_run", "source-bridge/collect_run.json")
COLLECT_LOG_FILE = _cfg_path("collect_log", "source-bridge/collect_v3.log")
COLLECT_V3 = _cfg_path("collect_v3", "source-bridge/collect_v3.py")
DOWNLOAD_COLLECTED = _cfg_path("download_collected", "source-bridge/download_collected.py")
QS_SESSION_FILE = _cfg_path("qs_session", "source-bridge/qs_session.json")

# 音源桥本机 HTTP 基址（server → bridge 反向代理用）
BRIDGE_URL = "http://127.0.0.1:%d" % BRIDGE_PORT

# 模板目录（server/templates）
TEMPLATE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "templates")

# ---------------- 上传 / 请求限制 ----------------

MAX_UPLOAD = 100 * 1024 * 1024        # 单曲音频上限 100MB
MAX_PROFILE = 8 * 1024 * 1024         # 注册/改资料请求上限 8MB
MAX_COMMENT = 200                     # 评论最大字符
MAX_COMMENT_IMAGE = 8 * 1024 * 1024   # 单张评论图片上限 8MB
MAX_NAME = 40                         # 昵称/歌手/标题最大长度

# ---------------- 鉴权 / 密码 / Token ----------------

TOKEN_TTL = 30 * 24 * 3600            # token 有效期 30 天
PBKDF2_ITER = 210000                  # 新密码哈希迭代次数
LEGACY_ITER = 120000                  # 旧哈希迭代次数（自动迁移）
AUTH_STRICT = _cfg_bool("MUSIC_AUTH_STRICT")
DEBUG = _cfg_bool("MUSIC_DEBUG")
SOCKET_TIMEOUT = 60

# ---------------- 流媒体签名防盗链 ----------------

STREAM_SIGN_TTL = 1800                # 签名流 URL 有效期 30 分钟
SIGN_STRICT = _cfg_bool("MUSIC_SIGN_STRICT")
PUBLIC_BASE = _cfg_str(
    "public_url", "MUSIC_PUBLIC_URL",
    "https://www.dbmt999.asia/music").rstrip("/")
# 主域名（无 /music 前缀，安装程序设置；分享短链 OG:url 用）
PRIMARY_DOMAIN = _cfg_str("domain", "MUSIC_DOMAIN",
                          "www.dbmt999.asia").rstrip("/")

SIGN_SECRET = os.environ.get("MUSIC_SIGN_SECRET", "")
if not SIGN_SECRET:
    _s = (_USER_CFG.get("sign_secret") if isinstance(_USER_CFG.get("sign_secret"), str) else "")
    if _s:
        SIGN_SECRET = _s
if not SIGN_SECRET:
    _secret_file = os.path.join(ROOT, ".sign_secret")
    try:
        if os.path.exists(_secret_file):
            with open(_secret_file, encoding="utf-8") as f:
                _s = f.read().strip()
            if _s:
                SIGN_SECRET = _s
        if not SIGN_SECRET:
            SIGN_SECRET = secrets.token_hex(32)
            with open(_secret_file, "w", encoding="utf-8") as f:
                f.write(SIGN_SECRET)
    except OSError:
        SIGN_SECRET = secrets.token_hex(32)

try:
    os.makedirs(FILES, exist_ok=True)
except OSError:
    # 部署目录尚不可写（如未安装先做只读检查、非 root 探测）时不应阻断 import；
    # 真正写文件时再由对应逻辑暴露权限错误。
    pass

# ---------------- 日志 ----------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("music")

# ---------------- 采集入库密钥 ----------------

COLLECT_KEY = _cfg_str("collect_key", "COLLECT_KEY", "liuying-collect-7f3a9c2e")

# ---------------- 后台密码文件 ----------------

ADMIN_PWD_FILE = os.environ.get(
    "MUSIC_ADMIN_PWD_FILE",
    (_USER_CFG.get("admin_pwd_file") if isinstance(_USER_CFG.get("admin_pwd_file"), str) else "")
    or os.path.join(ROOT, "admin_pwd"))

# ---------------- 官网展示配置 ----------------

SITE_CONFIG_FILE = os.path.join(ROOT, "site_config.json")
_SITE_CONFIG_DEFAULTS = {
    "site_name": "流萤音乐",
    "ios_url": "",
    "android_url": "",
    "hero_subtitle": "为你精心挑选的音乐，流式播放不等待，逐字歌词跟着唱。",
}

# ---------------- AI 乐评配置 ----------------
# 接入参数（base/key/model）存于该文件（安装程序/运维写入，权限 600），
# 同时支持环境变量 AI_API_BASE / AI_API_KEY / AI_MODEL 兜底。
AI_CFG_FILE = _cfg_path("ai_config", "ai_config.json")
AI_API_BASE_DEFAULT = ("https://ws-5usvd1tklaq38lj3.cn-beijing.maas.aliyuncs.com"
                       "/compatible-mode/v1")
AI_MODEL_DEFAULT = "qwen-turbo"
AI_UID = "ai_liuying_comment"

# ---------------- AI 主动乐评（定时自动评论） ----------------
# 后端定时为歌曲生成并发布 AI 乐评。默认值可被「网站管理」页保存到 ai_comment_cfg 表动态覆盖（无需重启）。
AI_AUTO_INTERVAL = _cfg_int("ai_auto_interval", "MUSIC_AI_AUTO_INTERVAL", 3600)          # 自动评论周期（秒），默认 1 小时
AI_AUTO_COUNT = _cfg_int("ai_auto_count", "MUSIC_AI_AUTO_COUNT", 2)                      # 每轮评论歌曲数，默认 2 首
AI_AUTO_MAX_PER_TRACK = _cfg_int("ai_auto_max_per_track", "MUSIC_AI_AUTO_MAX_PER_TRACK", 2)  # 每首歌最多 AI 乐评条数
AI_AUTO_SKIP_DAYS = _cfg_int("ai_auto_skip_days", "MUSIC_AI_AUTO_SKIP_DAYS", 7)          # 近 N 天已自动评过的歌不再选（防集中）

# ---------------- 实时热词（AI 乐评热梗来源：百度热搜 + 贴吧热议，按歌曲信息匹配） ----------------
# AI 生成乐评前抓取当前网络热梗池，并用歌曲信息（歌名/歌手/曲风）匹配出相关的热梗注入上下文；
# 抓取失败时静默降级（无热梗，评论回到纯乐评）。
HOT_WORDS_ENDPOINT = _cfg_str("hot_words_endpoint", "MUSIC_HOT_WORDS_ENDPOINT",
                              "https://top.baidu.com/api/board?platform=wise&tab=realtime")
HOT_WORDS_ENDPOINT_2 = _cfg_str("hot_words_endpoint_2", "MUSIC_HOT_WORDS_ENDPOINT_2",
                                "https://tieba.baidu.com/hottopic/browse/topicList")
HOT_WORDS_TTL = _cfg_int("hot_words_ttl", "MUSIC_HOT_WORDS_TTL", 3600)       # 热词缓存（秒），默认 1 小时
HOT_WORDS_TIMEOUT = _cfg_int("hot_words_timeout", "MUSIC_HOT_WORDS_TIMEOUT", 8)
HOT_WORDS_LIMIT = _cfg_int("hot_words_limit", "MUSIC_HOT_WORDS_LIMIT", 20)   # 注入的最大热词条数
HOT_WORDS_MATCH = _cfg_int("hot_words_match", "MUSIC_HOT_WORDS_MATCH", 3)    # 按歌曲匹配出的热梗上限

# ---------------- 汽水音乐分享解析 UA ----------------

QISHUI_SHARE_UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) "
                   "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1")

# ---------------- 封面缩略图参数 ----------------

COVER_SMALL_MAX_SIDE = 600            # 缩略图长边最大像素
COVER_SMALL_QUALITY = 82              # JPEG 质量
COVER_SMALL_MIN_SIZE = 150 * 1024     # 超过 150KB 才压缩（小图直接原样返回）

# ---------------- 个性化推荐参数 ----------------

REC_BUDGET = 20
REC_FRESH_DAYS = 14
REC_MAX_PER_ARTIST = 3
REC_MAX_PER_GENRE = 5
REC_MMR_LAMBDA = 0.7
REC_NOISE = float(os.environ.get("MUSIC_REC_NOISE", "1.2"))   # F4：扰动 0.6→1.2，让不同批次种子真正改变排序
REC_TITLE_SIM_THRESHOLD = 0.8
REC_BUCKET_SECONDS = int(os.environ.get("MUSIC_REC_BUCKET", str(6 * 3600)))
REC_SESSION_IDLE = int(os.environ.get("MUSIC_REC_IDLE", str(30 * 60)))
REC_EXPLORE_POOL = int(os.environ.get("MUSIC_REC_EXPLORE_POOL", "240"))   # F9：探索池=桶内 80%（8 桶每桶约 300 首）
REC_LIMITS = {
    "behavior": 40, "artist": 30, "genre": 30,
    "hot": 20, "fresh": 10, "explore": 30,
}
REC_WEIGHTS = {
    # F4：行为 5.0→4.0、探索 0.6→1.0（降低单一偏好垄断、提高新内容曝光）
    "behavior": float(os.environ.get("MUSIC_REC_W_BEHAVIOR", "4.0")),
    "artist": 4.0, "genre": 3.0,
    "hot": 1.2, "fresh": 2.0, "explore": float(os.environ.get("MUSIC_REC_W_EXPLORE", "1.0")),
}
REC_HOT_TOP = 60
# F3：推送去重窗口 3h→24h——长会话（实测最长 8.3h）中途不再重复推送已推过的歌
REC_PUSH_WINDOW = int(os.environ.get("MUSIC_REC_PUSH_WINDOW", str(24 * 3600)))
# 长期去重：解决"听来听去都是那几首"——
# 用户最近 N 天内听完成分 ≥ 阈值的歌，视为"已听过"，长期不再重复推荐（只推没听过的新内容）
REC_REPLAY_DAYS = int(os.environ.get("MUSIC_REC_REPLAY_DAYS", "30"))
REC_REPLAY_FRACTION_MIN = float(os.environ.get("MUSIC_REC_REPLAY_FRAC", "0.5"))

# ---------------- 天气×时段心情场景推荐参数（M2） ----------------
# 默认 Open-Meteo（免费、无需 key）；备选和风天气需用户自备 key 时替换 endpoint
WEATHER_ENDPOINT = _cfg_str("weather_endpoint", "MUSIC_WEATHER_ENDPOINT",
                            "https://api.open-meteo.com/v1/forecast")
WEATHER_TTL = int(os.environ.get("MUSIC_WEATHER_TTL", "1800"))     # 天气缓存 30 分钟
WEATHER_TIMEOUT = 10                                                # 出站请求超时 10s
# 场景路权重与融合系数（方案 §3.5：个性化×场景双向融合）
REC_WEIGHTS["scene"] = float(os.environ.get("MUSIC_REC_W_SCENE", "2.0"))
REC_LIMITS["scene"] = 25
REC_SCENE_BOOST = float(os.environ.get("MUSIC_REC_SCENE_BOOST", "1.5"))     # 场景加权倍数（近期爱听歌场景前移）
REC_SCENE_PROFILE = float(os.environ.get("MUSIC_REC_SCENE_PROFILE", "0.5")) # 应景歌吃个性化分的系数（吻合加权）
