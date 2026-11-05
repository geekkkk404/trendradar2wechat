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
#    - 读者个性化配置（关键词/主配置）外置于 {安装目录}/user-config/，升级重跑永不覆盖
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
TR2W_PORT=8899
BRIDGE_OK=0
BRIDGE_AUTHED=0
NODE_BIN="/usr/local/bin/node"

# ----------------------------- 卸载分支 --------------------------------------
if [ "$UNINSTALL" = "1" ]; then
  step "卸载 TrendRadar（目录: $DEST）"
  systemctl disable --now trendradar-fetch.timer >/dev/null 2>&1 || true
  systemctl disable --now trendradar-web trendradar-fetch trendradar-mcp any2wechat tr2w-handler >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/trendradar-web.service /etc/systemd/system/trendradar-fetch.service \
        /etc/systemd/system/trendradar-fetch.timer /etc/systemd/system/trendradar-mcp.service \
        /etc/systemd/system/any2wechat.service /etc/systemd/system/tr2w-handler.service
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
  # 升级路径：直连 30s 不通即切代理链（与全新克隆同一纪律）；全灭则优雅降级用现有版本
  UPD_GOT=0
  if timeout 30 git -C "$DEST" fetch --depth 1 origin "$REPO_BRANCH" >/dev/null 2>&1; then
    UPD_GOT=1
  else
    for prefix in "${GH_PROXY_FALLBACKS[@]}"; do
      if timeout 45 git -C "$DEST" fetch --depth 1 "${prefix}/$REPO_URL.git" "$REPO_BRANCH" >/dev/null 2>&1; then UPD_GOT=1; break; fi
    done
  fi
  if [ "$UPD_GOT" = "1" ]; then
    git -C "$DEST" reset --hard FETCH_HEAD >/dev/null 2>&1 && ok "已更新到最新版"
  else
    warn "源码更新未成功（网络问题），继续使用现有版本（配置与数据不受影响）"
  fi
elif [ -e "$DEST" ] && [ -n "$(ls -A "$DEST" 2>/dev/null)" ]; then
  die "目录 $DEST 已存在且非本脚本安装，请更换 --dir 或先清理"
else
  GOT=0
  # 超时解耦（家宽实测：直连 15.4s / ghfast 19s 可完成 28MB，15s 一刀切会杀死正在工作的慢传输）：
  # 直连 15s 只管「连不上秒败」的连接纪律；代理源给 45s 传输预算（CDN 承载，瓶颈在吞吐）
  for prefix in "" "${GH_PROXY_FALLBACKS[@]}"; do
    url="${prefix:+$prefix/}$REPO_URL.git"
    echo "  克隆: $url"
    if [ -z "$prefix" ]; then TMO=15; else TMO=45; fi
    if timeout "$TMO" git clone --depth 1 -b "$REPO_BRANCH" "$url" "$DEST" >/dev/null 2>&1; then GOT=1; break; fi
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
step "写入配置（trendradar.env + 用户配置外置）"
ENV_FILE="$DEST/trendradar.env"
touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
# systemd EnvironmentFile 与 bash source 双消费方：值一律单引号包裹（内嵌 JSON 安全）
upsert_env() { sed -i "/^$1=/d" "$ENV_FILE"; printf "%s='%s'\n" "$1" "$(printf '%s' "$2" | sed "s/'/'\\\\''/g")" >> "$ENV_FILE"; }

# 读者个性化配置外置（P-32）：user-config 是脚本自有目录、git 不跟踪——升级时的
# git reset --hard 永远碰不到它。首次安装从上游模板播种，此后存在即不覆盖。
# 上游消费链已核实：CONFIG_PATH（core/loader.py）与 FREQUENCY_WORDS_PATH（core/frequency.py）
# 两个环境变量均为上游官方入口，指向外部目录不修改上游任何源码。
USER_CONFIG="$DEST/user-config"
mkdir -p "$USER_CONFIG"
if [ -f "$USER_CONFIG/config.yaml" ]; then
  ok "用户配置已存在，升级不覆盖（$USER_CONFIG）"
else
  [ -f "$DEST/config/config.yaml" ] || die "上游模板缺失（源码 clone 不完整），请重跑本脚本"
  # 整目录播种（保持上游 config/ 目录形制）：上游按「与 config.yaml 同目录」解析伴生文件
  # （实测 timeline.yaml 未随迁 → 空模板 + preset 报错），AI 提示词等邻座文件一并外置
  cp -r "$DEST/config/." "$USER_CONFIG/"
  cat > "$USER_CONFIG/README.txt" <<'MDEOF'
此目录存放你的个性化配置；重跑安装脚本升级时【不会被覆盖】。

  frequency_words.txt   关注关键词（追什么词、排除什么词）
  config.yaml           主配置（推送节奏/信息源/报告形态等，文件内含中文注释）

修改后在下次定时抓取（每 30 分钟）自动生效；
想立即验证请在终端执行: systemctl start trendradar-fetch
MDEOF
  ok "用户配置已初始化（$USER_CONFIG，升级不覆盖）"
fi
# AI 分析默认关闭（P-44）：上游两级开关默认全开——ai.enabled 总开关 + regions.ai_analysis
# 显示开关。无 AI Key 的读者每期推送都带「⚠️ AI 分析失败」且每轮白跑一次 AI 调用。
# 未配置 Key 时一律收敛为 false（按行内唯一中文注释精确定位，避免误伤其他 enabled）；
# 读者已配 Key 则不动其开关。
if [ -z "$AI_KEY" ] && ! grep -q '^AI_API_KEY=' "$ENV_FILE" 2>/dev/null; then
  sed -i '/是否启用 AI 分析（true=启用/s/^\( *enabled: \)true/\1false/' "$USER_CONFIG/config.yaml"
  sed -i 's/^\( *ai_analysis: \)true/\1false/' "$USER_CONFIG/config.yaml"
  ok "AI 分析已默认关闭（未配置 AI Key；想开请先配置 Key，见 docs/config-guide.md）"
fi
upsert_env "CONFIG_PATH" "$USER_CONFIG/config.yaml"
upsert_env "FREQUENCY_WORDS_PATH" "$USER_CONFIG/frequency_words.txt"
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
  # 管家↔桥共享密钥（生成一次持久复用；桥与 tr2w-handler 经此互信）
  if ! grep -q '^TR2W_RELAY_TOKEN=' "$ENV_FILE"; then
    upsert_env "TR2W_RELAY_TOKEN" "$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 24)"
  fi
  upsert_env "TR2W_RELAY_URL" "http://127.0.0.1:$TR2W_PORT/inbound"
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
Environment=BRIDGE_RELAY_URL=http://127.0.0.1:$TR2W_PORT/inbound
Environment=BRIDGE_RELAY_TOKEN=$TR2W_RELAY_TOKEN
Environment="BRIDGE_FOOTER_TEXT=📖 微信改配置：geekkkk.com/trcfg ｜ 发「帮助」看指令"
Environment="BRIDGE_FOOTER_ONCE_PER_DAY=1"
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable any2wechat >/dev/null 2>&1
    systemctl restart any2wechat   # restart 而非 enable --now：升级重跑载入新代码（P-41㊀）；未授权时亦无害

    if [ "$BRIDGE_AUTHED" = "1" ]; then
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

