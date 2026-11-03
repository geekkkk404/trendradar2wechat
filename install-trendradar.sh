#!/usr/bin/env bash
# =============================================================================
#  TrendRadar 一键安装脚本（VPS 版 · 无 Docker 原生部署）— trendradar2wechat 项目分发
#  上游项目: https://github.com/sansan0/TrendRadar （GPL-3.0，安装时获取原版，不修改源码）
#  本项目:   https://github.com/geekkkk404/trendradar2wechat
#  适用系统: Ubuntu 20.04+ / Debian 11+（x86_64 / arm64），境内外 VPS 自适应
#            Python ≥3.12（Ubuntu 24.04 自带；不足时经 uv 自动安装）
#
#  ▍用法（在 SSH 或腾讯云 OrcaTerm 终端中粘贴）:
#    bash install-trendradar.sh [选项]
#
#  ▍常用示例:
#    bash install-trendradar.sh --wechat-bridge --no-web         # 微信个人号推送 + 零入站端口（推荐）
#    bash install-trendradar.sh                                  # 极简安装，仅网页报告，稍后补配推送
#    bash install-trendradar.sh --wework 'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxx'
#    bash install-trendradar.sh --feishu 'https://open.feishu.cn/open-apis/bot/v2/hook/xxx'
#    bash install-trendradar.sh --telegram '123456:AAHxxxx:你的ChatID'   # 格式 BotToken:ChatID
#    bash install-trendradar.sh --ai-key 'sk-xxx'                 # 启用 AI 分析（默认 deepseek 模型）
#    bash install-trendradar.sh --uninstall                       # 停止并卸载（数据保留）
#
#  ▍选项:
#    --wechat-bridge     部署微信个人号推送桥 any2wechat（安装中出授权链接，手机微信确认；推荐）
#    --port N            网页报告端口（默认 8080）
#    --dir PATH          安装目录（默认 /opt/TrendRadar）
#    --wework URL        企业微信群机器人 webhook，多个用英文分号 ; 隔开
#    --feishu URL        飞书自定义机器人 webhook
#    --dingtalk URL      钉钉机器人 webhook
#    --telegram T:C      Telegram，格式 BotToken:ChatID
#    --ai-key KEY        启用 AI 分析/筛选（模型默认 deepseek/deepseek-chat）
#    --ai-model MODEL    指定模型，如 deepseek/deepseek-chat、openai/gpt-4o-mini
#    --no-web            网页报告仅本机可访问（不监听公网）
#    --with-mcp          同时部署 MCP AI 分析服务（默认不部署）
#    --uninstall         停止并移除服务；配合 --purge 同时删除数据
#    --purge             配合 --uninstall 删除全部数据（含微信绑定凭证与 node/uv 工具）
#    -h, --help          显示本帮助
#
#  ▍环境变量等价写法（适合"自定义脚本/user-data"开机自动部署）:
#    WEWORK_WEBHOOK_URL / FEISHU_WEBHOOK_URL / DINGTALK_WEBHOOK_URL
#    TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID / AI_API_KEY / AI_MODEL / WECHAT_BRIDGE=1
#
#  ▍部署形态（v0.2.0 起为无 Docker 原生部署）:
#    - TrendRadar 源码安装于 {安装目录}，依赖经 uv 装入 .venv（境内走 PyPI 镜像，秒级）
#    - systemd 管三件事: 网页报告（trendradar-web）、定时抓取（trendradar-fetch.timer
#      每 30 分钟）、可选 MCP（trendradar-mcp）；日志统一 journalctl
#    - 推送渠道配置保存在 {安装目录}/trendradar.env，可随时手工编辑，下次抓取生效
#    - --wechat-bridge：Node 原生运行 any2wechat（零 npm 依赖），个人微信直推，
#      桥故障不影响 TrendRadar 本体
# =============================================================================

set -u -o pipefail

# ----------------------------- 常量 ------------------------------------------
REPO_URL="https://github.com/sansan0/TrendRadar"
REPO_BRANCH="master"
DEFAULT_PORT=8080
DEFAULT_DIR="/opt/TrendRadar"
GH_PROXY_FALLBACKS=("https://ghfast.top" "https://gh-proxy.com" "https://ghp.ci")
# 原生部署组件版本（钉死，升级随脚本发版）
NODE_VERSION="v22.23.4"
NODE_MIRROR_CN="https://registry.npmmirror.com/-/binary/node"
NODE_MIRROR_INTL="https://nodejs.org/dist"
UV_PY_MIRROR_PROXY="https://ghfast.top/https://github.com/astral-sh/python-build-standalone/releases/download"

