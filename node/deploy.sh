#!/usr/bin/env bash
# tx-node 部署与运维脚本
#
# 交互模式（进运维面板，推荐）:
#   bash deploy.sh
#   或装好后随时: txnode        （软链到 /usr/local/bin/txnode）
#
# 非交互模式（保持向后兼容，可用于自动化）:
#   bash deploy.sh install            交互式安装 / 重装
#   bash deploy.sh install --mode machine --panel-url https://panel.example.com --machine-id 1 --token TOKEN
#   bash deploy.sh upgrade            升级
#   bash deploy.sh status             查看状态
#   bash deploy.sh start|stop|restart 启动 / 停止 / 重启
#   bash deploy.sh logs               查看日志
#   bash deploy.sh reconfigure        重新配置
#   bash deploy.sh uninstall          卸载（保留配置）
#   bash deploy.sh purge              彻底清除（含配置与镜像）
#   bash deploy.sh help
#
# 一键在线执行:
#   bash <(curl -fsSL https://raw.githubusercontent.com/ANRCM0/TX-Node-Installer/main/deploy.sh)
set -euo pipefail

# ════════════════════════════════════════════════════════════════════
#  常量
# ════════════════════════════════════════════════════════════════════
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

APP_NAME="${APP_NAME:-tx-node}"
# txnode 自己的安装目录，与 install.sh 的 /etc/xboard-node **完全分离**，
# 两套部署可以并存、互不干扰（见 LEGACY_INSTALL_ROOT）。
# 可用环境变量覆盖（自定义布局 / 多实例 / 测试）。
INSTALL_DIR="${INSTALL_DIR:-/etc/txnode}"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
CONFIG_FILE="$INSTALL_DIR/config.yml"
# Canonical container config target. The legacy target is read only when
# repairing already-generated Compose files during the compatibility window.
CONTAINER_CONFIG_FILE="/etc/txnode/config.yml"
LEGACY_CONTAINER_CONFIG_FILE="/etc/xboard-node/config.yml"
BACKUP_DIR="$INSTALL_DIR/backups"
# Persist default kernel.config_dir (/etc/txnode) independently of the read-only YAML mount.
DATA_DIR="$INSTALL_DIR/data"
DATA_CONTAINER_DIR="/etc/txnode"
IMAGE="${IMAGE:-ghcr.io/anrcm0/tx-node:latest}"
CLI_LINK="${CLI_LINK:-/usr/local/bin/txnode}"
TXNODE_HEALTH_PORT="${TXNODE_HEALTH_PORT:-}"
ISOLATED_ROOT_BASE="${TXNODE_ISOLATED_ROOT_BASE:-/etc/txnode}"
ISOLATED_CLI_BASE="${TXNODE_ISOLATED_CLI_BASE:-/usr/local/bin/txnode}"
# 自身路径：优先用 BASH_SOURCE 推导，取不到就退化为当前目录下的文件名。
# 不用 $(dirname ...)：某些精简环境（容器 / busybox）没有 dirname，会导致 set -e 直接中止。
SELF_PATH=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  _self_dir="${BASH_SOURCE[0]%/*}"
  [ "$_self_dir" = "${BASH_SOURCE[0]}" ] && _self_dir="."
  SELF_PATH="$(cd "$_self_dir" 2>/dev/null && pwd)/${BASH_SOURCE[0]##*/}"
fi
[ -z "$SELF_PATH" ] && SELF_PATH="$0"
unset _self_dir

# install.sh（systemd / 非 docker 部署）的布局。这些路径只用于**探测与导入**，
# txnode 自己的文件一律不写进这里。
LEGACY_INSTALL_ROOT="${LEGACY_INSTALL_ROOT:-/etc/xboard-node}"
LEGACY_CONFIG_FILE="$LEGACY_INSTALL_ROOT/config.yml"
LEGACY_CREDENTIALS_FILE="$LEGACY_INSTALL_ROOT/credentials.env"
LEGACY_META_FILE="$LEGACY_INSTALL_ROOT/install-meta.json"
SERVICE_NAME="xboard-node.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
SB_BINARY="/usr/local/bin/xboard-node"
XBCTL_PATH="/usr/local/bin/xbctl"
XBCTL_COMPAT_PATH="${XBCTL_COMPAT_PATH:-/usr/bin/xbctl}"
# 本脚本的持久化副本（快捷命令 txnode 应该指向这里，而不是 $SELF_PATH）
SELF_COPY="$INSTALL_DIR/deploy.sh"
# 网络兜底：$SELF_PATH 不可靠时从这里重新拉一份脚本
# 公开安装脚本分发仓库。生产机器只从这里获取 deploy.sh，
# 运行时镜像则从公开 GHCR 拉取，因此不依赖 TX-Node 源码仓库可见性。
TXNODE_INSTALLER_REPO="${TXNODE_INSTALLER_REPO:-ANRCM0/TX-Node-Installer}"
SCRIPT_RAW_URL="${SCRIPT_RAW_URL:-https://raw.githubusercontent.com/${TXNODE_INSTALLER_REPO}/main/deploy.sh}"

# Machine Runtime Update v1 bridge. TX-Node receives a typed control-plane
# request and writes only a bounded request file into this bind-mounted
# directory. Host-side systemd delegates the actual upgrade back to this
# Installer runtime; the container never receives the Docker socket.
REMOTE_UPDATE_DIR="${REMOTE_UPDATE_DIR:-$INSTALL_DIR/remote-update}"
REMOTE_UPDATE_REQUEST="$REMOTE_UPDATE_DIR/request.env"
REMOTE_UPDATE_STATUS="$REMOTE_UPDATE_DIR/status.env"
REMOTE_UPDATE_CAPABILITIES="$REMOTE_UPDATE_DIR/capabilities.env"
REMOTE_UPDATE_CONTAINER_DIR="/run/txnode-update"
REMOTE_UPDATE_IMAGE_PREFIX="ghcr.io/anrcm0/tx-node"


# 运行模式：docker | legacy | none，由 detect_deploy_mode 填充
DEPLOY_MODE=""

# ════════════════════════════════════════════════════════════════════
#  输出helpers
# ════════════════════════════════════════════════════════════════════
info()  { echo -e "${CYAN}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
fail()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
hint()  { echo -e "${DIM}    $*${NC}"; }

hr() { echo -e "${DIM}────────────────────────────────────────────────────${NC}"; }

title() {
  echo
  echo -e "${BOLD}${BLUE}  $*${NC}"
  hr
}

# 暂停等回车（用于让用户看清日志）
pause() {
  echo
  read -r -p "$(echo -e "${DIM}按回车返回菜单...${NC}")" _ || true
}

confirm() { # confirm <prompt> <default Y|n>
  local prompt="$1" default="${2:-Y}" reply
  if [ "$default" = "Y" ]; then prompt="$prompt [Y/n] "; else prompt="$prompt [y/N] "; fi
  read -r -p "$prompt" reply || true
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy]$ ]]
}

# 危险操作：要求用户手动输入指定单词，避免手滑回车
confirm_typed() { # confirm_typed <提示> <需输入的单词>
  local prompt="$1" word="$2" reply
  echo -e "${RED}${BOLD}  此操作不可逆！${NC}"
  read -r -p "  请输入 ${BOLD}${word}${NC} 确认，其他任意输入取消: " reply || true
  [ "$reply" = "$word" ]
}

# ════════════════════════════════════════════════════════════════════
#  部署模式探测
# ════════════════════════════════════════════════════════════════════
docker_available() {
  command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1
}

detect_deploy_mode() {
  # docker 优先：compose 文件存在，或容器存在（这是 txnode 自己的部署）
  if command -v docker >/dev/null 2>&1; then
    if [ -f "$COMPOSE_FILE" ] || docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$APP_NAME"; then
      DEPLOY_MODE="docker"
      return
    fi
  fi
  # legacy = install.sh 装的 systemd 非 docker 部署。
  # 注意这不是"本脚本的部署"，只是**可以被导入**的来源（见 migrate 相关函数）。
  if detect_legacy_install; then
    DEPLOY_MODE="legacy"
    return
  fi
  DEPLOY_MODE="none"
}

# 是否存在 install.sh 部署（systemd 单元 / 二进制 / 配置目录任一存在即算）
detect_legacy_install() {
  [ -f "$SERVICE_PATH" ] || [ -x "$SB_BINARY" ] || [ -f "$LEGACY_CONFIG_FILE" ]
}

# 是否是一个"完整"的 install.sh 部署（三件套齐全，可安全导入）
# 只存在配置目录但没二进制/服务，通常是被手工清理过的残留，导入前要提醒用户。
legacy_install_completeness() { # 输出 full | partial | none
  local n=0
  [ -f "$LEGACY_CONFIG_FILE" ] && n=$((n+1))
  [ -x "$SB_BINARY" ] && n=$((n+1))
  [ -f "$SERVICE_PATH" ] && n=$((n+1))
  case "$n" in
    0) echo "none" ;;
    3) echo "full" ;;
    *) echo "partial" ;;
  esac
}

is_installed() { [ "$DEPLOY_MODE" = "docker" ]; }

# txnode 未部署时的统一提示：若发现 install.sh 部署，引导用户去导入而不是干瞪眼。
# 用法：legacy_hint_or_fail <动作名>
legacy_hint_or_fail() {
  local action="${1:-操作}"
  if detect_legacy_install; then
    fail "txnode 未部署，无法${action}。检测到 install.sh 部署 —— 请用「从 install.sh 导入」把它转成 docker 部署"
  fi
  fail "未检测到已部署的 txnode，请先安装"
}

# ════════════════════════════════════════════════════════════════════
#  docker 侧封装
# ════════════════════════════════════════════════════════════════════
dc() { docker compose -f "$COMPOSE_FILE" "$@"; }

container_state() { # 输出 running | exited | created | absent
  if ! command -v docker >/dev/null 2>&1; then echo "absent"; return; fi
  local st
  st=$(docker inspect -f '{{.State.Status}}' "$APP_NAME" 2>/dev/null || echo "absent")
  echo "${st:-absent}"
}

# 清掉占用 $APP_NAME 这个名字的容器，让 compose 能干净地重建。
#
# 为什么需要它：`docker compose up -d` 靠 com.docker.compose.project/service
# 标签识别「自己的旧容器」。若同名容器是**手工 docker run 创建**的，或来自
# 别的 project 路径（换了 INSTALL_DIR），compose 认不出来 → 直接报
#   Conflict. The container name "/tx-node" is already in use
# 于是升级失败。这里先按名字兜底清理，再交给 compose。
#
# 返回 0 = 目标名已可用（或本来就没占用）；非 0 = 清理失败
reset_container() {
  if ! command -v docker >/dev/null 2>&1; then return 0; fi
  # 该名字下不存在的容器 → 无事可做
  if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$APP_NAME"; then
    return 0
  fi

  # 先让 compose 自己收（正常路径：它认得这个容器），失败再按名字强删
  if dc down --remove-orphans >/dev/null 2>&1; then
    if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$APP_NAME"; then
      return 0
    fi
  fi

  warn "容器 $APP_NAME 已存在但不属于当前 compose 项目（可能是手工 docker run 或换过安装目录），强制移除"
  docker rm -f "$APP_NAME" >/dev/null 2>&1 || {
    warn "移除容器 $APP_NAME 失败，请手动执行: docker rm -f $APP_NAME"
    return 1
  }
  ok "已移除旧容器 $APP_NAME"
  return 0
}

# ════════════════════════════════════════════════════════════════════
#  install.sh（legacy systemd）侧封装
#  仅用于查看来源部署的状态 / 停止它，txnode 不写这里的任何文件。
# ════════════════════════════════════════════════════════════════════
svc_state() { # 输出 active | inactive | failed | absent
  if [ ! -f "$SERVICE_PATH" ]; then echo "absent"; return; fi
  systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo "inactive"
}

svc_ctrl() { # svc_ctrl start|stop|restart|enable|disable
  local action="$1"
  if [ ! -f "$SERVICE_PATH" ]; then
    fail "未找到 systemd 服务 ${SERVICE_NAME}"
  fi
  case "$action" in
    start)   systemctl start   "$SERVICE_NAME" ;;
    stop)    systemctl stop    "$SERVICE_NAME" ;;
    restart) systemctl restart "$SERVICE_NAME" ;;
    enable)  systemctl enable  "$SERVICE_NAME" ;;
    disable) systemctl disable "$SERVICE_NAME" ;;
  esac
}

# 统一的日志查看（自动分派 docker / legacy systemd）
show_logs() { # show_logs <tail行数|空=跟随>
  local n="${1:-}"
  # 自行探测：允许单独调用（例如 `deploy.sh logs` 已在 main 里探测，但函数内再保险一次）
  [ -n "$DEPLOY_MODE" ] || detect_deploy_mode
  case "$DEPLOY_MODE" in
    docker)
      if [ -n "$n" ]; then
        docker logs --tail "$n" "$APP_NAME" 2>&1 || true
      else
        info "实时日志（Ctrl+C 退出）"
        docker logs -f "$APP_NAME" 2>&1 || true
      fi
      ;;
    legacy)
      hint "以下是 install.sh 部署（${SERVICE_NAME}）的日志"
      if [ -n "$n" ]; then
        journalctl -u "$SERVICE_NAME" -n "$n" --no-pager 2>&1 || true
      else
        info "实时日志（Ctrl+C 退出）"
        journalctl -u "$SERVICE_NAME" -f --no-pager 2>&1 || true
      fi
      ;;
    *) warn "未检测到部署，无法查看日志" ;;
  esac
}

# ════════════════════════════════════════════════════════════════════
#  配置解析（不依赖 yq：用 grep 提取顶层简单字段）
# ════════════════════════════════════════════════════════════════════
cfg_get() { # cfg_get <key> —— 返回配置里第一个匹配的 key 值（去引号）
  local key="$1"
  [ -f "$CONFIG_FILE" ] || return 1
  local val
  val=$(grep -m1 -E "^[[:space:]]*${key}:" "$CONFIG_FILE" 2>/dev/null \
        | sed -E "s/^[[:space:]]*${key}:[[:space:]]*//; s/^[\"']//; s/[\"'][[:space:]]*$//; s/[[:space:]]*#.*$//" \
        | tr -d '\r')
  [ -n "$val" ] && echo "$val"
}

