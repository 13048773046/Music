# 流萤音乐 Liuying Music

iOS（SwiftUI）音乐 App 的一体化后端：Python 标准库 HTTP 服务 + SQLite + NodeJS 音源桥，
内置管理后台 H5、音源采集控制台、个性化推荐、WebSocket、音频 206 流式播放与防盗链，
并提供 **H5 自动安装向导**（下载 → 上传解压 → 浏览器访问即完成部署）。

- 后端端口：`127.0.0.1:8788`（由 Nginx 反代对外）
- 音源桥端口：`127.0.0.1:8789`
- 最低要求：Python 3.8+、NodeJS 16+、Nginx（推荐）、SQLite（Python 内置）

> **完整交接文档见 [`docs/流萤音乐-完整交接文档-20261018.md`](docs/流萤音乐-完整交接文档-20261018.md)**（v13，基于 `4b1c072` + 线上实测）：
> 覆盖 GitHub 仓库 / 线上服务器 / 后端 / 音源桥 / 官网 / iOS 前端全量说明、CI 流水线、运维高频命令、任务总清单（45+ 项已完成）。

---

## 一、目录结构

```
.
├── server.py                 # 兼容入口（薄包装，实际逻辑在 server/ 包；python3 server.py 启动）
├── server/                   # 规范化后端包
│   ├── config.py             # 统一配置（config.json + 环境变量 + 默认值），所有路径在此派生
│   ├── database.py           # SQLite 连接 + 幂等建表/增量迁移
│   ├── common.py             # 鉴权/密码/Token/限流/流签名/短码/文件安全/通知等
│   ├── ws.py                 # WebSocket（RFC6455）握手/帧/推送
│   ├── recommend.py          # 个性化推荐（多路召回+融合+MMR+去重）
│   ├── qishui.py             # 汽水音乐分享解析
│   ├── media.py              # 封面压缩/上传魔数校验/音频时长
│   ├── handler.py            # HTTP 路由分发主体
│   ├── main.py               # 服务入口
│   └── templates/            # 从代码剥离的 H5 页面
│       ├── admin.html        #   管理后台
│       ├── collect.html      #   音源采集控制台（含汽水音乐登录）
│       ├── share_player.html #   单歌分享播放页
│       └── share_collect.html#   汽水分享链接采集页
├── source-bridge/            # NodeJS 音源桥
│   ├── bridge.js             #   HTTP 服务（长青音源 + 汽水 + 兜底聚合）
│   ├── collect_v3.py         #   采集脚本（榜单 + 搜索补量，路径已参数化）
│   ├── package.json
│   └── source.js             #   ⚠ 长青音源脚本（外部音源文件，见“音源桥说明”）
├── install/                  # 自动安装程序
│   ├── index.html            #   H5 安装向导（5 步）
│   ├── install_api.py        #   安装向导 HTTP 服务（127.0.0.1:8899，一次性令牌，装完自锁）
│   ├── installer.py          #   安装核心（检测/备份/配置/建库/服务/自检/回滚）
│   ├── backup.py             #   备份与回滚（可单独命令行使用）
│   └── templates/            #   systemd / nginx 配置模板
├── install.sh                # 一键安装入口
├── web/index.html            # 官网落地页（Nginx 静态根）
├── config.json.example       # 配置文件样例（安装程序会自动生成 config.json）
├── requirements.txt          # Python 依赖（Pillow / mutagen）
├── tests/                    # 冒烟测试与专项验证
├── MusicApp/                 # iOS SwiftUI 客户端
└── .github/workflows/        # CI：冒烟测试 + 未签名 IPA 打包
```

---

## 二、全新服务器安装（推荐：H5 向导）

1. **下载源码**：`git clone` 或下载 Release 压缩包。
2. **配置域名**：在 DNS 控制台把域名（如 `music.example.com`）解析到本服务器 IP。
3. **上传并解压**到该域名的站点目录，例如 `/www/wwwroot/music/`（宝塔站点目录亦可）。
4. **执行安装入口**（root）：

   ```bash
   cd /www/wwwroot/music
   chmod +x install.sh
   ./install.sh music.example.com
   ```

5. **浏览器打开** `http://music.example.com/install/`，按 5 步向导操作：
   环境检测 → 站点配置（域名/端口）→ 后台密码（可随机生成）→ 确认 → 自动安装。
6. **安装完成页**给出并可一键复制：

   | 入口 | 地址 |
   |---|---|
   | 官网 | `https://<域名>/` |
   | 接口健康检查 | `https://<域名>/api/health` |
   | 管理后台 | `https://<域名>/music/admin.html` |
   | 采集控制台（含汽水音乐登录） | `https://<域名>/music/collect.html` |

   后台密码仅在完成页展示一次（选择“保留现有密码”除外），同时写入 `admin_pwd`。