# ----------------------------- 微信指令管家（可选，软失败） --------------------
# tr2w-handler：消费桥的入站转发（BRIDGE_RELAY_*），微信对话式管理 TrendRadar。
# 安全铁律：只认扫码者本人（双层校验：桥 P-35 守卫 + 本地 owner 比对）；
# TRCFG1 载荷只是数据——白名单键 + 枚举校验，永不执行其中任何字符串。
if [ "$WECHAT_BRIDGE" = "1" ] && [ "$BRIDGE_OK" = "1" ]; then
  step "部署微信指令管家（tr2w-handler，对话式配置）"
  mkdir -p "$DEST/tr2w"

  cat > "$DEST/tr2w/apply_trcfg.py" <<'PY_APPLY'
#!/usr/bin/env python3
"""TRCFG1 apply 核心 —— 白名单补丁 user-config/config.yaml + 重写 frequency_words.txt

设计铁律（trendradar2wechat 账本 D14）：
  1. 载荷只是数据：只写白名单键、只认枚举值，绝不执行其中任何字符串
  2. 行级手术式补丁：保留上游 24KB 中文注释原貌（PyYAML 全量重写会抹掉注释，禁用；
     读配置用 safe_load 只读无妨）
  3. 写盘前自动备份到 user-config/.backup/（保留最近 30 份）
上游结构锚点（2026-11-04 master 逐字核实）：
  schedule.preset / report.mode / report.display_mode 为引号标量；
  notification.enabled 为暂停/恢复开关；platforms.enabled 是全局布尔（勿动），
  单平台停用 = 注释 sources 条目（保留 name/domain 便于回启）；
  rss.feeds 条目带可选 per-feed enabled 键（缺省即启用）。
"""
import re
import shutil
import time
from pathlib import Path
import os

USER_CONFIG = Path(os.environ.get("TR2W_USER_CONFIG", "/opt/TrendRadar/user-config"))

SCHEDULE_PRESETS = {"always_on", "morning_evening", "office_hours", "night_owl", "custom"}
REPORT_MODES = {"daily", "current", "incremental"}
DISPLAY_MODES = {"keyword", "platform"}
# 回执展示用中文名（推送里不出现英文裸值）
PRESET_ZH = {
    "always_on": "全天模板",
    "morning_evening": "早晚报模板（白天照常 + 晚 20-22 点当日汇总）",
    "office_hours": "办公时间模板（工作日 9-11/13-15/17-19 点，周末 8-23 点）",
    "night_owl": "夜猫模板（15-17 点、22 点-次日 1 点）",
    "custom": "自定义模板",
}
MODE_ZH = {"current": "实时热榜", "daily": "当日汇总", "incremental": "只推新上榜"}
DMODE_ZH = {"keyword": "按主题分组", "platform": "按来源分组"}
KEEP_BACKUPS = 30
_SECTION = re.compile(r"^([A-Za-z_]+):\s*(?:#.*)?$")
_ENTRY = re.compile(r"^(\s*)- id:\s*[\"']?([A-Za-z0-9_-]+)[\"']?\s*(?:#.*)?$")
_ENTRY_C = re.compile(r"^(\s*)#\s*- id:\s*[\"']?([A-Za-z0-9_-]+)[\"']?\s*(?:#.*)?$")
_WORD_BAD = re.compile(r"(^[\s#！!＋+＠@\[/]|[\r\n])")


class ApplyError(Exception):
    pass