# 区段感知取值：_sec_get <段名> <键名> —— 只在指定顶层段内查找该键。
# 比全局 cfg_get 精确，能区分 panel.token 与 machine.token、machine.machine_id 与 nodes[].node_id。
# 支持：内联注释、单双引号、CRLF、段内多级缩进。
_sec_get() {
  local sec="$1" key="$2"
  [ -f "$CONFIG_FILE" ] || return 1
  local val
  val=$(awk -v sec="$sec" -v key="$key" '
    BEGIN { insec = 0 }
    /^[^[:space:]#]/ {
      # 顶层键：形如 "name:" 或 "name: value"；只认完全匹配的段名
      if ($0 ~ ("^" sec "[[:space:]]*:")) { insec = 1; next }
      insec = 0
    }
    insec && $0 ~ ("^[[:space:]]+" key "[[:space:]]*:") {
      sub("^[[:space:]]+" key "[[:space:]]*:[[:space:]]*", "")
      sub(/[[:space:]]*#.*$/, "")
      gsub(/^["'"'"']|["'"'"'][[:space:]]*$/, "")
      print
      exit
    }
  ' "$CONFIG_FILE" 2>/dev/null | tr -d '\r')
  [ -n "$val" ] && echo "$val"
}

# 读出所有顶层段名（每行一个），用于判断配置里到底配了什么
_top_sections() {
  [ -f "$CONFIG_FILE" ] || return 0
  awk '/^[^[:space:]#]/ { sub(/[[:space:]]*:.*$/, ""); if ($0 != "") print }' "$CONFIG_FILE" 2>/dev/null | tr -d '\r'
}

# 判断配置里是否存在某个顶层段
_has_section() {
  _top_sections | grep -qx "$1" 2>/dev/null
}

# 备份现有配置
backup_config() {
  [ -f "$CONFIG_FILE" ] || return 0
  mkdir -p "$BACKUP_DIR"
  local dest="$BACKUP_DIR/config.yml.$(date +%Y%m%d-%H%M%S)"
  cp -a "$CONFIG_FILE" "$dest"
  chmod 600 "$dest" 2>/dev/null || true
  ok "旧配置已备份 → $dest"
}

# ════════════════════════════════════════════════════════════════════
#  install.sh 部署的读取与解析（只读，绝不写入 LEGACY_INSTALL_ROOT）
#
#  install.sh 的 config.yml 是**多实例**结构：
#      instances:
#        - id: node-8f3a1c2e
#          panel:   { url, node_id, node_type, token_env }
#          machine: { machine_id, token_env }
#          kernel:  { type, config_dir }
#          health_port: 65530
#  密钥不落盘在 config.yml 里，而是 token_env 指向 credentials.env 中的变量名
#  （形如 INSTANCE_NODE_8F3A1C2E_API_KEY / ..._MACHINE_TOKEN），
#  由 systemd 的 EnvironmentFile 注入。所以导入时必须把 token_env 解析成真实值。
# ════════════════════════════════════════════════════════════════════

# 从 install-meta.json 取一个简单 key 的值（无 jq / python 依赖）
_meta_get() {
  local key="$1"
  [ -f "$LEGACY_META_FILE" ] || return 1
  local val
  val=$(sed -n "s/.*\"${key}\": *\"\{0,1\}\([^\"]*\)\"\{0,1\}.*/\1/p" "$LEGACY_META_FILE" 2>/dev/null | head -1 | tr -d '\r')
  val="${val%,}"
  [ -n "$val" ] && echo "$val"
}

# 从 credentials.env（KEY=VALUE / export KEY=VALUE）取一个变量的值
_cred_get() {
  local key="$1"
  [ -f "$LEGACY_CREDENTIALS_FILE" ] || return 1
  [ -n "$key" ] || return 1
  local val
  val=$(sed -n "s/^[[:space:]]*\(export[[:space:]]\+\)\{0,1\}${key}[[:space:]]*=[[:space:]]*//p" \
        "$LEGACY_CREDENTIALS_FILE" 2>/dev/null | head -1 | tr -d '\r')
  # 去成对的引号
  val="${val%\"}"; val="${val#\"}"
  val="${val%\'}"; val="${val#\'}"
  [ -n "$val" ] && echo "$val"
}

# 读取 install.sh config.yml 里的实例列表。
# 输出：每行一个实例，字段以 \x1f (US) 分隔，便于在 shell 里安全切分：
#   idx|id|mode|panel_url|node_id|machine_id|node_type|kernel|health_port|token_env|config_dir
# mode = node | machine
legacy_list_instances() {
  [ -f "$LEGACY_CONFIG_FILE" ] || return 1
  awk '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    function unq(s)  { gsub(/^["'"'"']|["'"'"']$/, "", s); return s }
    function out() {
      if (idx == 0) return
      printf "%d\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n", \
        idx, id, mode, url, nid, mid, ntype, kern, hp, tenv, cdir
    }

    BEGIN { idx = 0; inf = 0; inpan = 0; inmac = 0; inker = 0 }

    /^[^[:space:]#]/ {
      # 顶层键：离开 instances 段
      if ($0 !~ /^instances[[:space:]]*:/) { inf = 0 }
    }

    /^instances[[:space:]]*:/ { inf = 1; next }
    !inf { next }

    # 新实例起始：  - id: xxx   或   - panel:
    /^[[:space:]]*-[[:space:]]*/ {
      out()
      idx++
      id=""; mode="node"; url=""; nid=""; mid=""; ntype=""; kern=""; hp=""; tenv=""; cdir=""
      inpan=0; inmac=0; inker=0
      rest = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", rest)
      if (rest ~ /^id[[:space:]]*:/) {
        sub(/^id[[:space:]]*:[[:space:]]*/, "", rest); id = unq(trim(rest))
      }
      if (rest ~ /^panel[[:space:]]*:/)   inpan = 1
      if (rest ~ /^machine[[:space:]]*:/) { inmac = 1; mode = "machine" }
      if (rest ~ /^kernel[[:space:]]*:/)  inker = 1
      next
    }

    # 子段切换（同一实例内）
    /^[[:space:]]+panel[[:space:]]*:/   { inpan=1; inmac=0; inker=0; next }
    /^[[:space:]]+machine[[:space:]]*:/ { inmac=1; inpan=0; inker=0; mode="machine"; next }
    /^[[:space:]]+kernel[[:space:]]*:/  { inker=1; inpan=0; inmac=0; next }
    /^[[:space:]]+(node|log|ws|runtime|cert|standalone|audit|nodes)[[:space:]]*:/ {
      inpan=0; inmac=0; inker=0; next
    }

    # 键值
    {
      line = $0
      key = line; sub(/[[:space:]]*:.*$/, "", key); key = trim(key)
      val = line; sub(/^[^:]*:[[:space:]]*/, "", val)
      sub(/[[:space:]]*#.*$/, "", val); val = unq(trim(val))
      if (key == "") next
      if (inpan) {
        if (key=="url")        url = val
        else if (key=="node_id")    nid = val
        else if (key=="node_type")  ntype = val
        else if (key=="token_env")  tenv = val
      } else if (inmac) {
        if (key=="machine_id")      mid = val
        else if (key=="token_env")  tenv = val
      } else if (inker) {
        if (key=="type")       kern = val
        else if (key=="config_dir") cdir = val
      } else if (key=="health_port") {
        hp = val
      }
    }

    END { out() }
  ' "$LEGACY_CONFIG_FILE"
}

# 把一行实例记录拆到全局变量，供调用方使用
# 用法: legacy_parse_row "$row"; 之后读 LEG_* 变量
legacy_parse_row() {
  local row="$1"
  LEG_IDX=""; LEG_ID=""; LEG_MODE=""; LEG_URL=""; LEG_NID=""; LEG_MID=""
  LEG_NTYPE=""; LEG_KERN=""; LEG_HP=""; LEG_TENV=""; LEG_CDIR=""
  IFS=$'\037' read -r LEG_IDX LEG_ID LEG_MODE LEG_URL LEG_NID LEG_MID \
                     LEG_NTYPE LEG_KERN LEG_HP LEG_TENV LEG_CDIR <<EOF
$row
EOF
  LEG_KERN="${LEG_KERN:-singbox}"
}

# 解析某实例的真实 token：优先 token_env → credentials.env，退化到同名 env
legacy_resolve_token() { # legacy_resolve_token <token_env> [direct_token]
  local tenv="$1" direct="${2:-}"
  if [ -n "$direct" ]; then echo "$direct"; return 0; fi
  [ -n "$tenv" ] || return 1
  local v
  v=$(_cred_get "$tenv" || true)
  if [ -z "$v" ]; then
    # 退化：可能已经 export 在环境里
    eval "v=\${$tenv:-}"
  fi
  [ -n "$v" ] && echo "$v"
}

# 汇总：打印 install.sh 部署的概览（供菜单/交互确认用）
legacy_summary() {
  local rows; rows=$(legacy_list_instances || true)
  if [ -z "$rows" ]; then
    warn "未能从 $LEGACY_CONFIG_FILE 解析出任何实例"
    [ -f "$LEGACY_CONFIG_FILE" ] || hint "config.yml 不存在"
    return 1
  fi
  local n=0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    n=$((n+1))
    legacy_parse_row "$row"
    local label="node_id=${LEG_NID}"
    [ "$LEG_MODE" = "machine" ] && label="machine_id=${LEG_MID}"
    local tok_state="${RED}缺失${NC}"
    if legacy_resolve_token "$LEG_TENV" >/dev/null 2>&1; then tok_state="${GREEN}已解析${NC}"; fi
    echo -e "   ${BOLD}${n})${NC} ${LEG_ID:-<无 id>}  ${DIM}${LEG_MODE}${NC}  ${LEG_URL}  ${label}  kernel=${LEG_KERN}  token:${tok_state}"
    [ -n "$LEG_CDIR" ] && hint "config_dir: $LEG_CDIR"
  done <<EOF
$rows
EOF
  echo
  echo -e "   ${DIM}共 $n 个实例${NC}"
  return 0
}

# ════════════════════════════════════════════════════════════════════
#  install.sh → docker 的配置合并
#
#  目标：把 install.sh 的「instances 列表」映射成 txnode 的单份 config.yml。
#  映射规则（受限于 txnode 配置模型的表达能力）：
#
#    同一 panel.url 下的多个 node 实例
#        → panel: { url, token }  +  nodes: [ {node_id, node_type, kernel...}, ... ]
#        注意 txnode 多节点模式**所有节点共享同一个 panel.token**。
#        若这些实例的 token 实际不同，说明它们分属不同面板凭据，无法合并，
#        必须让用户挑一个（否则会静默丢掉一部分节点）。
#
#    machine 实例
#        → panel: { url } + machine: { machine_id, token }
#        machine 与 nodes **互斥**（Go 侧 validate 强制），二选一。
#
#    多个不同 panel.url / 不同 machine_id
#        → 单份 config.yml 无法表达 → 列出候选让用户选一个导入。
#
#  提取阶段只往内存里填 MIG_* 变量，确认后才落盘，失败可原地回滚。
# ════════════════════════════════════════════════════════════════════

# 收集候选：把 legacy 实例按「可合并组」归并
# 输出：每行一个候选组，"kind|key|label|count"，kind = node | machine
mig_collect_candidates() {
  local rows; rows=$(legacy_list_instances || true)
  [ -n "$rows" ] || return 1

  # 用关联数组把 node 按 "url" 分组、machine 按 "url|machine_id" 分组
  declare -A g_count=() g_label=() g_token=() g_token_mix=()
  local order=()
  local row
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    legacy_parse_row "$row"
    [ -n "$LEG_URL" ] || continue
    local tok; tok=$(legacy_resolve_token "$LEG_TENV" || true)
    if [ "$LEG_MODE" = "machine" ]; then
      local k="machine|${LEG_URL}|${LEG_MID}"
      if [ -z "${g_count[$k]:-}" ]; then
        order+=("$k"); g_label[$k]="${LEG_URL} · machine_id=${LEG_MID}"; g_token[$k]="$tok"
      fi
      g_count[$k]=$(( ${g_count[$k]:-0} + 1 ))
    else
      local k="node|${LEG_URL}|"
      if [ -z "${g_count[$k]:-}" ]; then
        order+=("$k"); g_label[$k]="${LEG_URL}"; g_token[$k]="$tok"
      elif [ -n "$tok" ] && [ -n "${g_token[$k]:-}" ] && [ "$tok" != "${g_token[$k]}" ]; then
        # 同 URL 但 token 不同 → 标记为不可合并
        g_token_mix[$k]=1
      fi
      g_count[$k]=$(( ${g_count[$k]:-0} + 1 ))
    fi
  done <<EOF
$rows
EOF

  local k
  for k in ${order[@]+"${order[@]}"}; do
    local kind="${k%%|*}"
    # mix 是独立字段，不要粘在 count 上（否则消费方按字段切分会读错 count）
    local mix=""; [ -n "${g_token_mix[$k]:-}" ] && mix="MIX"
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
      "$kind" "$k" "${g_label[$k]}" "${g_count[$k]}" "$mix"
  done
}

# 载入一个候选组的实例明细到 MIG_ITEMS 数组（每项为原始 row）
# 用法: mig_load_group <key>
mig_load_group() {
  local want="$1"
  MIG_ITEMS=()
  local rows; rows=$(legacy_list_instances || true)
  local row
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    legacy_parse_row "$row"
    [ -n "$LEG_URL" ] || continue
    local k
    if [ "$LEG_MODE" = "machine" ]; then
      k="machine|${LEG_URL}|${LEG_MID}"
    else
      k="node|${LEG_URL}|"
    fi
    [ "$k" = "$want" ] && MIG_ITEMS+=("$row")
  done <<EOF
$rows
EOF
  [ ${#MIG_ITEMS[@]} -gt 0 ]
}

# 交互式选组：把候选列出来让用户挑一个
# 用法: mig_pick_group <变量名>   → 选中后把 key 写入该变量
mig_pick_group() {
  local __out="$1"
  local cands; cands=$(mig_collect_candidates || true)
  if [ -z "$cands" ]; then
    fail "未能从 install.sh 配置解析出任何可用实例，无法导入"
  fi

  local items=()
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    items+=("$line")
  done <<EOF
$cands
EOF

  local n=${#items[@]}
  title "install.sh 部署中可导入的配置"
  echo
  local i=0
  while [ "$i" -lt "$n" ]; do
    # ⚠️ 字段变量一律加前缀：本函数靠 printf -v 回传 key，
    #    任何叫 key 的 local 都会把回传目标劫持成局部变量（见下方 n -eq 1 分支注释）。
    local d_kind d_key d_label d_count d_mix
    IFS=$'\037' read -r d_kind d_key d_label d_count d_mix <<EOF
${items[$i]}
EOF
    local kind_txt="节点"
    [ "$d_kind" = "machine" ] && kind_txt="机器"
    local warn_txt=""
    [ "${d_mix:-}" = "MIX" ] && warn_txt="  ${RED}⚠ 组内 token 不一致，无法合并${NC}"
    echo -e "   ${BOLD}$((i+1))${NC}) [${kind_txt}] ${d_label}  ${DIM}${d_count} 个实例${NC}${warn_txt}"
    i=$((i+1))
  done
  echo
  echo -e "   ${DIM}注：单份 config.yml 只能承载一组（多节点要求同一面板同一 token；机器与节点模式互斥）${NC}"
  echo

  if [ "$n" -eq 1 ]; then
    # 只有一个候选，直接确认。
    # ⚠️ 这里的字段变量必须加前缀（cf_*），不能叫 key：调用方是用
    #    `local key; mig_pick_group key` 的形式回传的，而 printf -v "$__out"
    #    解析的是**本函数作用域**里的同名变量。一旦此处 local 出 `key`，
    #    printf -v 就会写进这个局部变量、函数返回即销毁，调用方的 key
    #    仍是未赋值 —— 在 set -u 下直接 "key: unbound variable"。
    local cf_kind2 cf_key cf_label cf_count cf_mix
    IFS=$'\037' read -r cf_kind2 cf_key cf_label cf_count cf_mix <<EOF
${items[0]}
EOF
    if [ "${cf_mix:-}" = "MIX" ]; then
      fail "唯一的候选组内部 token 不一致，无法自动合并。请先在 install.sh 部署里统一 token，或手工迁移"
    fi
    if ! confirm "只有一组可导入（${cf_label:-}），用它转换？" "Y"; then
      info "已取消"
      return 1
    fi
    printf -v "$__out" '%s' "$cf_key"
    return 0
  fi

  local sel
  read -r -p "  请选择要导入的一组 [1-$n] (0=取消): " sel || fail "输入中断，已取消"
  sel="${sel//[[:space:]]/}"
  [ "$sel" = "0" ] && { info "已取消"; return 1; }
  [[ "$sel" =~ ^[0-9]+$ ]] || fail "请输入数字"
  [ "$sel" -ge 1 ] && [ "$sel" -le "$n" ] || fail "序号超出范围"

  local picked="${items[$((sel-1))]}"
  local pkind pkey plabel pcount pmix
  IFS=$'\037' read -r pkind pkey plabel pcount pmix <<EOF
$picked
EOF
  if [ "${pmix:-}" = "MIX" ]; then
    fail "该组内部 token 不一致，无法自动合并。请先在 install.sh 部署里统一 token，或手工迁移"
  fi
  printf -v "$__out" '%s' "$pkey"
  return 0
}

# 把一个候选组的实例明细转成 txnode 的配置片段（填 MIG_* 变量）
# 用法: mig_build_group <key>
# 产出: MIG_MODE(node|machine) MIG_URL MIG_TOKEN MIG_MACHINE_ID
#       MIG_NODES (每个 \n 一项: node_id|node_type|kernel|config_dir)
#       MIG_KERNEL MIG_HEALTH_PORT MIG_LOG_LEVEL MIG_HAS_KCDIR
mig_build_group() {
  local key="$1"
  mig_load_group "$key" || fail "读取候选组失败"

  MIG_MODE=""; MIG_URL=""; MIG_TOKEN=""; MIG_MACHINE_ID=""
  MIG_NODES=""; MIG_KERNEL=""; MIG_HEALTH_PORT=""; MIG_LOG_LEVEL=""
  MIG_HAS_KCDIR="false"
  MIG_MISSING_TOKEN=""

  local row
  for row in ${MIG_ITEMS[@]+"${MIG_ITEMS[@]}"}; do
    legacy_parse_row "$row"
    [ -n "$MIG_URL" ] || MIG_URL="$LEG_URL"

    local tok; tok=$(legacy_resolve_token "$LEG_TENV" || true)

    if [ "$LEG_MODE" = "machine" ]; then
      MIG_MODE="machine"
      MIG_MACHINE_ID="$LEG_MID"
      MIG_TOKEN="$tok"
      [ -n "$LEG_KERN" ] && MIG_KERNEL="$LEG_KERN"
      [ -n "$LEG_HP" ] && MIG_HEALTH_PORT="$LEG_HP"
      [ -z "$tok" ] && MIG_MISSING_TOKEN="${LEG_TENV:-<无 token_env>}"
    else
      [ -n "$MIG_MODE" ] || MIG_MODE="node"
      [ -z "$MIG_TOKEN" ] && MIG_TOKEN="$tok"
      [ -z "$tok" ] && MIG_MISSING_TOKEN="${LEG_TENV:-<无 token_env>}"
      # 全局 kernel 取第一个非空值；逐个实例的差异走 per-node kernel 覆盖
      [ -z "$MIG_KERNEL" ] && [ -n "$LEG_KERN" ] && MIG_KERNEL="$LEG_KERN"
      [ -z "$MIG_HEALTH_PORT" ] && [ -n "$LEG_HP" ] && MIG_HEALTH_PORT="$LEG_HP"
      MIG_NODES="${MIG_NODES}${LEG_NID}|${LEG_NTYPE}|${LEG_KERN}|${LEG_CDIR}|${LEG_HP}
"
      [ -n "$LEG_CDIR" ] && MIG_HAS_KCDIR="true"
    fi
  done

  MIG_KERNEL="${MIG_KERNEL:-singbox}"
  MIG_LOG_LEVEL="${MIG_LOG_LEVEL:-info}"

  # 校验：机器模式必须有 machine_id + token；节点模式必须有 node_id
  if [ "$MIG_MODE" = "machine" ]; then
    [[ "$MIG_MACHINE_ID" =~ ^[0-9]+$ ]] && [ "$MIG_MACHINE_ID" -gt 0 ] \
      || fail "machine_id 无效（$MIG_MACHINE_ID），无法导入"
  else
    # 逐个检查 node_id
    local entry
    while IFS='|' read -r nid ntype nkern ncdir nhp; do
      [ -n "$nid" ] || continue
      [[ "$nid" =~ ^[0-9]+$ ]] && [ "$nid" -gt 0 ] \
        || fail "解析到无效的 node_id（$nid），无法导入"
    done <<EOF
$MIG_NODES
EOF
  fi
  return 0
}

# 渲染 config.yml（迁移用；与 write_config_files 同格式，但支持 nodes 列表）
mig_render_config() {
  local out="$1"
  {
    echo "# Generated by tx-node deploy.sh ($(date '+%Y-%m-%d %H:%M:%S'))"
    echo "# 由 install.sh 部署转换而来 —— 源: $LEGACY_CONFIG_FILE"
    echo "panel:"
    echo "  url: \"$MIG_URL\""
    if [ "$MIG_MODE" = "machine" ]; then
      echo "machine:"
      echo "  machine_id: $MIG_MACHINE_ID"
      echo "  token: \"$MIG_TOKEN\""
    else
      echo "  token: \"$MIG_TOKEN\""
      if [ "${MIG_NODES_COUNT:-0}" -le 1 ]; then
        # 单节点：用 panel.node_id 形式，最贴近 install.sh 的原始语义
        local nid ntype
        nid=$(printf '%s' "$MIG_NODES" | awk -F'|' 'NF{print $1; exit}')
        ntype=$(printf '%s' "$MIG_NODES" | awk -F'|' 'NF{print $2; exit}')
        echo "  node_id: $nid"
        [ -n "$ntype" ] && echo "  node_type: \"$ntype\""
      else
        # 多节点：nodes 列表。node_type 逐节点写（允许各节点不同）。
        echo "nodes:"
        local entry
        while IFS='|' read -r nid ntype nkern ncdir nhp; do
          [ -n "$nid" ] || continue
          echo "  - node_id: $nid"
          [ -n "$ntype" ] && echo "    node_type: \"$ntype\""
          # config_dir 逐节点写：各实例原本就是独立目录，必须保留以免相互覆盖
          if [ -n "$ncdir" ]; then
            echo "    kernel:"
            echo "      config_dir: \"$ncdir\""
          fi
        done <<EOF
$MIG_NODES
EOF
      fi
    fi
    echo
    echo "kernel:"
    echo "  type: \"$MIG_KERNEL\""
    if [ "$MIG_MODE" != "machine" ] && [ "$MIG_NODES_COUNT" = "1" ] && [ "$MIG_HAS_KCDIR" = "true" ]; then
      local ncdir
      ncdir=$(printf '%s' "$MIG_NODES" | awk -F'|' 'NF{print $4; exit}')
      [ -n "$ncdir" ] && echo "  config_dir: \"$ncdir\""
    fi
    echo
    echo "log:"
    echo "  level: \"$MIG_LOG_LEVEL\""
    echo
    echo "# tx-node 访问审计（sing-box 内核）。删除本段或 enabled: false 即关闭。"
    echo "audit:"
    echo "  enabled: false"
    echo "  report_all: false"
  } > "$out"
}

# 整合入口：迁移确认后写盘 + 启动。dry_run=1 时只打印不落盘
# 用法: mig_write_and_start <group_key> [dry_run]
mig_write_and_start() {
  local key="$1" dry="${2:-0}"
  mig_build_group "$key"

  # 统计节点数
  MIG_NODES_COUNT=0
  if [ -n "$(printf '%s' "$MIG_NODES" | tr -d '\n')" ]; then
    MIG_NODES_COUNT=$(printf '%s' "$MIG_NODES" | sed '/^$/d' | wc -l | tr -d ' ')
  fi

  echo
  title "将生成的 txnode 配置"
  echo
  echo -e "   ${DIM}模式${NC}    : $MIG_MODE"
  echo -e "   ${DIM}面板${NC}    : $MIG_URL"
  if [ "$MIG_MODE" = "machine" ]; then
    echo -e "   ${DIM}machine${NC} : id=$MIG_MACHINE_ID  token=$(_mask "$MIG_TOKEN")"
  else
    echo -e "   ${DIM}token${NC}   : $(_mask "$MIG_TOKEN")"
    echo -e "   ${DIM}节点${NC}    : $MIG_NODES_COUNT 个"
    local entry
    while IFS='|' read -r nid ntype nkern ncdir nhp; do
      [ -n "$nid" ] || continue
      echo -e "             - node_id=$nid${ntype:+  type=$ntype}${ncdir:+  ${DIM}dir=$ncdir${NC}}"
    done <<EOF
$MIG_NODES
EOF
  fi
  echo -e "   ${DIM}内核${NC}    : $MIG_KERNEL"
  echo -e "   ${DIM}安装目录${NC}: $INSTALL_DIR  ${DIM}（install.sh 的 $LEGACY_INSTALL_ROOT 不受影响）${NC}"

  if [ -n "$MIG_MISSING_TOKEN" ]; then
    echo
    warn "有实例的 token 未解析成功：$MIG_MISSING_TOKEN"
    hint "该实例可能无法正常连接面板。可继续，但建议稍后在「修改配置」里补上。"
  fi

  if [ "$dry" = "1" ]; then
    echo
    hint "[dry-run] 预览结束，未写入任何文件"
    return 0
  fi

  echo
  echo -e "${BOLD}即将执行：${NC}"
  echo "   1) 备份 install.sh 的配置到 $BACKUP_DIR（可回滚）"
  echo "   2) 写入 $CONFIG_FILE 与 $COMPOSE_FILE"
  echo "   3) 停止 ${SERVICE_NAME}（避免与 txnode 抢同一 machine_id / 同一批节点）"
  echo "   4) 拉取镜像并启动 txnode"
  echo
  echo -e "   ${DIM}若 txnode 启动失败会自动回滚（重新拉起 ${SERVICE_NAME}）。${NC}"
  echo -e "   ${DIM}install.sh 的配置不会被删除，随时可切回。${NC}"
  if ! confirm "确认转换？" "Y"; then
    info "已取消，未做任何改动"
    return 1
  fi

  DATA_DIR="$INSTALL_DIR/data"
  mkdir -p "$INSTALL_DIR" "$BACKUP_DIR" "$REMOTE_UPDATE_DIR" "$DATA_DIR"
  chmod 700 "$DATA_DIR" 2>/dev/null || true
  chmod 700 "$REMOTE_UPDATE_DIR" 2>/dev/null || true
  # 源配置快照：即使后面失败，也能从这里回滚
  local src_backup="$BACKUP_DIR/legacy-source.$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$src_backup"
  local f
  for f in "$LEGACY_CONFIG_FILE" "$LEGACY_CREDENTIALS_FILE" "$LEGACY_META_FILE"; do
    [ -f "$f" ] && cp -a "$f" "$src_backup/" 2>/dev/null || true
  done
  ok "源配置已快照 → $src_backup"

  local tmp_cfg="$INSTALL_DIR/.config.yml.migrating"
  mig_render_config "$tmp_cfg"
  chmod 600 "$tmp_cfg"
  mv -f "$tmp_cfg" "$CONFIG_FILE"
  ok "配置已写入 $CONFIG_FILE"

  cat > "$COMPOSE_FILE" <<EOF
services:
  tx-node:
    image: $IMAGE
    container_name: $APP_NAME
    restart: unless-stopped
    network_mode: host
    command: ["-c", "$CONTAINER_CONFIG_FILE"]
    volumes:
      # Default kernel.config_dir is the directory containing config.yml.
      # Persist traffic pending spool, generated certificates and kernel cache.
      - $DATA_DIR:$DATA_CONTAINER_DIR
      - $CONFIG_FILE:$CONTAINER_CONFIG_FILE:ro
      - $REMOTE_UPDATE_DIR:$REMOTE_UPDATE_CONTAINER_DIR
EOF
  ok "compose 文件已写入 $COMPOSE_FILE"

  info "拉取镜像..."
  if ! dc pull; then
    warn "镜像拉取失败，已保留写入的配置，可在面板里重试「升级」"
    return 1
  fi

  # 先停 install.sh 侧，再起 txnode：
  # machine 模式下两边会用同一个 machine_id 连面板，若同时在线，
  # 面板会看到重复的机器连接，且 txnode 若启动失败会留下"两套都在跑"的
  # 混乱状态。先停机可以把冲突窗口压到零；失败则自动回滚（重新拉起 legacy）。
  local legacy_was_active="false"
  if [ "$(svc_state)" = "active" ]; then
    legacy_was_active="true"
    info "先停止 ${SERVICE_NAME}（避免与 txnode 抢同一 machine_id / 同一批节点）"
    systemctl stop "$SERVICE_NAME" 2>/dev/null || warn "停止失败，仍继续尝试启动 txnode"
  fi

  info "启动 txnode..."
  # 清掉可能残留的同名容器（例如之前手工跑过或上次转换中断）
  if ! reset_container; then
    if [ "$legacy_was_active" = "true" ]; then
      info "回滚：重新拉起 ${SERVICE_NAME}"
      systemctl start "$SERVICE_NAME" 2>/dev/null || warn "回滚失败，请手动执行: systemctl start $SERVICE_NAME"
    fi
    fail "清理同名容器失败（配置已保留）。请手动执行: docker rm -f $APP_NAME"
  fi

  if ! dc up -d --force-recreate; then
    warn "txnode 启动命令失败"
    if [ "$legacy_was_active" = "true" ]; then
      info "回滚：重新拉起 ${SERVICE_NAME}"
      systemctl start "$SERVICE_NAME" 2>/dev/null || warn "回滚失败，请手动执行: systemctl start $SERVICE_NAME"
    fi
    fail "启动失败（配置已保留）。排查：txnode logs"
  fi

  sleep 5
  if ! docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -q "$APP_NAME.*Up"; then
    warn "容器未正常运行，最近日志："
    show_logs 20
    if [ "$legacy_was_active" = "true" ]; then
      info "回滚：重新拉起 ${SERVICE_NAME}，并停掉未健康的 txnode"
      dc down 2>/dev/null || true
      systemctl start "$SERVICE_NAME" 2>/dev/null || warn "回滚失败，请手动执行: systemctl start $SERVICE_NAME"
      warn "已回滚到 install.sh 部署。配置保留在 $CONFIG_FILE，排查后可重试。"
    else
      warn "配置已保留，未动 install.sh 侧。排查后可重试。"
    fi
    return 1
  fi
  ok "txnode 容器运行中"

  install_cli_link
  install_remote_update_bridge
  mig_finish_legacy "$legacy_was_active"
  return 0
}

# 转换成功后：确认 install.sh 侧处于停止状态（配置已在快照里，可回滚）
# 默认保留其配置，不删除 —— 用户确认「先停服务，备份后清除」
mig_finish_legacy() {
  local was_active="${1:-false}"
  echo
  title "处理 install.sh 侧"
  local sst; sst=$(svc_state)
  if [ "$sst" = "absent" ]; then
    hint "未发现 systemd 服务，跳过"
    return 0
  fi
  if [ "$sst" = "active" ]; then
    # 正常路径上前面已停过；能走到这里说明当时停止失败
    info "停止并禁用 ${SERVICE_NAME}"
    systemctl stop "$SERVICE_NAME" 2>/dev/null || warn "停止失败，请手动检查"
  fi
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  ok "${SERVICE_NAME} 已停止且不再开机自启"

  echo
  hint "install.sh 的配置（$LEGACY_INSTALL_ROOT）**保留未删**，以便随时回滚。"
  hint "如需回滚：systemctl enable --now $SERVICE_NAME && systemctl stop $APP_NAME"
  hint "确认 txnode 稳定运行后，可删除残留:"
  echo -e "   ${DIM}rm -rf $LEGACY_INSTALL_ROOT $SERVICE_PATH $SB_BINARY $XBCTL_PATH${NC}"
}

# 遮蔽 token 用于展示
_mask() {
  local v="$1"
  if [ -z "$v" ]; then echo "${RED}（空）${NC}"; return; fi
  local n=${#v}
  if [ "$n" -le 8 ]; then echo "****"; else echo "${v:0:4}****${v: -4}"; fi
}

# 完整迁移流程（面板 / CLI 共用）
# 用法: do_migrate_legacy [dry_run]
do_migrate_legacy() {
  local dry="${1:-0}"

  if ! detect_legacy_install; then
    if [ "$dry" = "1" ]; then
      fail "未检测到 install.sh 部署，无需导入"
    fi
    hint "未检测到 install.sh 部署（$LEGACY_INSTALL_ROOT / $SERVICE_NAME）"
    return 1
  fi

  local complete; complete=$(legacy_install_completeness)
  case "$complete" in
    partial)
      warn "install.sh 部署看起来**不完整**（配置 / 二进制 / systemd 单元只有部分存在）"
      hint "可能已被手工清理过。仍可尝试导入配置，但请自行确认解析结果正确。"
      confirm "继续尝试导入？" "n" || { info "已取消"; return 1; }
      ;;
    none)
      fail "既没有 config.yml，也没有服务或二进制，无法导入"
      ;;
  esac

  if [ ! -f "$LEGACY_CONFIG_FILE" ]; then
    fail "找不到 install.sh 的配置文件 $LEGACY_CONFIG_FILE，无法提取配置"
  fi

  echo
  title "install.sh 部署概览"
  echo
  legacy_summary || fail "解析失败"
  echo

  local key
  mig_pick_group key || return 1
  mig_write_and_start "$key" "$dry"
}

ensure_docker() {
  if docker_available; then
    ok "Docker 环境就绪: $(docker --version 2>/dev/null | head -1)"
    return
  fi
  warn "未检测到可用的 docker / docker compose 插件"

  # 一键安装命令不能依赖 stdin 交互；非交互模式直接执行默认的
  # 官方 Docker 安装路径。交互模式仍保留确认提示。
  if [ "${NONINTERACTIVE_INSTALL:-0}" = "1" ] || confirm "自动安装 Docker（get.docker.com 官方脚本）？" "Y"; then
    info "安装 Docker..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable --now docker 2>/dev/null || true
    docker compose version >/dev/null 2>&1 || fail "docker compose 插件不可用，请手动安装后重跑"
    ok "Docker 安装完成"
  else
    fail "请先手动安装 Docker + compose 插件后重跑本脚本"
  fi
}

# ════════════════════════════════════════════════════════════════════
#  配置向导（写 config.yml + docker-compose.yml）
# ════════════════════════════════════════════════════════════════════

# 非交互安装参数。用于 TXBoard 等控制面生成可直接复制执行的一键命令。
# 支持 machine / node 两种模式；未传任何参数时仍走原交互向导。
parse_install_args() {
  PANEL_PROVIDER="xboard"
  INSTALL_CHANNEL="stable"
  MODE_STR=""
  PANEL_URL=""
  MACHINE_ID=""
  NODE_ID=""
  MACHINE_TOKEN=""
  NODE_TOKEN=""
  KERNEL="singbox"
  LOG_LEVEL="info"
  AUDIT_ENABLED="false"
  REPORT_ALL="false"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode)
        [ "$#" -ge 2 ] || fail "--mode 缺少参数"
        MODE_STR="$2"; shift 2 ;;
      --channel)
        [ "$#" -ge 2 ] || fail "--channel 缺少参数"
        INSTALL_CHANNEL="$2"; shift 2 ;;
      --provider)
        [ "$#" -ge 2 ] || fail "--provider 缺少参数"
        PANEL_PROVIDER="$2"; shift 2 ;;
      --panel|--panel-url)
        [ "$#" -ge 2 ] || fail "$1 缺少参数"
        PANEL_URL="$2"; shift 2 ;;
      --token)
        [ "$#" -ge 2 ] || fail "--token 缺少参数"
        if [ "${MODE_STR:-}" = "node" ]; then NODE_TOKEN="$2"; else MACHINE_TOKEN="$2"; fi
        shift 2 ;;
      --machine-id)
        [ "$#" -ge 2 ] || fail "--machine-id 缺少参数"
        MACHINE_ID="$2"; shift 2 ;;
      --node-id)
        [ "$#" -ge 2 ] || fail "--node-id 缺少参数"
        NODE_ID="$2"; shift 2 ;;
      --kernel)
        [ "$#" -ge 2 ] || fail "--kernel 缺少参数"
        KERNEL="$2"; shift 2 ;;
      --log-level)
        [ "$#" -ge 2 ] || fail "--log-level 缺少参数"
        LOG_LEVEL="$2"; shift 2 ;;
      --audit)
        [ "$#" -ge 2 ] || fail "--audit 缺少参数"
        AUDIT_ENABLED="$2"; shift 2 ;;
      --report-all)
        [ "$#" -ge 2 ] || fail "--report-all 缺少参数"
        REPORT_ALL="$2"; shift 2 ;;
      *)
        fail "未知 install 参数: $1"
        ;;
    esac
  done

  PANEL_URL="${PANEL_URL%/}"
  [[ "$PANEL_URL" =~ ^https?:// ]] || fail "--panel-url 必须以 http:// 或 https:// 开头"
  [[ "$MODE_STR" =~ ^(machine|node)$ ]] || fail "--mode 只支持 machine 或 node"
  [[ "$PANEL_PROVIDER" =~ ^(xboard|txboard)$ ]] || fail "--provider 只支持 xboard 或 txboard"
  [[ "$INSTALL_CHANNEL" =~ ^(stable|dev)$ ]] || fail "--channel 只支持 stable 或 dev"
  IMAGE="$(official_image_for_channel "$INSTALL_CHANNEL")"
  [[ "$KERNEL" =~ ^(singbox|xray)$ ]] || fail "--kernel 只支持 singbox 或 xray"
  [[ "$LOG_LEVEL" =~ ^(info|debug|warn|error)$ ]] || fail "--log-level 只支持 info/debug/warn/error"
  [[ "$AUDIT_ENABLED" =~ ^(true|false)$ ]] || fail "--audit 只支持 true/false"
  [[ "$REPORT_ALL" =~ ^(true|false)$ ]] || fail "--report-all 只支持 true/false"

  if [ "$KERNEL" = "xray" ] && [ "$AUDIT_ENABLED" = "true" ]; then
    fail "xray 内核不支持内嵌审计，请使用 --audit false"
  fi

  if [ "$MODE_STR" = "machine" ]; then
    [[ "$MACHINE_ID" =~ ^[0-9]+$ ]] && [ "$MACHINE_ID" -gt 0 ] || fail "--machine-id 必须是正整数"
    [ -n "$MACHINE_TOKEN" ] || fail "--token 不能为空"
    NODE_ID=""
    NODE_TOKEN=""
  else
    [[ "$NODE_ID" =~ ^[0-9]+$ ]] && [ "$NODE_ID" -gt 0 ] || fail "--node-id 必须是正整数"
    # --token 在解析时可能先于 --mode 出现，统一在这里兼容。
    if [ -z "$NODE_TOKEN" ] && [ -n "$MACHINE_TOKEN" ]; then
      NODE_TOKEN="$MACHINE_TOKEN"
      MACHINE_TOKEN=""
    fi
    [ -n "$NODE_TOKEN" ] || fail "--token 不能为空"
    MACHINE_ID=""
    MACHINE_TOKEN=""
  fi

  NONINTERACTIVE_INSTALL=1
}

read_panel_credentials() {
  PANEL_PROVIDER="xboard"
  INSTALL_CHANNEL="stable"
  echo
  info "配置向导（面板信息可在 Xboard 后台查到）"
  hint "面板地址示例：https://panel.example.com"

  # 向导中途 Ctrl+D / stdin 关闭 → 干净退出，不要留半截配置
  read -r -p "面板地址: " PANEL_URL || fail "输入中断，已取消"
  PANEL_URL="${PANEL_URL%/}"
  [[ "$PANEL_URL" =~ ^https?:// ]] || fail "面板地址必须以 http:// 或 https:// 开头"
  read -r -p "面板协议 [xboard/txboard] (默认 xboard): " PANEL_PROVIDER || fail "输入中断，已取消"
  PANEL_PROVIDER="${PANEL_PROVIDER:-xboard}"
  [[ "$PANEL_PROVIDER" =~ ^(xboard|txboard)$ ]] || fail "面板协议只支持 xboard 或 txboard"

  echo
  echo "运行模式:"
  echo "  1) node    —— 单节点（面板里这台就是一个节点）"
  echo "  2) machine —— 整机模式（接管面板上绑定到这台机器的所有节点）"
  read -r -p "选择 [1/2] (默认 1): " MODE || fail "输入中断，已取消"
  MODE="${MODE:-1}"

  MACHINE_ID=""; NODE_ID=""; MACHINE_TOKEN=""; NODE_TOKEN=""
  if [ "$MODE" = "2" ]; then
    read -r -p "machine_id（面板 → 机器管理里的 ID）: " MACHINE_ID || fail "输入中断，已取消"
    [[ "$MACHINE_ID" =~ ^[0-9]+$ ]] && [ "$MACHINE_ID" -gt 0 ] || fail "machine_id 必须是正整数"
    read -r -s -p "machine token（机器令牌，输入不回显）: " MACHINE_TOKEN || fail "输入中断，已取消"; echo
    [ -n "$MACHINE_TOKEN" ] || fail "machine token 不能为空"
    MODE_STR="machine"
  else
    read -r -p "node_id（面板 → 节点列表里的 ID）: " NODE_ID || fail "输入中断，已取消"
    [[ "$NODE_ID" =~ ^[0-9]+$ ]] && [ "$NODE_ID" -gt 0 ] || fail "node_id 必须是正整数"
    read -r -s -p "server_token（节点通讯密钥，输入不回显）: " NODE_TOKEN || fail "输入中断，已取消"; echo
    [ -n "$NODE_TOKEN" ] || fail "server_token 不能为空"
    MODE_STR="node"
  fi

  read -r -p "内核类型 [singbox/xray] (默认 singbox): " KERNEL || fail "输入中断，已取消"
  KERNEL="${KERNEL:-singbox}"
  [[ "$KERNEL" =~ ^(singbox|xray)$ ]] || fail "内核只支持 singbox 或 xray"

  AUDIT_ENABLED="false"
  if [ "$KERNEL" = "singbox" ]; then
    if confirm "启用访问审计（需面板已安装 AccessAudit 插件 v2.1+）？" "Y"; then
      AUDIT_ENABLED="true"
    fi
  else
    warn "xray 内核不支持内嵌审计；如需审计请用 AccessAudit 插件自带的 audit-agent.py（旁路 tail access log）"
  fi

  read -r -p "日志级别 [info/debug/warn/error] (默认 info): " LOG_LEVEL
  LOG_LEVEL="${LOG_LEVEL:-info}"

  # 审计全量上报（只在启用审计时询问）
  REPORT_ALL="false"
  if [ "$AUDIT_ENABLED" = "true" ]; then
    echo
    hint "report_all=false 时只上报「命中规则」的连接；面板上没有启用规则 = 一条都不会上报。"
    hint "需要面板看到全部连接日志则选 y。"
    if confirm "全量上报所有连接（report_all）？" "n"; then
      REPORT_ALL="true"
    fi
  fi
}

write_config_files() {
  DATA_DIR="$INSTALL_DIR/data"
  mkdir -p "$INSTALL_DIR" "$REMOTE_UPDATE_DIR" "$DATA_DIR"
  chmod 700 "$DATA_DIR" 2>/dev/null || true
  chmod 700 "$REMOTE_UPDATE_DIR" 2>/dev/null || true

  if [ "$MODE_STR" = "machine" ]; then
    PANEL_BLOCK=$(cat <<EOF
panel:
  provider: "${PANEL_PROVIDER:-xboard}"
  url: "$PANEL_URL"
machine:
  machine_id: $MACHINE_ID
  token: "$MACHINE_TOKEN"
EOF
)
  else
    PANEL_BLOCK=$(cat <<EOF
panel:
  provider: "${PANEL_PROVIDER:-xboard}"
  url: "$PANEL_URL"
  token: "$NODE_TOKEN"
  node_id: $NODE_ID
EOF
)
  fi

  local HEALTH_BLOCK=""
  if [ -n "$TXNODE_HEALTH_PORT" ]; then
    HEALTH_BLOCK="health_port: $TXNODE_HEALTH_PORT"
  fi

  cat > "$CONFIG_FILE" <<EOF
# Generated by tx-node deploy.sh ($(date '+%Y-%m-%d %H:%M:%S'))
# 重新生成请执行: txnode  → 选择「重新配置」
$PANEL_BLOCK
$HEALTH_BLOCK

kernel:
  type: "$KERNEL"

log:
  level: "$LOG_LEVEL"

# tx-node 访问审计（sing-box 内核）。删除本段或 enabled: false 即关闭。
audit:
  enabled: $AUDIT_ENABLED
  report_all: $REPORT_ALL
EOF
  chmod 600 "$CONFIG_FILE"
  ok "配置已写入 $CONFIG_FILE（权限 600）"

  cat > "$COMPOSE_FILE" <<EOF
services:
  tx-node:
    image: $IMAGE
    container_name: $APP_NAME
    restart: unless-stopped
    network_mode: host
    command: ["-c", "$CONTAINER_CONFIG_FILE"]
    volumes:
      # Default kernel.config_dir is the directory containing config.yml.
      # Persist traffic pending spool, generated certificates and kernel cache.
      - $DATA_DIR:$DATA_CONTAINER_DIR
      - $CONFIG_FILE:$CONTAINER_CONFIG_FILE:ro
      - $REMOTE_UPDATE_DIR:$REMOTE_UPDATE_CONTAINER_DIR
EOF
  ok "compose 文件已写入 $COMPOSE_FILE"
}

# ════════════════════════════════════════════════════════════════════
#  动作：安装 / 重装
# ════════════════════════════════════════════════════════════════════
do_install() {
  if [ "$#" -gt 0 ]; then
    parse_install_args "$@"
    info "使用非交互安装参数: mode=$MODE_STR panel=$PANEL_URL"
  else
    NONINTERACTIVE_INSTALL=0
  fi

  ensure_docker
  detect_deploy_mode

  if is_installed; then
    if [ "${NONINTERACTIVE_INSTALL:-0}" = "1" ]; then
      local installed_channel
      installed_channel="$(current_compose_channel)" || fail "当前部署使用自定义镜像，不能自动附加面板"
      if [ "$installed_channel" != "$INSTALL_CHANNEL" ]; then
        fail "当前容器是 $installed_channel 渠道，无法在同一容器安装 $INSTALL_CHANNEL 实例。请先运行 txnode channel $INSTALL_CHANNEL，或部署独立实例。"
      fi
      do_add_panel_instance
    else
      do_existing_install
    fi
    return
  fi

  if [ "${NONINTERACTIVE_INSTALL:-0}" != "1" ]; then
    read_panel_credentials
  fi

  if [ "${NONINTERACTIVE_INSTALL:-0}" != "1" ]; then
    local input_channel=""
    read -r -p "镜像渠道 stable(稳定版)/dev(开发版) [stable]: " input_channel || fail "输入中断，已取消"
    INSTALL_CHANNEL="${input_channel:-stable}"
    [[ "$INSTALL_CHANNEL" =~ ^(stable|dev)$ ]] || fail "只支持 stable/dev"
    IMAGE="$(official_image_for_channel "$INSTALL_CHANNEL")"
  fi

  backup_config
  write_config_files

  info "拉取镜像（首次较慢）..."
  dc pull || fail "镜像拉取失败。若是私有包未授权，请先 docker login ghcr.io；网络问题可配置镜像加速后重跑"

  reset_container || fail "清理旧容器失败，安装中止"

  info "启动并验证..."
  if ! guarded_compose_start 1; then
    warn "容器未能稳定运行，已保持 restart=no，避免无限 Restarting"
    show_logs 30
    fail "启动失败，请修正配置后重新执行安装/启动"
  fi
  ok "容器运行中（restart=unless-stopped）"

  if [ "$AUDIT_ENABLED" = "true" ]; then
    sleep 5
    if docker logs "$APP_NAME" 2>&1 | grep -q "audit reporter enabled"; then
      ok "审计模块已启用并连接面板"
      if [ "$REPORT_ALL" = "false" ]; then
        warn "当前 report_all=false —— 需要在面板配置启用规则，否则不会上报任何数据"
      fi
    else
      warn "未在日志中看到 'audit reporter enabled'，请检查日志"
    fi
  fi

  install_cli_link
  install_remote_update_bridge

  echo
  echo -e "${BOLD}== 部署完成 ==${NC}"
  hint "随时执行 ${BOLD}txnode${NC} 进入运维面板"
}

# 判断一个路径能否作为长期入口。
# 用 `bash <(curl ...)` 运行时 SELF_PATH 是 /dev/fd/63 —— 那是进程替换的临时 fd，
# **进程一退出就消失**。直接 ln -sf /dev/fd/63 /usr/local/bin/txnode，
# 建出来的软链当场就是坏的（下次执行 txnode 找不到文件）。这正是
# 「装完却没有可用快捷命令」的根因。
self_path_is_persistent() {
  local p="${1:-}"
  [ -n "$p" ] || return 1
  case "$p" in
    /dev/fd/*|/proc/*|/dev/stdin|/dev/stdout) return 1 ;;
  esac
  [ -f "$p" ] || return 1
  # 空文件也算不可靠（curl 失败/管道截断时会得到 0 字节）
  [ -s "$p" ] || return 1
  return 0
}

# 把脚本落到 $SELF_COPY：已有有效副本就直接用，否则复制自身，再不行才从网络拉。
#
# 顺序很重要：**先检查已有副本**。否则每次运行都要联网，一旦断网
# （或 raw.githubusercontent.com 不通）就会把上一轮留下的好副本删掉，
# 反而把本来能用的快捷命令搞坏。
materialize_self_copy() {
  mkdir -p "$INSTALL_DIR" 2>/dev/null || true
  local tmp="${SELF_COPY}.tmp.$$"

  # 1) 正常从持久化文件执行：优先复制当前脚本，确保副本就是本次运行的版本。
  if self_path_is_persistent "$SELF_PATH" && [ "$SELF_PATH" != "$SELF_COPY" ]; then
    if cp -f "$SELF_PATH" "$tmp" 2>/dev/null \
      && [ -s "$tmp" ] \
      && grep -q 'do_upgrade' "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$SELF_COPY"
      chmod +x "$SELF_COPY" 2>/dev/null || true
      return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
  fi

  # 2) bash <(curl ...) 场景：/dev/fd/* 不能长期保存，直接从 raw URL
  #    刷新持久化副本。下载到临时文件，校验后原子替换，避免损坏旧副本。
  if ! self_path_is_persistent "$SELF_PATH"; then
    if command -v curl >/dev/null 2>&1; then
      if curl -fsSL "$SCRIPT_RAW_URL" -o "$tmp" 2>/dev/null \
        && [ -s "$tmp" ] \
        && grep -q 'do_upgrade' "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$SELF_COPY"
        chmod +x "$SELF_COPY" 2>/dev/null || true
        return 0
      fi
      rm -f "$tmp" 2>/dev/null || true
    fi
    if command -v wget >/dev/null 2>&1; then
      if wget -qO "$tmp" "$SCRIPT_RAW_URL" 2>/dev/null \
        && [ -s "$tmp" ] \
        && grep -q 'do_upgrade' "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$SELF_COPY"
        chmod +x "$SELF_COPY" 2>/dev/null || true
        return 0
      fi
      rm -f "$tmp" 2>/dev/null || true
    fi
  fi

  # 3) 网络不可用时保留并继续使用已有有效副本。
  if [ -s "$SELF_COPY" ] && grep -q 'do_upgrade' "$SELF_COPY" 2>/dev/null; then
    chmod +x "$SELF_COPY" 2>/dev/null || true
    return 0
  fi

  return 1
}

# 把本脚本安装为 txnode 命令，方便后续进面板
install_cli_link() {
  local target=""
  if materialize_self_copy; then
    target="$SELF_COPY"
  elif self_path_is_persistent "$SELF_PATH"; then
    target="$SELF_PATH"
  fi

  if [ -z "$target" ]; then
    hint "未能取得脚本的持久化副本，跳过快捷命令安装"
    hint "装好后可手动执行: bash $SELF_PATH link"
    return 1
  fi
  chmod +x "$target" 2>/dev/null || true
  if ln -sf "$target" "$CLI_LINK" 2>/dev/null; then
    ok "已安装快捷命令: ${BOLD}txnode${NC}  ${DIM}(→ $target)${NC}"
    return 0
  fi
  hint "软链失败，可继续用: bash $target"
  return 1
}

# 已部署机器进入菜单时自动刷新脚本副本并修复 txnode 命令。
# 失败只给菜单继续运行，不因为快捷命令问题中断运维。
ensure_cli_link() {
  install_cli_link >/dev/null 2>&1 || true
  return 0
}

# 显式重建快捷命令（也可修复旧的坏软链）
do_link() {
  title "快捷命令"
  local cur=""
  [ -L "$CLI_LINK" ] && cur=$(readlink "$CLI_LINK" 2>/dev/null || true)
  if [ -n "$cur" ]; then
    info "当前 $CLI_LINK → $cur"
    if [ ! -e "$cur" ]; then
      warn "该软链指向的文件已不存在（典型的 curl|bash 安装后遗症），即将重建"
    fi
  else
    info "当前未安装快捷命令"
  fi
  echo
  if install_cli_link; then
    echo
    ok "现在可直接执行: ${BOLD}txnode${NC}"
    hint "查看全部命令: txnode help"
  else
    warn "快捷命令安装失败，可继续用: bash ${SELF_COPY}"
  fi
}

# ════════════════════════════════════════════════════════════════════
#  动作：状态
# ════════════════════════════════════════════════════════════════════
do_status() {
  detect_deploy_mode
  title "tx-node 运行状态"

  if ! is_installed; then
    warn "未检测到已部署的 tx-node"
    hint "执行本脚本选择「安装」开始部署"
    return 0
  fi

  echo -e "  部署模式: ${BOLD}${DEPLOY_MODE}${NC}"

  case "$DEPLOY_MODE" in
    docker)
      local st; st=$(container_state)
      local st_c
      case "$st" in
        running) st_c="${GREEN}运行中${NC}" ;;
        exited)  st_c="${RED}已停止${NC}" ;;
        *)       st_c="${YELLOW}${st}${NC}" ;;
      esac
      echo -e "  容器状态: ${st_c}"
      # 镜像与启动时间
      local img started
      img=$(docker inspect -f '{{.Config.Image}}' "$APP_NAME" 2>/dev/null || echo "-")
      started=$(docker inspect -f '{{.State.StartedAt}}' "$APP_NAME" 2>/dev/null | cut -d. -f1 || echo "-")
      echo "  镜像:     $img"
      echo "  启动于:   $started"
      # 容器内版本
      local ver
      ver=$(docker exec "$APP_NAME" /usr/local/bin/tx-node -v 2>/dev/null || docker exec "$APP_NAME" /usr/local/bin/xboard-node -v 2>/dev/null || echo "unknown")
      echo "  版本:     $ver"
      ;;
    legacy)
      local sst; sst=$(svc_state)
      local sst_c
      case "$sst" in
        active)   sst_c="${GREEN}运行中${NC}" ;;
        failed)   sst_c="${RED}失败${NC}" ;;
        inactive) sst_c="${YELLOW}已停止${NC}" ;;
        *)        sst_c="${YELLOW}${sst}${NC}" ;;
      esac
      echo -e "  服务状态: ${sst_c} ${DIM}(install.sh 部署，未转换为 docker)${NC}"
      local sver="unknown"
      if [ -x "$SB_BINARY" ]; then
        sver=$("$SB_BINARY" -v 2>/dev/null || echo "unknown")
      fi
      echo "  二进制:   $SB_BINARY"
      echo "  版本:     $sver"
      hint "txnode 尚未部署；可用菜单「从 install.sh 导入」把它转成 docker 部署"
      ;;
  esac

  # 配置摘要
  if [ -f "$CONFIG_FILE" ]; then
    echo
    echo -e "  ${BOLD}配置摘要${NC} ($CONFIG_FILE)"
    if config_uses_instances; then
      instances_summary
    else
    local url mid nid kern aud rpt hlvl
    url=$(_sec_get panel url || true)
    nid=$(_sec_get panel node_id || true)
    mid=$(_sec_get machine machine_id || true)
    kern=$(_sec_get kernel type || true)
    aud=$(_sec_get audit enabled || true)
    rpt=$(_sec_get audit report_all || true)
    hlvl=$(_sec_get log level || true)

    [ -n "$url" ]  && echo "    面板地址:   $url"
    [ -n "$nid" ]  && echo "    node_id:    $nid"
    [ -n "$mid" ]  && echo "    machine_id: $mid"
    [ -n "$kern" ] && echo "    内核:       $kern"
    [ -n "$hlvl" ] && echo "    日志级别:   $hlvl"
    if [ -n "$aud" ]; then
      if [ "$aud" = "true" ]; then
        echo -e "    访问审计:   ${GREEN}已启用${NC} (report_all=${rpt:-false})"
        if [ "${rpt:-false}" = "false" ]; then
          hint "report_all=false：需在面板配置启用规则，否则不会上报"
        fi
      else
        echo "    访问审计:   未启用"
      fi
    fi
    # 多节点模式提示
    if grep -qE '^nodes:' "$CONFIG_FILE" 2>/dev/null; then
      local ncount
      ncount=$(grep -cE '^[[:space:]]*-[[:space:]]*node_id:' "$CONFIG_FILE" 2>/dev/null || echo 0)
      echo -e "    多节点:     ${BOLD}${ncount}${NC} 个（nodes 段）"
    fi
    if grep -qE '^machine:' "$CONFIG_FILE" 2>/dev/null; then
      echo -e "    机器模式:   ${BOLD}是${NC}（接管该机器绑定的所有节点）"
    fi
    fi
  else
    warn "配置文件不存在: $CONFIG_FILE"
  fi

  # 健康检查
  echo
  local hport
  hport=$(grep -m1 -E '^health_port:' "$CONFIG_FILE" 2>/dev/null | sed -E 's/.*health_port:[[:space:]]*//' | tr -cd '0-9' || true)
  hport="${hport:-65530}"
  if [ "$hport" -gt 0 ] 2>/dev/null; then
    if curl -fsS "http://127.0.0.1:${hport}/healthz" >/dev/null 2>&1; then
      echo -e "  健康检查: ${GREEN}正常${NC} (127.0.0.1:${hport})"
    else
      echo -e "  健康检查: ${YELLOW}无响应${NC} (127.0.0.1:${hport})"
      hint "端口未监听可能是因为配置里未开启 health_port"
    fi
  fi
}

# ════════════════════════════════════════════════════════════════════
#  动作：启停 / 重启
# ════════════════════════════════════════════════════════════════════
compose_set_restart_policy() {
  local policy="$1" rendered="$1"
  # restart: no 在 YAML 里会被解析成布尔 false，必须加引号才等价于 "no"
  [ "$policy" = "no" ] && rendered='"no"'
  if [ -f "$COMPOSE_FILE" ] && grep -qE '^[[:space:]]*restart:' "$COMPOSE_FILE" 2>/dev/null; then
    sed -i -E "s|^([[:space:]]*)restart:.*$|\1restart: ${rendered}|" "$COMPOSE_FILE"
  fi
}

runtime_set_restart_policy() {
  local policy="$1"
  docker update --restart="$policy" "$APP_NAME" >/dev/null 2>&1 || true
}

wait_container_stable() {
  local seconds="${1:-5}" i
  i=0
  while [ "$i" -lt "$seconds" ]; do
    sleep 1
    [ "$(container_state)" = "running" ] || return 1
    i=$((i+1))
  done
  return 0
}

promote_restart_policy() {
  compose_set_restart_policy "unless-stopped"
  runtime_set_restart_policy "unless-stopped"
}

# 安全启动：先用 restart=no 起，确认连续稳定后再提升为 unless-stopped。
# 这样坏配置不会陷入 Restarting 死循环。
guarded_compose_start() {
  local recreate="${1:-0}"

  # 首次验证阶段禁用自动重启，坏配置不会形成 Restarting 死循环。
  compose_set_restart_policy "no"

  if [ "$recreate" = "1" ]; then
    dc up -d --force-recreate || {
      # 同名容器可能不属于当前 compose 项目（手工 docker run / 换过安装目录），
      # 直接 up 会报 "container name is already in use"，先清理再重建。
      warn "重建失败，尝试清理同名容器后重试"
      reset_container || return 1
      dc up -d --force-recreate || return 1
    }
  else
    dc up -d || {
      warn "启动失败，尝试清理同名容器后重试"
      reset_container || return 1
      dc up -d || return 1
    }
  fi

  if wait_container_stable 5; then
    if runtime_has_bind_conflict; then
      warn "检测到端口绑定冲突，保持 restart=no"
    elif wait_configured_health 12; then
      promote_restart_policy
      return 0
    else
      warn "health_port 健康检查未通过，保持 restart=no"
    fi
  fi

  runtime_set_restart_policy "no"
  docker stop "$APP_NAME" >/dev/null 2>&1 || true
  return 1
}

do_start() {
  detect_deploy_mode
  ! is_installed && legacy_hint_or_fail "启动"
  info "启动..."

  if ! guarded_compose_start 0; then
    warn "容器启动后未能稳定运行，已关闭自动重启，避免 Restarting 循环"
    show_logs 30
    fail "启动失败，请修正配置后再执行: txnode start"
  fi

  ok "已启动（restart=unless-stopped）"
  do_status
}

do_stop() {
  detect_deploy_mode
  ! is_installed && legacy_hint_or_fail "停止"
  if ! confirm "确认停止 tx-node？（节点将下线；手动停止后不会被自动拉起）" "n"; then
    info "已取消"; return 0
  fi
  info "停止..."
  dc stop
  ok "已停止"
}

do_restart() {
  detect_deploy_mode
  ! is_installed && legacy_hint_or_fail "重启"
  info "安全重启..."

  runtime_set_restart_policy "no"

  if [ "$(container_state)" = "absent" ]; then
    if ! guarded_compose_start 1; then
      warn "容器未能稳定启动，已保持 restart=no"
      show_logs 30
      fail "重启失败，请修正配置后执行: txnode start"
    fi
  else
    if ! docker restart "$APP_NAME" >/dev/null; then
      fail "docker restart 失败"
    fi
    if wait_container_stable 5; then
      promote_restart_policy
    else
      runtime_set_restart_policy "no"
      docker stop "$APP_NAME" >/dev/null 2>&1 || true
      warn "重启后进程未能稳定运行，已停止容器并关闭自动重启"
      show_logs 30
      fail "重启失败，请检查配置/日志"
    fi
  fi

  ok "已重启（restart=unless-stopped）"
  do_status
}

# 向后兼容旧命令：pause 不再修改 compose 状态机，等价于 stop。
do_pause() {
  warn "pause 已合并为 stop；不会再修改 compose 的 restart 配置"
  do_stop
}

restore_autostart() {
  return 0
}

# ════════════════════════════════════════════════════════════════════
#  Machine Runtime Update v1 — Installer-owned host bridge
# ════════════════════════════════════════════════════════════════════

remote_update_unit_base() {
  printf '%s' "$APP_NAME" | tr -c 'A-Za-z0-9_.@-' '-'
}

remote_update_service_path() {
  echo "/etc/systemd/system/$(remote_update_unit_base)-updater.service"
}

remote_update_path_path() {
  echo "/etc/systemd/system/$(remote_update_unit_base)-updater.path"
}

remote_update_host_supported() {
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

official_image_for_channel() {
  case "$1" in
    stable|latest) printf '%s:latest\n' "$REMOTE_UPDATE_IMAGE_PREFIX" ;;
    dev) printf '%s:dev\n' "$REMOTE_UPDATE_IMAGE_PREFIX" ;;
    *) return 1 ;;
  esac
}
current_compose_image() {
  [ -f "$COMPOSE_FILE" ] || return 1
  awk '/^[[:space:]]*image:[[:space:]]*/ {print $2; exit}' "$COMPOSE_FILE"
}
current_compose_channel() {
  local current
  current="$(current_compose_image)" || return 1
  case "$current" in
    "$REMOTE_UPDATE_IMAGE_PREFIX:latest") echo stable ;;
    "$REMOTE_UPDATE_IMAGE_PREFIX:dev") echo dev ;;
    *) return 1 ;;
  esac
}
remote_update_compose_supported() { current_compose_channel >/dev/null 2>&1; }
set_compose_channel() {
  local image tmp
  image="$(official_image_for_channel "$1")" || return 1
  remote_update_compose_supported || return 1
  tmp="$COMPOSE_FILE.channel.$BASHPID"
  awk -v image="$image" '
    /^[[:space:]]*image:[[:space:]]*/ {sub(/image:[[:space:]]*[^[:space:]]+/, "image: " image); n++}
    {print}
    END {if (n != 1) exit 42}
  ' "$COMPOSE_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$COMPOSE_FILE"
}

