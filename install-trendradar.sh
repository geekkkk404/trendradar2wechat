#!/usr/bin/env bash
# =============================================================================
#  TrendRadar 一键安装脚本（VPS 版）— trendradar2wechat 项目分发
#  上游项目: https://github.com/sansan0/TrendRadar （GPL-3.0，安装时获取原版，不修改源码）
#  本项目:   https://github.com/geekkkk404/trendradar2wechat
#  适用系统: Ubuntu 20.04+ / Debian 11+（x86_64 / arm64），境内外 VPS 自适应
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
#    --no-web            不对外开放网页报告（仅本机可访问）
#    --with-mcp          同时部署 MCP AI 分析服务（默认不部署）
#    --uninstall         停止并移除容器；配合 --purge 同时删除数据
#    --purge             配合 --uninstall 删除全部数据（含微信绑定凭证）
#    -h, --help          显示本帮助
#
#  ▍环境变量等价写法（适合"自定义脚本/user-data"开机自动部署）:
#    WEWORK_WEBHOOK_URL / FEISHU_WEBHOOK_URL / DINGTALK_WEBHOOK_URL
#    TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID / AI_API_KEY / AI_MODEL / WECHAT_BRIDGE=1
#
#  ▍特性:
#    - 全程非交互，可重复执行（重跑 = 更新到最新版并应用配置）
#    - 自动识别境内/境外网络，境内自动配置可用镜像加速
#    - 推送渠道配置保存在 {安装目录}/docker/.env，可随时手工编辑
#    - --wechat-bridge：个人微信直推（any2wechat，MIT），桥故障不影响 TrendRadar 本体
# =============================================================================

set -u -o pipefail

# ----------------------------- 常量 ------------------------------------------
REPO_URL="https://github.com/sansan0/TrendRadar"
REPO_BRANCH="master"
IMAGE_MAIN="wantcat/trendradar:latest"
IMAGE_MCP="wantcat/trendradar-mcp:latest"
DEFAULT_PORT=8080
DEFAULT_DIR="/opt/TrendRadar"
GH_PROXY_FALLBACKS=("https://ghfast.top" "https://gh-proxy.com" "https://ghp.ci")
REGISTRY_MIRRORS_CANDIDATES=("docker.1ms.run" "hub.rat.dev" "docker.m.daocloud.io" "dockerproxy.net")
TENCENT_INTERNAL_MIRROR="mirror.ccs.tencentyun.com"
COMPOSE_VERSION_URL="https://github.com/docker/compose/releases/latest/download"

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

# 微信推送桥（any2wechat，--wechat-bridge 时部署；源码安装时从官方仓获取）
A2W_GITEE="https://gitee.com/geekkkk404/any2wechat.git"
A2W_GITHUB="https://github.com/geekkkk404/any2wechat.git"
A2W_BRANCH="main"
A2W_SRC="$DEST/any2wechat"
A2W_DATA="$DEST/any2wechat-data"
A2W_IMAGE="any2wechat:local"
A2W_PORT=8788
BRIDGE_OK=0
BRIDGE_AUTHED=0

# ----------------------------- 卸载分支 --------------------------------------
if [ "$UNINSTALL" = "1" ]; then
  step "卸载 TrendRadar（目录: $DEST）"
  if [ -f "$DEST/docker/docker-compose.yml" ]; then
    (cd "$DEST/docker" && docker compose down --remove-orphans 2>/dev/null) || docker rm -f trendradar trendradar-mcp 2>/dev/null
    ok "容器已停止并移除"
  else
    docker rm -f trendradar trendradar-mcp 2>/dev/null
    warn "未找到安装目录中的 compose 文件，仅尝试移除同名容器"
  fi
  if [ "$PURGE" = "1" ]; then
    rm -rf "$DEST" && ok "已删除全部数据（含微信绑定凭证，如有）: $DEST"
  else
    ok "数据已保留在 $DEST（彻底删除请加 --purge）"
  fi
  ok "完成。Docker 本体未卸载，如需请自行处理"
  exit 0