def _backup(user_config, names):
    bdir = user_config / ".backup"
    bdir.mkdir(exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    for n in names:
        src = user_config / n
        if src.exists():
            shutil.copy2(src, bdir / f"{stamp}-{n}")
    olds = sorted(bdir.iterdir())
    for f in olds[:-KEEP_BACKUPS] if len(olds) > KEEP_BACKUPS else []:
        f.unlink()


def _lead(ln):
    return len(ln) - len(ln.lstrip())


def _patch_scalar(lines, section, key, value_repr, changes, label):
    """顶层 section（两格缩进）内替换 `key:` 的值，保留行尾注释；值未变则不动（不产生变化项）。"""
    cur = None
    pat = re.compile(r"^(\s+)" + re.escape(key) + r"(\s*:\s*)(.*)$")
    for i, ln in enumerate(lines):
        m = _SECTION.match(ln)
        if m:
            cur = m.group(1)
            continue
        if cur == section:
            m = pat.match(ln)
            if m and len(m.group(1)) == 2:
                comment_m = re.match(r"^(.*?)(\s+#.*)?$", m.group(3))
                comment = comment_m.group(2) or ""
                new_line = f"{m.group(1)}{key}{m.group(2)}{value_repr}{comment}"
                if new_line == ln:
                    return
                lines[i] = new_line
                changes.append(label)
                return
    raise ApplyError(f"config.yaml 缺少 {section}.{key}（模板异常），请重跑安装脚本更新模板")


def _find_block(lines, pid, commented):
    """找 - id: "pid" 条目块（活动或注释态），返回 (start, end, indent)；无则 None。
    end 为块后第一行下标；块 = 起始行 + 缩进更深的续行（含注释态续行）。"""
    pat = _ENTRY_C if commented else _ENTRY
    start = None
    indent = ""
    for i, ln in enumerate(lines):
        m = pat.match(ln)
        if m and m.group(2) == pid:
            start = i
            indent = m.group(1)
            break
    if start is None:
        return None
    base = len(indent)
    end = len(lines)
    for j in range(start + 1, len(lines)):
        ln = lines[j]
        if not ln.strip():
            continue
        if _SECTION.match(ln):
            end = j
            break
        m2 = _ENTRY.match(ln) or _ENTRY_C.match(ln)
        if m2 and len(m2.group(1)) <= base:
            end = j
            break
        if _lead(ln) <= base and not ln.lstrip().startswith("#"):
            end = j
            break
        end = j + 1
    return (start, end, indent)


def _toggle_platform(lines, pid, on, changes):
    cur = _find_block(lines, pid, commented=not on)
    if cur is None:
        if _find_block(lines, pid, commented=on) is not None:
            changes.append(f"平台 {pid} 已是{'启用' if on else '停用'}状态（无变化）")
            return
        raise ApplyError(f"未知平台 id: {pid!r}（以 config.yaml 的 sources 为准）")
    start, end, _indent = cur
    if on:
        for i in range(start, end):
            lines[i] = re.sub(r"^(\s*)#(\s)?", r"\1", lines[i], count=1)
        changes.append(f"启用平台 {pid}")
    else:
        for i in range(start, end):
            if lines[i].strip():
                lines[i] = re.sub(r"^(\s*)", r"\1# ", lines[i], count=1)
        changes.append(f"停用平台 {pid}")


def _toggle_feed(lines, fid, on, changes):
    cur = _find_block(lines, fid, commented=False)
    if cur is None:
        raise ApplyError(f"未知 RSS 源 id: {fid!r}")
    start, end, indent = cur
    pat = re.compile(r"^(\s+enabled\s*:\s*).*$")
    want = "true" if on else "false"
    for i in range(start, end):
        m = pat.match(lines[i])
        if m:
            if lines[i].rstrip().endswith(want):
                changes.append(f"RSS {fid} 已是{'启用' if on else '停用'}（无变化）")
            else:
                lines[i] = f"{m.group(1)}{want}"
                changes.append(f"{'启用' if on else '停用'} RSS {fid}")
            return
    if on:
        changes.append(f"RSS {fid} 已是启用（无变化）")
        return
    lines.insert(end, f"{indent}  enabled: false")
    changes.append(f"停用 RSS {fid}")


def _word(w, what):
    w = str(w).strip()
    if not w:
        raise ApplyError(f"{what}存在空词条")
    if _WORD_BAD.search(w):
        raise ApplyError(f"{what}词条含非法字符/语法前缀: {w[:30]!r}")
    if len(w) > 60:
        raise ApplyError(f"{what}词条过长: {w[:30]!r}…")
    return w


def gen_frequency(freq):
    if not isinstance(freq, dict):
        raise ApplyError("freq 必须是对象")
    out = ["# 本文件由 TRCFG1 生成（微信/网页配置端）。手工微调会在下次 TRCFG1 应用时被覆盖。", ""]
    gf = freq.get("global_filter") or []
    out.append("[GLOBAL_FILTER]")
    for w in gf:
        out.append(_word(w, "全局过滤"))
    out.append("")
    groups = freq.get("groups") or []
    if groups:
        out.append("[WORD_GROUPS]")
        for g in groups:
            if not isinstance(g, dict):
                raise ApplyError("词组必须是对象")
            out.append("")
            name = str(g.get("name") or "").strip()
            if name:
                name = _word(name, "词组名")
                if re.search(r"[\[\]]", name):
                    raise ApplyError(f"词组名含括号: {name!r}")
                out.append(f"[{name}]")
            for w in g.get("words") or []:
                out.append(_word(w, "关键词"))
            for w in g.get("must") or []:
                out.append("+" + _word(w, "必须词"))
            for w in g.get("exclude") or []:
                out.append("!" + _word(w, "排除词"))
            mx = g.get("max")
            if mx is not None:
                if not isinstance(mx, int) or not 0 < mx <= 50:
                    raise ApplyError(f"词组 {name!r} 的 max 需为 1-50 整数")
                out.append(f"@{mx}")
    return "\n".join(out).rstrip() + "\n"


def apply_payload(payload, user_config):
    """应用 TRCFG1 载荷 → 返回 changes 列表；任何错误抛 ApplyError（文件不动，天然全有或全无）。"""
    if not isinstance(payload, dict):
        raise ApplyError("载荷必须是 JSON 对象")
    if payload.get("v") != 1:
        raise ApplyError(f"不支持的载荷版本: {payload.get('v')!r}（本管家支持 v1）")
    cfg = payload.get("cfg") or {}
    freq = payload.get("freq")
    if not cfg and freq is None:
        raise ApplyError("载荷为空（cfg 与 freq 均缺省）")
    if not isinstance(cfg, dict):
        raise ApplyError("cfg 必须是对象")

    config_path = user_config / "config.yaml"
    original = config_path.read_text(encoding="utf-8")
    lines = original.splitlines()
    changes = []
    staged = []

    sched = cfg.get("schedule") or {}
    if "enabled" in sched:
        b = sched["enabled"]
        if not isinstance(b, bool):
            raise ApplyError("schedule.enabled 需为 true/false")
        staged.append(lambda b=b: _patch_scalar(
            lines, "schedule", "enabled", "true" if b else "false", changes,
            "推送节奏 → 按模板时段推送" if b else "推送节奏 → 全天（每 30 分钟一期）"))
    if "preset" in sched:
        v = sched["preset"]
        if v not in SCHEDULE_PRESETS:
            raise ApplyError(f"schedule.preset 非法: {v!r}（可选: {sorted(SCHEDULE_PRESETS)}）")
        staged.append(lambda v=v: _patch_scalar(lines, "schedule", "preset", f'"{v}"', changes, f"推送节奏 → {PRESET_ZH[v]}"))
    notif = cfg.get("notification") or {}
    if "enabled" in notif:
        b = notif["enabled"]
        if not isinstance(b, bool):
            raise ApplyError("notification.enabled 需为 true/false")
        staged.append(lambda b=b: _patch_scalar(lines, "notification", "enabled", "true" if b else "false", changes, "恢复推送" if b else "暂停推送"))
    rep = cfg.get("report") or {}
    if "mode" in rep:
        v = rep["mode"]
        if v not in REPORT_MODES:
            raise ApplyError(f"report.mode 非法: {v!r}（可选: {sorted(REPORT_MODES)}）")
        staged.append(lambda v=v: _patch_scalar(lines, "report", "mode", f'"{v}"', changes, f"每期内容 → {MODE_ZH[v]}"))
    if "display_mode" in rep:
        v = rep["display_mode"]
        if v not in DISPLAY_MODES:
            raise ApplyError(f"report.display_mode 非法: {v!r}（可选: {sorted(DISPLAY_MODES)}）")
        staged.append(lambda v=v: _patch_scalar(lines, "report", "display_mode", f'"{v}"', changes, f"分组方式 → {DMODE_ZH[v]}"))
    plat = cfg.get("platforms") or {}
    for pid, on in (plat.get("sources") or {}).items():
        if not isinstance(on, bool):
            raise ApplyError(f"platforms.sources.{pid} 需为 true/false")
        staged.append(lambda pid=pid, on=on: _toggle_platform(lines, str(pid), on, changes))
    rss = cfg.get("rss") or {}
    for fid, on in (rss.get("feeds") or {}).items():
        if not isinstance(on, bool):
            raise ApplyError(f"rss.feeds.{fid} 需为 true/false")
        staged.append(lambda fid=fid, on=on: _toggle_feed(lines, str(fid), on, changes))

    for fn in staged:
        fn()

    new_yaml = "\n".join(lines) + "\n"
    yaml_changed = bool(staged) and new_yaml != original
    freq_path = user_config / "frequency_words.txt"
    orig_freq = freq_path.read_text(encoding="utf-8") if freq_path.exists() else ""
    freq_text = gen_frequency(freq) if freq is not None else None
    freq_changed = freq_text is not None and freq_text != orig_freq
    if not yaml_changed and not freq_changed:
        return changes or ["载荷与当前配置一致，无变化"]
    if freq_changed:
        gf_n = len(freq.get("global_filter") or [])
        gs = freq.get("groups") or []
        w_n = sum(len(g.get("words") or []) for g in gs)
        head = (
            f"关注词 → 已更新（{len(gs)} 个主题 {w_n} 个词 · 屏蔽 {gf_n} 词）"
            if (gf_n or gs) else "关注词 → 已清空（恢复推送全部热榜）"
        )
        # 实名小票（P-45）：像点餐小票列出「你设置了什么」，而非只报计数；
        # 组数/词数超阈值折叠回计数（控微信阅读性）
        rows = []
        if gs and len(gs) <= 8 and w_n <= 30:
            for g in gs:
                nm = str(g.get("name") or "").strip() or "未命名主题"
                ws = [str(w) for w in (g.get("words") or [])]
                extra = []
                if g.get("must"):
                    extra.append("必须:" + "、".join(map(str, g["must"])))
                if g.get("exclude"):
                    extra.append("排除:" + "、".join(map(str, g["exclude"])))
                if g.get("max"):
                    extra.append(f"每轮≤{g['max']}条")
                tail = f"（{'；'.join(extra)}）" if extra else ""
                rows.append(f"　· {nm}：{'、'.join(ws)}{tail}" if ws else f"　· {nm}{tail}")
        if gf_n and gf_n <= 10:
            rows.append("　· 屏蔽：" + "、".join(str(w) for w in freq["global_filter"]))
        changes.append(head + (("\n" + "\n".join(rows)) if rows else ""))
    elif freq is not None and yaml_changed:
        changes.append("关注词 → 与当前一致")

    _backup(user_config, ["config.yaml", "frequency_words.txt"])
    if yaml_changed:
        config_path.write_text(new_yaml, encoding="utf-8")
    if freq_changed:
        freq_path.write_text(freq_text, encoding="utf-8")
    return changes or ["已写入"]


def toggle_push(enabled, user_config):
    return apply_payload({"v": 1, "cfg": {"notification": {"enabled": bool(enabled)}}}, user_config)


if __name__ == "__main__":
    # 急救通道：微信通道失灵时的终端入口（与微信指令同一 apply 核心、同一白名单）
    # 用法: python tr2w/apply_trcfg.py 载荷.json   （JSON 内容 = TRCFG1 冒号后的 base64url 串或原始 JSON）
    import base64 as _b64
    import json as _json
    import sys as _sys

    if len(_sys.argv) != 2:
        print("用法: python apply_trcfg.py 载荷文件.json（或 TRCFG1 码文件，内容一行）")
        raise SystemExit(2)
    raw = Path(_sys.argv[1]).read_text(encoding="utf-8").strip()
    if raw.startswith("TRCFG1:"):
        raw = raw[len("TRCFG1:"):].strip()
        raw = _b64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)).decode("utf-8")
    try:
        for c in apply_payload(_json.loads(raw), USER_CONFIG):
            print("·", c)
        print("已应用。立即验证: systemctl start trendradar-fetch")
    except ApplyError as e:
        print(f"❌ 配置未应用（文件未动）: {e}")
        raise SystemExit(1)