# ----------------------------- 日志 ------------------------------------------
C_G="\033[32m"; C_Y="\033[33m"; C_R="\033[31m"; C_B="\033[36m"; C_0="\033[0m"
step() { printf "\n${C_B}▶ %s${C_0}\n" "$*"; }
ok()   { printf "${C_G}  ✅ %s${C_0}\n" "$*"; }
warn() { printf "${C_Y}  ⚠️  %s${C_0}\n" "$*"; }
die()  { printf "${C_R}  ❌ %s${C_0}\n" "$*" >&2; exit 1; }

# ----------------------------- 参数解析 --------------------------------------
ARG_PORT=""; ARG_DIR=""; ARG_WEWORK=""; ARG_FEISHU=""; ARG_DINGTALK=""
ARG_TG=""; ARG_NTFY=""; ARG_AIKEY=""; ARG_AIMODEL=""
NO_WEB=0; WITH_MCP=0; UNINSTALL=0; PURGE=0; WECHAT_BRIDGE="${WECHAT_BRIDGE:-0}"

show_help() { awk 'NR>2 && /^# ===/ {exit} NR>2 {sub(/^# ?/, ""); print}' "$0"; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --port)     ARG_PORT="$2"; shift 2 ;;
    --dir)      ARG_DIR="$2"; shift 2 ;;
    --wework)   ARG_WEWORK="$2"; shift 2 ;;
    --feishu)   ARG_FEISHU="$2"; shift 2 ;;
    --dingtalk) ARG_DINGTALK="$2"; shift 2 ;;
    --telegram) ARG_TG="$2"; shift 2 ;;
    --ntfy)     ARG_NTFY="$2"; shift 2 ;;
    --ai-key)   ARG_AIKEY="$2"; shift 2 ;;
    --ai-model) ARG_AIMODEL="$2"; shift 2 ;;
    --no-web)   NO_WEB=1; shift ;;
    --with-mcp) WITH_MCP=1; shift ;;
    --wechat-bridge) WECHAT_BRIDGE=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --purge)    PURGE=1; shift ;;
    -h|--help)  show_help ;;
    *) die "未知参数: $1（用 --help 查看用法）" ;;
  esac
done

# 环境变量兜底（flag 优先），供 user-data / 自定义脚本场景
PORT="${ARG_PORT:-${WEBSERVER_PORT:-$DEFAULT_PORT}}"
DEST="${ARG_DIR:-${INSTALL_DIR:-$DEFAULT_DIR}}"
WEWORK="${ARG_WEWORK:-${WEWORK_WEBHOOK_URL:-}}"
FEISHU="${ARG_FEISHU:-${FEISHU_WEBHOOK_URL:-}}"
DINGTALK="${ARG_DINGTALK:-${DINGTALK_WEBHOOK_URL:-}}"
NTFY_TOPIC="${ARG_NTFY:-${NTFY_TOPIC:-}}"
AI_KEY="${ARG_AIKEY:-${AI_API_KEY:-}}"
AI_MODEL="${ARG_AIMODEL:-${AI_MODEL:-}}"
if [ -n "$ARG_TG" ]; then TG_RAW="$ARG_TG"
else TG_RAW="${TELEGRAM_BOT_TOKEN:-}"; [ -n "$TG_RAW" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] && TG_RAW="${TG_RAW}:${TELEGRAM_CHAT_ID}"; fi
TG_TOKEN=""; TG_CHAT=""; [ -n "$TG_RAW" ] && TG_TOKEN="${TG_RAW%:*}" && TG_CHAT="${TG_RAW##*:}"

# 微信推送桥（any2wechat，--wechat-bridge 时部署；原生 node 直跑）
A2W_GITEE="https://gitee.com/geekkkk404/any2wechat.git"
A2W_GITHUB="https://github.com/geekkkk404/any2wechat.git"
A2W_BRANCH="main"
A2W_SRC="$DEST/any2wechat"
A2W_DATA="$DEST/any2wechat-data"
A2W_PORT=8788
BRIDGE_OK=0
BRIDGE_AUTHED=0
NODE_BIN="/usr/local/bin/node"

