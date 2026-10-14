#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""专项验证：个性化推荐「3 小时内不重复推送同一首歌」去重逻辑。

独立于冒烟测试，直接调用 server.py 内部函数：
  1) 第一次推荐 → 记录推送 → 第二次推荐必须完全不重复
  2) 窗口内(2h)仍去重；窗口外(3h+)记录过期，可重新推送
  3) 不同用户去重互不影响
"""
import os
import sys
import time
import tempfile
import shutil

TMP = tempfile.mkdtemp(prefix="music_dedup_")
os.environ["MUSIC_ROOT"] = TMP
os.environ["MUSIC_PORT"] = "18799"

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import server  # noqa: E402

PASS = 0
FAIL = 0


def check(name, cond, extra=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print("  [PASS]", name)
    else:
        FAIL += 1
        print("  [FAIL]", name, extra)


def seed_tracks(n=60):
    """插入 n 首采集歌曲（歌名/歌手各不相同，避免相似度过滤互相干扰）"""
    c = server.db()
    now = time.time()
    for i in range(n):
        c.execute(
            "INSERT OR IGNORE INTO collected_tracks"
            "(id,title,artist,album,cover,duration,source,source_id,play_url,size,created,user_id)"
            " VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
            ("t%03d" % i, "测试歌曲%03d" % i, "歌手%03d" % i, "专辑%03d" % i,
             "", 180.0, "test", "sid%03d" % i, "http://x/%d" % i, 1024, now - 86400, ""))
    c.commit()
    c.close()


def main():
    seed_tracks(60)

    # ---------- 1) 同一用户：第一次推荐 → 记录 → 第二次推荐不重复 ----------
    now = time.time()
    uid = "user_a"
    rnd1 = server.random.Random("user_a|%d|0" % int(now // server.REC_BUCKET_SECONDS))
    b1 = server.build_recommendations(server.db(), uid, rnd=rnd1)
    ids1 = [tid for tid, _ in b1]
    check("第一批推荐非空且≤20", 0 < len(ids1) <= server.REC_BUDGET, "n=%d" % len(ids1))

    server._rec_remember_pushed(uid, ids1, now)
    recent = server._rec_recent_pushed(uid, now)
    check("记录成功：3小时内已推集合=第一批", recent == set(ids1),
          "recent=%d ids1=%d" % (len(recent), len(ids1)))

    rnd2 = server.random.Random("user_a|%d|1" % int(now // server.REC_BUCKET_SECONDS))
    b2 = server.build_recommendations(server.db(), uid, rnd=rnd2, pushed=recent)
    ids2 = [tid for tid, _ in b2]
    inter = set(ids1) & set(ids2)
    check("3小时内第二次推荐与第一批零重复", not inter, "交集=%d" % len(inter))
    check("第二批仍有推荐可推", len(ids2) > 0, "n=%d" % len(ids2))

    # ---------- 2) 窗口语义：2h 内仍去重，3h+ 记录过期可重新推 ----------
    recent2h = server._rec_recent_pushed(uid, now + 2 * 3600)
    check("2小时后仍在窗口内（继续去重）", recent2h == set(ids1))
    recent3h = server._rec_recent_pushed(uid, now + 3 * 3600 + 5)
    check("3小时后窗口过期（清空，可重新推）", recent3h == set())
    # 过期后再推荐，第一批的歌允许回归
    b3 = server.build_recommendations(server.db(), uid, rnd=rnd1)
    ids3 = [tid for tid, _ in b3]
    check("窗口过期后第一批歌曲可重新被推荐", len(set(ids1) & set(ids3)) > 0,
          "回归=%d" % len(set(ids1) & set(ids3)))

    # ---------- 3) 用户隔离：B 用户不受 A 用户推送记录影响 ----------
    uid_b = "user_b"
    recent_b = server._rec_recent_pushed(uid_b, now)
    check("不同用户去重记录互不影响", recent_b == set())
    # B 用与 A 完全相同的随机种子：若无去重隔离，B 应能推到 A 已推过的全部歌
    rnd_b = server.random.Random("user_a|%d|0" % int(now // server.REC_BUCKET_SECONDS))
    bb = server.build_recommendations(server.db(), uid_b, rnd=rnd_b)
    shared_b = set(ids1) & set(tid for tid, _ in bb)
    check("B 用户能推到 A 已推过的歌（去重按用户隔离）", len(shared_b) == len(ids1),
          "共享=%d/%d" % (len(shared_b), len(ids1)))

    # ---------- 4) 接口级联调：模拟两次 /api/recommend 行为 ----------
    _p = server._rec_recent_pushed(uid, time.time())
    rec1 = server.build_recommendations(server.db(), uid, pushed=_p)
    server._rec_remember_pushed(uid, [tid for tid, _ in rec1], time.time())
    _p2 = server._rec_recent_pushed(uid, time.time())
    rec2 = server.build_recommendations(server.db(), uid, pushed=_p2)
    inter_c = set(t for t, _ in rec1) & set(t for t, _ in rec2)
    check("接口级联（推→记→再推）零重复", not inter_c, "交集=%d" % len(inter_c))

    shutil.rmtree(TMP, ignore_errors=True)
    print("===== 推送去重专项验证: %d 通过, %d 失败 =====" % (PASS, FAIL))
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