def _parse_words(fp):
    """解析 frequency_words.txt → (总词数, 组数, 展示用概览文本)。只读。"""
    try:
        lines = fp.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return 0, 0, "未配置关键词（推送全部热榜）"
    in_groups = False
    n = 0
    groups = 0
    preview = []
    cur_group = None
    for ln in lines:
        s = ln.strip()
        if s == "[WORD_GROUPS]":
            in_groups = True
            continue
        if s == "[GLOBAL_FILTER]":
            in_groups = False
            continue
        if not in_groups or not s or s.startswith("#"):
            continue
        if s.startswith("[") and s.endswith("]"):
            groups += 1
            cur_group = s[1:-1]
            continue
        if s.startswith(("!", "+", "@")):
            continue
        n += 1
        if len(preview) < 40:
            preview.append(f"· {s}" + (f"（{cur_group}）" if cur_group else ""))
    return n, groups, "\n".join(preview)


def has_keywords(user_config):
    """词表是否配置了至少一个关键词。空词表 = 命中全部热榜，current 预览会整版刷屏（守卫用）。"""
    n, _g, _preview = _parse_words(user_config / "frequency_words.txt")
    return n > 0


def config_summary(user_config):
    import yaml

    cfg = yaml.safe_load((user_config / "config.yaml").read_text(encoding="utf-8")) or {}
    plat = cfg.get("platforms") or {}
    srcs = plat.get("sources") or []
    feeds = (cfg.get("rss") or {}).get("feeds") or []
    n_feed_on = sum(1 for f in feeds if f.get("enabled", True))
    rep = cfg.get("report") or {}
    sched = cfg.get("schedule") or {}
    notif = cfg.get("notification") or {}
    n, g, _ = _parse_words(user_config / "frequency_words.txt")
    push_state = "推送中 ✅" if notif.get("enabled", True) else "已暂停 ⏸"
    pace = ("全天（每 30 分钟一期）" if not sched.get("enabled", False)
            else PRESET_ZH.get(sched.get("preset"), sched.get("preset", "-")))
    return (
        f"📊 当前状态\n· 推送: {push_state}\n· 节奏: {pace}\n"
        f"· 形态: {MODE_ZH.get(rep.get('mode'), rep.get('mode', '-'))} · "
        f"{DMODE_ZH.get(rep.get('display_mode'), rep.get('display_mode', '-'))}\n"
        f"· 平台: {len(srcs)} 个｜RSS: {n_feed_on}/{len(feeds)} 个\n· 关键词: {n} 词 / {g} 组"
    )


def words_overview(user_config):
    n, g, preview = _parse_words(user_config / "frequency_words.txt")
    if n == 0:
        return "🔖 词表: 未配置关键词（推送全部热榜）"
    return f"🔖 词表: {n} 词 / {g} 组\n{preview}"


def parse_words_structured(fp):
    """frequency_words.txt → {"global_filter": [...], "groups": [...]}（gen_frequency 的反向，
    round-trip 恒等）。只读；分区外的裸词条上游本就不解析（惰性内容），此处同样忽略。"""
    out = {"global_filter": [], "groups": []}
    cur = None
    zone = None
    try:
        lines = fp.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return out
    for ln in lines:
        s = ln.strip()
        if not s or s.startswith("#"):
            continue
        if s == "[GLOBAL_FILTER]":
            zone, cur = "gf", None
            continue
        if s == "[WORD_GROUPS]":
            zone = "groups"
            continue
        if s.startswith("[") and s.endswith("]"):
            cur = {"name": s[1:-1], "words": []}
            out["groups"].append(cur)
            zone = "groups"
            continue
        if zone == "gf":
            out["global_filter"].append(s)
        elif zone == "groups":
            if cur is None:
                cur = {"words": []}
                out["groups"].append(cur)
            if s.startswith("+"):
                cur.setdefault("must", []).append(s[1:])
            elif s.startswith("!"):
                cur.setdefault("exclude", []).append(s[1:])
            elif s.startswith("@"):
                try:
                    cur["max"] = int(s[1:])
                except ValueError:
                    pass
            else:
                cur["words"].append(s)
    return out