ensure_remote_update_mount() {
  [ -f "$COMPOSE_FILE" ] || return 1
  mkdir -p "$REMOTE_UPDATE_DIR"
  chmod 700 "$REMOTE_UPDATE_DIR" 2>/dev/null || true

  if grep -Fq "$REMOTE_UPDATE_DIR:$REMOTE_UPDATE_CONTAINER_DIR" "$COMPOSE_FILE" 2>/dev/null; then
    return 0
  fi

  local tmp="$COMPOSE_FILE.remote-update.$$"
  local canonical_needle="$CONFIG_FILE:$CONTAINER_CONFIG_FILE:ro"
  local legacy_needle="$CONFIG_FILE:$LEGACY_CONTAINER_CONFIG_FILE:ro"
  awk -v canonical="$canonical_needle" \
      -v legacy="$legacy_needle" \
      -v mount="      - $REMOTE_UPDATE_DIR:$REMOTE_UPDATE_CONTAINER_DIR" '
    { print }
    index($0, canonical) || index($0, legacy) { print mount; inserted=1 }
    END { if (!inserted) exit 42 }
  ' "$COMPOSE_FILE" > "$tmp" || {
    rm -f "$tmp" 2>/dev/null || true
    return 1
  }
  mv -f "$tmp" "$COMPOSE_FILE"
  return 0
}