# ----------------------------- 卸载分支 --------------------------------------
if [ "$UNINSTALL" = "1" ]; then
  step "卸载 TrendRadar（目录: $DEST）"
  systemctl disable --now trendradar-fetch.timer >/dev/null 2>&1 || true
  systemctl disable --now trendradar-web trendradar-fetch trendradar-mcp any2wechat >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/trendradar-web.service /etc/systemd/system/trendradar-fetch.service \
        /etc/systemd/system/trendradar-fetch.timer /etc/systemd/system/trendradar-mcp.service \
        /etc/systemd/system/any2wechat.service
  systemctl daemon-reload 2>/dev/null || true
  rm -f /etc/cron.d/trendradar   # 清理 v0.1.x 实验期遗留（如有）
  ok "服务已停止并移除"
  if [ "$PURGE" = "1" ]; then
    rm -rf "$DEST" && ok "已删除全部数据（含微信绑定凭证，如有）: $DEST"
    rm -rf /usr/local/lib/nodejs; rm -f "$NODE_BIN"
    if [ -x /usr/local/bin/uv ]; then
      # 先 pip 卸载（24.04 的 pip 卸载同样受 PEP 668 管制，必须带 flag），再兜底删入口脚本
      pip3 uninstall -y --break-system-packages -q uv >/dev/null 2>&1 || true
      rm -f /usr/local/bin/uv /usr/local/bin/uvx
      ok "已移除 uv / node（脚本安装的工具链）"
    fi
  else
    ok "数据已保留在 $DEST（彻底删除请加 --purge，含 node/uv 工具链）"
  fi
  ok "完成。apt 安装的基础包（git/curl/python3-pip）未卸载，如需请自行处理"
  exit 0
fi

# ----------------------------- 前置检查 --------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  # curl|bash 场景 $0 不是文件路径，无法自动提权
  if [ -f "$0" ] && [ -x "$(command -v sudo)" ]; then exec sudo -E bash "$0" "$@"; fi
  die "请以 root 运行（如: sudo bash install-trendradar.sh）"
fi

step "环境检查"
NEED_APT=()
for t in curl git; do
  command -v "$t" >/dev/null 2>&1 || NEED_APT+=("$t")
done
command -v pip3 >/dev/null 2>&1 || NEED_APT+=("python3-pip")
if [ "${#NEED_APT[@]}" -gt 0 ]; then
  echo "  安装基础工具: ${NEED_APT[*]} ..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq "${NEED_APT[@]}" >/dev/null 2>&1 || die "基础工具安装失败，请先手动: apt-get install -y ${NEED_APT[*]}"
fi
command -v xz >/dev/null 2>&1 || { apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq xz-utils >/dev/null 2>&1 || true; }
ok "curl / git / pip3 就绪"

# 磁盘与内存提示
free_mb=$(df -Pm / | awk 'NR==2{print $4}')
[ "$free_mb" -lt 3072 ] && warn "根分区剩余 ${free_mb}MB，建议 ≥3GB"
mem_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
[ "$mem_mb" -lt 900 ] && warn "内存仅 ${mem_mb}MB，偏小但通常可运行"

# ----------------------------- 区域识别 --------------------------------------
step "网络环境识别"
REGION="cn"
if curl -sm2 -o /dev/null http://metadata.tencentyun.com/latest/meta-data/ 2>/dev/null; then
  REGION="tencent"
elif curl -sm2 -o /dev/null http://100.100.100.200/latest/meta-data/ 2>/dev/null; then
  REGION="aliyun"
elif curl -sm3 -o /dev/null https://www.google.com 2>/dev/null; then
  REGION="overseas"
fi
case "$REGION" in
  tencent)  ok "腾讯云（境内内网加速可用）" ;;
  aliyun)   ok "阿里云（境内内网加速可用）" ;;
  overseas) ok "境外网络（全部直连）" ;;
  *)        ok "境内网络（自动使用国内镜像源）" ;;
esac

# PyPI 镜像（uv 下载依赖用；境内秒级，境外官方源）
case "$REGION" in
  tencent)  PYPI_INDEX="https://mirrors.cloud.tencent.com/pypi/simple" ;;
  aliyun)   PYPI_INDEX="https://mirrors.aliyun.com/pypi/simple" ;;
  overseas) PYPI_INDEX="https://pypi.org/simple" ;;
  *)        PYPI_INDEX="https://pypi.tuna.tsinghua.edu.cn/simple" ;;
esac