def export_payload(user_config):
    """读服务端当前配置 → 反向生成 TRCFG1 v1 载荷（P-47「导出配置」）。
    与博客页 diff 约定对齐：freq 词表全量（空词表省略=页面留空=不动词表）；
    schedule 恒含（页面是单选态，无 diff 语义）；report 仅非页面默认值（current/keyword 不发）；
    platforms 仅停用项（注释态条目 yaml.safe_load 看不到，扫原文）；rss 全部显式布尔
    （页面默认可能与上游种子不一致，显式即保真）。只读，不写盘。"""
    import yaml
    p = {"v": 1}
    freq = parse_words_structured(user_config / "frequency_words.txt")
    if freq.get("global_filter") or freq.get("groups"):
        p["freq"] = freq
    cfg = yaml.safe_load((user_config / "config.yaml").read_text(encoding="utf-8")) or {}
    out = {}
    sched = cfg.get("schedule") or {}
    if sched.get("enabled", False):
        out["schedule"] = {"enabled": True, "preset": sched.get("preset", "always_on")}
    else:
        out["schedule"] = {"enabled": False}
    rep = cfg.get("report") or {}
    rep_out = {}
    if rep.get("mode") and rep["mode"] != "current":
        rep_out["mode"] = rep["mode"]
    if rep.get("display_mode") and rep["display_mode"] != "keyword":
        rep_out["display_mode"] = rep["display_mode"]
    if rep_out:
        out["report"] = rep_out
    plat_out = {}
    top = None
    in_sources = False
    for ln in (user_config / "config.yaml").read_text(encoding="utf-8").splitlines():
        m = _SECTION.match(ln)
        if m:
            top = m.group(1)
            in_sources = False
            continue
        if top == "platforms" and re.match(r"^  [A-Za-z_]+:", ln):
            in_sources = ln.lstrip().startswith("sources")
            continue
        if top == "platforms" and in_sources:
            m2 = _ENTRY_C.match(ln)
            if m2:
                plat_out[m2.group(2)] = False
    if plat_out:
        out["platforms"] = {"sources": plat_out}
    rss_out = {}
    for f in (cfg.get("rss") or {}).get("feeds") or []:
        fid = str(f.get("id", "")).strip()
        if fid:
            rss_out[fid] = bool(f.get("enabled", True))
    if rss_out:
        out["rss"] = {"feeds": rss_out}
    if out:
        p["cfg"] = out
    return p
PY_APPLY

  cat > "$DEST/tr2w/tr2w_handler.py" <<'PY_HANDLER'
#!/usr/bin/env python3
"""tr2w 管家 —— 消费 any2wechat 入站转发，微信对话式管理 TrendRadar。

安全铁律（D14）：只认扫码者本人（双层校验：桥 P-35 守卫 + 本地 owner 比对）；
只做白名单动作；TRCFG1 载荷只是数据，永不执行其中任何字符串。
回复走既有桥 /webhook（同机回环），桥零额外接口。
"""
import base64
import binascii
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import apply_trcfg  # noqa: E402

DEST = Path(os.environ.get("TR2W_DEST", "/opt/TrendRadar"))
USER_CONFIG = DEST / "user-config"
CREDS_FILE = Path(os.environ.get("TR2W_CREDS", str(DEST / "any2wechat-data" / "credentials.json")))
RELAY_TOKEN = os.environ.get("TR2W_RELAY_TOKEN", "")
BRIDGE_URL = os.environ.get("TR2W_BRIDGE_URL", "http://127.0.0.1:8788/webhook")
FETCH_UNIT = "trendradar-fetch"

MENU_BODY = (
    "📖 指令菜单（tr2w 管家）\n"
    "· 帮助 —— 本菜单\n"
    "· 状态 —— 当前配置速览\n"
    "· 词表 —— 查看关注关键词\n"
    "· 暂停 / 恢复 —— 停止/恢复推送\n"
    "· 立即推送 —— 马上抓取并推一期\n"
    "· 导出配置 —— 重新生成配置链接\n"
    "· TRCFG1:… —— 粘贴配置码（博客可视化页生成），立即生效\n"
    "· 设置AI密钥 sk-xxx —— 开启 AI 热点分析（腾讯 TokenHub 免费额度；结尾加「官方」二字 = DeepSeek 官方）\n"
    "· 测试AI / 删除AI配置 —— 验证 AI 连通 / 关闭并删除 Key\n"
)


def menu_text():
    """帮助菜单：尾部入口动态带当前配置（站主复测反馈 2026-11-05）——打开即改，
    无需先发「导出配置」，同时消除「空表单误覆盖」陷阱；默认配置时回落静态入口。"""
    tail = "🌐 配置页: geekkkk.com/trcfg"
    try:
        p = apply_trcfg.export_payload(USER_CONFIG)
        if p.get("freq") or p.get("cfg"):
            code = base64.urlsafe_b64encode(
                json.dumps(p, ensure_ascii=False).encode("utf-8")).decode().rstrip("=")
            tail = f"🌐 配置页（已含你的当前配置，打开即改）: https://geekkkk.com/trcfg#c={code}"
    except Exception as err:
        log(f"[menu] 动态入口生成失败，回落静态: {err}")
    return MENU_BODY + tail


def log(*a):
    print(*a, flush=True)


def owner_id():
    try:
        return json.loads(CREDS_FILE.read_text(encoding="utf-8")).get("user_id", "")
    except Exception as err:
        log(f"[handler] 读取凭证失败: {err}")
        return ""


def reply(text):
    req = urllib.request.Request(
        BRIDGE_URL,
        data=json.dumps({"content": text}).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=15) as r:
        body = r.read().decode("utf-8", "replace")
    if r.status != 202:
        raise RuntimeError(f"bridge HTTP {r.status}: {body[:120]}")


def report_mode():
    """当前 report.mode（只读）。解析失败回退 incremental——按最保守口径措辞。"""
    try:
        import yaml
        cfg = yaml.safe_load((USER_CONFIG / "config.yaml").read_text(encoding="utf-8")) or {}
        return (cfg.get("report") or {}).get("mode") or "incremental"
    except Exception:
        return "incremental"


def _env_pairs(path):
    """读 systemd EnvironmentFile → [(k, v)]，保序。值一律单引号包裹（安装器 upsert_env 约定，
    即 P-43 记录的引号设计），此处按同约定剥引号还原。"""
    out = []
    try:
        for ln in path.read_text(encoding="utf-8").splitlines():
            ln = ln.strip()
            if not ln or ln.startswith("#") or "=" not in ln:
                continue
            k, _, v = ln.partition("=")
            k = k.strip()
            if not k:
                continue
            v = v.strip()
            if len(v) >= 2 and v.startswith("'") and v.endswith("'"):
                v = v[1:-1].replace("'\\''", "'")
            out.append((k, v))
    except Exception as err:
        log(f"[preview] 读取 {path} 失败: {err}")
    return out


