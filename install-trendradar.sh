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
#    --enable-timer      启用每 30 分钟定时抓取（仅 --wechat-bridge 拉取模式下需要时用）
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
NO_WEB=0; WITH_MCP=0; UNINSTALL=0; PURGE=0; TIMER_OPTIN=0; WECHAT_BRIDGE="${WECHAT_BRIDGE:-0}"

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
    --enable-timer) TIMER_OPTIN=1; shift ;;
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
  # 系统 Python 过低 → uv 代装解释器，钉 3.12（与 24.04 系统路径同版本，避免读者间运行时漂移；
  # 不钉则 uv 拿最新 3.15.x，两路读者运行时不一致）。此处只设环境变量，实际安装
  # 在 uv 本体就绪之后进行（首版曾把安装放本分支 → purge 后 uv 缺位致镜像链假死，实测踩中）
  export UV_PYTHON="3.12"
  PY_NEED_INSTALL=1
  warn "系统 Python $(python3 --version | awk '{print $2}') 低于 3.12，将安装独立 Python 3.12（一次性）"
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

# uv 本体就绪后再装解释器（镜像链依赖 uv；系统已满足 ≥3.12 时跳过）
if [ "${PY_NEED_INSTALL:-0}" = "1" ]; then
  PY_OK=0
  if [ "$REGION" != "overseas" ]; then
    # 镜像链逐候选试装（2026-11-05 站主重装 22.04 实测暴露：ghfast 对 release 资产 403、ghp.ci 已死；
    # npmmirror=阿里 CDN 实装 3.12.16 仅 2.77s 最稳 → 链首；gh-proxy 200 可用次选；ghfast 降为保底）。
    # uv 只接受单值镜像 → 脚本级链；uv python install 幂等，已装秒回
    for M in "https://registry.npmmirror.com/-/binary/python-build-standalone" \
             "https://gh-proxy.com/https://github.com/astral-sh/python-build-standalone/releases/download" \
             "$UV_PY_MIRROR_PROXY"; do
      export UV_PYTHON_INSTALL_MIRROR="$M"
      echo "  安装 Python 3.12（镜像: $(echo "$M" | awk -F/ '{print $3}')）"
      if uv python install 3.12 >/tmp/tr-uvmirror.log 2>&1; then PY_OK=1; break; fi
      # 装报失败但解释器其实已在（半装态）→ 复验兜底
      uv python list --only-installed 2>/dev/null | grep -q "3.12" && { PY_OK=1; break; }
    done
  else
    unset UV_PYTHON_INSTALL_MIRROR
    echo "  安装 Python 3.12（官方源）..."
    uv python install 3.12 >/tmp/tr-uvmirror.log 2>&1 && PY_OK=1
  fi
  if [ "$PY_OK" = "1" ]; then
    ok "独立 Python 3.12 已就绪"
  else
    tail -5 /tmp/tr-uvmirror.log 2>/dev/null
    die "Python 3.12 安装失败（镜像链全灭），请重跑本脚本重试"
  fi
fi

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
  # 整链重试（P-28 硬化补回：原 Docker 脚本有、路线③重写时遗失）——抖动期一轮全灭常见，等 30s 二轮常活
  GOT=0
  for PASS in 1 2; do
    if [ "$PASS" = "2" ]; then
      echo "  第一轮克隆链全灭，等 30s 整链重试一轮…"
      sleep 30
    fi
    # 超时解耦（家宽实测：直连 15.4s / ghfast 19s 可完成 28MB，15s 一刀切会杀死正在工作的慢传输）：
    # 直连 15s 只管「连不上秒败」的连接纪律；代理源给 45s 传输预算（CDN 承载，瓶颈在吞吐）
    for prefix in "" "${GH_PROXY_FALLBACKS[@]}"; do
      url="${prefix:+$prefix/}$REPO_URL.git"
      echo "  克隆: $url"
      if [ -z "$prefix" ]; then TMO=15; else TMO=45; fi
      if timeout "$TMO" git clone --depth 1 -b "$REPO_BRANCH" "$url" "$DEST" >/dev/null 2>&1; then GOT=1; break; fi
      rm -rf "$DEST"
    done
    [ "$GOT" = "1" ] && break
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
  # TRD2W 默认信息源模板（2026-11-07 站主拍板，P-60 词表精修）：首装=「全网热点」——
  # 原生热榜直出 + 六大热点平台 + 按来源分组。热点速览兜底组是限流阀：空词表会全量推送
  # （上游 frequency.py `if not word_groups: return True` 实锤），六平台全量≈5-6 批连发
  # 贴风控红线（P-54 教训），@20 压回 1-2 批。仅首装分支内覆盖（升级永不触碰）；
  # trcfg 页可一键换其余三套模板（极客开发/商业财经/硬新闻脱水）或自由增删。
  cat > "$USER_CONFIG/frequency_words.txt" <<'KWEOF'
# 本文件由配置系统维护：微信 TRCFG1 应用时会整体重写本文件（手工微调会被下次应用覆盖）。

[GLOBAL_FILTER]

[WORD_GROUPS]

[热点速览]
/./
@20
KWEOF
  # 模板手术（对上游 config.yaml 原文，形制与管家 apply_trcfg 严格一致，trcfg 可随时改回）：
  # ① 平台停用=注释 sources 条目（保留 name/domain 便于回启，同 _toggle_platform）
  awk '
    /^ *- id: "(wallstreetcn-hot|thepaper|cls-hot|ifeng|tieba)"$/ { skip = 1 }
    skip && /^ *- id:/ && !/^ *- id: "(wallstreetcn-hot|thepaper|cls-hot|ifeng|tieba)"$/ { skip = 0 }
    skip && /^ *$/ { skip = 0 }
    skip { print "# " $0; next }
    { print }
  ' "$USER_CONFIG/config.yaml" > /tmp/tr-seed-awk.$$ && mv /tmp/tr-seed-awk.$$ "$USER_CONFIG/config.yaml"
  # ② RSS 停用=无 enabled 行的源补 enabled: false（同 _toggle_feed 缺行补法；阮一峰上游本就 false）
  sed -i '\|url: "https://hnrss.org/frontpage"|a\      enabled: false                  # 停用（默认模板，trcfg 可改回）' "$USER_CONFIG/config.yaml"
  sed -i '\|url: "https://finance.yahoo.com/news/rssindex"|a\      enabled: false                  # 停用（默认模板，trcfg 可改回）' "$USER_CONFIG/config.yaml"
  # ③ 按来源分组（模板语义：微博吵什么/抖音看什么一眼分层）
  sed -i 's|^\(  display_mode: \)"keyword"|\1"platform"|' "$USER_CONFIG/config.yaml"
  cat > "$USER_CONFIG/README.txt" <<'MDEOF'
