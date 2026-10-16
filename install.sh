#!/usr/bin/env bash
# =====================================================================
# 流萤音乐 · 一键安装入口
#
# 典型用法（在站点根目录，以 root 执行）：
#     ./install.sh                          # 监听 80 默认站点，访问 http://服务器IP/install/
#     ./install.sh music.example.com        # 指定域名，访问 http://music.example.com/install/
#
# 本地/演练（不写 /etc、不碰 systemd/nginx，直接起安装服务）：
#     ./install.sh --local [--dry-run] [--port 18899]
#
# 流程：启动安装向导服务(127.0.0.1:8899) → 配置安装期 Nginx → 浏览器访问向导
#       → 向导内完成 备份→配置→建库→装服务→自检，成功后输出各入口链接并自锁。
# =====================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_PORT="${INSTALL_PORT:-8899}"
DOMAIN=""
LOCAL=0
DRY=0

PY="$(command -v python3 || true)"
[ -z "$PY" ] && { echo "未找到 python3，请先安装 Python 3.8+"; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --local) LOCAL=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --port) INSTALL_PORT="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) DOMAIN="$1"; shift ;;
  esac
done

echo "=================================================="
echo " 流萤音乐 安装程序"
echo " 部署目录 : $ROOT"
echo " 安装端口 : $INSTALL_PORT"
echo "=================================================="

# ---------- 本地/演练模式 ----------
if [ "$LOCAL" = "1" ]; then
  echo "[local] 直接前台启动安装向导服务（不写系统配置）"
  ARGS=( "$PY" "$ROOT/install/install_api.py" --root "$ROOT" --port "$INSTALL_PORT" )
  [ "$DRY" = "1" ] && ARGS+=( --dry-run )
  echo "[local] 访问:  http://127.0.0.1:$INSTALL_PORT/install/"
  exec "${ARGS[@]}"
fi

# ---------- 正式模式需 root ----------
if [ "${EUID:-$(id -u)}" != "0" ]; then
  echo "请使用 root 运行： sudo ./install.sh ${DOMAIN}"
  exit 1
fi

# ---------- 1) 安装并启动安装向导 systemd 服务 ----------
UNIT=/etc/systemd/system/music-installer.service
if [ -d /run/systemd/system ]; then
  sed -e "s#__ROOT__#$ROOT#g" \
      -e "s#__INSTALL_PORT__#$INSTALL_PORT#g" \
      "$ROOT/install/templates/install_api.service.tpl" > "$UNIT"
  chmod 644 "$UNIT"
  systemctl daemon-reload
  systemctl enable --now music-installer.service
  echo "[ok] 安装向导服务 music-installer.service 已启动（127.0.0.1:$INSTALL_PORT）"
else
  echo "[warn] 无 systemd，使用 nohup 直接启动安装向导"
  pkill -f "install_api.py --root $ROOT" 2>/dev/null || true
  nohup "$PY" "$ROOT/install/install_api.py" --root "$ROOT" --port "$INSTALL_PORT" \
      > "$ROOT/install/install_api.log" 2>&1 &
  echo "[ok] 安装向导已后台启动，日志: $ROOT/install/install_api.log"
fi

# ---------- 2) 配置安装期 Nginx（把 /install、/installapi 反代到向导） ----------
if command -v nginx >/dev/null 2>&1; then
  TPL_CONF="$ROOT/install/templates/nginx.install.conf.tpl"
  TPL_LOC="$ROOT/install/templates/nginx.install.partial"
  LOCATIONS="$(sed -e "s#__INSTALL_PORT__#$INSTALL_PORT#g" \
                   -e "s#__API_PORT__#8788#g" "$TPL_LOC")"
  if [ -n "$DOMAIN" ]; then SERVER_NAME="$DOMAIN"; LISTEN="listen 80;"; else SERVER_NAME="_"; LISTEN="listen 80 default_server;"; fi

  # 选择 nginx 配置目录（宝塔优先，其次 conf.d）
  if [ -d /www/server/panel/vhost/nginx ]; then NGDIR=/www/server/panel/vhost/nginx
  elif [ -d /etc/nginx/conf.d ]; then NGDIR=/etc/nginx/conf.d
  else NGDIR=""; fi

  if [ -n "$NGDIR" ]; then
    CONF_NAME="liuying-install${DOMAIN:+-$DOMAIN}.conf"
    OUT="$NGDIR/$CONF_NAME"
    awk -v sn="$SERVER_NAME" -v listen="$LISTEN" -v rootd="$ROOT" -v loc="$LOCATIONS" '
      { gsub(/__DOMAIN__/,sn); gsub(/listen 80;/,listen); gsub(/__ROOT__/,rootd); gsub(/__LOCATIONS__/,loc); print }
    ' "$TPL_CONF" > "$OUT"
    if nginx -t 2>/tmp/liuying_nginx_t.log; then
      nginx -s reload
      echo "[ok] 安装期 Nginx 已生效：$OUT"
    else
      echo "[warn] nginx -t 失败，已保留配置但未 reload；详情："; cat /tmp/liuying_nginx_t.log
      echo "       你也可在宝塔面板手动把 /install 反代到 127.0.0.1:$INSTALL_PORT"
    fi
  else
    echo "[warn] 未找到 nginx 站点配置目录，请手动反代 /install → 127.0.0.1:$INSTALL_PORT"
  fi
else
  echo "[warn] 未安装 nginx；安装完成后请自行配置反向代理（模板见 install/templates/）"
fi

echo ""
echo "=================================================="
if [ -n "$DOMAIN" ]; then
  echo " 请用浏览器打开： http://$DOMAIN/install/"
else
  IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo " 请用浏览器打开： http://${IP:-服务器IP}/install/"
fi
echo " 按向导完成安装；成功后安装入口自动关闭。"
echo "=================================================="