# ----------------------------- Python 与 uv -----------------------------------
step "准备 Python 运行环境"
PY_GE_312=$(python3 -c 'import sys; print(1 if sys.version_info >= (3, 12) else 0)' 2>/dev/null || echo 0)
export UV_DEFAULT_INDEX="$PYPI_INDEX"
if [ "$PY_GE_312" = "1" ]; then
  export UV_PYTHON_PREFERENCE=only-system
  ok "系统 Python $(python3 --version | awk '{print $2}')（满足 ≥3.12，直接使用）"
else
  # 系统 Python 过低 → 让 uv 自动下载自带 Python（境内经代理加速）
  if [ "$REGION" != "overseas" ]; then
    export UV_PYTHON_INSTALL_MIRROR="$UV_PY_MIRROR_PROXY"
  fi
  warn "系统 Python 低于 3.12，将由 uv 自动安装独立 Python（一次性，约 30-60 秒）"
fi

if ! command -v uv >/dev/null 2>&1; then
  echo "  安装 uv 包管理器（$PYPI_INDEX）..."
  pip3 install --break-system-packages -q -i "$PYPI_INDEX" uv >/dev/null 2>&1 \
    || pip3 install -q -i "$PYPI_INDEX" uv >/dev/null 2>&1 || true
  # 半卸载态自愈：pip 认为已装但入口脚本丢失（如曾手工删除 /usr/local/bin/uv）→ 强制重装重建入口
  if ! command -v uv >/dev/null 2>&1; then
    echo "  uv 入口缺失，强制重装修复..."
    pip3 install --break-system-packages -q --force-reinstall --no-deps -i "$PYPI_INDEX" uv >/dev/null 2>&1 \
      || pip3 install -q --force-reinstall --no-deps -i "$PYPI_INDEX" uv >/dev/null 2>&1 || true
  fi
  if ! command -v uv >/dev/null 2>&1; then
    # pip 路线全败（pip 过旧/受管环境限制）→ GitHub 独立二进制回退（直连 15s → 代理链）
    echo "  pip 不可用，改用独立二进制安装 uv ..."
    case "$(uname -m)" in
      x86_64) UV_ARCH="x86_64-unknown-linux-gnu" ;; aarch64) UV_ARCH="aarch64-unknown-linux-gnu" ;;
      *) die "暂不支持的架构: $(uname -m)" ;;
    esac
    UV_GOT=0
    for prefix in "" "${GH_PROXY_FALLBACKS[@]}"; do
      url="${prefix:+$prefix/}https://github.com/astral-sh/uv/releases/latest/download/uv-${UV_ARCH}.tar.gz"
      if timeout 15 curl -fsSL "$url" -o /tmp/uv.tar.gz 2>/dev/null; then UV_GOT=1; break; fi
    done
    [ "$UV_GOT" = "1" ] || die "uv 安装失败（pip 与二进制均不可达），请检查网络后重跑"
    tar -xzf /tmp/uv.tar.gz -C /tmp
    mv "/tmp/uv-${UV_ARCH}/uv" /usr/local/bin/uv && chmod +x /usr/local/bin/uv
    rm -rf /tmp/uv.tar.gz "/tmp/uv-${UV_ARCH}"
  fi
fi
command -v uv >/dev/null 2>&1 || die "uv 仍不可用，请重跑或手动安装: pip3 install uv"
ok "uv $(uv --version | awk '{print $2}')（PyPI 源: $PYPI_INDEX）"

# ----------------------------- 获取源码 ---------------------------------------
step "获取 TrendRadar 源码 → $DEST"
if [ -d "$DEST/.git" ]; then
  git -C "$DEST" fetch --depth 1 origin "$REPO_BRANCH" >/dev/null 2>&1 \
    && git -C "$DEST" reset --hard "origin/$REPO_BRANCH" >/dev/null 2>&1 \
    && ok "已更新到最新版"
elif [ -e "$DEST" ] && [ -n "$(ls -A "$DEST" 2>/dev/null)" ]; then
  die "目录 $DEST 已存在且非本脚本安装，请更换 --dir 或先清理"
else
  GOT=0
  # 直连 15s 不通即切代理（社区代理单源 15s；连接不上的源等再久也连不上）
  for prefix in "" "${GH_PROXY_FALLBACKS[@]}"; do
    url="${prefix:+$prefix/}$REPO_URL.git"
    echo "  克隆: $url"
    if timeout 15 git clone --depth 1 -b "$REPO_BRANCH" "$url" "$DEST" >/dev/null 2>&1; then GOT=1; break; fi
    rm -rf "$DEST"
  done
  [ "$GOT" = "1" ] || die "源码克隆失败（网络问题），请重跑本脚本重试"
  ok "克隆完成"