write_remote_update_capability() {
  mkdir -p "$REMOTE_UPDATE_DIR"
  local tmp="$REMOTE_UPDATE_CAPABILITIES.tmp.$$"
  {
    echo "schema=1"
    echo "updater_available=true"
    echo "target=latest,dev"
  } > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$REMOTE_UPDATE_CAPABILITIES"
}

clear_remote_update_capability() {
  rm -f "$REMOTE_UPDATE_CAPABILITIES" 2>/dev/null || true
}

install_remote_update_bridge() {
  clear_remote_update_capability

  if ! remote_update_host_supported; then
    hint "systemd 不可用，远程 Runtime Update bridge 保持关闭"
    return 0
  fi
  if ! remote_update_compose_supported; then
    hint "当前 compose 不是官方 stable/dev 镜像，远程 Runtime Update bridge 保持关闭"
    return 0
  fi
  if ! ensure_remote_update_mount; then
    warn "无法为 compose 加入 Runtime Update 控制目录，远程更新保持关闭"
    return 0
  fi
  if ! materialize_self_copy; then
    warn "无法取得 Installer 持久化副本，远程 Runtime Update bridge 保持关闭"
    return 0
  fi

  mkdir -p "$REMOTE_UPDATE_DIR"
  chmod 700 "$REMOTE_UPDATE_DIR" 2>/dev/null || true

  local service_file path_file unit
  unit="$(remote_update_unit_base)-updater"
  service_file="$(remote_update_service_path)"
  path_file="$(remote_update_path_path)"

  cat > "$service_file" <<EOF
[Unit]
Description=TX-Node bounded runtime update for $APP_NAME
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
Environment="APP_NAME=$APP_NAME"
Environment="INSTALL_DIR=$INSTALL_DIR"
Environment="CLI_LINK=$CLI_LINK"
Environment="IMAGE=$(current_compose_image)"
Environment="REMOTE_UPDATE_DIR=$REMOTE_UPDATE_DIR"
ExecStart=/bin/bash $SELF_COPY remote-upgrade-apply
TimeoutStartSec=600
Nice=10
EOF

  cat > "$path_file" <<EOF
[Unit]
Description=Watch TX-Node runtime update requests for $APP_NAME
After=docker.service

[Path]
PathChanged=$REMOTE_UPDATE_REQUEST
Unit=$unit.service

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 "$service_file" "$path_file"
  systemctl daemon-reload >/dev/null 2>&1 || {
    warn "systemd daemon-reload 失败，远程 Runtime Update bridge 保持关闭"
    return 0
  }
  if ! systemctl enable --now "$unit.path" >/dev/null 2>&1; then
    warn "无法启用 $unit.path，远程 Runtime Update bridge 保持关闭"
    return 0
  fi

  write_remote_update_capability
  ok "已启用 TXBoard 远程 Runtime Update bridge"
}