fi

# ----------------------------- 前置检查 --------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  # curl|bash 场景 $0 不是文件路径，无法自动提权
  if [ -f "$0" ] && [ -x "$(command -v sudo)" ]; then exec sudo -E bash "$0" "$@"; fi
  die "请以 root 运行（如: sudo bash install-trendradar.sh）"
fi

step "环境检查"
# 基础工具
for t in curl git; do
  if ! command -v "$t" >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq "$t" >/dev/null 2>&1 \
      || die "缺少 $t 且自动安装失败，请先: apt-get install -y $t"
  fi
done
ok "curl / git 就绪"

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
  *)        ok "境内网络（将自动配置镜像加速）" ;;
esac

# ----------------------------- Docker ----------------------------------------
install_docker() {
  # 境内优先走镜像源 apt 直装（get.docker.com 在大陆 VPS 常被连接重置），境外走官方脚本
  local distro codename base
  distro="$(. /etc/os-release && echo "$ID")"
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  export DEBIAN_FRONTEND=noninteractive
  if [ "$REGION" != "overseas" ] && { [ "$distro" = "ubuntu" ] || [ "$distro" = "debian" ]; }; then
    case "$REGION" in
      tencent) base="https://mirrors.cloud.tencent.com/docker-ce" ;;
      *)       base="https://mirrors.aliyun.com/docker-ce" ;;
    esac
    echo "  经镜像源安装 Docker（$base）..."
    mkdir -p /etc/apt/keyrings
    if curl -fsSL --connect-timeout 8 "${base}/linux/${distro}/gpg" -o /etc/apt/keyrings/docker.asc 2>/dev/null; then
      echo "deb [signed-by=/etc/apt/keyrings/docker.asc] ${base}/linux/${distro} ${codename} stable" > /etc/apt/sources.list.d/docker.list
      apt-get update -qq >/dev/null 2>&1
      apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1 && return 0
      rm -f /etc/apt/sources.list.d/docker.list
    fi
    warn "镜像源安装失败，回退官方脚本..."
  fi
  curl -fsSL https://get.docker.com -o /tmp/getdocker.sh || die "下载 Docker 安装脚本失败"
  case "$REGION" in
    overseas) sh /tmp/getdocker.sh || die "Docker 安装失败" ;;
    *)        sh /tmp/getdocker.sh --mirror Aliyun || die "Docker 安装失败" ;;
  esac
  rm -f /tmp/getdocker.sh
}

step "检查 Docker"
if ! command -v docker >/dev/null 2>&1; then
  echo "  未安装，开始安装 Docker（约 1-3 分钟）..."
  install_docker
fi
if systemctl is-active docker >/dev/null 2>&1 || service docker status >/dev/null 2>&1; then
  :
else
  systemctl enable --now docker >/dev/null 2>&1 || service docker start >/dev/null 2>&1 || die "Docker 服务启动失败"
fi
docker info >/dev/null 2>&1 || die "Docker 未正常运行"
ok "Docker $(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"

# docker compose 插件
if ! docker compose version >/dev/null 2>&1; then
  echo "  安装 docker compose 插件..."
  if apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1; then
    :
  else
    ARCH=$(uname -m); case "$ARCH" in
      x86_64) CARCH="linux-x86_64" ;; aarch64) CARCH="linux-aarch64" ;;
      *) die "暂不支持的架构: $ARCH" ;;
    esac
    mkdir -p /usr/local/lib/docker/cli-plugins
    GOT=0
    for prefix in "" "${GH_PROXY_FALLBACKS[@]}"; do
      url="${prefix:+$prefix/}$COMPOSE_VERSION_URL/docker-compose-$CARCH"
      if curl -fsSL --connect-timeout 8 -m 180 "$url" -o /usr/local/lib/docker/cli-plugins/docker-compose 2>/dev/null; then GOT=1; break; fi
    done
    [ "$GOT" = "1" ] || die "docker compose 插件安装失败，请手动安装后重跑"
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  fi
  docker compose version >/dev/null 2>&1 || die "docker compose 仍不可用"
