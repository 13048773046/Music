#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""采集 v3：热门榜单多页 + 搜索补量，目标 500 首新歌（2020-2026 ID3 过滤）
封面与音频均下载到本地 files/；入库即写 play_url 本地文件名，App 立即可播。
v3.1：接入抖音官方音乐榜（chart/music/list）——只采抖音上很火的视频/图片配乐 BGM。
"""
import argparse, hashlib, json, os, re, ssl, sqlite3, time, urllib.parse, urllib.request

DB = "/www/wwwroot/music/tracks.db"
FILES = "/www/wwwroot/music/files"
BRIDGE = "http://127.0.0.1:8789"
OWNER_UID = "a334105a8a2f4401a19001ee4ce66929"
RUN_STATE = "/www/wwwroot/music/source-bridge/collect_run.json"
TGT_FILE = "/www/wwwroot/music/source-bridge/collect_target.json"

# 抖音官方音乐榜（热歌榜 BGM）：无签名公开接口，反映抖音热门视频/图集配乐热度
DY_MUSIC_URL = "https://aweme.snssdk.com/aweme/v1/chart/music/list/"
DY_CHART_ID = "6853972723954146568"   # 抖音热歌榜 chart_id
DY_HEADERS = {"User-Agent": "okhttp3"}

# —— 网络热门榜（非抖音）：网易云热歌榜 / QQ音乐热歌榜 ——
# 榜单提供"当前热门歌曲清单"，音源统一走 gd 音源桥搜索同名歌曲下载（gd 桥已验证可用）。
# 网易云热歌榜（歌单 3778678 = 云音乐热歌榜，n=100 取全榜 100 首）
WY_HOT_URL = "https://music.163.com/api/v6/playlist/detail?id=3778678&n=100"
# QQ音乐热歌榜（topid=26 = 热歌榜）
QQ_HOT_URL = "https://c.y.qq.com/v8/fcg-bin/fcg_v8_toplist_cp.fcg?topid=26&type=toplist&format=json&page=1&num=100"

def fetch_wy_hot():
    """网易云热歌榜：返回 [{name, singer}] 列表"""
    items = []
    try:
        req = urllib.request.Request(WY_HOT_URL, headers={"User-Agent": "Mozilla/5.0",
                                                          "Referer": "https://music.163.com/"})
        with urllib.request.urlopen(req, timeout=15, context=make_ctx()) as r:
            d = json.loads(r.read().decode("utf-8", "ignore"))
        for t in ((d.get("playlist") or {}).get("tracks") or []):
            items.append({"name": t.get("name") or "",
                          "singer": ",".join(a.get("name", "") for a in (t.get("ar") or []))})
    except Exception as e:
        print("[wy_hot-err] %s" % e, flush=True)
    return items

def fetch_qq_hot():
    """QQ音乐热歌榜：返回 [{name, singer}] 列表"""
    items = []
    try:
        req = urllib.request.Request(QQ_HOT_URL, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=15, context=make_ctx()) as r:
            d = json.loads(r.read().decode("utf-8", "ignore"))
        for s in (d.get("songlist") or []):
            it = s.get("data") or {}
            items.append({"name": it.get("songname") or "",
                          "singer": ",".join(x.get("name", "") for x in (it.get("singer") or []))})
    except Exception as e:
        print("[qq_hot-err] %s" % e, flush=True)
    return items

def norm_name(s):
    """归一化歌名/歌手，用于跨源匹配"""
    return re.sub(r"[\s\-–—·.()（）【】\[\]&&]|feat.*|ft\.?.*", "", str(s or "").lower())

# 翻唱/模仿/伴奏类歌手特征：热门榜匹配时跳过这些非原唱版本
COVER_MARK = ("小迷妹","翻唱","cover","Cover","模仿","深情","女声","男声","钢琴","吉他","伴奏",
              "弹唱","Remix","remix","DJ","Live","live","现场","纯享","慢摇","串烧","车载",
              "唢呐","笛子","二胡","古筝","萨克斯","小提琴","童声","粤语版","英文版","日语版")

def search_gd_match(name, singer):
    """用 gd 音源桥搜索同名歌曲（翻 2 页 + 失败重试）；歌名精确匹配 + 歌手包含任一方向，
    排除翻唱/模仿/伴奏等非原唱歌手。返回 (songmid, singer, album, interval, img) 或 None"""
    nn, ns = norm_name(name), norm_name(singer)
    for page in (1, 2):
        try:
            r = br("/search", {"source": "gd", "kw": f"{name} {singer}", "page": page, "limit": 15})
            if not r.get("ok"):
                time.sleep(0.5)
                r = br("/search", {"source": "gd", "kw": f"{name} {singer}", "page": page, "limit": 15})
            if not r.get("ok"):
                continue
            for s in r.get("list", []):
                sg_n = norm_name(s.get("singer"))
                # 跳过翻唱/模仿/伴奏等非原唱版本
                if any(m in sg_n for m in COVER_MARK):
                    continue
                if norm_name(s.get("name")) == nn and (ns and (ns in sg_n or sg_n in ns)):
                    return s.get("songmid"), s.get("singer"), s.get("albumName"), s.get("interval"), s.get("img")
        except Exception:
            continue
        time.sleep(0.2)
    return None

# —— 标签歌名过滤 ——
# 部分采集结果把"分类/场景标签"直接当歌名（如"伤感流行 - 南叙"、"2026热门DJ歌曲"、
# "emo合集"、"车载劲爆DJ"），并非真实歌曲，采集入库前一律剔除。
# 规则：
#  1) 歌名含明确的"列表/合集"性质词（歌单/合集/串烧/精选/必备/盘点/一次听个够/全集/大礼包）→ 剔除
#  2) 去掉年份/括号注释/装饰符后，剩余部分全部由标签词构成且歌名较短 → 剔除（标签当歌名）
TAGLIKE_WORDS = [
    "歌单","合集","串烧","精选","精选集","必备","盘点","排行榜","热歌榜","热歌","热门","最火",
    "劲爆","嗨曲","车载","酒吧","夜店","舞曲","纯音乐","BGM","bgm","emo","Emo","EMO","伤感",
    "民谣","流行","经典","粤语","华语","神曲","网络热歌","抖音热歌","抖音神曲","慢摇","蹦迪",
    "低音炮","卡顿","柏林之音","DJ","dj","歌曲","大礼包","全集","一次听个够","氛围感","深夜",
    "失恋","情感","高级感","节奏","旋律","原声","伴奏","钢琴","纯享","串烧舞曲","顶级","最新款",
    "网红","老歌","新歌","2026","2025","2024","2023","选","曲","嗨","燃","炸","动感","伤感歌",
    "新编","完整版","混音","混搭","MIX","Remix","remix","编","情歌","音乐","歌","单","最上头",
    "超重","烟嗓","夜色","抖音","首","低音","榜","TOP","top","柏林音","速递","排行","最新",
]
TAGLIST_MARK = ("歌单","合集","串烧","精选","必备","盘点","一次听个够","全集","大礼包")
# 场景标签词（用于"主标题同时出现 ≥2 个场景词且较短→标签歌"兜底）
SCENE_WORDS = ("DJ","dj","车载","夜店","酒吧","舞曲","串烧","蹦迪","嗨曲","劲爆","嗨","燃","炸",
               "动感","氛围","纯音乐","Remix","remix","混音","慢摇","低音炮","BGM","bgm","emo",
               "Emo","EMO","新编","完整版","最上头","顶级","最新款","网红","卡顿","柏林之音")
# 强标签词：主标题"整体等于"该词即视为标签歌名。
# 注意：流行/情歌/民谣等存在真实歌曲（李宇春《流行》、梁静茹《情歌》、赵雷《民谣》），
# 不放入此集合，只参与组合判定，避免误删真实歌曲。
TAGEXACT = {"歌单","合集","串烧","精选","必备","盘点","排行榜","热歌榜","热歌","热门","最火",
            "劲爆","嗨曲","车载","酒吧","夜店","舞曲","纯音乐","BGM","bgm","emo","Emo","EMO",
            "伤感","经典","神曲","网络热歌","抖音热歌","抖音神曲","慢摇","蹦迪","低音炮","卡顿",
            "柏林之音","顶级","最新款","网红","速递","排行","新歌","老歌","抖音","最上头","超重",
            "烟嗓","低音","榜","TOP","top","柏林音","最新","串烧舞曲","伤感歌","2026","2025",
            "2024","2023"}

def is_tag_title(name):
    """判定歌名是否为"标签/分类词当歌名"（非真实歌曲）。"""
    s = str(name or "").strip()
    if not s:
        return False
    # 先取主标题：按常见分隔符拆分，"伤感流行 - 南叙"→主标题"伤感流行"（歌手/后缀不参与判断）
    s = re.split(r"[-–—:：|·]+", s, maxsplit=1)[0].strip()
    # 去括号注释
    s = re.sub(r"[（(【\[].*?[)）】\]]", "", s)
    # 去年份/序号/连接词/装饰符/emoji
    s = re.sub(r"[\d]+年?|[\s🔥✨★☆⭐❤️💔·\-–—/、，,.!！?？]|#[^\s]*|[与和之]", "", s)
    if not s:
        return False
    # 1) 明确的合集/列表性质
    if any(w in s for w in TAGLIST_MARK):
        return True
    # 2) 主标题全部由标签词构成 → 标签当歌名
    #    长度下限 4：排除"流行/情歌/民谣"等 2 字真实歌名（误删保护）
    rest = s
    for w in sorted(TAGLIKE_WORDS, key=len, reverse=True):
        rest = rest.replace(w, "")
    if not rest and 4 <= len(s) <= 20:
        return True
    # 2b) 兜底：主标题同时出现 ≥2 个场景标签词且较短（如"夜色酒吧DJ""粤语DJ劲爆全场"）
    if len(s) <= 20 and sum(1 for w in SCENE_WORDS if w in s) >= 2:
        return True
    # 3) 主标题整体就是一个强标签词（如"emo""车载"）；流行/情歌/民谣等真实歌名不在集合内
    if s in TAGEXACT:
        return True
    return False

def load_cfg():
    """读采集配置：platforms / mode / keywords；缺省回退到老行为"""
    cfg = {"platforms": ["gd", "soda"], "mode": "search",
           "keywords": ["抖音热歌","华语流行","热门新歌","2024流行","2025流行","2023热门",
                        "华语金曲","伤感流行","民谣","抖音神曲","网络热歌","粤语经典"]}
    try:
        with open(TGT_FILE, "r", encoding="utf-8") as f:
            j = json.load(f)
        if isinstance(j, dict):
            ps = j.get("platforms")
            if isinstance(ps, list) and ps:
                cfg["platforms"] = [p for p in ps if p in ("kw","wy","kg","tx","gd","qs","soda","gm_migu","gm_fivesing","gm_joox","gm_kugou","gm_kuwo","gm_qq","dy","wy_hot","qq_hot")]
            m = j.get("mode")
            if m in ("search", "hot"):
                cfg["mode"] = m
            ks = j.get("keywords")
            if isinstance(ks, list) and ks:
                cfg["keywords"] = [str(k).strip() for k in ks if str(k).strip()]
    except Exception:
        pass
    return cfg

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

def download_cover(tid, pic_url):
    if not pic_url or not str(pic_url).startswith("http"):
        return ""
    try:
        req = urllib.request.Request(pic_url, headers={"User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)"})
        with urllib.request.urlopen(req, timeout=15, context=make_ctx()) as r:
            img = r.read()
        if len(img) < 500:
            return ""
        with open(os.path.join(FILES, f"{tid}_cover.jpg"), "wb") as f:
            f.write(img)
        return f"{tid}_cover.jpg"
    except Exception:
        return ""

def download_audio(tid, url):
    """下载音频到 files/{tid}.mp3，返回 (本地文件名, 字节数)；失败返回 ("", 0)"""
    if not url or not str(url).startswith("http"):
        return "", 0
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)"})
        with urllib.request.urlopen(req, timeout=60, context=make_ctx()) as r:
            data = r.read()
        if len(data) < 300 * 1024:
            return "", 0
        fn = tid + ".mp3"
        with open(os.path.join(FILES, fn), "wb") as f:
            f.write(data)
        return fn, len(data)
    except Exception:
        return "", 0

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

def duration_to_sec(s):
    if not s: return 0
    m = re.match(r"^(\d+):(\d{2})$", str(s).strip())
    return int(m.group(1))*60 + int(m.group(2)) if m else 0

def fetch_dy_hot(count=100):
    """抖音官方音乐榜：返回热门视频/图片配乐 BGM 列表（含标题/歌手/封面/MP3直链/热度）。
    榜单数据由抖音按 BGM 使用热度排序，天然满足"只采抖音上很火的配乐"。"""
    url = DY_MUSIC_URL + "?" + urllib.parse.urlencode({
        "device_platform": "android", "version_name": "13.2.0",
        "version_code": "130200", "aid": "1128",
        "chart_id": DY_CHART_ID, "count": count})
    req = urllib.request.Request(url, headers=DY_HEADERS)
    with urllib.request.urlopen(req, timeout=30) as r:
        d = json.loads(r.read().decode())
    if d.get("status_code") != 0:
        raise RuntimeError("dy status=%s %s" % (d.get("status_code"), d.get("status_msg")))
    out = []
    for item in (d.get("music_list") or []):
        mi = item.get("music_info") or {}
        pu = (mi.get("play_url") or {}).get("url_list") or []
        cv = (mi.get("cover_thumb") or {}).get("url_list") or []
        if not cv:
            cv = (mi.get("cover_medium") or {}).get("url_list") or []
        dur_sec = mi.get("duration") or 0   # 抖音音乐榜 duration 单位为秒（BGM 试听片段时长）
        out.append({
            "mid": str(mi.get("id_str") or mi.get("mid") or ""),
            "name": (mi.get("title") or "").strip(),
            "singer": (mi.get("author") or "").strip(),
            "album": (mi.get("album") or "").strip(),
            "url": pu[0] if pu else "",
            "img": cv[0] if cv else "",
            "dur": float(dur_sec),
            "heat": item.get("heat") or 0,
            "user_count": mi.get("user_count") or 0,
        })
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", type=int, default=500)
    args = ap.parse_args()
    cfg = load_cfg()
    plats = cfg["platforms"]
    mode = cfg["mode"]
    kws = cfg["keywords"]
    print("[cfg] platforms=%s mode=%s kws=%d" % (plats, mode, len(kws)), flush=True)
    os.makedirs(FILES, exist_ok=True)
    c = sqlite3.connect(DB, timeout=30)

    inserted = skip = fail = dropped = 0
    run_songs = []
    run_skipped = 0
    run_started = time.time()

    def save_run_state():
        _tmp = RUN_STATE + ".tmp"
        with open(_tmp, "w", encoding="utf-8") as _f:
            json.dump({"started": run_started, "collected": run_songs, "skipped": run_skipped}, _f, ensure_ascii=False)
        os.replace(_tmp, RUN_STATE)

    save_run_state()

    def add_candidate(src, mid, name, singer, album, interval, img, pre_url="", pre_pic="", pre_dur=0.0):
        nonlocal inserted, skip, fail, dropped, run_skipped
        if inserted >= args.target: return
        if not mid or not name: return
        artist = (singer or "").strip()
        # 0) 标签歌名过滤：歌名本身是"分类/场景标签"（如"伤感流行""2026热门DJ歌曲""emo合集"）
        #    而非真实歌曲 → 直接剔除，不入库
        if is_tag_title(name):
            dropped += 1
            run_skipped += 1
            print("[tag-skip %d] %s - %s （标签当歌名，过滤）" % (dropped, name, artist or "?"), flush=True)
            save_run_state()
            return
        # 1) 同源同 ID 去重：同一音源同一首歌只采集一次
        dup = c.execute("SELECT 1 FROM collected_tracks WHERE source=? AND source_id=?", (src, mid)).fetchone()
        if dup:
            skip += 1
            run_skipped += 1
            save_run_state()
            return
        # 2) 跨来源去重：同名同歌手已在库（采集库 / 用户上传库任一）→ 不再重复采集。
        #    同一首歌在不同平台 source_id 不同，若不按歌名+歌手查重，会重复入库多份
        dup2 = c.execute("SELECT 1 FROM collected_tracks WHERE title=? AND artist=?", (name, artist)).fetchone()
        if not dup2:
            dup2 = c.execute("SELECT 1 FROM tracks WHERE title=? AND artist=?", (name, artist)).fetchone()
        if dup2:
            skip += 1
            run_skipped += 1
            save_run_state()
            return
        tid = hashlib.md5(f"{src}:{mid}".encode()).hexdigest()
        # 抖音音乐榜数据自带播放地址/封面/时长：pre_url 非空则直接使用，免去音源桥解析
        if pre_url:
            lrc = ""
            pic = pre_pic or img or ""
            url = pre_url
            pre_dur = pre_dur or 0.0
        else:
            # 取歌词+封面+播放地址
            try:
                r = br("/song", {"source": src, "songmid": mid, "name": name,
                                 "singer": singer or "", "album": album or "",
                                 "interval": interval or "", "img": img or ""})
                if not r.get("ok"):
                    fail += 1; return
                lrc = r.get("lyric") or ""
                pic = r.get("pic") or img or ""
                url = str(r.get("url") or "")
            except Exception:
                fail += 1; return
        local_cover = download_cover(tid, pic)
        # 关键：先确认音频能下载成功，才允许入库；下载不了直接跳过（不留无音频脏记录）
        local_audio, audio_size, audio_ok = "", 0, False
        if url.startswith("http"):
            local_audio, audio_size = download_audio(tid, url)
            audio_ok = bool(local_audio)
            if audio_ok:
                year = extract_year(os.path.join(FILES, local_audio))
                if year is not None and (year < 2020 or year > 2026):
                    # 年份不符不入库（保持 2020-2026 选歌口径），删除已下文件
                    for _p in (os.path.join(FILES, local_audio), os.path.join(FILES, local_cover) if local_cover else None):
                        if _p:
                            try: os.remove(_p)
                            except Exception: pass
                    dropped += 1
                    print("[drop %d] %d年 %s - %s" % (dropped, year, name, artist or "?"), flush=True)
                    return
        if not audio_ok:
            # 音频下载失败：不入库，同时清理已下载的封面，避免孤儿文件
            if local_cover:
                try: os.remove(os.path.join(FILES, local_cover))
                except Exception: pass
            fail += 1
            print("[fail-audio] %s - %s （音频不可下载，跳过入库）" % (name, artist or "?"), flush=True)
            return
        c.execute(
            """INSERT OR IGNORE INTO collected_tracks
               (id,title,artist,album,cover,duration,source,source_id,play_url,size,created,user_id,lrc)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (tid, name, artist, (album or "").strip(),
             local_cover, pre_dur or duration_to_sec(interval), src, mid, local_audio, audio_size, time.time(), OWNER_UID, lrc))
        c.commit()
        inserted += 1
        run_songs.append({"title": name, "artist": artist, "t": time.time(), "audio": True})
        save_run_state()
        print("[+%d/%d] %s | %s - %s [音频✓]" % (inserted, args.target, src, name, artist or "?"), flush=True)

    # 1) 关键词搜索补量（仅 mode=search 时跑）
    if mode == "search":
      for kw in kws:
        if inserted >= args.target: break
        for src in plats:
            if inserted >= args.target: break
            for page in range(1, 4):
                if inserted >= args.target: break
                try:
                  r = br("/search", {"source": src, "kw": kw, "page": page, "limit": 20})
                  if not r.get("ok"): continue
                  for s in r.get("list", []):
                    if inserted >= args.target: break
                    add_candidate(src, s.get("songmid"), s.get("name"), s.get("singer"),
                                  s.get("albumName"), s.get("interval"), s.get("img"))
                    time.sleep(0.4)
                except Exception:
                    pass
                time.sleep(0.6)

    # 2) 热门榜兜底（所有选的平台翻页；dy=抖音官方音乐榜；wy_hot/qq_hot=网易云/QQ音乐热歌榜，
    #    只采全网热门歌曲，音源统一走 gd 桥，标签歌名过滤自动生效）
    for src in plats:
        if inserted >= args.target: break
        if src == "dy":
            try:
                for s in fetch_dy_hot(100):
                    if inserted >= args.target: break
                    add_candidate("dy", s["mid"], s["name"], s["singer"], s["album"],
                                  "", s["img"], pre_url=s["url"], pre_pic=s["img"], pre_dur=s["dur"])
                    time.sleep(0.4)
            except Exception as e:
                print("[dy-err] %s" % e, flush=True)
            continue
        if src in ("wy_hot", "qq_hot"):
            try:
                items = fetch_wy_hot() if src == "wy_hot" else fetch_qq_hot()
                for it in items:
                    if inserted >= args.target: break
                    hit = search_gd_match(it["name"], it["singer"])
                    if hit:
                        mid, sg2, alb2, iv2, im2 = hit
                        add_candidate("gd", mid, it["name"], sg2 or it["singer"], alb2, iv2, im2)
                    else:
                        print("[%s-skip] %s - %s （gd 未匹配同名热门歌）" % (src, it["name"], it["singer"] or "?"), flush=True)
                    time.sleep(0.4)
            except Exception as e:
                print("[%s-err] %s" % (src, e), flush=True)
            continue
        for page in range(1, 25):
            if inserted >= args.target: break
            try:
                r = br("/hot", {"source": src, "page": page, "limit": 20})
                if not r.get("ok"): continue
                for s in r.get("list", []):
                    if inserted >= args.target: break
                    add_candidate(src, s.get("songmid"), s.get("name"), s.get("singer"),
                                  s.get("albumName"), s.get("interval"), s.get("img"))
                    time.sleep(0.4)
            except Exception as e:
                print("[hot-err] %s p%d: %s" % (src, page, e), flush=True)
            time.sleep(0.8)

    c.close()
    # 收尾：自动补一轮音频下载（本轮下载失败的歌标待补，这里统一补齐，App 全部可播）
    try:
        import subprocess as _sp
        _sp.call(["python3", "/www/wwwroot/music/source-bridge/download_collected.py"])
    except Exception:
        pass
    print("DONE inserted=%d skip=%d fail=%d dropped=%d" % (inserted, skip, fail, dropped), flush=True)

if __name__ == "__main__":
    main()