disable_remote_update_bridge() {
  clear_remote_update_capability
  if remote_update_host_supported; then
    local unit
    unit="$(remote_update_unit_base)-updater"
    systemctl disable --now "$unit.path" >/dev/null 2>&1 || true
    systemctl stop "$unit.service" >/dev/null 2>&1 || true
    rm -f "$(remote_update_service_path)" "$(remote_update_path_path)" 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
}

parse_remote_update_request() {
  local file="${1:-$REMOTE_UPDATE_REQUEST}"
  REMOTE_REQUEST_ID=""
  REMOTE_REQUEST_TARGET=""

  [ -f "$file" ] || return 1
  [ "$(grep -c '^schema=' "$file" 2>/dev/null || true)" = "1" ] || return 1
  [ "$(grep -c '^request_id=' "$file" 2>/dev/null || true)" = "1" ] || return 1
  [ "$(grep -c '^target=' "$file" 2>/dev/null || true)" = "1" ] || return 1

  if grep -Ev '^(schema=1|request_id=[A-Za-z0-9._:-]{1,64}|target=(latest|dev)|[[:space:]]*)$' "$file" >/dev/null 2>&1; then
    return 1
  fi

  local schema
  schema=$(sed -n 's/^schema=//p' "$file" | head -n1)
  REMOTE_REQUEST_ID=$(sed -n 's/^request_id=//p' "$file" | head -n1)
  REMOTE_REQUEST_TARGET=$(sed -n 's/^target=//p' "$file" | head -n1)

  [ "$schema" = "1" ] || return 1
  [[ "$REMOTE_REQUEST_ID" =~ ^[A-Za-z0-9._:-]{1,64}$ ]] || return 1
  [[ "$REMOTE_REQUEST_TARGET" =~ ^(latest|dev)$ ]] || return 1
  return 0
}

remote_update_status_value() {
  local key="$1"
  [ -f "$REMOTE_UPDATE_STATUS" ] || return 0
  sed -n "s/^$key=//p" "$REMOTE_UPDATE_STATUS" 2>/dev/null | head -n1
}

write_remote_update_status() {
  local request_id="$1" target="$2" status="$3" message="${4:-}"
  mkdir -p "$REMOTE_UPDATE_DIR"
  message=$(printf '%s' "$message" | tr '\r\n=' '   ' | cut -c1-160)
  local tmp="$REMOTE_UPDATE_STATUS.tmp.$$"
  {
    echo "schema=1"
    echo "request_id=$request_id"
    echo "target=$target"
    echo "status=$status"
    echo "updated_at=$(date +%s)"
    echo "message=$message"
  } > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$REMOTE_UPDATE_STATUS"
}

# Shared Installer upgrade runtime. The remote bridge and manual 'txnode upgrade'
# both delegate here so upgrade/rollback semantics have one owner.
perform_docker_upgrade() {
  UPGRADE_OUTCOME="failed"
  local target="$1" old_image_id old_ref old_compose target_image
  remote_update_compose_supported || { warn "只支持官方 stable/dev 镜像"; return 1; }
  old_ref="$(current_compose_image)" || return 1
  if [ -z "$target" ]; then
    target="$(current_compose_channel)" || return 1
  fi
  target_image="$(official_image_for_channel "$target")" || return 1
  old_image_id=$(docker inspect -f '{{.Image}}' "$APP_NAME" 2>/dev/null || true)
  [ -n "$old_image_id" ] || { warn "无法读取原容器镜像"; return 1; }
  old_compose="$COMPOSE_FILE.upgrade-backup.$$"
  cp -p "$COMPOSE_FILE" "$old_compose" || return 1
  if ! set_compose_channel "$target"; then rm -f "$old_compose"; return 1; fi
  info "切换/升级渠道 $old_ref -> $target_image"
  if ! dc pull; then
    mv -f "$old_compose" "$COMPOSE_FILE"
    warn "拉取失败，已恢复原 Compose；运行容器不变"
    return 1
  fi
  if ! reset_container; then
    mv -f "$old_compose" "$COMPOSE_FILE"
    warn "无法重建，原 Compose 已恢复"
    return 1
  fi
  if guarded_compose_start 1; then
    rm -f "$old_compose"
    UPGRADE_OUTCOME="succeeded"
    return 0
  fi
  warn "新镜像未通过健康检查，恢复先前镜像和渠道"
  mv -f "$old_compose" "$COMPOSE_FILE"
  if docker image inspect "$old_image_id" >/dev/null 2>&1 && docker tag "$old_image_id" "$old_ref"; then
    reset_container >/dev/null 2>&1 || true
    if guarded_compose_start 1; then
      UPGRADE_OUTCOME="rolled_back"
      warn "已回滚到原来的镜像与渠道"
      return 1
    fi
  fi
  warn "升级及自动回滚均失败，需人工修复"
  return 1
}

do_remote_upgrade_apply() {
  detect_deploy_mode

  if ! parse_remote_update_request "$REMOTE_UPDATE_REQUEST"; then
    warn "拒绝无效的 Runtime Update request"
    return 1
  fi

  local request_id="$REMOTE_REQUEST_ID" target="$REMOTE_REQUEST_TARGET"
  local previous_id previous_status
  previous_id=$(remote_update_status_value request_id || true)
  previous_status=$(remote_update_status_value status || true)
  if [ "$previous_id" = "$request_id" ] && [[ "$previous_status" =~ ^(succeeded|rolled_back)$ ]]; then
    info "Runtime Update request $request_id 已处理，跳过重复执行"
    return 0
  fi

  if [ "$DEPLOY_MODE" != "docker" ]; then
    write_remote_update_status "$request_id" "$target" "failed" "docker deployment required"
    return 1
  fi
  if ! remote_update_compose_supported; then
    write_remote_update_status "$request_id" "$target" "failed" "official stable/dev channel required"
    return 1
  fi

  write_remote_update_status "$request_id" "$target" "running" "upgrade started"

  if perform_docker_upgrade "$target"; then
    write_remote_update_status "$request_id" "$target" "succeeded" "upgrade completed"
    return 0
  fi

  case "${UPGRADE_OUTCOME:-failed}" in
    rolled_back)
      write_remote_update_status "$request_id" "$target" "rolled_back" "upgrade failed and previous image restored"
      ;;
    *)
      write_remote_update_status "$request_id" "$target" "failed" "upgrade failed"
      ;;
  esac
  return 1
}

# ════════════════════════════════════════════════════════════════════
#  动作：升级
# ════════════════════════════════════════════════════════════════════
do_channel() {
  local target="${1:-}"
  if [ -z "$target" ]; then
    current_compose_channel || fail "当前渠道无法识别"
    return 0
  fi
  [[ "$target" =~ ^(stable|dev)$ ]] || fail "channel 只支持 stable/dev"
  do_upgrade "$target"
}
do_upgrade() {
  local target="${1:-}"
  if [ -n "$target" ]; then [[ "$target" =~ ^(stable|dev|latest)$ ]] || fail "upgrade 只支持 stable/dev"; fi
  detect_deploy_mode
  ! is_installed && fail "未检测到已部署的 tx-node，请先安装"

  case "$DEPLOY_MODE" in
    docker)
      ensure_remote_update_mount || warn "未能写入 Runtime Update 控制目录挂载"
      if perform_docker_upgrade "$target"; then
        ok "升级完成，容器运行中（restart=unless-stopped）"
      else
        if [ "${UPGRADE_OUTCOME:-failed}" = "rolled_back" ]; then
          fail "新版本启动失败，已自动回滚到升级前镜像"
        fi
        show_logs 30
        fail "升级失败，请检查日志"
      fi
      install_remote_update_bridge
      ;;
    legacy)
      warn "当前只有 install.sh 部署，txnode 自己的 docker 部署尚未安装"
      hint "txnode 不会去升级 install.sh 的部署（那是它自己的 ${XBCTL_PATH} 的职责）"
      hint "如果你想换到 txnode：用菜单「从 install.sh 导入」把它转成 docker 部署"
      return 0
      ;;
  esac

  # Only prune dangling layers after a verified successful manual update.
  if [ "$DEPLOY_MODE" = "docker" ] && [ "${UPGRADE_OUTCOME:-failed}" = "succeeded" ]; then
    local reclaimed
    reclaimed=$(docker image prune -f 2>/dev/null | tail -1 || true)
    if [ -n "$reclaimed" ]; then
      hint "镜像清理: $reclaimed"
    fi
  fi
  return 0
}


# 选一个可用的编辑器。
# $EDITOR 在很多最小化镜像/容器里**未设置**，而本脚本开了 set -u，
# 直接 "$EDITOR" 会 unbound variable 让菜单崩掉 —— 所以一律走这里拿默认值。
pick_editor() {
  local ed="${EDITOR:-}"
  [ -n "$ed" ] || ed="${VISUAL:-}"
  if [ -z "$ed" ]; then
    for c in nano vim vi; do
      if command -v "$c" >/dev/null 2>&1; then ed="$c"; break; fi
    done
  fi
  # 选中的编辑器不存在（比如 $EDITOR 指向没装的 emacs）→ 退回第一个可用的
  if [ -n "$ed" ] && ! command -v "$ed" >/dev/null 2>&1; then
    ed=""
    for c in nano vim vi; do
      if command -v "$c" >/dev/null 2>&1; then ed="$c"; break; fi
    done
  fi
  printf '%s' "${ed:-vi}"
}

# ════════════════════════════════════════════════════════════════════
#  动作：改配置
# ════════════════════════════════════════════════════════════════════
do_reconfigure() {
  detect_deploy_mode
  if [ "$DEPLOY_MODE" = "legacy" ]; then
    warn "当前只有 install.sh 部署，本脚本的配置向导只写 txnode 的 docker 布局"
    hint "legacy 管理面已冻结，不再继续通过 xbctl 扩展或修改"
    hint "请执行 txnode migrate（或菜单「从 install.sh 导入」）转成 Docker 部署后再修改"
    return 0
  fi
  if [ "$DEPLOY_MODE" = "none" ]; then
    warn "txnode 尚未部署，请先安装（或从 install.sh 导入）"
    return 0
  fi

  echo
  # 注意：$EDITOR 在多数最小化镜像里**根本没有设置**，而本脚本开了 set -u，
  # 这里裸写 "$EDITOR" 会直接 unbound variable 崩掉整个菜单。
  # 凡是从环境里读的变量一律给默认值，见下方 pick_editor()。
  echo "  1) 用向导重新生成配置（覆盖 config.yml）"
  echo "  2) 手动编辑 config.yml（$(pick_editor)）"
  echo "  3) 仅修改日志级别"
  echo "  4) 访问审计开关（同主菜单 ${BOLD}7${NC}）"
  echo "  5) 返回"
  read -r -p "选择 [1-5]: " c || return 0
  case "$c" in
    1)
      backup_config
      read_panel_credentials
      local prev_mode="$DEPLOY_MODE"
      write_config_files
      DEPLOY_MODE="$prev_mode"
      do_restart
      ;;
    2)
      local ed; ed=$(pick_editor)
      "$ed" "$CONFIG_FILE"
      if confirm "配置已保存，现在重启生效？" "Y"; then do_restart; fi
      ;;
    3)
      local nl
      read -r -p "新日志级别 [info/debug/warn/error]: " nl
      [[ "$nl" =~ ^(info|debug|warn|error)$ ]] || fail "日志级别只支持 info/debug/warn/error"
      backup_config
      # 只替换顶层 log.level，不动其它
      if grep -qE '^[[:space:]]*level:' "$CONFIG_FILE"; then
        sed -i -E "0,/^[[:space:]]*level:/s//  level: \"$nl\"/" "$CONFIG_FILE"
      else
        printf '\nlog:\n  level: "%s"\n' "$nl" >> "$CONFIG_FILE"
      fi
      ok "日志级别已改为 $nl"
      confirm "立即重启生效？" "Y" && do_restart || hint "稍后重启生效"
      ;;
    4)
      do_audit
      ;;
    *) return 0 ;;
  esac
}

