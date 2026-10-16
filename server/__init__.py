#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""流萤音乐后端包。

向后兼容：历史代码/验证脚本使用 ``import server; server.<func>`` 形式访问
（当 server.py 还是单文件时）。模块化后在此聚合 re-export，保证这些引用继续可用。
新代码请直接从具体子模块导入，例如 ``from server.database import db``。
"""
import random  # noqa: F401  兼容 server.random

from server.config import *  # noqa: F401,F403
from server.database import db  # noqa: F401
from server.common import *  # noqa: F401,F403
from server.ws import *  # noqa: F401,F403
from server.recommend import (  # noqa: F401
    build_recommendations,
    _rec_recent_pushed,
    _rec_remember_pushed,
    _rec_next_seq,
)