fi
[ -f "$DEST/pyproject.toml" ] || die "源码不完整（缺少 pyproject.toml）"

# ----------------------------- 依赖安装 ---------------------------------------
step "安装依赖（uv sync，境内秒级）"
cd "$DEST" || die "进入 $DEST 失败"
if uv sync --no-dev >>/tmp/tr-uvsync.log 2>&1; then
  ok "依赖就绪（.venv $(du -sm .venv | cut -f1)MB）"
else
  tail -5 /tmp/tr-uvsync.log | sed 's/^/  │ /'
  die "依赖安装失败，请重跑本脚本重试"
fi

# ----------------------------- 配置写入 ---------------------------------------
step "写入配置（trendradar.env）"
ENV_FILE="$DEST/trendradar.env"
touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
# systemd EnvironmentFile 与 bash source 双消费方：值一律单引号包裹（内嵌 JSON 安全）
upsert_env() { sed -i "/^$1=/d" "$ENV_FILE"; printf "%s='%s'\n" "$1" "$(printf '%s' "$2" | sed "s/'/'\\\\''/g")" >> "$ENV_FILE"; }
upsert_env "CONFIG_PATH" "$DEST/config/config.yaml"
upsert_env "FREQUENCY_WORDS_PATH" "$DEST/config/frequency_words.txt"
upsert_env "PYTHONUNBUFFERED" "1"
upsert_env "WEBSERVER_PORT" "$PORT"
[ -n "$WEWORK" ]   && upsert_env "WEWORK_WEBHOOK_URL"   "$WEWORK"
[ -n "$FEISHU" ]   && upsert_env "FEISHU_WEBHOOK_URL"   "$FEISHU"
[ -n "$DINGTALK" ] && upsert_env "DINGTALK_WEBHOOK_URL" "$DINGTALK"
[ -n "$NTFY_TOPIC" ] && upsert_env "NTFY_TOPIC" "$NTFY_TOPIC"
if [ -n "$TG_TOKEN" ]; then
  [ -n "$TG_CHAT" ] || die "Telegram 参数格式应为 BotToken:ChatID"
  upsert_env "TELEGRAM_BOT_TOKEN" "$TG_TOKEN"; upsert_env "TELEGRAM_CHAT_ID" "$TG_CHAT"
fi
[ -n "$AI_KEY" ]   && upsert_env "AI_API_KEY" "$AI_KEY" && upsert_env "AI_ANALYSIS_ENABLED" "true"
[ -n "$AI_MODEL" ] && upsert_env "AI_MODEL" "$AI_MODEL"
if [ "$WITH_MCP" = "1" ]; then
  upsert_env "MCP_HOST" "127.0.0.1"
  upsert_env "MCP_PORT" "3333"
fi
if [ "$WECHAT_BRIDGE" = "1" ]; then
  # TrendRadar 通用 webhook → 微信桥（原生同机回环）
  upsert_env "GENERIC_WEBHOOK_URL" "http://127.0.0.1:$A2W_PORT/webhook"
  upsert_env "GENERIC_WEBHOOK_TEMPLATE" '{"title":"{title}","content":"{content}"}'
fi
ok "配置已写入（保留既有手工配置项）"
# 载入配置供后续单元写入读取（如 MCP_HOST/MCP_PORT 支持在 env 中自定义）
MCP_HOST="${MCP_HOST:-127.0.0.1}"; MCP_PORT="${MCP_PORT:-3333}"
. "$ENV_FILE"

# ----------------------------- systemd 单元 -----------------------------------
step "安装 systemd 服务"
WEB_BIND="0.0.0.0"; [ "$NO_WEB" = "1" ] && WEB_BIND="127.0.0.1"

cat > /etc/systemd/system/trendradar-web.service <<EOF
[Unit]
Description=TrendRadar web report (static)
After=network.target

[Service]
ExecStart=$DEST/.venv/bin/python -m http.server $PORT --bind $WEB_BIND --directory $DEST/output
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/trendradar-fetch.service <<EOF
[Unit]
Description=TrendRadar news fetch (crawl + push)
After=network.target

[Service]
Type=oneshot
WorkingDirectory=$DEST
EnvironmentFile=$ENV_FILE
ExecStart=$DEST/.venv/bin/python -m trendradar
TimeoutStartSec=1500
EOF

cat > /etc/systemd/system/trendradar-fetch.timer <<EOF
[Unit]
Description=TrendRadar fetch schedule (every 30 min)

[Timer]
OnCalendar=*:0/30
Persistent=true