# 读取当前审计开关状态，输出到 stdout，格式 "enabled=<v> report_all=<v>"
audit_read() {
  local aud rpt
  aud=$(awk '
    /^audit:/ {inaudit=1}
    inaudit && /^[[:space:]]*enabled:/ && !d {sub(/.*enabled:[[:space:]]*/,""); gsub(/[^a-z]/,""); print; d=1}
    /^[^[:space:]#]/ && !/^audit:/ {inaudit=0}
  ' "$CONFIG_FILE" 2>/dev/null || true)
  rpt=$(awk '
    /^audit:/ {inaudit=1}
    inaudit && /^[[:space:]]*report_all:/ && !d {sub(/.*report_all:[[:space:]]*/,""); gsub(/[^a-z]/,""); print; d=1}
    /^[^[:space:]#]/ && !/^audit:/ {inaudit=0}
  ' "$CONFIG_FILE" 2>/dev/null || true)
  # 必须以换行结尾：调用方用 `read ... < <(audit_read)` 取值，
  # 而 read 遇到「无换行结尾的输入」会**返回非 0**（变量其实已赋值成功），
  # 在 set -e 下会当场把整个脚本杀掉，且没有任何输出。
  printf '%s %s\n' "${aud:-false}" "${rpt:-false}"
}

# 写入审计开关。参数：$1=enabled(可空) $2=report_all(可空)
audit_write() {
  local new_aud="${1:-}" new_rpt="${2:-}"
  if [ -z "$new_aud" ] && [ -z "$new_rpt" ]; then return 0; fi

  backup_config
  if [ -n "${new_aud:-}" ]; then
    if grep -qE '^audit:' "$CONFIG_FILE"; then
      # 精确替换 audit 段内的 enabled（用 awk 限定范围，避免误改 panel 段的字段）
      awk -v v="$new_aud" '
        /^audit:/ {inaudit=1}
        inaudit && /^[[:space:]]*enabled:/ && !done {sub(/enabled:.*/, "enabled: " v); done=1}
        /^[^[:space:]#]/ && !/^audit:/ {inaudit=0}
        {print}
      ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
      ok "audit.enabled → $new_aud"
    else
      printf '\naudit:\n  enabled: %s\n  report_all: false\n' "$new_aud" >> "$CONFIG_FILE"
      ok "已追加 audit 段 (enabled=$new_aud)"
    fi
  fi
  if [ -n "${new_rpt:-}" ]; then
    if grep -qE '^[[:space:]]*report_all:' "$CONFIG_FILE"; then
      awk -v v="$new_rpt" '
        /^audit:/ {inaudit=1}
        inaudit && /^[[:space:]]*report_all:/ && !done {sub(/report_all:.*/, "report_all: " v); done=1}
        /^[^[:space:]#]/ && !/^audit:/ {inaudit=0}
        {print}
      ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    else
      awk -v v="$new_rpt" '
        /^audit:/ {inaudit=1}
        inaudit && /^[[:space:]]*enabled:/ && !done {print; print "  report_all: " v; done=1; next}
        {print}
      ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    fi
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    ok "audit.report_all → $new_rpt"
    # 注意：这里不能用 `[ ... ] && hint` 收尾。该函数在 audit_write 里是最后一条语句时，
    # 条件为假会让函数返回非 0，set -e 下调用方直接退出（明明改成功了却报失败）。
    if [ "$new_rpt" = "false" ]; then
      hint "report_all=false 时需在面板配置启用规则，否则不上报任何数据"
    fi
  fi
  return 0
}

# 访问审计开关 —— 既支持主菜单交互，也支持非交互一键设置：
#   txnode audit            → 显示状态 + 交互切换
#   txnode audit on|off     → 一键开/关 enabled
#   txnode audit all on|off → 一键设置 report_all
do_audit() {
  detect_deploy_mode
  if [ "$DEPLOY_MODE" = "legacy" ]; then
    warn "当前只有 install.sh 部署，审计开关只能改 txnode 的 docker 布局"
    hint "想换到 txnode：用菜单「从 install.sh 导入」把它转成 docker 部署"
    return 0
  fi
  if [ "$DEPLOY_MODE" = "none" ]; then
    warn "txnode 尚未部署，请先安装（或从 install.sh 导入）"
    return 0
  fi
  if [ ! -f "$CONFIG_FILE" ]; then
    warn "配置文件不存在: $CONFIG_FILE"
    return 0
  fi

  local sub="${1:-}" val="${2:-}"
  local cur_aud cur_rpt
  # `|| true` 是双保险：即使 audit_read 因故没输出，read 返回非 0 也不该
  # 让 set -e 把脚本杀掉（后面的 :-false 兜底会补上默认值）。
  read -r cur_aud cur_rpt < <(audit_read) || true
  cur_aud="${cur_aud:-false}"; cur_rpt="${cur_rpt:-false}"

  # ── 非交互：一键设置 ──
  if [ -n "$sub" ]; then
    case "$sub" in
      on|enable|true)
        if [ "$cur_aud" = "true" ]; then ok "审计已经是开启状态，无需改动"; return 0; fi
        audit_write "true" ""
        ok "访问审计已开启 (enabled=true)"
        ;;
      off|disable|false)
        if [ "$cur_aud" = "false" ]; then ok "审计已经是关闭状态，无需改动"; return 0; fi
        audit_write "false" ""
        ok "访问审计已关闭 (enabled=false)"
        ;;
      all|report-all|report_all)
        case "$val" in
          on|enable|true)  val="true" ;;
          off|disable|false) val="false" ;;
          *)
            if [ "$cur_rpt" = "true" ]; then val="false"; else val="true"; fi ;;
        esac
        audit_write "" "$val"
        ok "report_all 已设为 $val"
        if [ "$val" = "true" ]; then
          hint "全量上报：所有连接都记入面板访问日志（量可能很大）"
        else
          hint "仅上报命中规则的连接 —— 面板没配启用规则时一条都不会上报"
        fi
        ;;
      status|show)
        echo "  audit.enabled   = $cur_aud"
        echo "  audit.report_all= $cur_rpt"
        return 0
        ;;
      *)
        warn "未知参数: audit $sub"
        hint "用法: txnode audit [on|off|all on|off|status]"
        return 1
        ;;
    esac
    if confirm "立即重启生效？" "Y"; then do_restart; else hint "稍后执行 txnode restart 生效"; fi
    return 0
  fi

  # ── 交互：主菜单 ──
  while true; do
    banner
    echo
    echo -e "  ${BOLD}访问审计开关${NC}"
    echo
    if [ "$cur_aud" = "true" ]; then
      echo -e "  当前状态: ${GREEN}已开启${NC}    report_all=${cur_rpt}"
    else
      echo -e "  当前状态: ${DIM}已关闭${NC}    report_all=${cur_rpt}"
    fi
    echo
    if [ "$cur_aud" = "true" ]; then
      echo -e "   ${BOLD}1${NC}) ${BOLD}一键关闭审计${NC}       ${DIM}enabled=false${NC}"
    else
      echo -e "   ${BOLD}1${NC}) ${BOLD}一键开启审计${NC}       ${DIM}enabled=true${NC}"
    fi
    if [ "$cur_rpt" = "true" ]; then
      echo -e "   ${BOLD}2${NC}) 只上报命中规则的连接   ${DIM}report_all=false${NC}"
    else
      echo -e "   ${BOLD}2${NC}) 上报全部连接           ${DIM}report_all=true${NC}"
    fi
    echo -e "   ${BOLD}3${NC}) 返回"
    echo
    if [ "$cur_aud" = "true" ] && [ "$cur_rpt" = "false" ]; then
      echo -e "   ${YELLOW}[!]${NC} report_all=false：面板若没有启用任何规则，一条数据都不会上报。"
      echo -e "       想要全量访问日志请选 ${BOLD}2${NC}。"
      echo
    fi
    read -r -p "  请选择: " c || return 0
    case "$c" in
      1)
        if [ "$cur_aud" = "true" ]; then
          audit_write "false" ""; ok "访问审计已关闭"
        else
          audit_write "true" ""; ok "访问审计已开启"
        fi
        if confirm "立即重启生效？" "Y"; then do_restart; else hint "稍后执行重启生效"; fi
        return 0
        ;;
      2)
        if [ "$cur_rpt" = "true" ]; then
          audit_write "" "false"; ok "report_all → false（仅上报命中规则的连接）"
        else
          audit_write "" "true"; ok "report_all → true（上报全部连接）"
        fi
        if confirm "立即重启生效？" "Y"; then do_restart; else hint "稍后执行重启生效"; fi
        return 0
        ;;
      *) return 0 ;;
    esac
  done
}

# 配置校验：语法层面（YAML 缩进/引号）与必填字段
do_validate() {
  title "配置校验"
  if [ ! -f "$CONFIG_FILE" ]; then
    warn "配置文件不存在: $CONFIG_FILE"
    return 0
  fi
  if config_uses_instances; then
    validate_instances_config
    return $?
  fi
  local errs=0

  # 1) 区段感知取值，避免 panel / machine / nodes 之间串味
  local url ptok mtok nid mid
  url=$(_sec_get panel url || true)
  ptok=$(_sec_get panel token || true)
  mtok=$(_sec_get machine token || true)
  nid=$(_sec_get panel node_id || true)
  mid=$(_sec_get machine machine_id || true)
  # token 也可能写在 token_env 里（不落盘明文）
  local ptenv mtenv
  ptenv=$(_sec_get panel token_env || true)
  mtenv=$(_sec_get machine token_env || true)

  local is_machine=no
  _has_section machine && is_machine=yes

  # 2) panel.url 必填（machine 模式同样需要 url）
  [ -n "$url" ] || { warn "缺少 panel.url"; errs=$((errs+1)); }

  # 3) token：至少一处（明文或 token_env）
  if [ -z "$ptok" ] && [ -z "$mtok" ] && [ -z "$ptenv" ] && [ -z "$mtenv" ]; then
    warn "缺少 token（panel.token / machine.token / *_env 至少要有一个）"; errs=$((errs+1))
  fi
  # 明文与 token_env 同时给属于歧义
  if [ -n "$ptok" ] && [ -n "$ptenv" ]; then
    warn "panel.token 与 panel.token_env 同时存在，配置有歧义（token_env 优先）"; errs=$((errs+1))
  fi
  if [ -n "$mtok" ] && [ -n "$mtenv" ]; then
    warn "machine.token 与 machine.token_env 同时存在，配置有歧义（token_env 优先）"; errs=$((errs+1))
  fi

  # 4) 节点与机器：二选一（machine 段存在 = 机器模式，由节点动态发现，无需 node_id）
  if [ "$is_machine" = "yes" ]; then
    [ -n "$mid" ] || { warn "machine 段存在但缺少 machine_id"; errs=$((errs+1)); }
    [ -n "$nid" ] && warn "机器模式下 panel.node_id 会被忽略（节点由面板动态下发）"
  else
    if [ -z "$nid" ]; then
      warn "缺少 panel.node_id（单节点模式必填；多节点请改用 machine 段）"; errs=$((errs+1))
    fi
  fi

  # 5) URL 形状
  if [ -n "$url" ] && ! [[ "$url" =~ ^https?:// ]]; then
    warn "panel.url 必须以 http:// 或 https:// 开头（当前: $url）"; errs=$((errs+1))
  fi

  # 6) 内核取值：Go 侧枚举是 singbox / xray，"sing-box" 是官方产品名不是配置值
  local kern
  kern=$(_sec_get kernel type || true)
  if [ -n "$kern" ]; then
    case "$kern" in
      singbox|xray) ;;
      sing-box) warn "kernel.type 应写 singbox（当前: sing-box）；sing-box 是产品名，配置值不带连字符"; errs=$((errs+1)) ;;
      *) warn "kernel.type 只支持 singbox / xray（当前: $kern）"; errs=$((errs+1)) ;;
    esac
  else
    warn "缺少 kernel.type（默认按 singbox 处理，建议显式写出）"
  fi

  # 7) TAB 字符（YAML 不允许缩进用 TAB）
  if grep -qP '^\t' "$CONFIG_FILE" 2>/dev/null; then
    warn "配置中存在 TAB 缩进，YAML 要求使用空格"; errs=$((errs+1))
  fi

  # 8) audit 段一致性（内嵌审计只在 singbox 内核下生效）
  local aud rpt
  aud=$(_sec_get audit enabled || true)
  rpt=$(_sec_get audit report_all || true)
  if [ "$aud" = "true" ]; then
    if [ -n "$kern" ] && [ "$kern" != "singbox" ]; then
      warn "audit.enabled=true 但内核是 $kern —— 内嵌审计仅在 singbox 内核下工作"
      hint "xray 请用 AccessAudit 插件自带的 audit-agent.py 旁路"
      errs=$((errs+1))
    fi
    if [ "${rpt:-false}" != "true" ]; then
      warn "audit.enabled=true 且 report_all=false —— 只上报命中规则的连接"
      hint "面板上若没有启用规则，将不会上报任何数据（这是最常见的「开了没数据」原因）"
      hint "要全量日志请把 report_all 改为 true"
    fi
    if [ -z "$aud" ] || [ -z "$kern" ]; then
      hint "audit 段存在但取值读不全，请检查缩进是否规范"
    fi
  fi

  echo
  if [ "$errs" -eq 0 ]; then
    ok "校验通过，未发现问题"
  else
    warn "发现 $errs 个问题，请修正后重启"
  fi

  # 6) 额外：如果容器在跑，检查日志里有无明显错误
  detect_deploy_mode
  if [ "$DEPLOY_MODE" = "docker" ] && [ "$(container_state)" = "running" ]; then
    echo
    info "最近日志中的告警/错误（最多 10 条）："
    docker logs --tail 200 "$APP_NAME" 2>&1 \
      | grep -iE 'error|warn|failed|refused' | tail -10 || hint "（无）"
  fi
}

# ════════════════════════════════════════════════════════════════════
#  动作：备份 / 恢复
# ════════════════════════════════════════════════════════════════════
do_backup() {
  if [ ! -f "$CONFIG_FILE" ]; then
    warn "没有可备份的配置"
    return 0
  fi
  mkdir -p "$BACKUP_DIR"
  local stamp dest
  stamp=$(date +%Y%m%d-%H%M%S)
  dest="$BACKUP_DIR/backup-$stamp.tar.gz"
  tar -czf "$dest" -C "$INSTALL_DIR" config.yml docker-compose.yml 2>/dev/null \
    || tar -czf "$dest" -C "$INSTALL_DIR" config.yml
  chmod 600 "$dest"
  ok "备份完成 → $dest"
  list_backups
}

list_backups() {
  [ -d "$BACKUP_DIR" ] || return 0
  local files
  files=$(ls -1t "$BACKUP_DIR" 2>/dev/null || true)
  [ -z "$files" ] && { hint "（暂无备份）"; return 0; }
  echo
  echo "  现有备份："
  local i=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    i=$((i+1))
    printf "    %2d) %s\n" "$i" "$f"
  done <<< "$files"
}