def trigger_fetch(preview=False):
    """触发一次抓取并返回如实的预期文案（P-41②/④）。

    preview=True（方案 B，2026-11-05 站主拍板）：临时配置目录整目录复制 user-config 后
    手术式翻 report.mode=current，起一次性运行——读者配完或按「立即推送」立刻看到当前
    榜单命中内容；稳态配置与 incremental 防扰完全不动。上游零改动：
    CONFIG_PATH/FREQUENCY_WORDS_PATH 为上游官方 env 入口（P-32 外置即建于其上）；
    伴生文件随整目录复制满足上游「与 config.yaml 同目录」解析（P-37 教训）。
    守卫：仅在词表非空时 preview——空词表 = 命中全部热榜，current 预览会整版刷屏。
    preview 任何环节失败都退回普通触发（软失败，不影响推送本体）。
    """
    if preview:
        tmp = None
        try:
            import shutil
            import tempfile
            import time
            tmp = Path(tempfile.mkdtemp(prefix="trcfg-once-"))
            shutil.copytree(USER_CONFIG, tmp, dirs_exist_ok=True,
                            ignore=shutil.ignore_patterns(".backup"))
            apply_trcfg.apply_payload({"v": 1, "cfg": {"report": {"mode": "current"}}}, tmp)
            unit = f"trcfg-once-{time.time_ns() // 1000}"
            script = f'"{DEST / ".venv/bin/python"}" -m trendradar; rc=$?; rm -rf "{tmp}"; exit $rc'
            # 不用 -p EnvironmentFile：实测它会压过 --setenv（CONFIG_PATH 指回真配置=预览失效），
            # 改为显式逐项注入；CONFIG_PATH/FREQUENCY_WORDS_PATH 指临时目录（P-41④）
            run_args = ["systemd-run", "--unit", unit, "--collect",
                        # 不能用 Type=oneshot：其 start job 要等 ExecStart 跑完才返回，
                        # systemd-run 会陪跑整个抓取（~40s）→ 触发超时降级（实测踩中）。
                        # 默认 Type=simple 即发即返；RuntimeMaxSec 只作失控保险。
                        "-p", "RuntimeMaxSec=1800",
                        "-p", f"WorkingDirectory={DEST}"]
            for k, v in _env_pairs(DEST / "trendradar.env"):
                if k in ("CONFIG_PATH", "FREQUENCY_WORDS_PATH"):
                    continue
                run_args.append(f"--setenv={k}={v}")
            run_args += ["--setenv=CONFIG_PATH=" + str(tmp / "config.yaml"),
                         "--setenv=FREQUENCY_WORDS_PATH=" + str(tmp / "frequency_words.txt"),
                         "/bin/bash", "-c", script]
            subprocess.run(run_args, capture_output=True, text=True, timeout=5, check=True)
            log("[preview] 一次性 current 预览已排程（unit=%s）" % unit)
            return "⏳ 已触发立即抓取：当前榜单命中内容约 1 分钟送达（若暂无命中，之后命中即推）"
        except Exception as err:
            log(f"[preview] 一次性预览失败，退回普通触发: {err}")
            if tmp is not None:
                import shutil
                shutil.rmtree(tmp, ignore_errors=True)
            preview = False
    subprocess.Popen(["systemctl", "start", FETCH_UNIT])
    m = report_mode()
    if m == "incremental":
        return "⏳ 已触发立即抓取（增量模式：只有新上榜且命中关注词的内容会推送，命中即推）"
    if m == "current":
        return "⏳ 已触发立即抓取，当前榜单命中内容约 1 分钟送达"
    return "⏳ 已触发立即抓取（按当前推送形态排程推送）"


def export_link():
    """「导出配置」→ 带配置态的 trcfg 链接（P-47）：打开页面即载入当前全部配置，
    改完生成新配置码发回即生效。链接只经微信消息传递，不经任何第三方存储。"""
    try:
        p = apply_trcfg.export_payload(USER_CONFIG)
    except Exception as err:
        return f"❌ 导出失败: {err.__class__.__name__}: {err}"
    if not (p.get("freq") or p.get("cfg")):
        return "📭 当前是默认配置，无需导出（打开 geekkkk.com/trcfg 从头勾选即可）"
    code = base64.urlsafe_b64encode(
            json.dumps(p, ensure_ascii=False).encode("utf-8")).decode().rstrip("=")
    return ("📋 打开链接即载入你的当前配置（改完点生成 → 微信发回即可）：\n"
            f"https://geekkkk.com/trcfg#c={code}")


# ============================== AI 通道（P-48，2026-11-05 定型） ==============================
# 机制（POC 实证）：全部走 trendradar.env 的上游官方 AI_* 覆盖链（loader.py env 优先于
# config.yaml）+ regions.ai_analysis 显示开关手术一行；fetch 瞬态服务每次启动重读
# EnvironmentFile → 零重启、下一期生效。Key 结构性不进 TRCFG1/导出/#c= 链接（export
# 读不到 env）。TokenHub OpenAI 兼容端点实测三模型对比后默认 deepseek-flash（原厂直供，
# 17.9s 全绿；hy4/GLM 思维链会吃光上游 max_tokens=5000 致空响应，勿设为默认）。
ENV_FILE = DEST / "trendradar.env"
AI_ENV_KEYS = ("AI_API_KEY", "AI_MODEL", "AI_API_BASE", "AI_TIMEOUT", "AI_ANALYSIS_ENABLED")
TOKENHUB_BASE = "https://tokenhub.tencentmaas.com/v1"
TOKENHUB_MODEL = "openai/deepseek/deepseek-flash"
_KEY_RE = re.compile(r"^[A-Za-z0-9._-]{20,200}$")
_REGIONS_AI = re.compile(r"^(\s+)ai_analysis:(\s+)(true|false)(\s*(?:#.*)?)$")


def _mask_key(key):
    """Key 打码：首 5 字符 + ******（上游 analyzer.py 同款惯例）。永不回显完整 Key。"""
    return (key[:5] + "******") if len(key) >= 5 else "******"


def _write_env(set_pairs, remove_keys=()):
    """upsert trendradar.env：先删待写键与 remove_keys 的旧行，再按 P-43 单引号约定追加。
    值均来自白名单校验（KEY_RE）或本文件常量，无引号注入面；写后 chmod 600。
    直接改文件而非进程 env：handler 常驻而 env 常变，逐请求读文件才见新值。"""
    rm = set(remove_keys) | {k for k, _v in set_pairs}
    try:
        kept = []
        for ln in ENV_FILE.read_text(encoding="utf-8").splitlines():
            k = ln.split("=", 1)[0].strip() if "=" in ln else None
            if k not in rm:
                kept.append(ln)
    except FileNotFoundError:
        kept = []
    for k, v in set_pairs:
        if "'" in v or "\n" in v:
            raise ValueError(f"env 值含非法字符: {k}")
        kept.append(f"{k}='{v}'")
    ENV_FILE.write_text("\n".join(kept) + ("\n" if kept else ""), encoding="utf-8")
    os.chmod(ENV_FILE, 0o600)


def _regions_ai_flip(on):
    """手术翻 regions.ai_analysis 显示开关（唯一锚点：缩进 ai_analysis:+bool 值；
    顶层 ai_analysis: 节头无值不会命中）。保留行尾注释；改动前按 .backup/ 约定备份。"""
    want = "true" if on else "false"
    path = USER_CONFIG / "config.yaml"
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return False
    for i, ln in enumerate(lines):
        m = _REGIONS_AI.match(ln)
        if m:
            if m.group(3) == want:
                return False
            apply_trcfg._backup(USER_CONFIG, ["config.yaml"])
            lines[i] = f"{m.group(1)}ai_analysis:{m.group(2)}{want}{m.group(4)}"
            path.write_text("\n".join(lines) + "\n", encoding="utf-8")
            return True
    log("[ai] regions.ai_analysis 锚点未找到（种子异常？），显示开关未动")
    return False