[Install]
WantedBy=timers.target
EOF

if [ "$WITH_MCP" = "1" ]; then
  cat > /etc/systemd/system/trendradar-mcp.service <<EOF
[Unit]
Description=TrendRadar MCP AI analysis server
After=network.target

[Service]
WorkingDirectory=$DEST
EnvironmentFile=$ENV_FILE
ExecStart=$DEST/.venv/bin/python -m mcp_server.server --transport http --host ${MCP_HOST:-127.0.0.1} --port ${MCP_PORT:-3333}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
fi
systemctl daemon-reload
systemctl enable trendradar-web >/dev/null 2>&1
systemctl restart trendradar-web      # restart 而非 enable --now：重跑改端口/绑定即时生效
systemctl enable --now trendradar-fetch.timer >/dev/null 2>&1
if [ "$WITH_MCP" = "1" ]; then
  systemctl enable trendradar-mcp >/dev/null 2>&1 && systemctl restart trendradar-mcp && ok "MCP 服务已启动（$MCP_HOST:$MCP_PORT）"
fi
if [ "$NO_WEB" = "1" ]; then
  ok "网页报告服务已启动（仅本机 127.0.0.1:$PORT，外网暴露面为零）"
else
  ok "网页报告服务已启动（0.0.0.0:$PORT）"
fi
ok "定时抓取已排程（每 30 分钟，systemd timer 持久化）"

# ----------------------------- 首次抓取 ---------------------------------------
step "首次抓取（真实运行一次，生成报告与推送）"
if ( set -a; . "$ENV_FILE"; set +a; cd "$DEST" && exec "$DEST/.venv/bin/python" -m trendradar ); then
  ok "首次抓取完成"
else
  warn "首次抓取未成功（数据源偶发不可达属正常；定时任务会自动重试，不影响安装）"
fi

# ----------------------------- 健康检查 ---------------------------------------
HEALTH="fail"
for i in $(seq 1 12); do
  code=$(curl -sm2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null) || code="000"
  if [ "$code" = "200" ]; then HEALTH="ok"; break; fi
  sleep 5
done
if [ "$HEALTH" != "ok" ]; then
  journalctl -u trendradar-web --no-pager -n 5 2>/dev/null | sed 's/^/  │ /'
  die "网页服务未就绪（端口 $PORT）。可重跑本脚本或查看: journalctl -u trendradar-web"
fi
ok "网页报告就绪（HTTP $code）"