此目录存放你的个性化配置；重跑安装脚本升级时【不会被覆盖】。

  frequency_words.txt   关注关键词（默认=「全网热点」模板：热榜直出、每轮最多 20 条）
  config.yaml           主配置（信息源/推送分组等，文件内含中文注释）

修改后下次抓取自动生效；微信里发「推送」可立即抓取并推送；
打开 geekkkk.com/trcfg 可一键换模板（极客开发/商业财经/硬新闻脱水）或自由配置。
MDEOF
  ok "用户配置已初始化（$USER_CONFIG，升级不覆盖；默认=全网热点模板：六大平台热榜直出、每轮≤20条）"
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
# 拉取模式（P-55/P-54，2026-11-06 站主拍板）：桥安装默认不启用定时——bot 上行 token 存在
# ~30 分钟 TTL（P-55 实锤：用户不说话则定时推送必败）且单方面高频发送有风控面（P-54 实锤）。
# 微信发「推送 / 获取 / 新闻」即现抓现推（token 新鲜必达）。--enable-timer 可选回定时形态。
if [ "$WECHAT_BRIDGE" = "1" ] && [ "$TIMER_OPTIN" != "1" ]; then
  systemctl disable trendradar-fetch.timer >/dev/null 2>&1 || true
  systemctl stop trendradar-fetch.timer >/dev/null 2>&1 || true
  ok "拉取模式：定时抓取已停用，微信发「推送 / 获取 / 新闻」即抓即推（--enable-timer 可启用定时）"
else
  systemctl enable --now trendradar-fetch.timer >/dev/null 2>&1
  ok "定时抓取已排程（每 30 分钟，systemd timer 持久化）"  # P-57④：仅定时形态打印（拉取分支已有自己的行）
fi
if [ "$WITH_MCP" = "1" ]; then
  systemctl enable trendradar-mcp >/dev/null 2>&1 && systemctl restart trendradar-mcp && ok "MCP 服务已启动（$MCP_HOST:$MCP_PORT）"
fi
if [ "$NO_WEB" = "1" ]; then
  ok "网页报告服务已启动（仅本机 127.0.0.1:$PORT，外网暴露面为零）"
else
  ok "网页报告服务已启动（0.0.0.0:$PORT）"