fi
ok "docker compose $(docker compose version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"

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
  # 社区代理存在分钟级抖动（实测全灭后数十秒内即恢复）：全链失败后整链重试一轮
  for round in 1 2; do
    for prefix in "" "${GH_PROXY_FALLBACKS[@]}"; do
      url="${prefix:+$prefix/}$REPO_URL.git"
      echo "  克隆: $url"
      if timeout 180 git clone --depth 1 -b "$REPO_BRANCH" "$url" "$DEST" >/dev/null 2>&1; then GOT=1; break; fi
    done
    [ "$GOT" = "1" ] && break
    [ "$round" = "1" ] && { echo "  全部克隆源失败，30 秒后整链重试..."; sleep 30; }
  done
  [ "$GOT" = "1" ] || die "源码克隆失败（网络问题），请重跑本脚本重试"
  ok "克隆完成"
fi
[ -f "$DEST/docker/docker-compose.yml" ] || die "源码不完整（缺少 docker-compose.yml）"

# ----------------------------- 配置写入 ---------------------------------------
step "写入配置（.env）"
ENV_FILE="$DEST/docker/.env"
touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
upsert_env() { sed -i "/^$1=/d" "$ENV_FILE"; printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"; }
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
if [ "$WECHAT_BRIDGE" = "1" ]; then
  # TrendRadar 通用 webhook → 微信桥（compose 网络内容器名即 DNS；官方 compose 已预埋变量通道）
  upsert_env "GENERIC_WEBHOOK_URL" "http://any2wechat:$A2W_PORT/webhook"
  upsert_env "GENERIC_WEBHOOK_TEMPLATE" '{"title":"{title}","content":"{content}"}'
fi
ok "配置已写入（保留既有手工配置项）"

# 网页端口绑定：默认对外开放（官方仅 127.0.0.1）；--no-web 则强制仅本机（幂等双向）
if [ "$NO_WEB" = "0" ]; then
  sed -i '/WEBSERVER_PORT:-8080}/s/127\.0\.0\.1://' "$DEST/docker/docker-compose.yml"
  grep -q '"\${WEBSERVER_PORT' "$DEST/docker/docker-compose.yml" \
    && ok "网页报告端口 $PORT 已对外开放" \
    || warn "端口绑定改写未命中（可能上游格式变化），网页可能仅本机可访问"
else
  sed -i '/WEBSERVER_PORT:-8080}/s/- "\${WEBSERVER_PORT/- "127.0.0.1:\${WEBSERVER_PORT/' "$DEST/docker/docker-compose.yml"
  grep -q '"127\.0\.0\.1:\${WEBSERVER_PORT' "$DEST/docker/docker-compose.yml" \
    && ok "网页报告仅本机可访问（外网暴露面为零，无需放行任何端口）" \
    || warn "端口绑定改写未命中，请人工检查 compose 的 ports 行"
fi

# ----------------------------- 镜像加速（境内） --------------------------------
setup_mirrors() {
  # 已配置过则不重复处理（幂等）
  if [ -f /etc/docker/daemon.json ] && grep -q registry-mirrors /etc/docker/daemon.json 2>/dev/null; then
    ok "已存在镜像加速配置，跳过"
    return 0
  fi
  local candidates=() m probe_url final code json="[" first=1
  # 腾讯内网镜像无条件收录（内网域名探测易受瞬时因素干扰；即使不可达，docker 也会按序回退）
  if [ "$REGION" = "tencent" ]; then
    json="\"http://$TENCENT_INTERNAL_MIRROR\""; first=0
  fi
  for m in "${REGISTRY_MIRRORS_CANDIDATES[@]}"; do candidates+=("$m"); done
  for m in "${candidates[@]}"; do
    probe_url="https://$m/v2/"; final="https://$m"
    code=$(curl -sm4 -o /dev/null -w '%{http_code}' "$probe_url" 2>/dev/null) || code="000"
    case "$code" in
      200|401|302)
        [ "$first" = "0" ] && json="$json,"
        json="$json\"$final\""; first=0 ;;
    esac
  done
  json="$json]"
  if [ "$first" = "1" ]; then
    warn "所有镜像加速均不可达，将尝试直连拉取"
    return 1
  fi
  [ -f /etc/docker/daemon.json ] && cp /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%s)"
  mkdir -p /etc/docker
  printf '{ "registry-mirrors": %s }\n' "$json" > /etc/docker/daemon.json
  systemctl restart docker 2>/dev/null || service docker restart 2>/dev/null || die "Docker 重启失败"
  sleep 2
  ok "镜像加速已配置: $(echo "$json" | tr -d '"[]')"
  return 0
}

step "拉取镜像 $IMAGE_MAIN"
PULL_OK=0
if [ "$REGION" != "overseas" ]; then
  setup_mirrors || true
fi
echo "  首次拉取（上限 300 秒，慢网自动重试）..."
if timeout 300 docker pull "$IMAGE_MAIN" >/tmp/tr-pull.log 2>&1; then
  PULL_OK=1
else
  tail -3 /tmp/tr-pull.log | sed 's/^/  │ /'
  if [ "$REGION" = "overseas" ]; then
    warn "直连拉取失败，配置镜像加速后重试..."
    setup_mirrors || true
  fi
  for t in 600 900; do
    echo "  重试拉取（上限 ${t} 秒）..."
    if timeout "$t" docker pull "$IMAGE_MAIN" >>/tmp/tr-pull.log 2>&1; then PULL_OK=1; break; fi
    tail -3 /tmp/tr-pull.log | sed 's/^/  │ /'
  done
fi
[ "$PULL_OK" = "1" ] && ok "镜像拉取成功"
[ "$PULL_OK" = "1" ] || { tail -5 /tmp/tr-pull.log | sed 's/^/  │ /'; die "镜像拉取失败。可重跑本脚本重试（已完成的层会复用）；若持续失败请反馈"; }
[ "$WITH_MCP" = "1" ] && { timeout 420 docker pull "$IMAGE_MCP" >/dev/null 2>&1 && ok "MCP 镜像拉取成功" || warn "MCP 镜像拉取失败（不影响主服务）"; }

# ----------------------------- 启动 -------------------------------------------
step "启动服务"
cd "$DEST/docker" || die "进入 $DEST/docker 失败"
if [ "$WITH_MCP" = "1" ]; then
  UP_OUT=$(docker compose up -d 2>&1) || { printf '%s\n' "$UP_OUT"; die "启动失败（详见上方输出）"; }
else
  UP_OUT=$(docker compose up -d trendradar 2>&1) || { printf '%s\n' "$UP_OUT"; die "启动失败（详见上方输出）"; }
fi
printf '%s\n' "$UP_OUT" | grep -v '^ Network\|^ Volume' || true
ok "容器已创建，等待首次抓取与 Web 服务启动（约 30-120 秒）..."

# ----------------------------- 健康检查 ---------------------------------------
HEALTH="fail"
for i in $(seq 1 36); do
  state=$(docker inspect -f '{{.State.Status}}' trendradar 2>/dev/null || echo "gone")
  if [ "$state" = "exited" ]; then
    echo "  ---- 容器日志（末 25 行）----"
    docker logs --tail 25 trendradar 2>&1 | sed 's/^/  │ /'
    die "容器异常退出。常见原因: 数据源临时不可达（会自动重试，可稍后 docker start trendradar）"
  fi
  code=$(curl -sm2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null) || code="000"
  if [ "$code" != "000" ]; then HEALTH="ok"; break; fi
  sleep 5
done

