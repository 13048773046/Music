#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""流萤音乐后端 · 兼容入口（薄包装）

架构规范化后，实际实现位于 server/ 包。本文件保留是为了兼容：
    - 线上既有 systemd 启动命令 `python3 server.py`
    - tests/server_smoke_test.py 与 CI 对 server.py 的调用
    - 运维既有操作习惯

可直接运行：python3 server.py
"""
import os
import sys

# 确保以任意工作目录运行时都能找到同目录下的 server 包
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from server.main import main  # noqa: E402

if __name__ == "__main__":
    main()
