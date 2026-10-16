#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""流萤音乐 · 备份与回滚核心（自动安装程序使用，也可单独命令行运行）

备份内容：
    - SQLite 数据库（先 PRAGMA wal_checkpoint(TRUNCATE)，连同 -wal/-shm 一起备份）
    - files/ 全部媒体（音频/封面/歌词/头像/评论图）
    - 关键配置（config.json / admin_pwd / .sign_secret / site_config.json /
      source-bridge 的 collect_target|collect_run|qs_session 等）
    - source-bridge/（含线上补齐的 source.js、download_collected.py；默认排除 node_modules）
    - 系统配置（systemd unit、nginx 站点 conf，可读才备份）

产物：
    <root>/backup/<时间戳>/full_backup.tar.gz
    <root>/backup/<时间戳>/manifest.json   （逐项 sha256 + 大小 + 时间 + 版本）
    <root>/backup/latest -> <时间戳>/
    仅保留最近 KEEP_BACKUPS 份。

用法：
    python3 install/backup.py backup   [--root /www/wwwroot/music] [--keep 3]
    python3 install/backup.py verify   [--backup-dir <dir>]
    python3 install/backup.py restore  [--backup-dir <dir>] [--yes]
"""
import os
import sys
import json
import time
import shutil
import hashlib
import sqlite3
import tarfile
import argparse
import datetime

KEEP_BACKUPS = 3
BACKUP_SUBDIR = "backup"
VERSION = "1.0"

# 备份的关键相对路径（相对 root），存在才备份
CONFIG_RELPATHS = [
    "config.json", "admin_pwd", ".sign_secret", "site_config.json",
    "ai_config.json",
    "source-bridge/collect_target.json",
    "source-bridge/collect_run.json",
    "source-bridge/qs_session.json",
]
# 备份 source-bridge 时排除的子项（可在打包时按需保留 node_modules：--include-node-modules）
BRIDGE_EXCLUDE_DIRS = {"node_modules", "__pycache__", ".git"}

# 系统配置（可读才备份；容器/非 root 可能无权）
SYSTEMD_UNITS = ["/etc/systemd/system/music.service",
                 "/etc/systemd/system/source-bridge.service"]
# nginx 常见站点配置路径（宝塔 + 标准 conf.d），逐个探测
NGINX_CONF_CANDIDATES = [
    "/www/server/panel/vhost/nginx",
    "/etc/nginx/conf.d",
    "/etc/nginx/sites-available",
]
NGINX_NAME_HINTS = ("dbmt999", "music")


def log(msg):
    print("[backup] %s" % msg, flush=True)


def sha256_file(path, buf=1 << 20):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(buf)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def checkpoint_db(db_path):
    """WAL 落盘，尽量减少热备份时 -wal 残留；失败不阻断（继续拷物理文件）。"""
    if not os.path.exists(db_path):
        return False
    try:
        conn = sqlite3.connect(db_path, timeout=15)
        try:
            conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        finally:
            conn.close()
        return True
    except Exception as e:
        log("wal_checkpoint 跳过：%s" % e)
        return False


def _add_file_manifest(entries, root, abspath, arcname, required_nonempty=False):
    if not os.path.isfile(abspath):
        return False
    size = os.path.getsize(abspath)
    entries.append({
        "arcname": arcname,
        "abspath": abspath,
        "size": size,
        "sha256": sha256_file(abspath),
        "required_nonempty": required_nonempty,
    })
    return True


def collect_entries(root, include_node_modules=False):
    """收集待备份文件清单（返回 entries 列表，arcname 以 root/ 为前缀）。"""
    entries = []
    root = os.path.abspath(root)

    # 1) 数据库（checkpoint 后连同 wal/shm）
    db_path = os.path.join(root, "tracks.db")
    checkpoint_db(db_path)
    for name in ("tracks.db", "tracks.db-wal", "tracks.db-shm"):
        _add_file_manifest(entries, root, os.path.join(root, name),
                           os.path.join("root", name),
                           required_nonempty=(name == "tracks.db"))

    # 2) files/ 目录（逐个文件）
    files_dir = os.path.join(root, "files")
    n_files = 0
    for base, dirs, fnames in os.walk(files_dir):
        dirs[:] = [d for d in dirs if d not in ("__pycache__",)]
        for fn in fnames:
            ap = os.path.join(base, fn)
            rel = os.path.relpath(ap, root)
            if _add_file_manifest(entries, root, ap, os.path.join("root", rel)):
                n_files += 1
    log("files/ 媒体文件 %d 个" % n_files)

    # 3) 关键配置
    for rel in CONFIG_RELPATHS:
        _add_file_manifest(entries, root, os.path.join(root, rel),
                           os.path.join("root", rel))

    # 4) source-bridge（排除 node_modules 等）
    bridge = os.path.join(root, "source-bridge")
    n_bridge = 0
    for base, dirs, fnames in os.walk(bridge):
        if not include_node_modules:
            dirs[:] = [d for d in dirs if d not in BRIDGE_EXCLUDE_DIRS]
        else:
            dirs[:] = [d for d in dirs if d not in ("__pycache__", ".git")]
        for fn in fnames:
            ap = os.path.join(base, fn)
            rel = os.path.relpath(ap, root)
            if _add_file_manifest(entries, root, ap, os.path.join("root", rel)):
                n_bridge += 1
    log("source-bridge 文件 %d 个" % n_bridge)

    # 5) 系统配置（可读才备份）
    for unit in SYSTEMD_UNITS:
        _add_file_manifest(entries, root, unit, os.path.join("system", os.path.basename(unit)))
    for d in NGINX_CONF_CANDIDATES:
        if not os.path.isdir(d):
            continue
        for fn in os.listdir(d):
            if fn.endswith(".conf") or fn.endswith(".bak"):
                low = fn.lower()
                if any(h in low for h in NGINX_NAME_HINTS):
                    ap = os.path.join(d, fn)
                    _add_file_manifest(entries, root, ap,
                                       os.path.join("nginx", fn))
    return entries


def create_backup(root, keep=KEEP_BACKUPS, include_node_modules=False):
    """执行完整备份；返回 (backup_dir, report)。校验失败抛 RuntimeError。"""
    root = os.path.abspath(root)
    if not os.path.isdir(root):
        raise RuntimeError("部署根目录不存在：%s" % root)

    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    bdir = os.path.join(root, BACKUP_SUBDIR, ts)
    os.makedirs(bdir, exist_ok=True)
    tar_path = os.path.join(bdir, "full_backup.tar.gz")

    entries = collect_entries(root, include_node_modules=include_node_modules)

    # 必含校验：数据库必须存在且非空（存在旧部署时）
    db_entries = [e for e in entries if e["arcname"] == os.path.join("root", "tracks.db")]
    if db_entries and db_entries[0]["size"] == 0:
        raise RuntimeError("数据库文件为空，拒绝备份：tracks.db")

    manifest_items = []
    with tarfile.open(tar_path, "w:gz") as tar:
        for e in entries:
            tar.add(e["abspath"], arcname=e["arcname"])
            manifest_items.append({k: e[k] for k in ("arcname", "size", "sha256")})

    manifest = {
        "version": VERSION,
        "created_at": datetime.datetime.now().isoformat(timespec="seconds"),
        "root": root,
        "timestamp": ts,
        "file_count": len(manifest_items),
        "total_size": sum(i["size"] for i in manifest_items),
        "files": manifest_items,
    }
    with open(os.path.join(bdir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)

    # 备份后自检：tar 可打开、逐项存在且 sha256 一致
    ok, bad = verify_tar(tar_path, manifest)
    if not ok:
        raise RuntimeError("备份完整性校验失败：%s" % bad[:5])

    _prune_and_link(root, keep, ts)
    log("备份完成：%s（%d 个文件，%.1f MB）" % (
        bdir, len(manifest_items), manifest["total_size"] / 1048576.0))
    return bdir, manifest


def verify_tar(tar_path, manifest):
    if not os.path.isfile(tar_path):
        return False, ["tar 不存在"]
    with tarfile.open(tar_path, "r:gz") as tar:
        members = {m.name: m for m in tar.getmembers() if m.isfile()}
        want = {i["arcname"]: i for i in manifest["files"]}
        for name, item in want.items():
            m = members.get(name)
            if m is None:
                return False, ["缺失成员 %s" % name]
            if m.size != item["size"]:
                return False, ["大小不一致 %s" % name]
        # 内容 sha256 校验（抓出 tar 内部被篡改/截断）
        for name, item in want.items():
            f = tar.extractfile(members[name])
            if f is None:
                return False, ["无法读取 %s" % name]
            h = hashlib.sha256()
            while True:
                b = f.read(1 << 20)
                if not b:
                    break
                h.update(b)
            if h.hexdigest() != item["sha256"]:
                return False, ["内容校验失败 %s" % name]
    return True, []


def _prune_and_link(root, keep, latest_ts):
    broot = os.path.join(root, BACKUP_SUBDIR)
    dirs = sorted(d for d in os.listdir(broot)
                  if os.path.isdir(os.path.join(broot, d)) and d[0].isdigit())
    # 超出保留份数删除最旧
    for old in dirs[:-keep] if len(dirs) > keep else []:
        shutil.rmtree(os.path.join(broot, old), ignore_errors=True)
        log("清理旧备份：%s" % old)
    # latest 软链
    link = os.path.join(broot, "latest")
    try:
        if os.path.islink(link) or os.path.exists(link):
            os.remove(link)
        os.symlink(latest_ts, link)
    except OSError:
        pass


def resolve_backup_dir(root, backup_dir=None):
    if backup_dir:
        return os.path.abspath(backup_dir)
    link = os.path.join(root, BACKUP_SUBDIR, "latest")
    if os.path.islink(link):
        return os.path.realpath(link)
    broot = os.path.join(root, BACKUP_SUBDIR)
    dirs = sorted(d for d in os.listdir(broot)
                  if os.path.isdir(os.path.join(broot, d)) and d[0].isdigit())
    if not dirs:
        raise RuntimeError("没有可用备份")
    return os.path.join(broot, dirs[-1])


def restore_backup(root, backup_dir=None, stop_services=None):
    """从备份恢复。stop_services: 可选回调，恢复前停服务（返回其输出）。"""
    root = os.path.abspath(root)
    bdir = resolve_backup_dir(root, backup_dir)
    tar_path = os.path.join(bdir, "full_backup.tar.gz")
    with open(os.path.join(bdir, "manifest.json"), encoding="utf-8") as f:
        manifest = json.load(f)
    ok, bad = verify_tar(tar_path, manifest)
    if not ok:
        raise RuntimeError("备份包损坏，拒绝回滚：%s" % bad[:5])

    svc_out = ""
    if callable(stop_services):
        try:
            svc_out = stop_services() or ""
        except Exception as e:
            svc_out = "停服务异常（继续恢复）：%s" % e

    # 恢复到临时目录，校验后再合并，避免半成品覆盖
    staging = os.path.join(bdir, "restore_staging")
    if os.path.isdir(staging):
        shutil.rmtree(staging)
    with tarfile.open(tar_path, "r:gz") as tar:
        try:
            tar.extractall(staging, filter="data")   # Python 3.12+ 安全过滤
        except TypeError:
            tar.extractall(staging)                  # 旧版 Python 回退

    root_src = os.path.join(staging, "root")
    if not os.path.isdir(root_src):
        raise RuntimeError("备份内缺少 root/ 目录")

    # 逐项校验 staging 文件 sha256
    want = {i["arcname"]: i["sha256"] for i in manifest["files"]}
    for base, _, fnames in os.walk(staging):
        for fn in fnames:
            ap = os.path.join(base, fn)
            arc = os.path.relpath(ap, staging).replace(os.sep, "/")
            if arc in want and sha256_file(ap) != want[arc]:
                raise RuntimeError("恢复文件校验失败：%s" % arc)

    # 合并恢复 root/ 下内容到真实 root（覆盖同名）
    for item in manifest["files"]:
        arc = item["arcname"]
        if not (arc.startswith("root/")):
            continue
        rel = arc[len("root/"):]
        src = os.path.join(staging, "root", rel)
        dst = os.path.join(root, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)

    shutil.rmtree(staging, ignore_errors=True)
    log("回滚完成：%s → %s" % (bdir, root))
    return {"backup_dir": bdir, "root": root, "stop_services": svc_out,
            "file_count": manifest["file_count"]}


def detect_root():
    """install/backup.py 的上两级即部署根（<root>/install/backup.py）。"""
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["backup", "verify", "restore"])
    ap.add_argument("--root", default=None)
    ap.add_argument("--backup-dir", default=None)
    ap.add_argument("--keep", type=int, default=KEEP_BACKUPS)
    ap.add_argument("--include-node-modules", action="store_true")
    ap.add_argument("--yes", action="store_true")
    args = ap.parse_args()

    root = os.path.abspath(args.root or detect_root())
    if args.action == "backup":
        bdir, _ = create_backup(root, keep=args.keep,
                                include_node_modules=args.include_node_modules)
        print("BACKUP_DIR=%s" % bdir)
    elif args.action == "verify":
        bdir = resolve_backup_dir(root, args.backup_dir)
        with open(os.path.join(bdir, "manifest.json"), encoding="utf-8") as f:
            manifest = json.load(f)
        ok, bad = verify_tar(os.path.join(bdir, "full_backup.tar.gz"), manifest)
        print("VERIFY=%s files=%d %s" % ("OK" if ok else "FAIL",
                                         manifest["file_count"], bad[:3]))
        sys.exit(0 if ok else 1)
    else:
        if not args.yes:
            print("将用备份覆盖 %s，输入 yes 继续：" % root, end="")
            if input().strip().lower() != "yes":
                print("已取消")
                return
        rep = restore_backup(root, args.backup_dir)
        print("RESTORE_OK %s" % rep["backup_dir"])


if __name__ == "__main__":
    main()