if [ "$HEALTH" != "ok" ]; then
  echo "  ---- 容器日志（末 25 行）----"
  docker logs --tail 25 trendradar 2>&1 | sed 's/^/  │ /'
  die "Web 服务未在预期时间内就绪（端口 $PORT）。若容器仍在运行，多为首次抓取耗时较长，稍后重跑本脚本确认"
fi
ok "Web 服务已就绪（HTTP $code）"

# ----------------------------- 微信推送桥（可选，软失败） ----------------------
# 桥的任何失败都不影响 TrendRadar 本体：warn + 降级提示，重跑幂等补齐
if [ "$WECHAT_BRIDGE" = "1" ]; then
  step "部署微信推送桥 any2wechat（个人微信直推）"

  # 源码：Gitee 优先（大陆可达），GitHub 走代理回退
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
      if timeout 180 git clone --depth 1 -b "$A2W_BRANCH" "$u" "$A2W_SRC" >/dev/null 2>&1; then GOT=1; break; fi
    done
    if [ "$GOT" = "0" ]; then
      for prefix in "${GH_PROXY_FALLBACKS[@]}"; do
        u="$prefix/$A2W_GITHUB"
        echo "  克隆: $u"
        if timeout 180 git clone --depth 1 -b "$A2W_BRANCH" "$u" "$A2W_SRC" >/dev/null 2>&1; then GOT=1; break; fi
      done
    fi
    [ "$GOT" = "1" ] && ok "桥源码克隆完成" || warn "桥源码克隆失败（网络问题），跳过桥部署；可重跑本脚本重试"
  fi

  # 构建（node:22-slim 走已配置的镜像加速链；层缓存使重跑秒级）
  if [ -f "$A2W_SRC/docker/Dockerfile" ]; then
    echo "  构建桥镜像 $A2W_IMAGE（首次约 1-5 分钟）..."
    if timeout 900 docker build -t "$A2W_IMAGE" -f "$A2W_SRC/docker/Dockerfile" "$A2W_SRC" >/tmp/a2w-build.log 2>&1; then
      BRIDGE_OK=1
      ok "桥镜像构建完成"
    else
      tail -3 /tmp/a2w-build.log | sed 's/^/  │ /'
      warn "桥镜像构建失败，跳过桥部署；可重跑本脚本重试"
    fi
  fi

  if [ "$BRIDGE_OK" = "1" ]; then
    mkdir -p "$A2W_DATA" && chmod 700 "$A2W_DATA"

    # 扫码授权：交互终端现场完成；管道/自动化（非 TTY）自动跳过，命令见完成摘要
    if [ -t 0 ]; then
      echo ""
      echo "  ──────────────────────────────────────────────────"
      echo "  微信授权：下面会显示一条授权链接。"
      echo "  把链接发送到手机（微信文件传输助手即可），用手机微信打开并确认。"
      echo "  ──────────────────────────────────────────────────"
      if docker run --rm -it -v "$A2W_DATA:/app/data" "$A2W_IMAGE" node bin/login.mjs; then
        ok "微信授权完成（凭证已保存）"
      else
        warn "授权未完成（不影响安装，可稍后按完成摘要里的命令补做）"
      fi
    else
      warn "当前为非交互环境，跳过微信授权（补做命令见完成摘要）"
    fi
    [ -f "$A2W_DATA/credentials.json" ] && BRIDGE_AUTHED=1

    # 并入 TrendRadar compose 栈（同网络，容器名即 DNS；仅本机回环端口）
    if ! grep -q '^  any2wechat:' "$DEST/docker/docker-compose.yml"; then
      cat >> "$DEST/docker/docker-compose.yml" <<EOF

  any2wechat:
    image: ${A2W_IMAGE}
    container_name: any2wechat
    restart: unless-stopped

    ports:
      - "127.0.0.1:${A2W_PORT}:${A2W_PORT}"

    environment:
      - BRIDGE_HOST=0.0.0.0
      - BRIDGE_PORT=${A2W_PORT}

    volumes:
      - ${A2W_DATA}:/app/data
