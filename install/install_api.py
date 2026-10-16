#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""流萤音乐 · H5 安装向导 HTTP 服务（仅安装期运行，127.0.0.1，经 Nginx /install 暴露）

路由：
    GET  /install/                 向导页面 index.html
    GET  /installapi/bootstrap     一次性安装令牌 + 当前状态
    GET  /installapi/probe         环境检测 / 是否旧部署
    POST /installapi/start         开始安装（需 X-Install-Token）
    GET  /installapi/status        安装进度/结果（轮询）

安全：
    - 仅绑定 127.0.0.1，对外只经 Nginx /install、/installapi；
    - start 需一次性 token；
    - 安装完成（locked）后所有写接口 403，向导显示“已安装”，服务延迟自退；
    - 正式 Nginx 配置在成功后移除 /install、/installapi。

用法：
    python3 install/install_api.py --root /www/wwwroot/music [--port 8899] [--dry-run]
"""
import os
import sys
import json
import time
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import installer  # noqa: E402

ROOT = installer.ROOT_DEFAULT
DRY = False
PORT = installer.INSTALL_PORT_DEFAULT


class InstallHandler(BaseHTTPRequestHandler):
    server_version = "LiuyingInstaller/1.0"

    def log_message(self, *a):
        pass

    # ---------- 基础 ----------
    def _json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _state(self):
        return installer.load_state(ROOT)

    def _read_body(self):
        try:
            n = int(self.headers.get("Content-Length", "0"))
            if n <= 0 or n > 1 << 20:
                return {}
            return json.loads(self.rfile.read(n).decode("utf-8"))
        except Exception:
            return {}

    def _token_ok(self):
        st = self._state()
        tok = self.headers.get("X-Install-Token", "")
        return bool(st and tok and secrets_eq(tok, st.get("token", "")))

    # ---------- GET ----------
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        p = u.path.rstrip("/") or "/"
        try:
            if p in ("/install", "/install/"):
                return self._serve_index()
            if p == "/installapi/bootstrap":
                return self._bootstrap()
            if p == "/installapi/probe":
                return self._probe()
            if p == "/installapi/status":
                return self._status()
            self._json(404, {"ok": False, "err": "not found"})
        except BrokenPipeError:
            pass

    # ---------- POST ----------
    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        p = u.path.rstrip("/")
        st = self._state()
        if st and st.get("locked"):
            return self._json(403, {"ok": False, "err": "already installed"})
        if p == "/installapi/start":
            if not self._token_ok():
                return self._json(403, {"ok": False, "err": "bad install token"})
            return self._start()
        self._json(404, {"ok": False, "err": "not found"})

    # ---------- 业务 ----------
    def _serve_index(self):
        idx = os.path.join(HERE, "index.html")
        with open(idx, "rb") as f:
            body = f.read()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _bootstrap(self):
        """确保存在一个待安装 state，返回一次性 token 与摘要。"""
        st = self._state()
        if st is None:
            st = installer.new_state(ROOT, DRY, PORT)
            installer.save_state(st)
        if st.get("locked"):
            return self._json(200, {"locked": True, "phase": "done",
                                    "result": _public_result(st)})
        return self._json(200, {"locked": False, "token": st["token"],
                                "root": ROOT, "dry_run": DRY,
                                "existing": installer.is_existing_deploy(ROOT),
                                "phase": st.get("phase")})

    def _probe(self):
        st = self._state()
        if st and st.get("locked"):
            return self._json(403, {"ok": False, "err": "already installed"})
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        api_port = int((qs.get("api_port") or [installer.API_PORT_DEFAULT])[0])
        bridge_port = int((qs.get("bridge_port") or [installer.BRIDGE_PORT_DEFAULT])[0])
        env = installer.detect_env(ROOT, PORT, api_port, bridge_port)
        self._json(200, env)

    def _start(self):
        st = self._state()
        if st and st.get("phase") == "running":
            return self._json(409, {"ok": False, "err": "install already running"})
        body = self._read_body()
        domain = (body.get("domain") or "").strip().lower()
        if not domain or len(domain) > 253 or not all(
                c.isalnum() or c in ".-" for c in domain) or ".." in domain:
            return self._json(400, {"ok": False, "err": "域名不合法"})
        keep = bool(body.get("keep_admin_pwd"))
        gen = bool(body.get("gen_password"))
        pwd = body.get("password") or ""
        existing_pwd = os.path.exists(os.path.join(ROOT, "admin_pwd"))
        if not keep and not gen and not (6 <= len(pwd) <= 64):
            return self._json(400, {"ok": False, "err": "后台密码需 6-64 位，或选择随机生成/保留现有密码"})
        if keep and not existing_pwd:
            return self._json(400, {"ok": False, "err": "未检测到现有后台密码，无法保留"})
        params = {
            "domain": domain,
            "password": pwd,
            "gen_password": gen,
            "keep_admin_pwd": keep,
            "api_port": int(body.get("api_port") or installer.API_PORT_DEFAULT),
            "bridge_port": int(body.get("bridge_port") or installer.BRIDGE_PORT_DEFAULT),
        }
        installer.run_install(ROOT, params, dry_run=DRY, install_port=PORT,
                              on_done=_schedule_self_exit)
        self._json(200, {"ok": True, "phase": "running"})

    def _status(self):
        st = self._state()
        if st is None:
            return self._json(200, {"phase": "idle", "locked": False})
        return self._json(200, {
            "phase": st.get("phase"),
            "locked": st.get("locked"),
            "steps": st.get("steps"),
            "logs": st.get("logs", [])[-60:],
            "error": st.get("error"),
            "rolled_back": st.get("rolled_back"),
            "backup_dir": st.get("backup_dir"),
            "result": _public_result(st) if st.get("locked") else None,
        })


def _public_result(st):
    """完成结果；admin_password 仅在本次安装（非保留密码）时随结果返回一次。"""
    r = dict(st.get("result") or {})
    return r


def secrets_eq(a, b):
    import hmac
    return hmac.compare_digest(str(a or ""), str(b or ""))


_self_exit_timer = {"set": False}


def _schedule_self_exit(state):
    """安装结束（成功锁定或失败回滚）后，延迟退出安装服务，使向导能拉到最终状态。"""
    if DRY:
        return
    if _self_exit_timer["set"]:
        return
    _self_exit_timer["set"] = True

    def _exit():
        time.sleep(8)
        os._exit(0)
    threading.Thread(target=_exit, daemon=True).start()


def main():
    import argparse
    global ROOT, DRY, PORT
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=installer.ROOT_DEFAULT)
    ap.add_argument("--port", type=int, default=installer.INSTALL_PORT_DEFAULT)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    ROOT = os.path.abspath(args.root)
    DRY = bool(args.dry_run)
    PORT = args.port
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), InstallHandler)
    srv.daemon_threads = True
    print("[install_api] on 127.0.0.1:%d root=%s dry_run=%s" % (PORT, ROOT, DRY), flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