do_restore() {
  [ -d "$BACKUP_DIR" ] || { warn "没有备份目录"; return 0; }
  local files
  mapfile -t files < <(ls -1t "$BACKUP_DIR" 2>/dev/null || true)
  if [ ${#files[@]} -eq 0 ]; then
    warn "没有可用备份"; return 0
  fi
  title "从备份恢复"
  local i=1
  for f in "${files[@]}"; do
    echo "    $i) $f"
    i=$((i+1))
  done
  read -r -p "  选择要恢复的备份编号 [1-${#files[@]}]: " sel
  [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le ${#files[@]} ] || fail "无效编号"
  local chosen="${files[$((sel-1))]}"
  if ! confirm "确认用 $chosen 覆盖当前配置？" "n"; then
    info "已取消"; return 0
  fi
  backup_config
  if [[ "$chosen" == *.tar.gz ]]; then
    tar -xzf "$BACKUP_DIR/$chosen" -C "$INSTALL_DIR"
  else
    cp -a "$BACKUP_DIR/$chosen" "$CONFIG_FILE"
  fi
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
  ok "已恢复 $chosen"
  detect_deploy_mode
  if is_installed; then
    confirm "立即重启生效？" "Y" && do_restart || hint "稍后重启生效"
  fi
}

# ════════════════════════════════════════════════════════════════════
#  多面板 / 隔离实例
# ════════════════════════════════════════════════════════════════════
config_uses_instances() {
  [ -f "$CONFIG_FILE" ] && grep -qE '^instances:[[:space:]]*$' "$CONFIG_FILE" 2>/dev/null
}

config_instance_targets() {
  [ -f "$CONFIG_FILE" ] || return 0
  awk '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); gsub(/^"|"$/, "", s); return s }
    function flush() {
      if (url == "") return
      if (mid != "") print url "\tmachine\t" mid
      for (i = 1; i <= ncount; i++) if (nodes[i] != "") print url "\tnode\t" nodes[i]
    }
    BEGIN { ininst=0; url=""; mid=""; ncount=0; inpanel=0 }
    /^instances:[[:space:]]*$/ { ininst=1; next }
    ininst && /^[^[:space:]#]/ { flush(); exit }
    !ininst { next }
    /^[[:space:]]*-[[:space:]]*(panel:)?[[:space:]]*$/ {
      flush(); url=""; mid=""; ncount=0; delete nodes; inpanel=($0 ~ /panel:/); next
    }
    /^[[:space:]]+panel:[[:space:]]*$/ { inpanel=1; next }
    /^[[:space:]]+(machine|kernel|log|audit|runtime|ws|cert|node|nodes):[[:space:]]*$/ { inpanel=0; next }
    inpanel && /^[[:space:]]+url:[[:space:]]*/ {
      v=$0; sub(/^[^:]*:[[:space:]]*/, "", v); sub(/[[:space:]]*#.*$/, "", v); url=trim(v); next
    }
    /^[[:space:]]+machine_id:[[:space:]]*/ {
      v=$0; sub(/.*machine_id:[[:space:]]*/, "", v); sub(/[^0-9].*$/, "", v); mid=v; next
    }
    /^[[:space:]]+(-[[:space:]]*)?node_id:[[:space:]]*/ {
      v=$0; sub(/.*node_id:[[:space:]]*/, "", v); sub(/[^0-9].*$/, "", v)
      if (v != "") nodes[++ncount]=v
    }
    END { if (ininst) flush() }
  ' "$CONFIG_FILE" 2>/dev/null | awk '!seen[$0]++'
}

instances_summary() {
  local rows count=0
  rows=$(config_instance_targets || true)
  if [ -z "$rows" ]; then
    hint "（instances 已启用，但没有解析到目标）"
    return 0
  fi
  while IFS=$'\t' read -r url mode id; do
    [ -n "$url" ] || continue
    count=$((count+1))
    if [ "$mode" = "machine" ]; then
      echo "    $count) $url · machine_id=$id"
    else
      echo "    $count) $url · node_id=$id"
    fi
  done <<EOF
$rows
EOF
}

current_target_exists() {
  local url="${1%/}" mode="$2" id="$3"
  if config_uses_instances; then
    config_instance_targets | awk -F'\t' -v u="$url" -v m="$mode" -v i="$id" '
      $1 == u && $2 == m && $3 == i { found=1 }
      END { exit(found ? 0 : 1) }
    '
    return $?
  fi

  local cur_url
  cur_url=$(_sec_get panel url || true)
  cur_url="${cur_url%/}"
  [ "$cur_url" = "$url" ] || return 1
  if [ "$mode" = "machine" ]; then
    [ "$(_sec_get machine machine_id || true)" = "$id" ]
    return $?
  fi
  if [ "$(_sec_get panel node_id || true)" = "$id" ]; then
    return 0
  fi
  grep -qE "^[[:space:]]*-[[:space:]]*node_id:[[:space:]]*$id([[:space:]]|$)" "$CONFIG_FILE" 2>/dev/null
}

wrap_config_as_instances() {
  config_uses_instances && return 0
  local tmp="$CONFIG_FILE.instances.$$"
  {
    echo "# Multi-panel layout managed by tx-node deploy.sh"
    echo "instances:"
    echo "  -"
    sed 's/^/    /' "$CONFIG_FILE"
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$CONFIG_FILE"
}

render_instance_block() {
  if [ "$MODE_STR" = "machine" ]; then
    cat <<EOF
  - panel:
      provider: "${PANEL_PROVIDER:-xboard}"
      url: "$PANEL_URL"
    machine:
      machine_id: $MACHINE_ID
      token: "$MACHINE_TOKEN"
    kernel:
      type: "$KERNEL"
    log:
      level: "$LOG_LEVEL"
    audit:
      enabled: $AUDIT_ENABLED
      report_all: $REPORT_ALL
EOF
  else
    cat <<EOF
  - panel:
      provider: "${PANEL_PROVIDER:-xboard}"
      url: "$PANEL_URL"
      token: "$NODE_TOKEN"
      node_id: $NODE_ID
    kernel:
      type: "$KERNEL"
    log:
      level: "$LOG_LEVEL"
    audit:
      enabled: $AUDIT_ENABLED
      report_all: $REPORT_ALL
EOF
  fi
}

append_instance_block() {
  local block_file="$1" tmp="$CONFIG_FILE.append.$$"
  awk -v bf="$block_file" '
    function emit() { while ((getline line < bf) > 0) print line; close(bf) }
    BEGIN { ininst=0; inserted=0 }
    /^instances:[[:space:]]*$/ { ininst=1; print; next }
    ininst && /^[^[:space:]#]/ {
      if (!inserted) { emit(); inserted=1 }
      ininst=0
    }
    { print }
    END { if (ininst && !inserted) emit() }
  ' "$CONFIG_FILE" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$CONFIG_FILE"
}

configured_health_port() {
  [ -f "$CONFIG_FILE" ] || return 0
  grep -m1 -E '^[[:space:]]*health_port:[[:space:]]*[0-9]+' "$CONFIG_FILE" 2>/dev/null \
    | sed -E 's/.*health_port:[[:space:]]*//' | tr -cd '0-9'
}

wait_configured_health() {
  local hp seconds="${1:-10}" i=0
  hp=$(configured_health_port || true)
  [ -n "$hp" ] && [ "$hp" -gt 0 ] 2>/dev/null || return 0
  while [ "$i" -lt "$seconds" ]; do
    curl -fsS "http://127.0.0.1:$hp/healthz" >/dev/null 2>&1 && return 0
    sleep 1
    i=$((i+1))
  done
  return 1
}

runtime_has_bind_conflict() {
  docker logs --since 20s "$APP_NAME" 2>&1 \
    | grep -qiE 'address already in use|bind:.*in use|failed to (listen|bind)|port .*already.*use'
}

restart_after_instance_change() {
  local rollback="$1"
  runtime_set_restart_policy "no"
  if docker restart "$APP_NAME" >/dev/null 2>&1 \
    && wait_container_stable 6 \
    && ! runtime_has_bind_conflict \
    && wait_configured_health 12; then
    promote_restart_policy
    ok "新实例已生效"
    return 0
  fi

  warn "新实例启动验证失败，自动恢复原配置"
  cp -f "$rollback" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
  docker restart "$APP_NAME" >/dev/null 2>&1 || true
  wait_container_stable 6 && promote_restart_policy || true
  return 1
}

do_add_panel_instance() {
  detect_deploy_mode
  [ "$DEPLOY_MODE" = "docker" ] || { warn "需要先有 txnode docker 部署"; return 1; }
  [ -f "$CONFIG_FILE" ] || fail "配置文件不存在: $CONFIG_FILE"

  title "添加面板 / 实例"
  hint "推荐：同一个 tx-node 容器用 instances[] 同时连接多个 TXBoard。"
  if [ "${NONINTERACTIVE_INSTALL:-0}" != "1" ]; then
    read_panel_credentials
  fi

  local target_mode target_id
  if [ "$MODE_STR" = "machine" ]; then
    target_mode="machine"; target_id="$MACHINE_ID"
  else
    target_mode="node"; target_id="$NODE_ID"
  fi

  if current_target_exists "$PANEL_URL" "$target_mode" "$target_id"; then
    warn "该面板目标已经存在：$PANEL_URL · ${target_mode}_id=$target_id"
    return 0
  fi

  if [ "${NONINTERACTIVE_INSTALL:-0}" != "1" ]; then
    if ! confirm "把该目标加入当前 tx-node 容器？" "Y"; then
      info "已取消"; return 0
    fi
  else
    info "检测到已有 TX-Node，非交互安装将追加为新的 panel instance"
  fi

  mkdir -p "$BACKUP_DIR"
  local rollback="$BACKUP_DIR/pre-instance-add.$(date +%Y%m%d-%H%M%S).yml"
  cp -a "$CONFIG_FILE" "$rollback"

  wrap_config_as_instances
  local block="$INSTALL_DIR/.instance.$$"
  render_instance_block > "$block"
  append_instance_block "$block"
  rm -f "$block"

  if restart_after_instance_change "$rollback"; then
    instances_summary
    return 0
  fi
  return 1
}

port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$p$"
    return $?
  fi
  return 1
}

find_free_health_port() {
  local p="${1:-65531}" end=$((${1:-65531} + 200))
  while [ "$p" -le "$end" ]; do
    if ! port_in_use "$p"; then echo "$p"; return 0; fi
    p=$((p+1))
  done
  return 1
}

find_next_isolated_suffix() {
  local n=2
  while [ "$n" -lt 100 ]; do
    local name="tx-node-$n" dir="$ISOLATED_ROOT_BASE-$n" cli="$ISOLATED_CLI_BASE-$n"
    if [ ! -e "$dir" ] && [ ! -e "$cli" ] \
      && ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
      echo "$n"
      return 0
    fi
    n=$((n+1))
  done
  return 1
}

do_install_isolated() {
  ensure_docker
  local suffix hp runner
  suffix=$(find_next_isolated_suffix) || fail "无法分配新的隔离实例编号"
  hp=$(find_free_health_port $((65529 + suffix))) || fail "无法找到空闲健康检查端口"

  local child_name="tx-node-$suffix"
  local child_dir="$ISOLATED_ROOT_BASE-$suffix"
  local child_cli="$ISOLATED_CLI_BASE-$suffix"

  title "创建隔离 TX-Node"
  echo "  容器:     $child_name"
  echo "  配置目录: $child_dir"
  echo "  快捷命令: $child_cli"
  echo "  健康端口: $hp"
  hint "仍使用 host network；若面板下发的服务端口冲突，启动验证会失败。"
  confirm "继续？" "Y" || return 0

  runner="$SELF_COPY"
  if ! materialize_self_copy; then
    self_path_is_persistent "$SELF_PATH" || fail "无法取得持久化 deploy.sh"
    runner="$SELF_PATH"
  fi

  APP_NAME="$child_name" \
  INSTALL_DIR="$child_dir" \
  CLI_LINK="$child_cli" \
  TXNODE_HEALTH_PORT="$hp" \
  IMAGE="$IMAGE" \
  TXNODE_ISOLATED_ROOT_BASE="$ISOLATED_ROOT_BASE" \
  TXNODE_ISOLATED_CLI_BASE="$ISOLATED_CLI_BASE" \
    bash "$runner" install
}

do_existing_install() {
  title "检测到已有 TX-Node"
  echo "  1) 添加新的面板 / 实例（推荐）"
  echo "  2) 创建完全隔离的第二个 TX-Node"
  echo "  3) 覆盖重配当前实例"
  echo "  0) 取消"
  read -r -p "选择 [0-3]: " c || return 0
  case "$c" in
    1) do_add_panel_instance ;;
    2) do_install_isolated ;;
    3)
      confirm "确认覆盖当前 config.yml？" "n" || return 0
      read_panel_credentials
      backup_config
      write_config_files
      do_restart
      ;;
    *) return 0 ;;
  esac
}

validate_instances_config() {
  local rows errs=0 count=0 duplicates
  rows=$(config_instance_targets || true)
  if [ -z "$rows" ]; then
    warn "instances 段存在，但没有解析到有效目标"
    return 1
  fi

  while IFS=$'\t' read -r url mode id; do
    [ -n "$url" ] || continue
    count=$((count+1))
    [[ "$url" =~ ^https?:// ]] || { warn "无效 panel.url: $url"; errs=$((errs+1)); }
    [[ "$id" =~ ^[0-9]+$ ]] && [ "$id" -gt 0 ] || { warn "无效 ${mode}_id: $id"; errs=$((errs+1)); }
  done <<EOF
$rows
EOF

  duplicates=$(printf '%s\n' "$rows" | sort | uniq -d)
  if [ -n "$duplicates" ]; then
    warn "发现重复面板目标："
    printf '%s\n' "$duplicates"
    errs=$((errs+1))
  fi

  if [ "$errs" -eq 0 ]; then
    ok "多面板配置校验通过：$count 个目标"
    return 0
  fi
  return 1
}

# ════════════════════════════════════════════════════════════════════
#  动作：多节点 / 多机器（基于 nodes 段）
# ════════════════════════════════════════════════════════════════════
# 读取 config 里 nodes: 段的现状
nodes_summary() {
  [ -f "$CONFIG_FILE" ] || return 0
  if config_uses_instances; then
    instances_summary
    return 0
  fi
  if ! grep -qE '^nodes:' "$CONFIG_FILE" 2>/dev/null; then
    hint "（当前是单节点/machine 模式，未使用 nodes 段）"
    return 0
  fi
  echo "  当前 nodes 段内容："
  awk '/^nodes:/{f=1} f&&/^[^[:space:]#]/&&!/^nodes:/{f=0} f{print "    "$0}' "$CONFIG_FILE"
}

do_add_node() {
  detect_deploy_mode
  if config_uses_instances; then
    warn "当前已启用 instances 多面板布局，请使用「添加面板 / 实例」。"
    return 0
  fi
  if [ "$DEPLOY_MODE" = "legacy" ]; then
    warn "当前只有 install.sh legacy 部署；其管理面已冻结"
    hint "请先执行 txnode migrate（或菜单「从 install.sh 导入」）迁移到 Docker，再管理节点"
    return 0
  fi

  # docker 模式：往 config.yml 的 nodes 段追加
  [ -f "$CONFIG_FILE" ] || fail "配置文件不存在，请先安装"
  title "添加节点（多节点模式）"
  warn "加入 nodes 段后，panel.node_id 将被忽略，本进程会同时服务 nodes 段里的全部节点"
  hint "前提：这些节点与当前配置的 panel.url / token 相同"

  local nid ntype
  read -r -p "node_id（要新增的节点 ID）: " nid
  [[ "$nid" =~ ^[0-9]+$ ]] && [ "$nid" -gt 0 ] || fail "node_id 必须是正整数"

  # 去重
  if grep -qE "^[[:space:]]*-[[:space:]]*node_id:[[:space:]]*${nid}([[:space:]]|$)" "$CONFIG_FILE" 2>/dev/null; then
    warn "node_id ${nid} 已存在于 nodes 段"; return 0
  fi

  read -r -p "node_type（可留空，面板可自动识别）: " ntype

  backup_config
  # 确保存在 nodes: 段
  if ! grep -qE '^nodes:' "$CONFIG_FILE" 2>/dev/null; then
    printf '\n# 多节点：本进程同时服务以下节点（panel.node_id 被忽略）\nnodes:\n' >> "$CONFIG_FILE"
  fi
  {
    echo "  - node_id: $nid"
    [ -n "$ntype" ] && echo "    node_type: \"$ntype\""
  } >> "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
  ok "已添加 node_id=$nid 到 nodes 段"
  nodes_summary
  confirm "立即重启生效？" "Y" && do_restart || hint "稍后重启生效"
}

do_remove_node() {
  detect_deploy_mode
  if config_uses_instances; then
    warn "当前已启用 instances 多面板布局；请手动编辑对应 instance，避免误删其它面板。"
    return 0
  fi
  [ -f "$CONFIG_FILE" ] || fail "配置文件不存在"
  if ! grep -qE '^nodes:' "$CONFIG_FILE" 2>/dev/null; then
    warn "当前没有 nodes 段（单节点模式）"
    hint "要改单节点的 node_id，请用「重新配置」"
    return 0
  fi
  title "移除节点"
  nodes_summary
  local nid
  read -r -p "  要移除的 node_id: " nid
  [[ "$nid" =~ ^[0-9]+$ ]] || fail "node_id 必须是正整数"
  if ! grep -qE "^[[:space:]]*-[[:space:]]*node_id:[[:space:]]*${nid}([[:space:]]|$)" "$CONFIG_FILE" 2>/dev/null; then
    warn "nodes 段中没有 node_id=$nid"; return 0
  fi
  if ! confirm "确认移除 node_id=$nid？" "n"; then info "已取消"; return 0; fi

  backup_config
  # 删除该 node 条目（含紧随其后的缩进子字段，直到下一个 - node_id 或段结束）
  awk -v target="$nid" '
    function is_entry(l) { return l ~ /^[[:space:]]*-[[:space:]]*node_id:/ }
    function is_top(l)   { return l ~ /^[^[:space:]#]/ }
    {
      if (is_entry($0)) {
        if (in_skip) in_skip=0
        n=$0; sub(/.*node_id:[[:space:]]*/, "", n); sub(/[^0-9].*$/, "", n)
        if (n == target) { in_skip=1; next }
      } else if (in_skip && is_top($0)) {
        in_skip=0
      }
      if (!in_skip) print
    }
  ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
  ok "已移除 node_id=$nid"
  nodes_summary
  confirm "立即重启生效？" "Y" && do_restart || hint "稍后重启生效"
}

do_machine_mode() {
  detect_deploy_mode
  if config_uses_instances; then
    warn "当前已启用 instances 多面板布局，请通过「添加面板 / 实例」新增 machine instance。"
    return 0
  fi
  title "机器模式设置"
  echo "  机器模式下，本进程通过 machine token 接管面板上绑定到该机器的【全部】节点。"
  echo "  优点：面板上加节点无需改本机配置。"
  echo
  echo "  1) 切换到机器模式（用 machine_id + 令牌重配）"
  echo "  2) 切回单节点模式"
  echo "  3) 返回"
  read -r -p "选择 [1-3]: " c
  case "$c" in
    1)
      [ "$DEPLOY_MODE" = "legacy" ] && {
        warn "当前只有 install.sh legacy 部署；请先迁移到 txnode Docker 再切换 Machine mode"
        hint "执行: txnode migrate"
        return 0
      }
      [ "$DEPLOY_MODE" = "docker" ] || { warn "txnode 尚未部署，请先安装或从 install.sh 导入"; return 0; }
      local url mid tok
      read -r -p "面板地址: " url || return 0
      url="${url%/}"
      [[ "$url" =~ ^https?:// ]] || fail "面板地址必须以 http:// 或 https:// 开头"
      read -r -p "machine_id: " mid
      [[ "$mid" =~ ^[0-9]+$ ]] && [ "$mid" -gt 0 ] || fail "machine_id 必须是正整数"
      read -r -s -p "machine token（不回显）: " tok; echo
      [ -n "$tok" ] || fail "machine token 不能为空"
      backup_config
      cat > "$CONFIG_FILE" <<EOF
# Generated by tx-node deploy.sh ($(date '+%Y-%m-%d %H:%M:%S'))
panel:
  url: "$url"
machine:
  machine_id: $mid
  token: "$tok"

kernel:
  type: "singbox"

log:
  level: "info"

audit:
  enabled: true
  report_all: false
EOF
      chmod 600 "$CONFIG_FILE"
      ok "已切换为机器模式 (machine_id=$mid)"
      confirm "立即重启生效？" "Y" && do_restart || hint "稍后重启生效"
      ;;
    2)
      if ! grep -qE '^machine:' "$CONFIG_FILE" 2>/dev/null; then
        warn "当前不是机器模式"; return 0
      fi
      info "切回单节点模式需要 node_id 与 server token，将走完整配置向导"
      do_reconfigure
      ;;
    *) return 0 ;;
  esac
}

# ════════════════════════════════════════════════════════════════════
#  Legacy install.sh runtime cleanup
#  This is the Installer-owned replacement for the retired xbctl uninstall
#  path. It never touches the canonical Docker deployment under /etc/txnode.
# ════════════════════════════════════════════════════════════════════
do_legacy_cleanup() {
  local purge=0 yes=0 arg
  for arg in "$@"; do
    case "$arg" in
      --purge) purge=1 ;;
      --yes|-y) yes=1 ;;
      *) fail "legacy-cleanup 不支持参数: $arg" ;;
    esac
  done

  if ! detect_legacy_install; then
    info "未检测到 install.sh / systemd legacy 部署，无需清理"
    return 0
  fi

  title "清理 install.sh legacy runtime"
  echo "  服务:     $SERVICE_NAME"
  echo "  二进制:   $SB_BINARY"
  echo "  旧命令:   $XBCTL_PATH"
  echo "  配置目录: $LEGACY_INSTALL_ROOT"
  if [ "$purge" = "1" ]; then
    warn "将同时删除 legacy 配置目录；canonical /etc/txnode 不受影响"
  else
    hint "默认只删除 legacy runtime，保留 $LEGACY_INSTALL_ROOT 供审计/回滚"
  fi

  if [ "$yes" != "1" ]; then
    if [ "$purge" = "1" ]; then
      confirm_typed " " "LEGACY-PURGE" || { info "已取消"; return 0; }
    else
      confirm "确认删除 legacy systemd runtime？" "n" || { info "已取消"; return 0; }
    fi
  fi

  local warnings=()

  if [ -f "$SERVICE_PATH" ]; then
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    if ! rm -f "$SERVICE_PATH"; then
      warnings+=("remove service file: $SERVICE_PATH")
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  for legacy_bin in "$SB_BINARY" "$XBCTL_PATH" "$XBCTL_COMPAT_PATH"; do
    if [ -e "$legacy_bin" ] || [ -L "$legacy_bin" ]; then
      rm -f "$legacy_bin" || warnings+=("remove $legacy_bin")
    fi
  done

  if [ "$purge" = "1" ]; then
    rm -rf "$LEGACY_INSTALL_ROOT" || warnings+=("remove $LEGACY_INSTALL_ROOT")
  fi

  if [ -f "$SERVICE_PATH" ] || [ -x "$SB_BINARY" ] || [ -x "$XBCTL_PATH" ]; then
    warnings+=("legacy runtime markers still detected")
  fi

  if [ "${#warnings[@]}" -gt 0 ]; then
    warn "legacy cleanup 完成，但有以下残留："
    local item
    for item in "${warnings[@]}"; do
      echo "  - $item"
    done
    return 1
  fi

  ok "legacy systemd runtime 已清理"
  if [ "$purge" != "1" ] && [ -d "$LEGACY_INSTALL_ROOT" ]; then
    hint "legacy 配置仍保留在 $LEGACY_INSTALL_ROOT"
  fi
}

# ════════════════════════════════════════════════════════════════════
#  动作：卸载 / 彻底清除
# ════════════════════════════════════════════════════════════════════
do_uninstall() {
  detect_deploy_mode
  ! is_installed && fail "未检测到已部署的 tx-node"

  title "卸载 tx-node（保留配置）"
  hint "容器/服务与命令会被移除，配置保留在 $INSTALL_DIR"
  hint "如需连配置一起删除，请用「彻底清除」"

  if ! confirm "确认卸载？" "n"; then info "已取消"; return 0; fi

  case "$DEPLOY_MODE" in
    docker)
      dc down 2>/dev/null || docker rm -f "$APP_NAME" 2>/dev/null || true
      # 停用 compose 但保留文件（重装时可直接复用）
      [ -f "$COMPOSE_FILE" ] && mv "$COMPOSE_FILE" "$COMPOSE_FILE.uninstalled" 2>/dev/null || true
      ;;
    legacy)
      warn "检测到 install.sh 部署（${SERVICE_NAME}）"
      hint "txnode 的卸载不会动它 —— 它有自己的卸载入口"
      hint "如需清理 legacy runtime，请执行: txnode legacy-cleanup [--purge]"
      ;;
  esac

  rm -f "$CLI_LINK" 2>/dev/null || true
  ok "已卸载，配置保留在 $INSTALL_DIR"
  hint "重新安装: bash $SELF_PATH install"
}

do_purge() {
  detect_deploy_mode
  title "彻底清除 tx-node"
  echo -e "${RED}  将删除以下内容：${NC}"
  echo "    - txnode 容器"
  echo "    - compose / 配置 / 备份（$INSTALL_DIR）"
  echo "    - 拉取的镜像 $IMAGE"
  echo "    - 快捷命令 $CLI_LINK"
  echo -e "${DIM}    （install.sh 的 /etc/xboard-node 不在范围内）${NC}"
  if [ "$DEPLOY_MODE" = "none" ]; then
    warn "未检测到部署，但仍会清理残留文件与镜像"
  fi

  if ! confirm_typed " " "PURGE"; then
    info "已取消（输入不匹配）"; return 0
  fi

  case "$DEPLOY_MODE" in
    docker)
      dc down -v 2>/dev/null || docker rm -f "$APP_NAME" 2>/dev/null || true
      ;;
    legacy)
      warn "检测到 install.sh 部署 —— txnode 的 purge 不会删除它"
      hint "如需清理 install.sh legacy 部署，请执行: txnode legacy-cleanup --purge"
      ;;
  esac

  rm -f "$CLI_LINK" 2>/dev/null || true
  rm -rf "$INSTALL_DIR"
  ok "已删除 $INSTALL_DIR"

  # 删镜像（先确认没有其他容器在用）
  if command -v docker >/dev/null 2>&1; then
    if docker images -q "$IMAGE" >/dev/null 2>&1 && [ -n "$(docker images -q "$IMAGE" 2>/dev/null)" ]; then
      docker rmi "$IMAGE" >/dev/null 2>&1 && ok "已删除镜像 $IMAGE" \
        || warn "镜像删除失败（可能仍被其他容器引用）"
    fi
    # 清理同名旧镜像的悬空层
    docker image prune -f >/dev/null 2>&1 || true
  fi

  echo
  ok "彻底清除完成，系统已恢复干净状态"
  hint "如需重新部署: bash <(curl -fsSL https://raw.githubusercontent.com/ANRCM0/TX-Node-Installer/main/deploy.sh)"
}