def _ai_channel(env):
    """→ (渠道名, 模型展示名)。与 cmd_set_ai_key 的三种写入口径一致。"""
    base = env.get("AI_API_BASE", "")
    model = env.get("AI_MODEL", "")
    if base == TOKENHUB_BASE:
        return "腾讯 TokenHub", "deepseek-flash（原厂直供）"
    if base:
        return "自定义接口", model or "-"
    if model:
        return "自定义模型", model
    return "DeepSeek 官方", "上游默认模型"


def ai_status_line():
    """「状态」指令的 AI 行（只读）。Key 只打码。"""
    env = dict(_env_pairs(ENV_FILE))
    key = env.get("AI_API_KEY", "")
    if not key:
        return "· AI 分析: 未开启（发「设置AI密钥 sk-你的密钥」开启，微信零终端）"
    prov, model = _ai_channel(env)
    if env.get("AI_ANALYSIS_ENABLED", "") != "true":
        return f"· AI 分析: Key 已存（{_mask_key(key)}）但总开关未开（重发设置指令即可修复）"
    return f"· AI 分析: 已启用（{prov} · {model} · Key {_mask_key(key)}）"


def cmd_set_ai_key(rest):
    """「设置AI密钥 <key> [官方]」：默认 TokenHub 预置（模型/接口/超时全自动），
    结尾「官方」= DeepSeek 官方（清掉 TokenHub 预置键，走上游默认模型）。
    小票回执（P-42 风格）：逐项回显 + 免费额度/泄露面如实提示。"""
    official = False
    rest = rest.strip()
    if rest.endswith("官方"):
        official = True
        rest = rest[:-2].strip()
    key = rest
    if not _KEY_RE.match(key):
        return ("❌ Key 格式不合法（sk- 开头的字母/数字/点/连字符，20-200 字符；已忽略，未写入）\n"
                "· 腾讯 TokenHub 开通+建 Key: console.cloud.tencent.com/tokenhub\n"
                "· 正确用法: 设置AI密钥 sk-xxxxxxxx")
    if official:
        _write_env([("AI_API_KEY", key), ("AI_ANALYSIS_ENABLED", "true")],
                   remove_keys=("AI_MODEL", "AI_API_BASE", "AI_TIMEOUT"))
        ch = "· 渠道: DeepSeek 官方（上游默认模型）\n· 计费: 按 DeepSeek 官方价目（便宜档，需账户有余额）"
    else:
        _write_env([
            ("AI_API_KEY", key),
            ("AI_MODEL", TOKENHUB_MODEL),
            ("AI_API_BASE", TOKENHUB_BASE),
            ("AI_TIMEOUT", "300"),
            ("AI_ANALYSIS_ENABLED", "true"),
        ])
        ch = ("· 渠道: 腾讯 TokenHub · 模型 deepseek-flash（原厂直供）\n"
              "· 计费: 新用户免费额度（约每期消耗几千 tokens）；额度用尽后需开通后付费继续，或发「删除AI配置」关闭")
    _regions_ai_flip(True)
    return (f"✅ AI 分析 → 已启用\n{ch}\n"
            f"· Key: {_mask_key(key)}（已存服务器 env 文件，权限 600）\n"
            "· 下一期推送起生效；当期无命中内容则该期无 AI 段\n"
            "· 发「测试AI」可立即验证连通\n"
            "· 如怀疑泄露: 去控制台重置 Key 后重发本指令即可")