> 暂不配置域名时，可执行 `./install.sh`，用 `http://服务器IP/install/` 访问。
> 安装向导仅在安装期可用，**成功后自动锁定并关闭**；正式 Nginx 配置会移除 `/install` 入口。

### 本地演练（不写系统配置）

```bash
./install.sh --local --dry-run        # 前台启动向导：http://127.0.0.1:8899/install/
# 或纯命令行演练：
python3 install/installer.py --root /tmp/test_music --domain t.example.com --gen-password --dry-run
```

---

## 三、覆盖升级现有服务器（先备份再做）

安装程序检测到已有部署（存在 `tracks.db` / `files/` / `admin_pwd`）时自动进入**覆盖升级**：

1. **强制先完整备份**：数据库（WAL checkpoint）、`files/`、全部配置、音源桥、systemd/nginx；
   逐项 sha256 校验通过后才替换。
2. **默认保留**现有后台密码（向导勾选）、`.sign_secret`（已分享短链/签名流不失效）、
   以及 `source-bridge/source.js` 等音源文件。
3. 数据库只做幂等增量迁移，**不删数据、不重建表**。
4. **任一步失败自动回滚**到安装前快照；备份保留最近 3 份。

手动备份 / 回滚：

```bash
python3 install/backup.py backup                 # 立即完整备份
python3 install/backup.py verify                 # 校验最新备份
python3 install/backup.py restore --yes          # 回滚到最新备份
python3 install/backup.py restore --backup-dir /www/wwwroot/music/backup/20261016_210000 --yes
```

备份产物：`backup/<时间戳>/full_backup.tar.gz` 与 `manifest.json`（含逐项 sha256），
以及安装报告 `backup/install_report.json`。

---

## 四、配置说明（config.json）

安装程序自动生成；优先级：**环境变量 > config.json > 内置默认值**。无 config.json 也能运行。
常用环境变量：`MUSIC_ROOT`、`MUSIC_PORT`、`MUSIC_CONFIG`、`MUSIC_DEBUG`、
`MUSIC_AUTH_STRICT`、`MUSIC_SIGN_STRICT`、`MUSIC_SIGN_SECRET`、`MUSIC_PUBLIC_URL`、`BRIDGE_PORT`。

> 所有历史硬编码绝对路径已消除，统一由 `config.py` 派生，`collect_v3.py` 同样读取该配置。

---

## 五、音源桥说明

- `bridge.js` 启动**强依赖** `source-bridge/source.js`（落雪音乐源格式脚本）。
  该文件为**外部音源文件、不随仓库提供**；缺失时音源桥无法启动，但**不影响后端与后台安装**，
  完成页会给出明确提示。
  - **覆盖升级**：自动从备份恢复 `source.js`、`download_collected.py`。
  - **全新安装**：请将可用的 `source.js` 放入 `source-bridge/` 后
    `systemctl restart source-bridge.service`。
- 汽水音乐解析依赖 `ly-music-source`（npm 自动安装），支持扫码/短信/Cookie 登录与 session 持久化。

---

## 六、运维常用命令

```bash
systemctl restart music.service            # 重启后端
journalctl -u music.service -f             # 后端实时日志
systemctl restart source-bridge.service    # 重启音源桥
journalctl -u source-bridge.service -f     # 音源桥日志
nginx -t && nginx -s reload                # 校验并重载 Nginx
```

---

## 七、测试与 CI

```bash
python3 tests/server_smoke_test.py                 # 冒烟测试（默认端口 18788，临时数据目录）
python3 tests/verify_push_dedup.py                 # 推荐 3 小时推送去重
python3 tests/verify_recommend_newmix.py           # 推荐新歌混入
```

- 架构重构后冒烟 **130 项全部通过**，对 iOS 客户端 API 行为零变化。
- CI（`.github/workflows/build.yml`）：推送 main → Ubuntu 跑冒烟测试 → macOS 构建未签名 IPA。
  因根目录保留了 `server.py` 薄入口，CI 与既有调用方式无需改动。

---

## 八、兼容性红线（重构承诺）

- iOS 客户端零改动；所有 `/api/*`、`/s/*`、`/music/*` 路径、参数、返回结构保持不变。
- 现有 `tracks.db` 直接沿用，仅幂等增量迁移。
- 端口、systemd 服务名、Nginx 反代路径与线上一致。
