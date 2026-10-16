#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""流萤音乐 · 安装核心逻辑（被 install_api.py 调用，也可独立 dry-run 演练）。

安装步骤（状态机，可断点续跑）：
    env_check → backup(仅覆盖旧部署) → write_config → install_deps →
    init_db → setup_systemd → setup_nginx → start_services → selfcheck → finalize

dry-run 模式：不执行 systemctl/nginx 等特权命令，改为渲染预览文件 + 直接拉起
python 服务做自检，用于在无 root 的 CI / 沙箱中端到端验证安装逻辑。
"""
import os
import sys
import json
import time
import shutil
import secrets
import socket
import subprocess
import threading
import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT_DEFAULT = os.path.dirname(HERE)          # <root>
sys.path.insert(0, ROOT_DEFAULT)

STATE_FILE_NAME = "install_state.json"
CONFIG_NAME = "config.json"
ADMIN_PWD_NAME = "admin_pwd"

INSTALL_PORT_DEFAULT = 8899
API_PORT_DEFAULT = 8788
BRIDGE_PORT_DEFAULT = 8789


# ---------------- 工具 ----------------

def log(state, msg, level="info"):
    line = {"t": datetime.datetime.now().strftime("%H:%M:%S"), "level": level, "msg": msg}
    state.setdefault("logs", []).append(line)
    print("[installer] %s" % msg, flush=True)
    save_state(state)


def state_path(root):
    return os.path.join(root, STATE_FILE_NAME)


def load_state(root):
    p = state_path(root)
    if os.path.exists(p):
        try:
            with open(p, encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return None


def save_state(state):
    p = state_path(state["root"])
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=2)
    os.replace(tmp, p)


def new_state(root, dry_run, install_port):
    return {
        "root": root,
        "dry_run": bool(dry_run),
        "install_port": install_port,
        "phase": "idle",
        "locked": False,
        "token": secrets.token_urlsafe(24),
        "steps": [],
        "logs": [],
        "result": None,
        "started_at": None,
        "finished_at": None,
    }


def run_cmd(cmd, dry_run, timeout=180, shell=False):
    """执行系统命令；dry_run 时只回显不执行（返回 0 与占位输出）。"""
    if dry_run:
        return 0, "[dry-run] %s" % (cmd if isinstance(cmd, str) else " ".join(cmd)), ""
    p = subprocess.run(cmd if shell else cmd, shell=shell,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       timeout=timeout)
    return p.returncode, p.stdout.decode("utf-8", "ignore"), ""


def have(cmd):
    return shutil.which(cmd) is not None


def port_in_use(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(0.3)
    try:
        return s.connect_ex(("127.0.0.1", port)) == 0
    finally:
        s.close()


def is_existing_deploy(root):
    """判断是否覆盖现有线上：有 tracks.db 或 files/ 或 admin_pwd。"""
    return any(os.path.exists(os.path.join(root, x))
               for x in ("tracks.db", "admin_pwd")) or os.path.isdir(os.path.join(root, "files"))


# ---------------- Step: 环境检测 ----------------

def detect_env(root, install_port, api_port, bridge_port):
    checks = []

    def add(name, ok, required, detail=""):
        checks.append({"name": name, "ok": bool(ok), "required": required, "detail": detail})

    # Python
    py = sys.version.split()[0]
    pyok = sys.version_info >= (3, 8)
    add("Python ≥ 3.8（当前 %s）" % py, pyok, True)
    # Node
    node = ""
    if have("node"):
        try:
            node = subprocess.check_output(["node", "-v"], timeout=10).decode().strip()
        except Exception:
            node = ""
    add("NodeJS（音源桥，当前 %s）" % (node or "未安装"), bool(node), True,
        "" if node else "音源桥需要 Node 16+，可在安装 Node 后重装音源桥服务")
    # npm
    add("npm（%s）" % ("已安装" if have("npm") else "未安装"), have("npm"), False)
    # nginx
    add("Nginx（%s）" % ("已安装" if have("nginx") else "未安装"), have("nginx"), False,
        "" if have("nginx") else "可安装后由面板/手工配置反代")
    # sqlite
    import sqlite3
    add("SQLite（%s）" % sqlite3.sqlite_version, True, True)
    # systemd
    sd = os.path.isdir("/run/systemd/system")
    add("systemd（%s）" % ("可用" if sd else "不可用"), sd, False,
        "" if sd else "将降级为直接进程方式（需自行守护）")
    # 目录可写
    wok = os.access(root, os.W_OK)
    add("部署目录可写 %s" % root, wok, True)
    # 磁盘
    free_gb = shutil.disk_usage(root).free / 1073741824.0
    add("磁盘剩余 %.1f GB（≥1GB）" % free_gb, free_gb >= 1, True)
    # 端口
    for label, p in (("安装端口", install_port), ("API端口", api_port), ("音源桥端口", bridge_port)):
        busy = port_in_use(p)
        # 全新场景端口应空闲；busy 仅警告（可能是旧服务在跑，覆盖升级会重启它）
        add("%s %d（%s）" % (label, p, "占用中" if busy else "空闲"),
            not busy or is_existing_deploy(root), False,
            "占用中" if busy else "")
    # pip 依赖
    pil = mutagen = False
    try:
        import PIL  # noqa
        pil = True
    except Exception:
        pass
    try:
        import mutagen  # noqa
        mutagen = True
    except Exception:
        pass
    add("Python 依赖 Pillow（%s）" % ("已装" if pil else "缺失，安装阶段自动 pip"), pil, False)
    add("Python 依赖 mutagen（%s）" % ("已装" if mutagen else "缺失，安装阶段自动 pip"), mutagen, False)
    # 音源桥 node_modules
    nm = os.path.isdir(os.path.join(root, "source-bridge", "node_modules"))
    add("音源桥 node_modules（%s）" % ("已安装" if nm else "缺失，安装阶段自动 npm"), nm, False)
    # 音源桥源脚本 source.js（bridge.js 启动强依赖，缺失则音源桥无法启动）
    src_js = os.path.join(root, "source-bridge", "source.js")
    has_source_js = os.path.isfile(src_js)
    add("音源桥 source.js（%s）" % ("已就位" if has_source_js else "缺失，音源桥将无法启动"),
        has_source_js, False,
        "" if has_source_js else "覆盖安装会自动从备份恢复；全新安装需自行放入 source-bridge/source.js")

    blocking = [c for c in checks if c["required"] and not c["ok"]]
    return {
        "checks": checks,
        "can_install": len(blocking) == 0,
        "blocking": blocking,
        "existing": is_existing_deploy(root),
    }


# ---------------- Step: 写 config.json ----------------

def step_write_config(state, p):
    root = state["root"]
    domain = p["domain"].strip().lower()
    api_port = int(p.get("api_port") or API_PORT_DEFAULT)
    bridge_port = int(p.get("bridge_port") or BRIDGE_PORT_DEFAULT)
    # 复用既有签名密钥（config.py 也会自动读 .sign_secret；这里显式读出写进 config，便于安装报告）
    sign_secret = ""
    sf = os.path.join(root, ".sign_secret")
    if os.path.exists(sf):
        sign_secret = open(sf, encoding="utf-8").read().strip()
    if not sign_secret:
        sign_secret = secrets.token_hex(32)
        with open(sf, "w", encoding="utf-8") as f:
            f.write(sign_secret)
    cfg = {
        "root": root,
        "domain": domain,
        "public_url": "https://%s/music" % domain,
        "sign_secret": sign_secret,
        "collect_key": secrets.token_hex(12),
        "ports": {"api": api_port, "bridge": bridge_port,
                  "install": state["install_port"]},
        "admin_pwd_file": os.path.join(root, ADMIN_PWD_NAME),
        "paths": {
            "files": os.path.join(root, "files"),
            "db": os.path.join(root, "tracks.db"),
            "bridge_dir": os.path.join(root, "source-bridge"),
            "collect_target": os.path.join(root, "source-bridge", "collect_target.json"),
            "collect_run": os.path.join(root, "source-bridge", "collect_run.json"),
            "collect_log": os.path.join(root, "source-bridge", "collect_v3.log"),
            "collect_v3": os.path.join(root, "source-bridge", "collect_v3.py"),
            "download_collected": os.path.join(root, "source-bridge", "download_collected.py"),
            "qs_session": os.path.join(root, "source-bridge", "qs_session.json"),
        },
    }
    tmp = os.path.join(root, CONFIG_NAME + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
    os.replace(tmp, os.path.join(root, CONFIG_NAME))
    os.makedirs(cfg["paths"]["files"], exist_ok=True)
    state["config"] = cfg
    log(state, "config.json 已生成（domain=%s）" % domain)


# ---------------- Step: 管理员密码 ----------------

def step_admin_pwd(state, p):
    root = state["root"]
    pwd_file = os.path.join(root, ADMIN_PWD_NAME)
    keep = bool(p.get("keep_admin_pwd")) and os.path.exists(pwd_file)
    if keep:
        log(state, "覆盖安装：保留现有后台密码")
        state["admin_password_kept"] = True
        return
    pwd = p.get("password") or ""
    if p.get("gen_password"):
        pwd = secrets.token_urlsafe(12)
    if not (6 <= len(pwd) <= 64):
        raise RuntimeError("后台密码长度需 6-64 位")
    with open(pwd_file, "w", encoding="utf-8") as f:
        f.write(pwd)
    os.chmod(pwd_file, 0o600)
    state["admin_password"] = pwd       # 仅本次安装结果返回一次
    state["admin_password_kept"] = False
    log(state, "后台密码已%s" % ("随机生成" if p.get("gen_password") else "写入"))


# ---------------- Step: 依赖 ----------------

def step_install_deps(state, p):
    root = state["root"]
    dry = state["dry_run"]
    # pip 依赖
    try:
        import PIL  # noqa
        import mutagen  # noqa
        log(state, "Python 依赖已就绪，跳过 pip")
    except Exception:
        req = os.path.join(root, "requirements.txt")
        if os.path.exists(req):
            rc, out, _ = run_cmd(["pip3", "install", "-r", req], dry, timeout=300)
            log(state, "pip 依赖安装 rc=%s" % rc)
        else:
            log(state, "requirements.txt 缺失，跳过 pip", "warn")
    # npm 依赖
    bdir = os.path.join(root, "source-bridge")
    if os.path.isdir(os.path.join(bdir, "node_modules")):
        log(state, "node_modules 已存在，跳过 npm")
    elif have("npm") and os.path.isdir(bdir):
        rc, out, _ = run_cmd("cd %s && npm install" % bdir, dry, timeout=600, shell=True)
        log(state, "音源桥 npm install rc=%s" % rc)
    else:
        log(state, "npm 或 source-bridge 缺失，跳过音源桥依赖（音源桥可能不可用）", "warn")


# ---------------- Step: 建库（幂等） ----------------

def step_init_db(state, p):
    root = state["root"]
    os.environ["MUSIC_CONFIG"] = os.path.join(root, CONFIG_NAME)
    # 清掉可能残留的 ROOT 环境变量，强制走 config
    os.environ.pop("MUSIC_ROOT", None)
    for m in [k for k in list(sys.modules) if k == "server" or k.startswith("server.")]:
        del sys.modules[m]
    from server import database  # noqa
    conn = database.db()
    try:
        n = conn.execute("SELECT count(*) FROM sqlite_master WHERE type='table'").fetchone()[0]
        ok = conn.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    finally:
        conn.close()
    log(state, "数据库初始化/迁移完成，表数量=%d integrity=%s" % (n, ok))
    if not ok:
        raise RuntimeError("数据库完整性检查失败")


# ---------------- Step: systemd ----------------

def render_template(root, tpl_name, mapping):
    with open(os.path.join(HERE, "templates", tpl_name), encoding="utf-8") as f:
        s = f.read()
    for k, v in mapping.items():
        s = s.replace(k, str(v))
    return s


def step_setup_systemd(state, p):
    root = state["root"]
    dry = state["dry_run"]
    cfg = state["config"]
    m = {"__ROOT__": root, "__API_PORT__": cfg["ports"]["api"],
         "__BRIDGE_PORT__": cfg["ports"]["bridge"]}
    units = [
        ("music.service.tpl", "music.service", "music.service"),
        ("source-bridge.service.tpl", "source-bridge.service", "source-bridge.service"),
    ]
    use_systemd = os.path.isdir("/run/systemd/system") and not dry
    preview = os.path.join(root, "install_preview", "systemd")
    os.makedirs(preview, exist_ok=True)
    for tpl, name, svc in units:
        content = render_template(root, tpl, m)
        if use_systemd:
            dst = os.path.join("/etc/systemd/system", name)
            with open(dst, "w", encoding="utf-8") as f:
                f.write(content)
            log(state, "写入 %s" % dst)
        else:
            with open(os.path.join(preview, name), "w", encoding="utf-8") as f:
                f.write(content)
            log(state, "[%s] 生成预览 %s" % ("dry-run" if dry else "no-systemd",
                                            os.path.join(preview, name)))
    state["use_systemd"] = use_systemd


# ---------------- Step: Nginx ----------------

def _nginx_conf_dir():
    bt = "/www/server/panel/vhost/nginx"
    if os.path.isdir(bt):
        return bt
    std = "/etc/nginx/conf.d"
    if os.path.isdir(std):
        return std
    return None


def step_setup_nginx(state, p, mode):
    """mode: 'install' | 'production'。"""
    root = state["root"]
    dry = state["dry_run"]
    cfg = state["config"]
    partial_tpl = "nginx.install.partial" if mode == "install" else "nginx.production.partial"
    full_tpl = "nginx.install.conf.tpl" if mode == "install" else "nginx.production.conf.tpl"
    m = {"__ROOT__": root, "__DOMAIN__": cfg["domain"],
         "__API_PORT__": cfg["ports"]["api"], "__BRIDGE_PORT__": cfg["ports"]["bridge"],
         "__INSTALL_PORT__": cfg["ports"]["install"]}
    locations = render_template(root, partial_tpl, m)
    m2 = dict(m); m2["__LOCATIONS__"] = locations
    conf = render_template(root, full_tpl, m2)

    conf_dir = _nginx_conf_dir() if (have("nginx") and not dry) else None
    preview = os.path.join(root, "install_preview", "nginx")
    os.makedirs(preview, exist_ok=True)
    name = "%s.conf" % cfg["domain"]

    if conf_dir:
        dst = os.path.join(conf_dir, name)
        # 旧同名 conf 仅做“单文件”轻量留档（不再触发全量备份，避免挤掉安装前关键快照）
        if os.path.exists(dst):
            bkdir = os.path.join(root, "backup")
            os.makedirs(bkdir, exist_ok=True)
            ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
            shutil.copy2(dst, os.path.join(bkdir, "nginx_%s_%s.conf.bak" % (mode, ts)))
        with open(dst, "w", encoding="utf-8") as f:
            f.write(conf)
        rc, out, _ = run_cmd(["nginx", "-t"], dry)
        if rc != 0:
            log(state, "nginx -t 失败：%s" % out, "error")
            raise RuntimeError("nginx 配置校验失败，正式配置未生效")
        run_cmd(["nginx", "-s", "reload"], dry)
        log(state, "Nginx 配置已写入并 reload：%s（%s）" % (dst, mode))

        # 正式配置生效后，删除安装期临时配置（仍含 /install 入口），再 reload 关闭安装入口
        if mode == "production":
            removed = []
            for fn in os.listdir(conf_dir):
                if fn.startswith("liuying-install") and fn.endswith(".conf"):
                    try:
                        os.remove(os.path.join(conf_dir, fn))
                        removed.append(fn)
                    except OSError:
                        pass
            if removed:
                rc2, out2, _ = run_cmd(["nginx", "-t"], dry)
                if rc2 == 0:
                    run_cmd(["nginx", "-s", "reload"], dry)
                    log(state, "已移除安装期 Nginx 临时配置并关闭 /install 入口：%s" % ", ".join(removed))
                else:
                    log(state, "移除安装期配置后 nginx -t 异常，已保留：%s" % out2, "warn")
    else:
        pdst = os.path.join(preview, name)
        with open(pdst, "w", encoding="utf-8") as f:
            f.write(conf)
        log(state, "[%s] 生成 Nginx 预览：%s（未实际 reload）" % ("dry-run" if dry else "no-nginx",
                                                                   pdst), "warn")
    state["nginx_conf_name"] = name


# ---------------- Step: 启动服务 ----------------

_procs = []


def step_start_services(state, p):
    global _procs
    root = state["root"]
    dry = state["dry_run"]
    cfg = state["config"]
    env = dict(os.environ, MUSIC_CONFIG=os.path.join(root, CONFIG_NAME))
    env.pop("MUSIC_ROOT", None)

    if state.get("use_systemd"):
        for svc in ("music.service", "source-bridge.service"):
            run_cmd(["systemctl", "daemon-reload"], dry)
            run_cmd(["systemctl", "enable", svc], dry)
            run_cmd(["systemctl", "restart", svc], dry)
        log(state, "systemd 服务已 enable + restart")
        time.sleep(2)
        return

    # 直接进程方式（dry-run / 无 systemd）：先清理旧的本地进程，再拉起
    bridge_env = dict(env)
    bridge_env["BRIDGE_PORT"] = str(cfg["ports"]["bridge"])
    bridge_env["SOURCE_FILE"] = os.path.join(root, "source-bridge", "source.js")
    bridge_env["QS_SESSION_FILE"] = os.path.join(root, "source-bridge", "qs_session.json")
    for label, cmd, cwd, proc_env in (
        ("api", [sys.executable, os.path.join(root, "server.py")], root, env),
        ("bridge", ["node", os.path.join(root, "source-bridge", "bridge.js")],
         os.path.join(root, "source-bridge"), bridge_env),
    ):
        if label == "bridge" and not have("node"):
            log(state, "无 node，跳过音源桥进程", "warn")
            continue
        try:
            pobj = subprocess.Popen(cmd, cwd=cwd, env=proc_env,
                                    stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL)
            _procs.append(pobj)
            log(state, "已直接拉起 %s 进程 pid=%s" % (label, pobj.pid))
        except FileNotFoundError as e:
            log(state, "拉起 %s 失败：%s" % (label, e), "warn")
    time.sleep(3)


# ---------------- Step: 自检 ----------------

def _http_get(url, timeout=8):
    import urllib.request
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "ignore")
    except Exception as e:
        return 0, str(e)


def step_selfcheck(state, p):
    cfg = state["config"]
    api = cfg["ports"]["api"]
    bridge = cfg["ports"]["bridge"]
    # health
    ok = False
    detail = ""
    for _ in range(15):
        st, body = _http_get("http://127.0.0.1:%d/api/health" % api)
        if st == 200:
            try:
                ok = json.loads(body).get("ok") is True
            except Exception:
                ok = True
            detail = body[:120]
            break
        time.sleep(1)
    log(state, "API /api/health：%s %s" % ("OK" if ok else "FAIL", detail),
        "info" if ok else "error")
    if not ok:
        raise RuntimeError("API 健康检查失败：%s" % detail)
    # 后台 H5
    st, _ = _http_get("http://127.0.0.1:%d/admin.html" % api)
    log(state, "后台 H5 /admin.html：HTTP %s" % st, "info" if st == 200 else "warn")
    # 采集 H5
    st2, _ = _http_get("http://127.0.0.1:%d/collect.html" % api)
    log(state, "采集 H5 /collect.html：HTTP %s" % st2, "info" if st2 == 200 else "warn")
    # 音源桥（有 node 才有）。音源桥不可用不阻断后端安装，仅明确报告原因与修复方式。
    bridge_status = {"ok": False, "http": 0, "hint": ""}
    if have("node"):
        st3, body3 = _http_get("http://127.0.0.1:%d/ping" % bridge)
        bridge_status["http"] = st3
        if st3:
            bridge_status["ok"] = True
            log(state, "音源桥 /ping：HTTP %s %s" % (st3, body3[:60]))
        else:
            if not os.path.isfile(os.path.join(state["root"], "source-bridge", "source.js")):
                bridge_status["hint"] = ("音源桥未启动：缺少 source-bridge/source.js（长青音源脚本）。"
                                         "覆盖安装可从备份恢复；放入后执行 "
                                         "systemctl restart source-bridge.service")
            else:
                bridge_status["hint"] = ("音源桥未响应：查看日志 journalctl -u source-bridge.service -f；"
                                         "常见为 source.js 失效或端口被占用")
            log(state, bridge_status["hint"], "warn")
    else:
        bridge_status["hint"] = "未安装 NodeJS，音源桥未部署"
    state["bridge_status"] = bridge_status
    state["selfcheck"] = {"health": ok, "admin": st, "collect": st2,
                          "bridge": bridge_status["ok"]}


# ---------------- Step: finalize（自锁 + 报告） ----------------

def step_finalize(state, p):
    root = state["root"]
    cfg = state["config"]
    domain = cfg["domain"]
    base = "https://%s" % domain
    pwd = None if state.get("admin_password_kept") else state.get("admin_password")
    result = {
        "domain": domain,
        "links": {
            "site": base + "/",
            "api_health": base + "/api/health",
            "admin": base + "/music/admin.html",
            "collect": base + "/music/collect.html",
            "qishui": base + "/music/collect.html",   # 汽水登录区在采集控制台
        },
        "admin_password": pwd,
        "admin_password_kept": state.get("admin_password_kept"),
        "ops": {
            "restart_api": "systemctl restart music.service",
            "log_api": "journalctl -u music.service -f",
            "restart_bridge": "systemctl restart source-bridge.service",
            "log_bridge": "journalctl -u source-bridge.service -f",
            "nginx_reload": "nginx -t && nginx -s reload",
            "rollback": "python3 install/backup.py restore --yes",
        },
        "use_systemd": state.get("use_systemd"),
        "dry_run": state["dry_run"],
        "selfcheck": state.get("selfcheck"),
        "source_bridge": state.get("bridge_status"),
        "backup_dir": state.get("backup_dir"),
        "finished_at": datetime.datetime.now().isoformat(timespec="seconds"),
    }
    state["result"] = result
    state["locked"] = True
    state["phase"] = "done"
    state["finished_at"] = result["finished_at"]
    save_state(state)
    # 安装报告落盘
    repdir = os.path.join(root, "backup")
    os.makedirs(repdir, exist_ok=True)
    with open(os.path.join(repdir, "install_report.json"), "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
    log(state, "安装完成并自锁，报告已写入 backup/install_report.json")

    # 禁用安装服务开机自启（不立即 --now：让向导拿到最终完成结果；
    # install_api 检测到锁定后会延迟自退，unit 为 Restart=on-failure，正常退出不再拉起）
    if state.get("use_systemd"):
        run_cmd(["systemctl", "disable", "music-installer.service"], False)


# ---------------- 安装编排（后台线程） ----------------

STEPS = [
    ("env_check", "环境检测", lambda s, p: None),
    ("backup", "备份现有部署", None),     # 特殊处理
    ("write_config", "生成 config.json", step_write_config),
    ("admin_pwd", "设置后台密码", step_admin_pwd),
    ("install_deps", "安装依赖", step_install_deps),
    ("init_db", "初始化数据库", step_init_db),
    ("setup_systemd", "配置 systemd", step_setup_systemd),
    ("setup_nginx_install", "配置 Nginx（安装期）", lambda s, p: step_setup_nginx(s, p, "install")),
    ("start_services", "启动服务", step_start_services),
    ("selfcheck", "自检", step_selfcheck),
    ("finalize", "切换正式配置并锁定", None),   # 特殊处理
]


def run_install(root, params, dry_run=False, install_port=INSTALL_PORT_DEFAULT,
                on_done=None):
    state = load_state(root) or new_state(root, dry_run, install_port)
    state["dry_run"] = bool(dry_run)
    state["phase"] = "running"
    state["started_at"] = datetime.datetime.now().isoformat(timespec="seconds")
    # 重置步骤状态
    state["steps"] = [{"key": k, "name": n, "status": "pending"} for k, n, _ in STEPS]
    save_state(state)

    def set_step(key, status, msg=""):
        for st in state["steps"]:
            if st["key"] == key:
                st["status"] = status
                st["msg"] = msg
        save_state(state)

    def worker():
        try:
            for key, name, fn in STEPS:
                set_step(key, "running")
                if key == "env_check":
                    env = detect_env(root, install_port,
                                     int(params.get("api_port") or API_PORT_DEFAULT),
                                     int(params.get("bridge_port") or BRIDGE_PORT_DEFAULT))
                    if not env["can_install"]:
                        raise RuntimeError("环境不满足：" +
                                           "；".join(c["name"] for c in env["blocking"]))
                elif key == "backup":
                    if is_existing_deploy(root):
                        import backup as bk
                        bdir, _ = bk.create_backup(root)
                        state["backup_dir"] = bdir
                        log(state, "已先完整备份：%s" % bdir)
                    else:
                        log(state, "全新安装，无需备份")
                elif key == "finalize":
                    # 先切正式 Nginx（去掉 /install），再自锁
                    try:
                        step_setup_nginx(state, params, "production")
                    except Exception as e:
                        log(state, "正式 Nginx 切换跳过：%s" % e, "warn")
                    step_finalize(state, params)
                    set_step(key, "done")
                    break
                else:
                    fn(state, params)
                set_step(key, "done")
            state["phase"] = "done"
            save_state(state)
        except Exception as e:
            state["phase"] = "error"
            state["error"] = str(e)
            log(state, "安装失败：%s" % e, "error")
            save_state(state)
            # 自动回滚（仅当做过备份）
            if state.get("backup_dir"):
                try:
                    import backup as bk
                    log(state, "尝试自动回滚到安装前备份…", "warn")
                    bk.restore_backup(root, state["backup_dir"])
                    state["rolled_back"] = True
                    save_state(state)
                except Exception as re:
                    log(state, "自动回滚失败：%s" % re, "error")
        finally:
            if callable(on_done):
                try:
                    on_done(state)
                except Exception:
                    pass

    t = threading.Thread(target=worker, daemon=True)
    t.start()
    return state


# ---------------- CLI dry-run ----------------

if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=ROOT_DEFAULT)
    ap.add_argument("--domain", default="music.example.com")
    ap.add_argument("--password", default=None)
    ap.add_argument("--gen-password", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--keep-admin-pwd", action="store_true")
    ap.add_argument("--install-port", type=int, default=INSTALL_PORT_DEFAULT)
    args = ap.parse_args()

    done = threading.Event()

    def _on(_s):
        done.set()

    params = {"domain": args.domain, "password": args.password,
              "gen_password": args.gen_password, "keep_admin_pwd": args.keep_admin_pwd,
              "api_port": 18791, "bridge_port": 18792}
    run_install(args.root, params, dry_run=args.dry_run,
                install_port=args.install_port, on_done=_on)
    done.wait(timeout=300)
    st = load_state(args.root)
    print(json.dumps({"phase": st["phase"], "locked": st.get("locked"),
                      "error": st.get("error"), "rolled_back": st.get("rolled_back"),
                      "result_links": (st.get("result") or {}).get("links")},
                     ensure_ascii=False, indent=2))
    # CLI 演练：清理直接拉起的测试进程（systemd 正式部署由系统托管，不走这里）
    import signal as _sig
    for _p in _procs:
        try:
            _p.send_signal(_sig.SIGTERM)
        except Exception:
            pass
    sys.exit(0 if st["phase"] == "done" else 1)