# ----------------------------- 微信推送桥（可选，软失败） ----------------------
# 桥的任何失败都不影响 TrendRadar 本体：warn + 降级提示，重跑幂等补齐
if [ "$WECHAT_BRIDGE" = "1" ]; then
  step "部署微信推送桥 any2wechat（个人微信直推，原生 node 运行）"

  # Node 运行时（钉死版本；npmmirror 大陆秒下）
  NODE_OK=0
  if [ -x "$NODE_BIN" ] && [ "$("$NODE_BIN" --version 2>/dev/null)" = "$NODE_VERSION" ]; then
    NODE_OK=1; ok "Node $NODE_VERSION 已就绪"
  else
    case "$(uname -m)" in
      x86_64) NARCH="x64" ;; aarch64) NARCH="arm64" ;;
      *) warn "不支持的架构: $(uname -m)，跳过桥部署" ;;
    esac
    if [ -n "${NARCH:-}" ]; then
      NMIRROR="$NODE_MIRROR_CN"; [ "$REGION" = "overseas" ] && NMIRROR="$NODE_MIRROR_INTL"
      echo "  安装 Node $NODE_VERSION（$NMIRROR）..."
      if curl -fsSL --retry 2 -m 180 "$NMIRROR/$NODE_VERSION/node-$NODE_VERSION-linux-$NARCH.tar.xz" -o /tmp/node.tar.xz 2>/dev/null; then
        mkdir -p /usr/local/lib/nodejs
        tar -xJf /tmp/node.tar.xz -C /usr/local/lib/nodejs --strip-components=1 >/dev/null 2>&1 \
          && ln -sf /usr/local/lib/nodejs/bin/node "$NODE_BIN" \
          && NODE_OK=1
        rm -f /tmp/node.tar.xz
      fi
      [ "$NODE_OK" = "1" ] && ok "Node $(node --version) 就绪" || warn "Node 安装失败，跳过桥部署；可重跑本脚本重试"
    fi
  fi

  # 源码：Gitee 优先（大陆可达），GitHub 走代理回退
  if [ "$NODE_OK" = "1" ]; then
    if [ -d "$A2W_SRC/.git" ]; then
      git -C "$A2W_SRC" fetch --depth 1 origin "$A2W_BRANCH" >/dev/null 2>&1 \
        && git -C "$A2W_SRC" reset --hard "origin/$A2W_BRANCH" >/dev/null 2>&1 \
        && ok "桥源码已更新"
    elif [ -e "$A2W_SRC" ] && [ -n "$(ls -A "$A2W_SRC" 2>/dev/null)" ]; then
      warn "$A2W_SRC 已存在且非本脚本安装，跳过桥部署"
    else
      GOT=0
      for u in "$A2W_GITEE" "$A2W_GITHUB"; do
        echo "  克隆: $u"
        if timeout 15 git clone --depth 1 -b "$A2W_BRANCH" "$u" "$A2W_SRC" >/dev/null 2>&1; then GOT=1; break; fi
        rm -rf "$A2W_SRC"
      done
      if [ "$GOT" = "0" ]; then
        for prefix in "${GH_PROXY_FALLBACKS[@]}"; do
          u="$prefix/$A2W_GITHUB"
          echo "  克隆: $u"
          if timeout 15 git clone --depth 1 -b "$A2W_BRANCH" "$u" "$A2W_SRC" >/dev/null 2>&1; then GOT=1; break; fi
          rm -rf "$A2W_SRC"
        done
      fi
      [ "$GOT" = "1" ] && ok "桥源码克隆完成" || warn "桥源码克隆失败（网络问题），跳过桥部署；可重跑本脚本重试"
    fi
  fi

  # 数据目录 + 授权 + 服务
  if [ -f "$A2W_SRC/src/main.mjs" ]; then
    BRIDGE_OK=1
    mkdir -p "$A2W_DATA" && chmod 700 "$A2W_DATA"

    # 扫码授权：交互终端现场完成；管道/自动化（非 TTY）自动跳过，命令见完成摘要
    if [ -t 0 ]; then
      echo ""
      echo "  ──────────────────────────────────────────────────"
      echo "  微信授权：下面会显示一条授权链接。"
      echo "  把链接发送到手机（微信文件传输助手即可），用手机微信打开并确认。"
      echo "  ──────────────────────────────────────────────────"
      if (cd "$A2W_SRC" && BRIDGE_DATA_DIR="$A2W_DATA" node bin/login.mjs); then
        ok "微信授权完成（凭证已保存）"
      else
        warn "授权未完成（不影响安装，可稍后按完成摘要里的命令补做）"
      fi
    else
      warn "当前为非交互环境，跳过微信授权（补做命令见完成摘要）"
    fi
    [ -f "$A2W_DATA/credentials.json" ] && BRIDGE_AUTHED=1

    cat > /etc/systemd/system/any2wechat.service <<EOF
[Unit]
Description=any2wechat WeChat push bridge
After=network.target