EOF
      ok "桥已并入 compose 栈（端口仅本机回环，未对外暴露）"
    fi

    docker rm -f any2wechat >/dev/null 2>&1 || true  # 清理外部遗留同名容器（凭证在数据卷，不受影响）
    if (cd "$DEST/docker" && docker compose up -d any2wechat >/dev/null 2>&1); then
      ok "桥容器已启动"
    else
      warn "桥容器启动失败；可稍后执行: cd $DEST/docker && docker compose up -d any2wechat"
    fi
    BH="fail"
    for i in $(seq 1 12); do
      bcode=$(curl -sm2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$A2W_PORT/health" 2>/dev/null) || bcode="000"
      if [ "$bcode" != "000" ]; then BH="ok"; break; fi
      sleep 5
    done
    if [ "$BH" = "ok" ]; then
      ok "桥服务就绪（127.0.0.1:$A2W_PORT）"
    else
      warn "桥服务未就绪，稍后查看: docker logs any2wechat"
    fi
  fi
fi

# ----------------------------- 防火墙 -----------------------------------------
step "检查本机防火墙"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
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
echo "    ✅ TrendRadar 部署完成"
echo "  ═══════════════════════════════════════════════════════"
if [ "$NO_WEB" = "0" ]; then
  echo "    🌐 网页报告: http://${PUB_IP:-你的服务器IP}:$PORT"
  echo "       （首次抓取约需 1-2 分钟后才有内容；浏览器提示\"不安全\"属正常现象）"
fi
if [ "$WECHAT_BRIDGE" = "1" ] && [ "$BRIDGE_OK" = "1" ]; then
  echo "    📱 微信推送: any2wechat 桥已部署（TrendRadar 通用 webhook 已指向桥）"
  if [ "$BRIDGE_AUTHED" = "1" ]; then
    echo "       ▶ 最后一步: 在微信里给 bot 发一句「绑定」"
    echo "         bot 会话可在微信通讯录里找到（授权时创建）；绑定确认后热点日报直达微信"
    echo "         想立刻收第一期: docker restart trendradar"
  else
    echo "       ▶ 微信授权尚未完成，在服务器终端补做（复制整段执行）:"
    echo "         docker run --rm -it -v $A2W_DATA:/app/data $A2W_IMAGE node bin/login.mjs"
    echo "         授权成功后，在微信里给 bot 发一句「绑定」即完成绑定"
  fi
  echo "       ▶ 桥日志: docker logs -f any2wechat"
elif [ -n "$CHANNELS" ]; then
  echo "    📱 已配置推送:$CHANNELS"
else
  echo "    📱 尚未配置手机推送。推荐微信个人号直推（最简单，零注册）:"
  echo "       bash install-trendradar.sh --wechat-bridge --no-web"
  echo "       （也支持 --wework / --feishu / --dingtalk / --telegram 'BotToken:ChatID'）"
fi
echo "    🔧 查看日志:   docker logs -f trendradar"
echo "    🔄 升级更新:   重跑本脚本即可（幂等，保留配置与数据；含 --wechat-bridge 时桥同步更新）"
echo "    🗑  停止卸载:   bash install-trendradar.sh --uninstall（彻底删除含微信凭证用 --uninstall --purge）"
if [ "$NO_WEB" = "1" ]; then
  echo "    🔒 仅本机模式: 未开放任何入站端口（网页报告已生成在 $DEST/output/index.html，仅服务器本机可见）"
else
  case "$REGION" in
    tencent) echo "    ⚠️  若网页打不开: 腾讯云控制台 → 轻量应用服务器(或云服务器) → 防火墙 → 添加规则放行 TCP $PORT" ;;
    aliyun)  echo "    ⚠️  若网页打不开: 阿里云控制台 → 实例 → 安全组 → 配置规则放行 TCP $PORT" ;;
    *)       echo "    ⚠️  若网页打不开: 请在云服务商控制台的防火墙/安全组放行 TCP $PORT" ;;
  esac
fi
echo "  ═══════════════════════════════════════════════════════"