fi

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
          && ln -sf /usr/local/lib/nodejs/bin/npm /usr/local/bin/npm \
          && ln -sf /usr/local/lib/nodejs/bin/npx /usr/local/bin/npx \
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

    # 桥运行时依赖（v0.4.0 起唯一依赖 qrcode——配置二维码图片，P-53；npmmirror 秒级）
    if [ -f "$A2W_SRC/package.json" ] && grep -q '"dependencies"' "$A2W_SRC/package.json"; then
      NPM_BIN="$(command -v npm || echo /usr/local/lib/nodejs/bin/npm)"
      if [ -x "$NPM_BIN" ]; then
        echo "  安装桥依赖（npmmirror）..."
        if (cd "$A2W_SRC" && "$NPM_BIN" install --omit=dev --no-audit --no-fund --registry=https://registry.npmmirror.com >/dev/null 2>&1) && [ -d "$A2W_SRC/node_modules/qrcode" ]; then
          ok "桥依赖就绪"
        else
          warn "桥依赖安装失败（配置二维码将不可用，文本推送不受影响）；可重跑本脚本重试"
        fi
      else
        warn "npm 不可用（Node 安装异常？），跳过桥依赖——配置二维码将不可用，文本推送不受影响"
      fi
    fi

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
Environment="BRIDGE_FOOTER_TEXT=📖 微信发「帮助」改配置"
Environment="BRIDGE_FOOTER_ONCE_PER_DAY=1"
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable any2wechat >/dev/null 2>&1
    # P-64㊁（v0.9.2）：此处只 enable 不启动——桥若先于管家运行，读者扫码即发「绑定」时
    # 首绑消息的转发会撞上管家未就绪窗口（安装收尾两者启动间隔 ~10s，2026-11-08 真机实锤
    # 欢迎语永久丢失）。启动挪至管家 restart 之后（对调消除窗口本体；桥 relay 失败重试
    # v0.4.7 为运行期兜底）。restart 而非 enable --now 的升级载新语义保持（P-41㊀）。
    ok "桥服务已注册（启动安排在管家就绪之后）"
  fi
fi

# ----------------------------- 微信指令管家（可选，软失败） --------------------
# P-61 海报配置卡装饰条（C 款，站主 2026-11-07 选定）：本地 HTML 2x 截图烤制入仓，
# base64 内嵌安装器（头条 120KB / 页脚 22KB）；管家运行时贴条+实时填内容，失败回退纯 QR。
POSTER_HEADER_B64="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"
POSTER_FOOTER_B64="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4AAAAAAAAELAAQAAAAAAIAQcAAAAAAAAQsABAAAAAAAgBBwAAAAAAEAIOAAAAAAAAISAAwAAAAAAQAg4AAAAAAAAhIADAAAAAAAIAQcAAAAAAIAQcAAAAAAAAAgBBwAAAAAAgBBwAAAAAAAAIeAAAAAAAAAQAg4AAAAAAAAh4AAAAAAAABACDgAAAAAAIAQcAAAAAAAAQsABAAAAAAAgBBwAAAAAAABCwAEAAAAAAISAAwAAAAAAQAg4AAAAAAAAhIADAAAAAABACDgAAAAAAIAQcAAAAAAAAAgBBwAAAAAAgBBwAAAAAAAACAEHAAAAAAAQAg4AAAAAAAAh4AAAAAAAABACDgAAAAAAACHgAAAAAAAAQsABAAAAAAAgBBwAAAAAAABCwAEAAAAAACAEHAAAAAAAQAg4AAAAAAAAhIADAAAAAABACDgAAAAAAAAIOAAAAAAAgBBwAAAAAAAACAEHAAAAAACAEHAAAAAAAAAh4AAAAAAAABACDgAAAAAAACHgAAAAAAAAEAIOAAAAAAAgBBwAAAAAAABCwAEAAAAAACAEHAAAAAAAAELAAQAAAAAAhIADAAAAAABACDgAAAAAAACEgAMAAAAAAEAIOAAAAAAAgBBwAAAAAAAACAEHAAAAAADAZfL/AYYJzExmJAjxAAAAAElFTkSuQmCC"

# tr2w-handler：消费桥的入站转发（BRIDGE_RELAY_*），微信对话式管理 TrendRadar。
# 安全铁律：只认扫码者本人（双层校验：桥 P-35 守卫 + 本地 owner 比对）；
# TRCFG1 载荷只是数据——白名单键 + 枚举校验，永不执行其中任何字符串。
if [ "$WECHAT_BRIDGE" = "1" ] && [ "$BRIDGE_OK" = "1" ]; then
  step "部署微信指令管家（tr2w-handler，对话式配置）"
  mkdir -p "$DEST/tr2w"

  # ---- P-61 海报配置卡：venv 绘图依赖 + 钉版中文字体（三层软降级，任一缺失→回退纯 QR） ----
  mkdir -p "$DEST/tr2w/assets/fonts"
  echo "$POSTER_HEADER_B64" | base64 -d > "$DEST/tr2w/assets/poster_header.png" 2>/dev/null || true
  echo "$POSTER_FOOTER_B64" | base64 -d > "$DEST/tr2w/assets/poster_footer.png" 2>/dev/null || true
  if "$DEST/.venv/bin/python" -c "import PIL, qrcode" >/dev/null 2>&1; then
    ok "海报绘图依赖就绪"
  elif uv pip install --python "$DEST/.venv/bin/python" pillow qrcode >>/tmp/tr-poster.log 2>&1; then
    ok "海报绘图依赖就绪（Pillow+qrcode）"
  else
    warn "绘图依赖安装失败——配置卡回退纯二维码（推送本体不受影响）；可重跑本脚本重试"
  fi
  FONT_R="$DEST/tr2w/assets/fonts/HarmonyOS_Sans_SC_Regular.ttf"
  FONT_M="$DEST/tr2w/assets/fonts/HarmonyOS_Sans_SC_Medium.ttf"
  if [ -s "$FONT_R" ] && [ -s "$FONT_M" ]; then
    ok "海报字体已就位"
  else
    echo "  下载海报字体（npmmirror 钉版包约 50MB，云上通常 <10s）..."
    FONT_TGZ=/tmp/harmonyos-sans-1.0.0.tgz
    if curl -fsSL --retry 3 --max-time 300 "https://registry.npmmirror.com/harmonyos-sans/-/harmonyos-sans-1.0.0.tgz" -o "$FONT_TGZ"        && [ "$(md5sum "$FONT_TGZ" | cut -d' ' -f1)" = "bd3f25f9206444561a9721f2d658b639" ]        && "$DEST/.venv/bin/python" - "$FONT_TGZ" "$DEST/tr2w/assets/fonts" <<'PYFONT'
import io, pathlib, sys, tarfile, zipfile
tgz, outdir = sys.argv[1], pathlib.Path(sys.argv[2])
with tarfile.open(tgz, "r:gz") as tf:
    zi = next(m for m in tf.getmembers() if m.name.endswith("HarmonyOS Sans.zip"))
    with zipfile.ZipFile(io.BytesIO(tf.extractfile(zi).read())) as zf:
        for weight in ("Regular", "Medium"):
            name = next(x for x in zf.namelist() if x.endswith(f"HarmonyOS_Sans_SC_{weight}.ttf"))
            (outdir / f"HarmonyOS_Sans_SC_{weight}.ttf").write_bytes(zf.read(name))
PYFONT
    then rm -f "$FONT_TGZ"; ok "海报字体就位（HarmonyOS Sans SC Regular/Medium）"
    else warn "字体下载/校验失败——配置卡回退纯二维码（推送本体不受影响）；可重跑本脚本重试"; fi
  fi

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

DISPLAY_MODES = {"keyword", "platform"}
# 回执展示用中文名（推送里不出现英文裸值）
# P-57（2026-11-06 站主拍板）：拉取模式为唯一默认形态——schedule 节奏与 report.mode 的
# 白名单/中文名已全线摘除（配置页对应控件删除；拉取路径恒走 current 预览，稳态 mode 被架空；
# 上游模板 schedule.enabled 本就默认 false，窗口门控无来源）。
DMODE_ZH = {"keyword": "按主题分组", "platform": "按来源分组"}
KEEP_BACKUPS = 30
_SECTION = re.compile(r"^([A-Za-z_]+):\s*(?:#.*)?$")
_ENTRY = re.compile(r"^(\s*)- id:\s*[\"']?([A-Za-z0-9_-]+)[\"']?\s*(?:#.*)?$")
_ENTRY_C = re.compile(r"^(\s*)(?:#\s*)+- id:\s*[\"']?([A-Za-z0-9_-]+)[\"']?\s*(?:#.*)?$")
_FIELD_RE = re.compile(r"^\s*(?:-\s*)?[A-Za-z_][A-Za-z0-9_-]*\s*:")  # 条目/字段行形态（含被注释态），P-65 块边界判定用
# P-56：`/` 前缀放行——它是上游词表 DSL 的正则词条法（/…/ => 别名），官方默认词表 30 词
# 以此开头，旧规则会拒掉整份默认配置；其余前缀（注释/必须/排除/条数/组头）仍是保留字。
# 与博客页 chkWord 同规则（geekkkk-site static/trcfg）。
_WORD_BAD = re.compile(r"(^[\s#！!＋+＠@\[]|[\r\n])")


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
        if ln.lstrip().startswith("#"):
            # P-65（v0.9.1）注释行收边：只有「剥净注释标记后 = 更深缩进的条目/字段行」才属本块，
            # 章节段落头（# ===… / # 3. 数据源…）与任意其他注释一律断边。旧实现放行任意注释行，
            # 末项平台（zhihu）的块会吞下后续 RSS 段落头：停用把它二次注释成 # #（化妆伤），
            # 启用再被剥标记循环剥光成裸文本 → 非法 YAML → 推送全断
            t = ln
            while re.match(r"^\s*#", t):  # 逐枚剥「#␠」标记（保留语义缩进，兼容行首 # 与随缩 # 两种注释态）
                t = re.sub(r"^(\s*)# ?", r"\1", t, count=1)
            if not t.strip() or _lead(t) <= base or not _FIELD_RE.match(t):
                end = j
                break
        end = j + 1
    return (start, end, indent)


def _toggle_platform(lines, pid, on, changes):
    # P-60 修复（v0.8.0，2026-11-07 round-trip 测试抓出）：v0.3.0 起两向搜索写反——
    # 目标态块被当待切换块，真实切换全落空（回执「已是启用/停用」读者无法察觉，
    # trcfg 页取消勾选平台从未真正生效）；已注释块再停用会被二次注释（# # 前缀令
    # _ENTRY_C 失配，后续指令报「未知平台」）。恢复语义：目标态命中=无变化；
    # 相反态命中=执行切换；两态皆无=未知 id。
    tgt = _find_block(lines, pid, commented=not on)   # 目标态块（on=True→活动块）
    if tgt is not None:
        changes.append(f"平台 {pid} 已是{'启用' if on else '停用'}状态（无变化）")
        return
    cur = _find_block(lines, pid, commented=on)        # 当前相反态块（待切换）
    if cur is None:
        raise ApplyError(f"未知平台 id: {pid!r}（以 config.yaml 的 sources 为准）")
    start, end, _indent = cur
    if on:
        for i in range(start, end):
            # 循环剥标记：单发会留下半修复态（# # → #），顺带治愈历史二次注释伤害
            while re.match(r"^\s*#", lines[i]):
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
    # P-50：值单独捕获比对，行尾注释不参与判定、改写时原样保留（旧行为会把
    # `enabled: false # 注释` 误报为变化并抹掉注释）
    pat = re.compile(r"^(\s+enabled\s*:\s*)([A-Za-z]+)(\s*#.*)?\s*$")
    want = "true" if on else "false"
    for i in range(start, end):
        m = pat.match(lines[i])
        if m:
            if m.group(2).lower() == want:
                changes.append(f"RSS {fid} 已是{'启用' if on else '停用'}（无变化）")
            else:
                lines[i] = f"{m.group(1)}{want}{m.group(3) or ''}"
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
    if len(w) > 200:  # P-56：官方默认词表正则词（/…/ => 别名）最长 113 字，60 上限会拒掉整份默认配置
        raise ApplyError(f"{what}词条过长: {w[:30]!r}…")
    return w


def gen_frequency(freq):
    if not isinstance(freq, dict):
        raise ApplyError("freq 必须是对象")
    out = ["# 本文件由配置系统维护：微信 TRCFG1 应用时会整体重写本文件（手工微调会被下次应用覆盖）。", ""]
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

    # P-57：cfg.schedule / cfg.report.mode 不再消费——拉取模式下无定时无稳态形态分歧，
    # 页面/导出也不再生成这两段；白名单机制对未知键天然静默忽略，旧码不会报错。
    notif = cfg.get("notification") or {}
    if "enabled" in notif:
        b = notif["enabled"]
        if not isinstance(b, bool):
            raise ApplyError("notification.enabled 需为 true/false")
        staged.append(lambda b=b: _patch_scalar(lines, "notification", "enabled", "true" if b else "false", changes, "恢复推送" if b else "暂停推送"))
    rep = cfg.get("report") or {}
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
        return ["载荷与当前配置一致，无变化"]  # 全 no-op（含「已是 XX 态」项）收口单行，回执如实
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

    if yaml_changed:
        # P-65（v0.9.1）落盘前 YAML 门禁：行级手术产物必须先通过整表解析才允许写盘。
        # 坏结果在此拦截（文件一字不动、备份不做、回执照实报错），根绝「回执绿灯但 config 已死」；
        # 对既有坏文件（如 P-65 站主箱）同样生效：任何应用都会被拒并如实报错，而非静默继续
        import yaml
        try:
            yaml.safe_load(new_yaml)
        except yaml.YAMLError as e:
            first = (str(e).splitlines() or [""])[0][:120]
            raise ApplyError(f"应用结果未通过 YAML 校验，config.yaml 未做任何改动: {first}")
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
    notif = cfg.get("notification") or {}
    n, g, _ = _parse_words(user_config / "frequency_words.txt")
    push_state = "推送中 ✅" if notif.get("enabled", True) else "已暂停 ⏸"
    # P-57：节奏/形态行摘除（拉取模式无定时、无稳态形态分歧），改示拉取口令
    return (
        f"📊 当前状态\n· 推送: {push_state}\n"
        f"· 拉取: 发「推送 / 获取 / 新闻」随时抓取推送（无定时）\n"
        f"· 分组: {DMODE_ZH.get(rep.get('display_mode'), rep.get('display_mode', '-'))}\n"
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
    schedule/report.mode 不导出（P-57：拉取模式下页面已无对应控件，导出即虚诺）；
    report 仅非页面默认值（keyword 不发）；platforms 仅停用项（注释态条目
    yaml.safe_load 看不到，扫原文）；rss 全部显式布尔（页面默认可能与上游种子
    不一致，显式即保真）。ts（P-61）：导出时刻随码入载荷，配置页横幅显示配置码年龄
    （扫旧码防误覆盖）；apply 白名单对 ts 天然忽略，不参与写盘。只读，不写盘。"""
    import yaml
    p = {"v": 1, "ts": time.strftime("%Y-%m-%d %H:%M")}
    freq = parse_words_structured(user_config / "frequency_words.txt")
    if freq.get("global_filter") or freq.get("groups"):
        p["freq"] = freq
    cfg = yaml.safe_load((user_config / "config.yaml").read_text(encoding="utf-8")) or {}
    out = {}
    rep = cfg.get("report") or {}
    rep_out = {}
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
    "· 推送 / 获取 / 新闻 —— 立即抓取并推送最新热点\n"
    "· 帮助 —— 本菜单\n"
    "· 状态 —— 当前配置速览\n"
    "· 词表 —— 查看关注关键词\n"
    "· 暂停 / 恢复 —— 停止/恢复推送\n"
    "· 触发词 —— 查看拉取触发词（加触发词 X / 删触发词 X 可自定义）\n"
    "· 导出配置 —— 生成配置二维码\n"
    "· TRCFG1:… —— 粘贴配置码（博客可视化页生成），立即生效\n"
    "· 设置AI密钥 sk-xxx —— 开启 AI 热点分析（腾讯 TokenHub 免费额度；结尾加「官方」二字 = DeepSeek 官方）\n"
    "· 测试AI / 删除AI配置 —— 验证 AI 连通 / 关闭并删除 Key\n"
)


def menu_text():
    """帮助菜单（P-53 全面二维码化 + P-61 海报卡）：配置态媒体出口统一走
    _menu_tail_and_media（海报卡优先 → 纯 QR 回退 → 超大词表文本码提示）。"""
    tail, qr, imgs = _menu_tail_and_media()
    return MENU_BODY + tail, qr, imgs


def welcome_text():
    """P-64 绑定欢迎语：菜单+状态拼一条 + 配置海报卡（复用帮助媒体出口）。
    「绑定」是读者与 bot 的第一次对话（P-63 行动卡教的话）——回执即完整指令面，
    省一次「帮助」往返；此前「绑定」落进 dispatch 兜底回「没听懂」，首触体验断裂。"""
    body, qr, imgs = menu_text()
    status = apply_trcfg.config_summary(USER_CONFIG) + "\n" + ai_status_line()
    head = "👋 你好，我是 TrendRadar 微信管家——热点推送与配置修改都在这里完成！\n\n"
    return head + body + "\n\n📌 当前状态：\n" + status, qr, imgs


# ============================== P-61 海报配置卡（C 款，2026-11-07 站主选定） ==============================
# 装饰条（蓝渐变头条+深色页脚）烤死在 tr2w/assets/；中段 Pillow 实时绘制（QR+摘要，2x 合成）。
# 任一环缺失（资产/字体/PIL/qrcode/异常）→ _poster_compose 返回 None → 调用方回退纯 QR。
# 词多折叠复用 P-45 规则（组>8 或词>30 → 纯计数）；时间戳取 export_payload.ts（码与图同源）。

POSTER_ASSETS = Path(os.environ.get("TR2W_ASSETS", str(Path(__file__).parent / "assets")))
POSTER_BG = (248, 250, 252)      # #f8fafc
POSTER_TEXT = (15, 23, 42)       # #0f172a
POSTER_MUTED = (100, 116, 139)   # #64748b
POSTER_FAINT = (148, 163, 184)   # #94a3b8
POSTER_BORDER = (226, 232, 240)  # #e2e8f0
POSTER_ACCENT = (37, 99, 235)    # #2563eb
POSTER_RED = (220, 38, 38)       # #dc2626
POSTER_GREEN = (5, 150, 105)     # #059669
POSTER_TIME_WHITE = (223, 232, 250)


def _poster_wrap(text, font, max_w):
    """按宽度贪心折行，优先在「、」边界断行。"""
    lines, cur = [], ""
    for ch in text:
        if ch == "、" and cur and font.getlength(cur + ch) > max_w:
            lines.append(cur + "、")
            cur = ""
            continue
        if font.getlength(cur + ch) > max_w and cur:
            lines.append(cur)
            cur = ch if ch != "、" else ""
        else:
            cur += ch
    if cur:
        lines.append(cur)
    return lines or [""]


def _poster_compose(groups, blocked, sources, qr_url, ts):
    """合成海报卡 PNG → base64；任何异常返回 None（调用方回退纯 QR）。布局=C 款小样。"""
    try:
        import io
        import qrcode
        from PIL import Image, ImageDraw, ImageFont

        S = 2
        CANVAS_W, HEADER_H, FOOTER_H = 1440, 300, 240
        f = lambda path, px: ImageFont.truetype(path, px * S)
        fr = str(POSTER_ASSETS / "fonts" / "HarmonyOS_Sans_SC_Regular.ttf")
        fm = str(POSTER_ASSETS / "fonts" / "HarmonyOS_Sans_SC_Medium.ttf")
        f_title, f_count = f(fm, 24), f(fm, 21)
        f_name, f_tag, f_words = f(fm, 24), f(fr, 18), f(fr, 23)
        f_hint, f_hint_b, f_time = f(fr, 21), f(fm, 21), f(fm, 20)

        card_ml, card_mr, card_pl = 80, 80, 60  # 卡左右边距 / 卡内左右 padding（2x）
        inner_w = CANVAS_W - card_ml - card_mr - card_pl * 2 - 44  # 再扣词行缩进

        qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_M, border=2, box_size=12)
        qr.add_data(qr_url)
        qr.make(fit=True)
        qimg = qr.make_image(fill_color="black", back_color="white").convert("RGB")
        qimg = qimg.resize((680, 680), Image.NEAREST)
        plate = 720

        rows, card_h = [], 44

        def sec_title(color, text, count):
            nonlocal card_h
            rows.append(("title", color, text, count))
            card_h += f_title.size + 20

        def grp(name, tag, words):
            nonlocal card_h
            rows.append(("grp", name, tag))
            card_h += f_name.size + 8
            for ln in _poster_wrap(words, f_words, inner_w):
                rows.append(("words", ln))
                card_h += int(f_words.size * 1.45)
            card_h += 6

        def line(text, strong):
            nonlocal card_h
            ft, col = (f_name, POSTER_TEXT) if strong else (f_words, POSTER_MUTED)
            for ln in _poster_wrap(text, ft, inner_w):
                rows.append(("line", ln, strong, col))
                card_h += int(ft.size * 1.45)

        total_words = sum(len(w.split("、")) for _, _, w in groups)
        if len(groups) > 8 or total_words > 30:
            sec_title(POSTER_ACCENT, "关注主题", len(groups))
            line(f"共 {len(groups)} 个主题 · {total_words} 个词（较多，已折叠）", False)
        else:
            sec_title(POSTER_ACCENT, "关注主题", len(groups))
            for name, tag, words in groups:
                grp(name, tag, words)
        if blocked:
            sec_title(POSTER_RED, "屏蔽词", len([w for w in blocked.split("、") if w]))
            line(blocked, True)
        if sources:
            sec_title(POSTER_GREEN, "信息源", len([w for w in sources.split("、") if w]))
            line(sources, False)
        card_h += 36

        qr_top = 48
        hint_y = qr_top + plate + 28
        hint_h = int(f_hint.size * 1.5)
        card_top = hint_y + hint_h + 40
        middle_h = card_top + card_h + 56
        total_h = HEADER_H + middle_h + FOOTER_H

        canvas = Image.new("RGB", (CANVAS_W, total_h), POSTER_BG)
        canvas.paste(Image.open(io.BytesIO((POSTER_ASSETS / "poster_header.png").read_bytes()))
                     .convert("RGB"), (0, 0))
        canvas.paste(Image.open(io.BytesIO((POSTER_ASSETS / "poster_footer.png").read_bytes()))
                     .convert("RGB"), (0, HEADER_H + middle_h))
        draw = ImageDraw.Draw(canvas)

        if ts:
            tw = draw.textlength(ts, font=f_time)
            draw.text((CANVAS_W - 96 - tw, HEADER_H - 68 - int(f_time.size * 0.35)), ts,
                      font=f_time, fill=POSTER_TIME_WHITE)

        plate_x = (CANVAS_W - plate) // 2
        draw.rounded_rectangle([plate_x, HEADER_H + qr_top, plate_x + plate, HEADER_H + qr_top + plate],
                               radius=24, fill=(255, 255, 255), outline=POSTER_BORDER, width=2)
        canvas.paste(qimg, (plate_x + 20, HEADER_H + qr_top + 20))

        parts = [("微信", f_hint), ("长按识别二维码", f_hint_b), (" · 打开配置页", f_hint)]
        hx = (CANVAS_W - sum(draw.textlength(t, font=ft) for t, ft in parts)) // 2
        hy = HEADER_H + hint_y
        for t, ft in parts:
            draw.text((hx, hy), t, font=ft, fill=POSTER_ACCENT if ft is f_hint_b else POSTER_MUTED)
            hx += draw.textlength(t, font=ft)

        card_y = HEADER_H + card_top
        draw.rounded_rectangle([card_ml, card_y, CANVAS_W - card_mr, card_y + card_h],
                               radius=28, fill=(255, 255, 255), outline=POSTER_BORDER, width=2)
        y = card_y + 44
        x0 = card_ml + card_pl
        for r in rows:
            kind = r[0]
            if kind == "title":
                _, color, text, count = r
                draw.rounded_rectangle([x0, y + 14, x0 + 24, y + 38], radius=8, fill=color)
                draw.text((x0 + 44, y), text, font=f_title, fill=POSTER_TEXT)
                if count is not None:
                    draw.text((x0 + 44 + draw.textlength(text, font=f_title) + 18, y + 6),
                              str(count), font=f_count, fill=POSTER_ACCENT)
                y += f_title.size + 20
            elif kind == "grp":
                _, name, tag = r
                nx = x0 + 44
                draw.text((nx, y), name, font=f_name, fill=POSTER_TEXT)
                if tag:
                    off = draw.textlength(name, font=f_name) + 24
                    tw2 = draw.textlength(tag, font=f_tag)
                    draw.rounded_rectangle([nx + off, y + 10, nx + off + tw2 + 32,
                                            y + 10 + int(f_tag.size * 1.5)],
                                           radius=12, outline=POSTER_BORDER, width=2)
                    draw.text((nx + off + 16, y + 14), tag, font=f_tag, fill=POSTER_FAINT)
                y += f_name.size + 8
            elif kind == "words":
                draw.text((x0 + 44, y), r[1], font=f_words, fill=POSTER_MUTED)
                y += int(f_words.size * 1.45)
            elif kind == "line":
                _, ln, strong, col = r
                draw.text((x0 + 44, y), ln, font=f_name if strong else f_words, fill=col)
                y += int((f_name if strong else f_words).size * 1.45)

        import base64 as _b64
        buf = io.BytesIO()
        canvas.save(buf, "PNG", optimize=True)
        return _b64.b64encode(buf.getvalue()).decode()
    except Exception as err:
        log(f"[poster] 合成失败（回退纯 QR）: {err.__class__.__name__}: {err}")
        return None


def _poster_summary():
    """user-config → 海报摘要 (groups, blocked, sources)。词表用 apply_trcfg 结构化解析；
    信息源=config.yaml 里可见的平台（停用项是注释态，yaml 看不到=不数）+ 启用 RSS 计数。"""
    freq = apply_trcfg.parse_words_structured(USER_CONFIG / "frequency_words.txt")
    groups = []
    for g in freq.get("groups", []):
        name = g.get("name") or "未命名主题"
        parts = list(g.get("words", []))
        if g.get("must"):
            parts.extend("+" + w for w in g["must"])
        if g.get("exclude"):
            parts.extend("!" + w for w in g["exclude"])
        tag = f"每轮 ≤{g['max']} 条" if g.get("max") else None
        groups.append((name, tag, "、".join(parts)))
    blocked = "、".join(freq.get("global_filter", []))
    srcs = []
    try:
        import yaml
        cfg = yaml.safe_load((USER_CONFIG / "config.yaml").read_text(encoding="utf-8")) or {}
        plat = (cfg.get("platforms") or {}).get("sources")
        items = plat.items() if isinstance(plat, dict) else []
        for pid, pc in items:
            if isinstance(pc, dict) and pc.get("enabled") is False:
                continue
            srcs.append((pc.get("name") or pid) if isinstance(pc, dict) else pid)
        n_rss = sum(1 for fd in (cfg.get("rss") or {}).get("feeds") or [] if fd.get("enabled", True))
        if n_rss:
            srcs.append(f"RSS ×{n_rss}")
    except Exception as err:
        log(f"[poster] 信息源解析失败（省略信息源段）: {err}")
    return groups, blocked, "、".join(srcs)


def _menu_tail_and_media():
    """帮助/导出共用的媒体出口。返回 (tail_text, qr_content, images)：
    海报卡成功 → (文案, None, [b64])；海报失败 → (文案, link, None)；超大词表 → 文本码提示。"""
    try:
        p = apply_trcfg.export_payload(USER_CONFIG)
    except Exception as err:
        log(f"[poster] 导出载荷失败: {err}")
        return "🌐 配置入口异常：发「导出配置」取配置码", None, None
    link = f"https://geekkkk.com/trcfg#c={trcfg_code(p)}"
    if len(link.encode("utf-8")) > QR_CONTENT_MAX:
        return "🌐 词表较大：发「导出配置」取配置码，粘进配置页导入框即改", None, None
    groups, blocked, sources = _poster_summary()
    b64 = _poster_compose(groups, blocked, sources, link, f"{p.get('ts', '')} 生成")
    if b64:
        return "🌐 你的配置卡随后附上——微信长按识别二维码，打开即改当前配置", None, [b64]
    return "🌐 配置二维码随后附上——微信长按识别，打开即改你的当前配置", link, None


def log(*a):
    print(*a, flush=True)


def owner_id():
    try:
        return json.loads(CREDS_FILE.read_text(encoding="utf-8")).get("user_id", "")
    except Exception as err:
        log(f"[handler] 读取凭证失败: {err}")
        return ""


def reply(text, qr_content=None, images=None):
    body = {"content": text}
    if qr_content:
        body["qr_content"] = qr_content
    if images:
        body["images"] = images  # P-61 海报卡：base64 PNG 数组（桥通用 images 契约）
    req = urllib.request.Request(
        BRIDGE_URL,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=15) as r:
        data = r.read().decode("utf-8", "replace")
    if r.status != 202:
        raise RuntimeError(f"bridge HTTP {r.status}: {data[:120]}")


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


# ============================== 拉取触发词（P-55 拉取模式，2026-11-06 站主拍板） ==============================
# 拉取模式：定时抓取已停用（token ~30min TTL 使定时推送不可靠 + 单方面发送有风控面），
# 用户主动发消息 = 新鲜 token = 推送必达。内置触发词不可变动；用户自定义词存
# user-config/tr2w_triggers.txt（每行一个，升级重跑不覆盖）。词仅做整串匹配，无注入面。
BUILTIN_TRIGGERS = ("推送", "获取", "新闻")
TRIGGER_FILE = USER_CONFIG / "tr2w_triggers.txt"


def pull_triggers():
    """内置 + 自定义触发词（自定义读文件，逐行 trim，去重保序）。"""
    custom = []
    try:
        for ln in TRIGGER_FILE.read_text(encoding="utf-8").splitlines():
            w = ln.strip()
            if w and w not in custom:
                custom.append(w)
    except FileNotFoundError:
        pass
    out = list(BUILTIN_TRIGGERS)
    for w in custom:
        if w not in out:
            out.append(w)
    return out


def cmd_trigger_list():
    custom = pull_triggers()[len(BUILTIN_TRIGGERS):]
    if not custom:
        return "🔔 拉取触发词:\n· 内置: " + "、".join(BUILTIN_TRIGGERS) + "\n· 自定义: 无（发「加触发词 词汇」添加，每次一个）"
    return ("🔔 拉取触发词:\n· 内置: " + "、".join(BUILTIN_TRIGGERS) +
            "\n· 自定义: " + "、".join(custom))


def cmd_trigger_add(rest):
    w = rest.strip()
    if not w or len(w) > 20 or "\n" in w:
        return "❌ 用法: 加触发词 词汇（≤20 字，每次一个）"
    cur = pull_triggers()
    if w in cur:
        return f"「{w}」已是触发词（无需重复添加）"
    lines = []
    try:
        lines = [l.strip() for l in TRIGGER_FILE.read_text(encoding="utf-8").splitlines() if l.strip()]
    except FileNotFoundError:
        lines = []
    lines.append(w)
    TRIGGER_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return f"✅ 已添加触发词「{w}」——以后发「{w}」即可拉取最新热点"


def cmd_trigger_del(rest):
    w = rest.strip()
    if w in BUILTIN_TRIGGERS:
        return f"「{w}」是内置触发词，不可删除"
    try:
        lines = [l.strip() for l in TRIGGER_FILE.read_text(encoding="utf-8").splitlines() if l.strip()]
    except FileNotFoundError:
        lines = []
    if w not in lines:
        return f"「{w}」不在自定义触发词里（发「触发词」查看）"
    lines = [l for l in lines if l != w]
    if lines:
        TRIGGER_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")
    else:
        TRIGGER_FILE.unlink(missing_ok=True)
    return f"✅ 已删除触发词「{w}」"


# ============================== 配置载荷 zlib（P-53，D14 预留兑现） ==============================
# hash 形态：z 前缀 + b64url(zlib(json))。中文词表 deflate 仅 ~1.8x，但足以把 QR 内容
# 压进容量（实测 53 词配置 2979B JSON → 1689B）；页面端 DecompressionStream('deflate') 解压。
import zlib

QR_CONTENT_MAX = 2500  # QR 内容字节上限（version 40-L 容量 2953B，留纠错与 URL 头余量）


def trcfg_code(payload):
    """载荷 → zlib 配置码（z 前缀 + b64url），QR 与文本回退共用。"""
    raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    return "z" + base64.urlsafe_b64encode(zlib.compress(raw, 9)).decode().rstrip("=")


def parse_trcfg_code(code):
    """配置码 → 载荷（handle_payload 消费）。兼容旧版明文码与新 zlib 码。"""
    code = code.strip()
    if code.startswith("z"):
        raw = zlib.decompress(base64.urlsafe_b64decode(code[1:] + "=" * (-len(code[1:]) % 4)))
        return json.loads(raw.decode("utf-8"))
    return json.loads(base64.urlsafe_b64decode(code + "=" * (-len(code) % 4)).decode("utf-8"))


def export_link():
    """「导出配置」（P-47/P-53/P-61 三形态）：海报卡（QR+配置摘要一体）优先，
    海报失败回退纯 QR，zlib 载荷超 QR 容量 → 文本码（复制粘贴导入）。"""
    try:
        p = apply_trcfg.export_payload(USER_CONFIG)
    except Exception as err:
        return f"❌ 导出失败: {err.__class__.__name__}: {err}"
    if not (p.get("freq") or p.get("cfg")):
        return "📭 当前是默认配置，无需导出——发「帮助」即可拿到配置卡，打开即从头勾选"
    code = trcfg_code(p)
    link = f"https://geekkkk.com/trcfg#c={code}"
    if len(link.encode("utf-8")) > QR_CONTENT_MAX:
        # 超大配置回退：zlib 文本码（复制 → 页面导入框粘贴，导入即回填不清空）
        return ("📋 你的词表较大，二维码放不下，改用配置码：\n"
                "👇 复制下面整串，在配置页（geekkkk.com/trcfg）的「导入」框粘贴——导入会恢复你的全部配置，不会清空\n"
                f"TRCFG1z:{code}")
    groups, blocked, sources = _poster_summary()
    b64 = _poster_compose(groups, blocked, sources, link, f"{p.get('ts', '')} 生成")
    text = ("📋 配置卡这就来——微信长按识别二维码即可打开你的配置页\n"
            "（改完点「生成配置码」→ 微信发回即生效）")
    if b64:
        return text, None, [b64]
    return text, link, None


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
        if rest.startswith("TRCFG1z:"):
            payload = parse_trcfg_code(rest[len("TRCFG1z:"):])  # zlib 码（P-53 超大配置回退路径）
        else:
            raw = base64.urlsafe_b64decode(rest + "=" * (-len(rest) % 4))
            payload = json.loads(raw.decode("utf-8"))
    except (binascii.Error, UnicodeDecodeError, json.JSONDecodeError, zlib.error, ValueError) as err:
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
    if text.startswith("TRCFG1z:"):
        return handle_payload(text)  # zlib 码（P-53 超大配置回退），handle_payload 内部再剥前缀
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
    if t in ("测试ai", "测试"):
        return cmd_test_ai()
    if t in ("删除ai配置", "关闭ai"):
        return cmd_del_ai()
    if t.startswith("加触发词"):
        return cmd_trigger_add(t[len("加触发词"):])
    if t.startswith("删触发词"):
        return cmd_trigger_del(t[len("删触发词"):])
    if t in ("触发词", "触发词列表"):
        return cmd_trigger_list()
    if t in pull_triggers() or t == "立即推送":
        return trigger_fetch(preview=apply_trcfg.has_keywords(USER_CONFIG))
    if t in ("绑定", "开始", "start"):
        return welcome_text()  # P-64：绑定欢迎语=菜单+状态+海报卡（放在触发词之后：自定义触发词「绑定」拉取意图优先）
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
        qr = None
        imgs = None
        if isinstance(out, tuple):
            if len(out) == 3:
                out, qr, imgs = out  # (文本, QR内容, 海报图) 三形态——P-61 海报卡经桥 images 契约
            else:
                out, qr = out  # (文本, QR内容) 旧双形态兼容
        try:
            reply(out, qr_content=qr, images=imgs)
            media = f" + 海报x{len(imgs)}" if imgs else (" + QR" if qr else "")
            log(f"[handler] 已回复 ({len(out)} 字符{media})")
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
      ok "管家已上线"
    else
      warn "管家未就绪（不影响推送本体；查看: journalctl -u tr2w-handler -n 20）"
    fi
    # P-64㊁（v0.9.2）：桥启动安排在管家就绪之后——读者按摘要发「绑定」时管家必然已在位，
    # 首绑欢迎语不再撞启动竞态；「绑定后教什么」的引导全归微信端欢迎语（P-63 重开边界）
    if [ "$BRIDGE_OK" = "1" ]; then
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
      echo "         bot 会话可在微信通讯录里找到（授权时创建）；收到「✅ 绑定成功」回执后即可使用"
    else
      echo "       ▶ 微信授权尚未完成，在服务器终端补做（复制整段执行）:"
      echo "         cd $A2W_SRC && BRIDGE_DATA_DIR=$A2W_DATA node bin/login.mjs"
      echo "         授权成功后，在微信里给 bot 发任意一条消息（如「绑定」）即完成绑定"
    fi
      echo "       ▶ 桥日志: journalctl -u any2wechat -f"
      echo "       💬 绑定后的一切指令与配置引导，bot 会以欢迎语送达微信（P-63 边界：SSH 只教到发绑定）"
elif [ -n "$CHANNELS" ]; then
  echo "    📱 已配置推送:$CHANNELS"
else
  echo "    📱 尚未配置手机推送。推荐微信个人号直推（最简单，零注册）:"
  echo "       bash install-trendradar.sh --wechat-bridge --no-web"
  echo "       （也支持 --wework / --feishu / --dingtalk / --telegram 'BotToken:ChatID'）"
fi
echo "    📖 可视化配置: geekkkk.com/trcfg （浏览器打开，粘贴配置码即可视化编辑）｜进阶: docs/config-guide.md"
echo "    🔧 查看抓取日志: journalctl -u trendradar-fetch -n 50   （跟踪 -f）"
if [ "$WECHAT_BRIDGE" = "1" ] && [ "$TIMER_OPTIN" != "1" ]; then
  echo "    ⏰ 抓取模式:     拉取式——微信发「推送 / 获取 / 新闻」即抓即推（--enable-timer 可启用 30 分钟定时）"
else
  echo "    ⏰ 定时任务:     systemctl list-timers trendradar-fetch*"
fi
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

# P-63 绑定行动卡（A 方案；2026-11-08 重开收边=方案 b）：全场最后一块输出。SSH 端义务
# 止于「强烈提醒发绑定」；绑定之后的一切交互引导归微信端欢迎语（P-64），摘要不再教发推送/指令。
if [ "$WECHAT_BRIDGE" = "1" ] && [ "$BRIDGE_OK" = "1" ] && [ "$BRIDGE_AUTHED" = "1" ]; then
  echo ""
  echo "  ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [ -f "$A2W_DATA/session.json" ]; then
    echo "  ┃  ✅ 微信已绑定"
  else
    echo "  ┃  📱 最后一步：打开微信 → 通讯录找 bot → 发「绑定」"
  fi
  echo "  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi
