# -*- coding: utf-8 -*-
"""服务入口：初始化数据库并启动 ThreadingHTTPServer + AI 主动乐评后台线程。"""
from http.server import ThreadingHTTPServer
from server.config import PORT, ROOT, AUTH_STRICT, log
from server import database
from server import ai
from server.handler import H


def main():
    database.db().close()
    ai.start_ai_worker()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    srv.daemon_threads = True
    log.info("music server on 127.0.0.1:%d root=%s strict_auth=%s",
             PORT, ROOT, AUTH_STRICT)
    srv.serve_forever()


if __name__ == "__main__":
    main()