[Service]
WorkingDirectory=$A2W_SRC
ExecStart=$NODE_BIN src/main.mjs
Environment=BRIDGE_DATA_DIR=$A2W_DATA
Environment=BRIDGE_HOST=127.0.0.1
Environment=BRIDGE_PORT=$A2W_PORT
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now any2wechat >/dev/null 2>&1

    if [ "$BRIDGE_AUTHED" = "1" ]; then
      systemctl restart any2wechat   # 载入新凭证
      BH="fail"
      for i in $(seq 1 12); do
        bcode=$(curl -sm2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$A2W_PORT/health" 2>/dev/null) || bcode="000"
        if [ "$bcode" != "000" ]; then BH="ok"; break; fi
        sleep 5
      done
      if [ "$BH" = "ok" ]; then
        ok "桥服务就绪（127.0.0.1:$A2W_PORT）"
      else
        warn "桥服务未就绪，稍后查看: journalctl -u any2wechat -n 20"
      fi
    else
      ok "桥服务已注册（待微信授权后自动上线，期间每 30 秒重试属正常）"
    fi
  fi
fi

# ----------------------------- 防火墙 -----------------------------------------
step "检查本机防火墙"
if [ "$NO_WEB" = "1" ]; then
  ok "仅本机模式：未开放任何入站端口"
elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "$PORT/tcp" >/dev/null 2>&1 && ok "ufw 已放行 TCP $PORT"
elif systemctl is-active firewalld >/dev/null 2>&1; then
  firewall-cmd --add-port="$PORT/tcp" --permanent >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1 \
    && ok "firewalld 已放行 TCP $PORT"
else
  ok "本机防火墙未启用（云服务器还需检查控制台防火墙，见下方提示）"
fi

# ----------------------------- 公网 IP ----------------------------------------
PUB_IP=""
PUB_IP=$(curl -sm3 http://metadata.tencentyun.com/latest/meta-data/public-ipv4 2>/dev/null) \
  || PUB_IP=$(curl -sm3 http://100.100.100.200/latest/meta-data/eipv4 2>/dev/null) \
  || PUB_IP=$(curl -sm4 https://api.ipify.org 2>/dev/null) \
  || PUB_IP=$(curl -sm4 https://ip.3322.net 2>/dev/null) \
  || true
[ -z "$PUB_IP" ] && PUB_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

# ----------------------------- 完成摘要 ---------------------------------------
CHANNELS=""
[ -n "$WEWORK" ]     && CHANNELS="$CHANNELS 企业微信"
[ -n "$FEISHU" ]     && CHANNELS="$CHANNELS 飞书"
[ -n "$DINGTALK" ]   && CHANNELS="$CHANNELS 钉钉"
[ -n "$TG_TOKEN" ]   && CHANNELS="$CHANNELS Telegram"
[ -n "$NTFY_TOPIC" ] && CHANNELS="$CHANNELS ntfy"

printf "\n"
echo "  ═══════════════════════════════════════════════════════"
echo "    ✅ TrendRadar 部署完成（原生部署，未使用 Docker）"
echo "  ═══════════════════════════════════════════════════════"
if [ "$NO_WEB" = "0" ]; then
  echo "    🌐 网页报告: http://${PUB_IP:-你的服务器IP}:$PORT"
  echo "       （报告已生成；浏览器提示\"不安全\"属正常现象）"
else
  echo "    🔒 仅本机模式: 未开放任何入站端口（报告在 $DEST/output/，服务器本机可见）"
fi
if [ "$WECHAT_BRIDGE" = "1" ] && [ "$BRIDGE_OK" = "1" ]; then
  echo "    📱 微信推送: any2wechat 桥已部署（TrendRadar 通用 webhook 已指向桥）"
  if [ "$BRIDGE_AUTHED" = "1" ]; then
    echo "       ▶ 最后一步: 在微信里给 bot 发一句「绑定」"
    echo "         bot 会话可在微信通讯录里找到（授权时创建）；绑定确认后热点日报直达微信"
    echo "         想立刻收第一期: systemctl start trendradar-fetch"
  else
    echo "       ▶ 微信授权尚未完成，在服务器终端补做（复制整段执行）:"
    echo "         cd $A2W_SRC && BRIDGE_DATA_DIR=$A2W_DATA node bin/login.mjs"
    echo "         授权成功后，在微信里给 bot 发一句「绑定」即完成绑定"
  fi
  echo "       ▶ 桥日志: journalctl -u any2wechat -f"
elif [ -n "$CHANNELS" ]; then
  echo "    📱 已配置推送:$CHANNELS"
else
  echo "    📱 尚未配置手机推送。推荐微信个人号直推（最简单，零注册）:"
  echo "       bash install-trendradar.sh --wechat-bridge --no-web"
  echo "       （也支持 --wework / --feishu / --dingtalk / --telegram 'BotToken:ChatID'）"
fi
echo "    🔧 查看抓取日志: journalctl -u trendradar-fetch -n 50   （跟踪 -f）"
echo "    ⏰ 定时任务:     systemctl list-timers trendradar-fetch*"
echo "    🔄 升级更新:     重跑本脚本即可（幂等，保留配置与数据；含 --wechat-bridge 时桥同步更新）"
echo "    🗑  停止卸载:     bash install-trendradar.sh --uninstall（彻底删除含微信凭证用 --uninstall --purge）"
if [ "$NO_WEB" = "0" ]; then
  case "$REGION" in
    tencent) echo "    ⚠️  若网页打不开: 腾讯云控制台 → 轻量应用服务器(或云服务器) → 防火墙 → 添加规则放行 TCP $PORT" ;;
    aliyun)  echo "    ⚠️  若网页打不开: 阿里云控制台 → 实例 → 安全组 → 配置规则放行 TCP $PORT" ;;
    *)       echo "    ⚠️  若网页打不开: 请在云服务商控制台的防火墙/安全组放行 TCP $PORT" ;;
  esac
fi
echo "  ═══════════════════════════════════════════════════════"