def cmd_test_ai():
    """「测试AI」：用服务器上已配置的 Key 发一次最小调用（max_tokens=300 封顶），
    把「贴错 Key 干等下期」变成当场知道（P-41 承诺如实化的 AI 版）。失败信息短截，
    不回显完整诊断（防诊断文本携带 Key 片段）。"""
    env = dict(_env_pairs(ENV_FILE))
    key = env.get("AI_API_KEY", "")
    if not key:
        return "❌ 尚未配置 AI Key（发「设置AI密钥 sk-你的密钥」先配置）"
    cfg = {
        "MODEL": env.get("AI_MODEL") or "deepseek/deepseek-v4-flash",
        "API_KEY": key,
        "API_BASE": env.get("AI_API_BASE", ""),
        "TIMEOUT": 90, "TEMPERATURE": 1.0, "MAX_TOKENS": 300,
        "NUM_RETRIES": 0, "FALLBACK_MODELS": [], "EXTRA_PARAMS": {},
    }
    code = (
        "import sys, json\n"
        f"sys.path.insert(0, {str(DEST)!r})\n"
        "from trendradar.ai.client import AIClient\n"
        "cfg = json.loads(sys.stdin.read())\n"
        "c = AIClient(cfg)\n"
        "out = c.chat([{\'role\': \'user\', \'content\': \'回复两个字: 成功\'}])\n"
        "print(out[:60])\n"
    )
    prov, model = _ai_channel(env)
    t0 = time.time()
    try:
        p = subprocess.run([str(DEST / ".venv/bin/python"), "-c", code],
                           input=json.dumps(cfg), capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        return f"❌ AI 测试超时（120s 无响应）· {prov}\n稍后重试；若持续超时发「删除AI配置」关闭"
    dt = time.time() - t0
    if p.returncode != 0:
        tail = [l for l in (p.stderr or "").strip().splitlines() if l.strip()]
        brief = (tail[-1][:80] + "…") if tail else "未知错误"
        return (f"❌ AI 测试失败 · {prov}\n· {brief}\n"
                "常见原因: Key 无效/额度用尽/账户未开通；确认后重发「设置AI密钥」")
    out = (p.stdout or "").strip()
    if not out:
        return (f"⚠️ AI 接口连通但模型回复为空 · {prov}\n"
                "该模型可能是思考型（思维链耗尽输出预算）；建议重发「设置AI密钥」用默认 TokenHub 模型")
    return f"✅ AI 连通 · {prov} · {model}\n· 耗时 {dt:.0f}s，模型回复: {out[:40]}"


def cmd_del_ai():
    """「删除AI配置」：清全部 AI_* env 键 + 显示开关翻回 false（对称撤销，回 P-44 默认态）。"""
    _write_env([], remove_keys=AI_ENV_KEYS)
    _regions_ai_flip(False)
    return ("🗑 AI 配置已删除\n"
            "· AI 分析 → 已关闭（回到默认省流模式，推送不再有 AI 段）\n"
            "· Key 已从服务器移除；想再开启随时发「设置AI密钥」")


def handle_payload(rest):
    rest = rest.strip()
    try:
        raw = base64.urlsafe_b64decode(rest + "=" * (-len(rest) % 4))
        payload = json.loads(raw.decode("utf-8"))
    except (binascii.Error, UnicodeDecodeError, json.JSONDecodeError) as err:
        return f"❌ 配置码解码失败: {err}"
    try:
        changes = apply_trcfg.apply_payload(payload, USER_CONFIG)
    except apply_trcfg.ApplyError as err:
        return f"❌ 配置未应用（文件未动）: {err}"
    except Exception as err:  # 兜底：任何异常都不落半态（apply 内部已保证不写盘）
        return f"❌ 配置未应用（文件未动）: {err.__class__.__name__}: {err}"
    body = "✅ 配置已应用：\n" + "\n".join(f"· {c}" for c in changes)
    return body + "\n" + trigger_fetch(preview=apply_trcfg.has_keywords(USER_CONFIG))


def dispatch(text):
    if text.startswith("TRCFG1:"):
        return handle_payload(text[len("TRCFG1:"):])
    if text.startswith("设置AI密钥"):
        return cmd_set_ai_key(text[len("设置AI密钥"):])
    t = text.strip().lower()
    if t in ("帮助", "菜单", "help", "h", "?", "？"):
        return menu_text()
    if t == "状态":
        return apply_trcfg.config_summary(USER_CONFIG) + "\n" + ai_status_line()
    if t == "词表":
        return apply_trcfg.words_overview(USER_CONFIG)
    if t in ("导出配置", "导出"):
        return export_link()
    if t == "暂停":
        changes = apply_trcfg.toggle_push(False, USER_CONFIG)
        return "⏸ 推送已暂停（抓取照常，发「恢复」继续）"
    if t == "恢复":
        changes = apply_trcfg.toggle_push(True, USER_CONFIG)
        return "▶️ 推送已恢复"
    if t == "立即推送":
        return trigger_fetch(preview=apply_trcfg.has_keywords(USER_CONFIG))
    if t in ("测试ai", "测试"):
        return cmd_test_ai()
    if t in ("删除ai配置", "关闭ai"):
        return cmd_del_ai()
    if text.startswith("TRCFG1"):
        return "❌ 配置码格式: 以 TRCFG1: 开头（博客可视化页一键生成）"
    return "没听懂这条指令 🤔 发「帮助」查看我能做什么"


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"ok":true}')
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        if self.path != "/inbound":
            self.send_response(404)
            self.end_headers()
            return
        if RELAY_TOKEN:
            auth = (self.headers.get("Authorization") or "").replace("Bearer ", "")
            if auth != RELAY_TOKEN:
                log("[handler] 401 token mismatch")
                self.send_response(401)
                self.end_headers()
                return
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n)
        try:
            j = json.loads(body.decode("utf-8"))
        except Exception:
            self.send_response(400)
            self.end_headers()
            return
        frm = j.get("from_user_id", "")
        text = str(j.get("text") or "").strip()
        owner = owner_id()
        if owner and frm != owner:
            log(f"[handler] 403 非扫码者消息已忽略 from={frm[:20]}")
            self.send_response(403)
            self.end_headers()
            return
        log(f"[handler] 收到指令 len={len(text)} head={text[:20]!r}")
        try:
            out = dispatch(text)
        except Exception as err:
            log(f"[handler] 处理异常: {err}")
            out = f"❌ 处理失败: {err.__class__.__name__}: {err}"
        try:
            reply(out)
            log(f"[handler] 已回复 ({len(out)} 字符)")
        except Exception as err:
            log(f"[handler] 回复失败（桥未就绪？）: {err}")
        try:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"ok":true}')
        except Exception:
            pass  # 客户端（桥 relay 5s 超时/诊断 curl 断开）已断开属常态，勿刷 BrokenPipe 栈

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    log("=== tr2w 管家 ===")
    log(f"配置目录: {USER_CONFIG}｜桥: {BRIDGE_URL}｜鉴权: {'开' if RELAY_TOKEN else '关'}")
    ThreadingHTTPServer(("127.0.0.1", int(os.environ.get("TR2W_PORT", "8899"))), H).serve_forever()
PY_HANDLER

  if ! "$DEST/.venv/bin/python" -m py_compile "$DEST/tr2w/apply_trcfg.py" "$DEST/tr2w/tr2w_handler.py" 2>/dev/null; then
    warn "管家脚本语法校验失败，跳过部署（不影响 TrendRadar 与推送本体）"
  else
    cat > /etc/systemd/system/tr2w-handler.service <<EOF
[Unit]
Description=tr2w WeChat config handler (any2wechat relay consumer)
After=network.target any2wechat.service

[Service]
WorkingDirectory=$DEST/tr2w
EnvironmentFile=$ENV_FILE
Environment=TR2W_DEST=$DEST
Environment=TR2W_BRIDGE_URL=http://127.0.0.1:$A2W_PORT/webhook
Environment=TR2W_PORT=$TR2W_PORT
ExecStart=$DEST/.venv/bin/python $DEST/tr2w/tr2w_handler.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable tr2w-handler >/dev/null 2>&1
    systemctl restart tr2w-handler   # restart 而非 enable --now：升级重跑载入新代码（P-41㊀ 实锤：stale 进程曾静默丢 sch 段）
    sleep 2
    if curl -sm2 "http://127.0.0.1:$TR2W_PORT/health" 2>/dev/null | grep -q '"ok":true'; then
      ok "管家已上线（微信里给 bot 发『帮助』查看指令菜单）"
    else
      warn "管家未就绪（不影响推送本体；查看: journalctl -u tr2w-handler -n 20）"
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
      echo "       ▶ 最后一步: 在微信里给 bot 发任意一条消息（如「绑定」）即完成绑定"
      echo "         bot 会话可在微信通讯录里找到（授权时创建）；收到「✅ 绑定成功」回执后，热点日报直达微信"
      echo "         想立刻收第一期: systemctl start trendradar-fetch"
    else
      echo "       ▶ 微信授权尚未完成，在服务器终端补做（复制整段执行）:"
      echo "         cd $A2W_SRC && BRIDGE_DATA_DIR=$A2W_DATA node bin/login.mjs"
      echo "         授权成功后，在微信里给 bot 发任意一条消息（如「绑定」）即完成绑定"
    fi
      echo "       ▶ 桥日志: journalctl -u any2wechat -f"
      echo "       💬 微信指令: 给 bot 发『帮助』查看菜单（改配置/暂停/恢复/词表/状态）"
      echo "       🤖 AI 热点分析: 微信发『设置AI密钥 sk-你的密钥』开启（腾讯 TokenHub 免费额度，步骤见 geekkkk.com/trcfg）"
elif [ -n "$CHANNELS" ]; then
  echo "    📱 已配置推送:$CHANNELS"
else
  echo "    📱 尚未配置手机推送。推荐微信个人号直推（最简单，零注册）:"
  echo "       bash install-trendradar.sh --wechat-bridge --no-web"
  echo "       （也支持 --wework / --feishu / --dingtalk / --telegram 'BotToken:ChatID'）"
fi
echo "    📖 可视化配置: geekkkk.com/trcfg （生成配置码发微信即生效）｜进阶: docs/config-guide.md"
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