# ════════════════════════════════════════════════════════════════════
#  动作：健康检查 / 诊断
# ════════════════════════════════════════════════════════════════════
do_doctor() {
  detect_deploy_mode
  title "诊断"
  echo -e "  1) 部署模式: ${BOLD}${DEPLOY_MODE}${NC}"

  # Docker 环境
  if command -v docker >/dev/null 2>&1; then
    echo "  Docker: $(docker --version 2>/dev/null | head -1)"
    if docker compose version >/dev/null 2>&1; then
      echo "  compose: 可用"
    else
      warn "compose 插件不可用"
    fi
  else
    warn "未安装 docker"
  fi

  # 系统资源
  echo
  echo -e "  ${BOLD}系统${NC}"
  echo "    CPU 核数: $(nproc 2>/dev/null || echo '?')"
  if [ -r /proc/meminfo ]; then
    local mt ma
    mt=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
    # 老内核没有 MemAvailable，退化用 MemFree
    ma=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
    [ -n "$ma" ] || ma=$(awk '/^MemFree:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
    if [ -n "$mt" ] && [ -n "$ma" ]; then
      echo "    内存: ${ma}MB 可用 / ${mt}MB 总计"
    elif [ -n "$mt" ]; then
      echo "    内存: ${mt}MB 总计"
    fi
  fi
  echo "    磁盘 ${INSTALL_DIR}: $(df -h "$INSTALL_DIR" 2>/dev/null | awk 'NR==2{print $4" 可用 / "$2" 总计 ("$5" 已用)"}' || echo '?')"

  # 端口占用（节点需要监听面板下发配置里的端口，这里只做提示）
  echo
  echo -e "  ${BOLD}网络${NC}"
  local panel_url
  panel_url=$(_sec_get panel url || true)
  if [ -n "$panel_url" ]; then
    echo "    面板地址: $panel_url"
    if curl -fsS -o /dev/null -m 8 "$panel_url" 2>/dev/null; then
      ok "    面板可达"
    else
      warn "    面板不可达（检查网络 / 域名解析 / 防火墙）"
    fi
  fi

  # 容器细节
  if [ "$DEPLOY_MODE" = "docker" ]; then
    echo
    echo -e "  ${BOLD}容器${NC}"
    echo "    状态: $(container_state)"
    local restarts
    restarts=$(docker inspect -f '{{.RestartCount}}' "$APP_NAME" 2>/dev/null || echo "?")
    echo "    重启次数: $restarts"
    [ "$restarts" != "0" ] && [ "$restarts" != "?" ] && warn "重启次数偏高，可能有崩溃循环，请查看日志"
  fi

  # 审计状态检查
  if [ "$DEPLOY_MODE" = "docker" ] && [ "$(container_state)" = "running" ]; then
    echo
    echo -e "  ${BOLD}审计模块${NC}"
    if docker logs "$APP_NAME" 2>&1 | grep -q "audit reporter enabled"; then
      ok "    已启用并连接面板"
      # 检查空规则告警（这个坑很常见）
      if docker logs "$APP_NAME" 2>&1 | grep -q "report_all=false"; then
        warn "    日志提示 report_all=false —— 若面板无启用规则则不会上报任何数据"
        hint "    详见 README「最常见的坑」一节"
      fi
      local rep
      rep=$(docker logs "$APP_NAME" 2>&1 | grep -c "audit: reported" || true)
      [ "${rep:-0}" -gt 0 ] && echo "    已成功上报批次: $rep" || hint "    尚未观察到成功上报"
    else
      hint "    未启用（或日志已滚动）"
    fi
  fi

  echo
  ok "诊断完成"
}

# ════════════════════════════════════════════════════════════════════
#  交互式主菜单
# ════════════════════════════════════════════════════════════════════
banner() {
  clear 2>/dev/null || true
  detect_deploy_mode
  echo -e "${BOLD}${CYAN}"
  cat <<'ASCII'
   ████████ ██   ██       ███    ██  ██████  ██████  ███████
      ██     ██ ██        ████   ██ ██    ██ ██   ██ ██
      ██      ███         ██ ██  ██ ██    ██ ██   ██ █████
      ██     ██ ██        ██  ██ ██ ██    ██ ██   ██ ██
      ██    ██   ██       ██   ████  ██████  ██████  ███████
ASCII
  echo -e "${NC}"
  local state_txt state_color
  case "$DEPLOY_MODE" in
    docker)
      local cst; cst=$(container_state)
      case "$cst" in
        running) state_color="$GREEN"; state_txt="运行中" ;;
        *)       state_color="$YELLOW"; state_txt="$cst" ;;
      esac
      echo -e "   状态: ${state_color}● ${state_txt}${NC}  ${DIM}(docker · $APP_NAME)${NC}"
      ;;
    legacy)
      local sst; sst=$(svc_state)
      case "$sst" in
        active) state_color="$GREEN"; state_txt="运行中" ;;
        *)      state_color="$YELLOW"; state_txt="$sst" ;;
      esac
      echo -e "   状态: ${state_color}● ${state_txt}${NC}  ${DIM}(install.sh · $SERVICE_NAME)${NC}"
      echo -e "   ${YELLOW}检测到 install.sh 部署，可导入为 txnode${NC}"
      ;;
    *)
      echo -e "   状态: ${YELLOW}● 未部署${NC}"
      ;;
  esac
  hr
}

menu() {
  while true; do
    banner
    echo
    echo -e "  ${BOLD}运维面板${NC}"
    echo
    if is_installed; then
      echo -e "   ${BOLD}1${NC}) 查看状态            ${DIM}运行状态 / 配置摘要 / 健康检查${NC}"
      echo -e "   ${BOLD}2${NC}) 查看日志            ${DIM}实时跟踪${NC}"
      echo -e "   ${BOLD}3${NC}) 重启                ${DIM}改完配置后用这个${NC}"
      echo -e "   ${BOLD}4${NC}) 启动 / 停止         ${DIM}子菜单${NC}"
      echo -e "   ${BOLD}5${NC}) 升级                ${DIM}拉取当前渠道镜像并重建${NC}"
      echo -e "  ${BOLD}15${NC}) 切换稳定/开发版     ${DIM}切换渠道、健康检查、失败回滚${NC}"
      echo -e "   ${BOLD}6${NC}) 修改配置            ${DIM}向导 / 手编 / 日志级别${NC}"
      echo -e "   ${BOLD}7${NC}) 访问审计开关        ${DIM}一键开启 / 关闭审计上报${NC}"
      echo -e "   ${BOLD}8${NC}) 配置校验与诊断      ${DIM}排错用${NC}"
      echo -e "   ${BOLD}9${NC}) 节点与机器管理      ${DIM}多节点 / 机器模式${NC}"
      echo -e "  ${BOLD}10${NC}) 备份 / 恢复         ${DIM}配置备份与回滚${NC}"
      echo -e "  ${BOLD}11${NC}) 卸载                ${DIM}保留配置${NC}"
      echo -e "  ${BOLD}12${NC}) 彻底清除            ${RED}${DIM}删除全部数据（不可逆）${NC}"
      echo -e "  ${BOLD}13${NC}) 快捷命令            ${DIM}安装 / 重建 txnode 命令${NC}"
      if detect_legacy_install; then
        echo -e "  ${BOLD}14${NC}) 从 install.sh 导入   ${CYAN}${DIM}检测到 install.sh 部署，可转成 docker${NC}"
      fi
    else
      echo -e "   ${BOLD}1${NC}) 安装 / 部署         ${DIM}交互式向导${NC}"
      if detect_legacy_install; then
        echo -e "   ${BOLD}2${NC}) 从 install.sh 导入   ${CYAN}${DIM}提取 install.sh 配置并转成 docker${NC}"
      else
        echo -e "   ${BOLD}2${NC}) 从备份恢复         ${DIM}复用已有配置${NC}"
      fi
      echo -e "   ${BOLD}3${NC}) 诊断                ${DIM}检查环境${NC}"
    fi
    echo -e "   ${BOLD}0${NC}) 退出"
    echo
    # EOF（Ctrl+D / stdin 被关闭）时 read 返回非 0；不处理会变成死循环刷屏
    if ! read -r -p "  请选择: " opt; then
      echo; info "输入结束，退出"; exit 0
    fi
    opt="${opt//[[:space:]]/}"   # 容忍误输入的空格

    if ! is_installed; then
      # 有 install.sh 部署时，2 是「导入」；否则是「从备份恢复」
      if detect_legacy_install; then
        case "$opt" in
          1) do_install; pause ;;
          2) do_migrate_legacy; pause ;;
          3) do_doctor; pause ;;
          0) echo; info "再见"; exit 0 ;;
          *) warn "无效选项"; sleep 1 ;;
        esac
      else
        case "$opt" in
          1) do_install; pause ;;
          2) do_restore; pause ;;
          3) do_doctor; pause ;;
          0) echo; info "再见"; exit 0 ;;
          *) warn "无效选项"; sleep 1 ;;
        esac
      fi
      continue
    fi

    case "$opt" in
      1) do_status; pause ;;
      2) show_logs "" ;;
      3) do_restart; pause ;;
      4) menu_power ;;
      5) do_upgrade; pause ;;
      6) do_reconfigure; pause ;;
      7) do_audit; pause ;;
      8) do_validate; pause ;;
      9) menu_nodes ;;
      10) menu_backup ;;
      11) do_uninstall; pause ;;
      12) do_purge; pause ;;
      13) do_link; pause ;;
      14) do_migrate_legacy; pause ;;
      15) echo "当前渠道: $(current_compose_channel || echo 未知)"; read -r -p "切换至 stable/dev (留空取消): " ch || true; if [ -n "$ch" ]; then do_channel "$ch"; fi; pause ;;
      0) echo; info "再见"; exit 0 ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

menu_power() {
  while true; do
    banner
    echo
    echo -e "  ${BOLD}启动 / 停止${NC}"
    echo
    echo -e "   1) 启动                    ${DIM}启动成功后启用 unless-stopped${NC}"
    echo -e "   2) 停止                    ${DIM}手动停止后保持停止${NC}"
    echo -e "   3) 安全重启                ${DIM}失败时自动停止，避免重启循环${NC}"
    echo -e "   0) 返回"
    echo
    read -r -p "  请选择: " c || return 0
    case "$c" in
      1) do_start; pause ;;
      2) do_stop; pause ;;
      3) do_restart; pause ;;
      0) return ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

menu_nodes() {
  while true; do
    banner
    echo
    echo -e "  ${BOLD}节点与机器管理${NC}"
    echo
    nodes_summary
    echo
    echo -e "   1) 添加面板 / 实例       ${DIM}推荐：同一容器连接多个 TXBoard${NC}"
    echo -e "   2) 创建隔离 TX-Node      ${DIM}自动 tx-node-N / /etc/txnode-N${NC}"
    echo -e "   3) 添加同面板节点        ${DIM}旧 nodes 模式${NC}"
    echo -e "   4) 移除同面板节点        ${DIM}旧 nodes 模式${NC}"
    echo -e "   5) 机器模式设置          ${DIM}单面板旧布局${NC}"
    echo -e "   6) 查看当前配置摘要      ${DIM}含 instances / nodes / machine${NC}"
    echo -e "   0) 返回"
    echo
    read -r -p "  请选择: " c
    case "$c" in
      1) do_add_panel_instance; pause ;;
      2) do_install_isolated; pause ;;
      3) do_add_node; pause ;;
      4) do_remove_node; pause ;;
      5) do_machine_mode; pause ;;
      6) do_status; pause ;;
      0) return ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

menu_backup() {
  while true; do
    banner
    echo
    echo -e "  ${BOLD}备份 / 恢复${NC}"
    echo
    list_backups
    echo
    echo -e "   1) 立即备份              ${DIM}打包 config.yml + compose${NC}"
    echo -e "   2) 从备份恢复            ${DIM}覆盖当前配置${NC}"
    echo -e "   3) 查看备份列表 / 路径   ${DIM}$BACKUP_DIR${NC}"
    echo -e "   4) 清理旧备份            ${DIM}保留最近 10 份${NC}"
    echo -e "   0) 返回"
    echo
    read -r -p "  请选择: " c
    case "$c" in
      1) do_backup; pause ;;
      2) do_restore; pause ;;
      3) title "备份列表"; list_backups; pause ;;
      4) prune_backups; pause ;;
      0) return ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

prune_backups() {
  [ -d "$BACKUP_DIR" ] || { warn "没有备份目录"; return 0; }
  local files count
  mapfile -t files < <(ls -1t "$BACKUP_DIR" 2>/dev/null || true)
  count=${#files[@]}
  if [ "$count" -le 10 ]; then
    hint "备份数量 $count ≤ 10，无需清理"
    return 0
  fi
  info "共 $count 份备份，将保留最近 10 份"
  local i=10
  while [ "$i" -lt "$count" ]; do
    rm -f "$BACKUP_DIR/${files[$i]}" 2>/dev/null || true
    i=$((i+1))
  done
  ok "已清理 $((count-10)) 份旧备份"
}

# ════════════════════════════════════════════════════════════════════
#  非交互 CLI 入口
# ════════════════════════════════════════════════════════════════════
usage() {
  cat <<'HELP'

  tx-node 部署与运维脚本

  用法:
    bash deploy.sh              进入交互式运维面板（推荐）
    bash deploy.sh <命令>       非交互执行单个命令

  命令:
    install        安装 / 重新部署（无参数时进入交互式向导）
      --mode machine --provider txboard --panel-url URL --machine-id ID --token TOKEN
                   非交互机器模式安装（TXBoard 一键安装使用）
      --mode node --panel-url URL --node-id ID --token TOKEN
                   非交互单节点安装
      [--provider xboard|txboard] [--channel stable|dev] [--kernel singbox|xray] [--log-level info|debug|warn|error]
      [--audit true|false] [--report-all true|false]
    migrate        从 install.sh 部署导入配置并转成 docker 部署
    migrate --dry-run
                   只预览将要生成的配置，不写入任何文件
    legacy-cleanup 删除旧 install.sh/systemd runtime，默认保留旧配置
      [--purge] [--yes]
                   --purge 同时删除 /etc/xboard-node；不会删除 /etc/txnode
    upgrade [stable|dev]  升级当前渠道，或指定渠道切换并升级
    channel [stable|dev]  查看或切换稳定版/开发版
    status         查看运行状态与配置摘要
    start          启动
    stop           停止
    restart        重启
    pause          兼容旧命令；现在等价于 stop
    logs           查看实时日志
    reconfigure    修改配置
    audit          访问审计开关（见下方）
    validate       配置校验
    doctor         环境与运行诊断
    panel-add      向当前容器添加新的面板 / 实例
    isolated-add   自动创建 tx-node-N 隔离实例
    backup         备份当前配置
    restore        从备份恢复
    uninstall      卸载（保留配置）
    purge          彻底清除（删除配置、镜像，不可逆）
    link           安装 / 重建快捷命令 txnode
    help           显示本帮助

  访问审计（audit）一键设置:
    txnode audit           显示当前状态并交互式切换
    txnode audit on        一键开启审计（enabled=true）
    txnode audit off       一键关闭审计（enabled=false）
    txnode audit all on    一键开全量上报（report_all=true）
    txnode audit all off   仅上报命中规则的连接（report_all=false）

    注：report_all=false 时，若面板没配任何启用规则，一条数据都不会上报。
        要"全量访问日志"请用 all on；要"只记命中"请 all off 并在面板配规则。

  关于 install.sh 导入:
    txnode 使用独立目录 /etc/txnode，与 install.sh 的 /etc/xboard-node 完全分离，
    两者可并存。检测到 install.sh 部署时进入面板会自动询问是否导入。
    转换流程：提取配置 → 启动 txnode → 停止 install.sh 服务（其配置保留可回滚）。

  示例:
    bash deploy.sh                       # 进面板
    bash deploy.sh install               # 交互式安装
    bash deploy.sh install --mode machine --panel-url https://panel.example.com --machine-id 12 --token TOKEN
                                         # 非交互机器模式安装
    bash deploy.sh migrate               # 从 install.sh 导入
    bash deploy.sh migrate --dry-run     # 只看会生成什么
    bash deploy.sh upgrade               # 直接升级
    bash deploy.sh uninstall             # 卸载

  装好后可直接用快捷命令:
    txnode                               # 进运维面板
    txnode status                        # 同上，直接看状态

  快捷命令没生效？
    用 bash <(curl ...) 安装时，脚本自身路径是 /dev/fd/63 这类临时文件，
    软链会在进程退出后失效。执行下面这条即可重建（会重新拉一份脚本到
    /etc/txnode/deploy.sh 再软链过去）：
      bash deploy.sh link

HELP
}

main() {
  local action="${1:-}"

  if [ -z "$action" ]; then
    # 无参数 → 交互面板
    [ "$(id -u)" -eq 0 ] || fail "请用 root 运行（或 sudo bash $0）"
    [ -d /etc ] || fail "仅支持 Linux"
    detect_deploy_mode
    # 已部署机器：在线打开菜单时自动刷新持久化脚本并自愈 txnode 快捷命令。
    if is_installed; then
      ensure_cli_link
    fi
    # 检测到 install.sh 部署且本机尚无 txnode → 主动询问是否导入
    if detect_legacy_install && ! is_installed; then
      clear 2>/dev/null || true
      banner
      echo
      hint "检测到 install.sh 部署（$LEGACY_INSTALL_ROOT / $SERVICE_NAME）"
      hint "txnode 使用独立目录 $INSTALL_DIR，两者可并存；也可以把它的配置直接导入转换。"
      echo
      if confirm "是否现在把 install.sh 部署导入为 txnode（docker）？" "n"; then
        if do_migrate_legacy; then
          pause
        else
          warn "导入未完成，可稍后在面板里选「从 install.sh 导入」重试"
          sleep 2
        fi
      else
        hint "已跳过 —— 稍后可在面板里选「从 install.sh 导入」"
        sleep 1
      fi
    fi
    menu
    exit 0
  fi

  case "$action" in
    help|-h|--help) usage; exit 0 ;;
  esac

  shift || true

  # migrate 支持 --dry-run
  local mig_dry=0
  if [ "$action" = "migrate" ] || [ "$action" = "import" ]; then
    case "${1:-}" in
      --dry-run|-n) mig_dry=1; shift || true ;;
    esac
  fi

  # status/doctor 只读，但仍需 root 才能读配置与 systemd 状态
  [ "$(id -u)" -eq 0 ] || fail "请用 root 运行（或 sudo bash $0 $action）"
  [ -d /etc ] || fail "仅支持 Linux"

  case "$action" in
    install)     do_install "$@" ;;
    migrate|import) do_migrate_legacy "$mig_dry" ;;
    legacy-cleanup) do_legacy_cleanup "$@" ;;
    upgrade)     do_upgrade "${1:-}" ;;
    channel)     do_channel "${1:-}" ;;
    remote-upgrade-apply) do_remote_upgrade_apply ;;
    status)      do_status ;;
    start)       do_start ;;
    stop)        do_stop ;;
    restart)     do_restart ;;
    pause)       do_pause ;;
    logs|log)    detect_deploy_mode; show_logs "" ;;
    reconfigure) do_reconfigure ;;
    link)        do_link ;;
    audit)       do_audit "$@" ;;
    validate)    do_validate ;;
    doctor)      do_doctor ;;
    panel-add)   NONINTERACTIVE_INSTALL=0; do_add_panel_instance ;;
    isolated-add) NONINTERACTIVE_INSTALL=0; do_install_isolated ;;
    backup)      do_backup ;;
    restore)     do_restore ;;
    uninstall)   do_uninstall ;;
    purge)       do_purge ;;
    *)
      warn "未知命令: $action"
      usage
      exit 1
      ;;
  esac
}

# 仅在被直接执行时运行 main；被 source 时只加载函数定义（便于测试与复用）
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
