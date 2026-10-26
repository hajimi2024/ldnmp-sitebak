#!/usr/bin/env bash

set -Eeuo pipefail

VERSION="0.3.7"
APP_NAME="LDNMP 单站备份恢复工具"

WEB_ROOT="${SITEBAK_WEB_ROOT:-/home/web}"
SITE_ROOT="${SITEBAK_SITE_ROOT:-$WEB_ROOT/html}"
BACKUP_DIR="${SITEBAK_BACKUP_DIR:-/home}"
INSTALL_PATH="${SITEBAK_INSTALL_PATH:-/usr/local/bin/kk}"
UPDATE_URL="${SITEBAK_UPDATE_URL:-https://raw.githubusercontent.com/hajimi2024/ldnmp-sitebak/main/sitebak.sh}"
PROJECT_URL="https://github.com/hajimi2024/ldnmp-sitebak"
MIGRATION_LOG_DIR="${SITEBAK_MIGRATION_LOG_DIR:-/var/log/sitebak}"
MIGRATION_TMP_ROOT="${SITEBAK_MIGRATION_TMP_ROOT:-/tmp}"
MIGRATION_LOG_FILE=''

NGINX_CONF_DIRS=(
  "$WEB_ROOT/conf.d"
  "$WEB_ROOT/nginx/conf.d"
  "/etc/nginx/conf.d"
  "/etc/nginx/sites-enabled"
)

CERT_DIRS=(
  "$WEB_ROOT/certs"
  "$WEB_ROOT/cert"
  "/etc/letsencrypt"
)

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
LIGHT_GREEN=$'\033[0;92m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;96m'
CYAN=$'\033[0;36m'
NUMBER=$'\033[1;33m'
BOLD=$'\033[1;96m'
RESET=$'\033[0m'
NO_UNDERLINE=$'\033[24m'
LINK_OPEN=''
LINK_CLOSE=''
if [[ ${TERM:-} == dumb || -n ${NO_COLOR+x} ]] || [[ ! -t 1 && ! -t 2 ]]; then
  RED='' GREEN='' LIGHT_GREEN='' YELLOW='' BLUE='' CYAN='' NUMBER='' BOLD='' RESET='' NO_UNDERLINE=''
else
  LINK_OPEN=$'\033]8;;'"$PROJECT_URL"$'\033\\'
  LINK_CLOSE=$'\033]8;;\033\\'
fi

info() { printf '%s[INFO] %s%s\n' "$BLUE" "$*" "$RESET"; }
ok() { printf '%s[OK] %s%s\n' "$GREEN" "$*" "$RESET"; }
warn() { printf '%s[WARN] %s%s\n' "$YELLOW" "$*" "$RESET"; }
err() { printf '%s[ERROR] %s%s\n' "$RED" "$*" "$RESET" >&2; }
ui_prompt() { printf '%s%s%s' "$BOLD" "$1" "$NUMBER"; }

sanitize_migration_log_text() {
  sed -E \
    -e 's/((DB_)?PASSWORD|PASSWD|TOKEN|SECRET|PRIVATE_KEY|API_KEY)([[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1\3[REDACTED]/Ig' \
    -e 's/([[:space:]]--?password=)[^[:space:]]+/\1[REDACTED]/Ig' \
    -e 's#(mysql://[^:/@[:space:]]+:)[^@[:space:]]+@#\1[REDACTED]@#Ig'
}

migration_log_init() {
  local mode="${1:-migration}" stamp old_umask created
  need_cmd install mktemp chmod date sed
  install -d -m 0700 "$MIGRATION_LOG_DIR"
  chmod 0700 "$MIGRATION_LOG_DIR"
  stamp="$(date +'%Y%m%d_%H%M%S')"
  old_umask="$(umask)"
  umask 077
  if ! created="$(mktemp "$MIGRATION_LOG_DIR/migration_${mode}_${stamp}.XXXXXX.log")"; then
    umask "$old_umask"
    err "无法创建迁移日志：$MIGRATION_LOG_DIR"
    return 1
  fi
  umask "$old_umask"
  chmod 0600 "$created"
  MIGRATION_LOG_FILE="$created"
  migration_log INFO "迁移任务已创建；模式=$mode"
}

migration_log() {
  local level="${1:-INFO}" safe_text
  shift || true
  [[ -n "$MIGRATION_LOG_FILE" ]] || { err '迁移日志尚未初始化。'; return 1; }
  safe_text="$(printf '%s' "$*" | sanitize_migration_log_text)"
  printf '%s [%s] %s\n' "$(date -Iseconds)" "$level" "$safe_text" >> "$MIGRATION_LOG_FILE"
}

migration_log_finish() {
  local status="${1:-0}"
  migration_log INFO "迁移任务结束；退出状态=$status"
}

show_recent_migration_log() {
  local file latest='' modified latest_modified=''
  need_cmd find stat cat
  if [[ ! -d "$MIGRATION_LOG_DIR" ]]; then
    warn '尚无迁移日志。'
    return 0
  fi
  while IFS= read -r -d '' file; do
    modified="$(stat -c '%y' "$file")" || continue
    if [[ -z "$latest_modified" || "$modified" > "$latest_modified" ]]; then
      latest="$file"
      latest_modified="$modified"
    fi
  done < <(find "$MIGRATION_LOG_DIR" -maxdepth 1 -type f -name 'migration_*.log' -print0 2>/dev/null)
  if [[ -z "$latest" ]]; then
    warn '尚无迁移日志。'
    return 0
  fi
  info "最近一次迁移日志：$latest"
  printf '\n'
  cat -- "$latest"
}

ui_read() {
  local variable="$1" output_fd="${2:-1}" status
  if IFS= read -r "$variable"; then
    status=0
  else
    status=$?
  fi
  printf '%s' "$RESET" >&"$output_fd"
  return "$status"
}

pause() {
  ui_prompt $'\n按回车键继续...'
  ui_read _ || true
}

clear_screen() {
  if [[ -t 1 && ${TERM:-} != dumb ]]; then
    command -v clear >/dev/null 2>&1 && clear || true
  fi
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "请使用 root 用户运行此脚本。"
    exit 1
  fi
}

need_cmd() {
  local missing=()
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if ((${#missing[@]} > 0)); then
    err "缺少必要命令：${missing[*]}"
    exit 1
  fi
}

terminal_columns() {
  local columns="${COLUMNS:-}"
  if [[ ! "$columns" =~ ^[0-9]{1,4}$ ]]; then
    columns="$(tput cols 2>/dev/null || true)"
  fi
  if [[ "$columns" =~ ^[0-9]{1,4}$ ]] && ((10#$columns > 0)); then
    printf '%d' "$((10#$columns))"
  else
    printf '80'
  fi
}

menu_separator() {
  printf '%s%s%s\n' "$CYAN" '------------------------' "$RESET"
}

menu_item() {
  local text="$1" number="${1%% *}"
  printf '%s%s%s%s%s' "$NUMBER" "$number" "$BLUE" "${text#"$number"}" "$RESET"
}

menu_pair() {
  local left="$1" right="$2" left_cells="$3"
  menu_item "$left"
  # ANSI color codes do not occupy cells; pad using the plain-text width.
  if [[ -n "$right" ]]; then
    if (( $(terminal_columns) >= 58 )); then
      printf '%*s' "$((40 - left_cells))" ''
    else
      printf '\n'
    fi
    menu_item "$right"
  fi
  printf '\n'
}

menu_row_gap() {
  printf '\n'
}

render_main_menu() {
  printf '%s操作%s\n' "$BOLD" "$RESET"
  menu_separator
  menu_pair '1.  列出 WordPress 站点' '2.  备份单个站点' 23
  menu_row_gap
  menu_pair '3.  查看备份文件' '4.  恢复单个站点' 16
  menu_row_gap
  menu_pair '5.  快照管理' '6.  删除旧备份' 12
  menu_row_gap
  menu_pair '7.  更新脚本' '' 12
  menu_separator
  menu_item '8.  站点迁移 ♻️'; printf '\n'
  menu_separator
  menu_item '0.  退出'; printf '\n'
  menu_separator
}

render_snapshot_menu() {
  printf '%s快照管理%s\n' "$BOLD" "$RESET"
  menu_separator
  menu_pair '1.  创建完整快照' '2.  查看快照' 16
  menu_row_gap
  menu_pair '3.  恢复完整快照' '4.  删除快照' 16
  menu_separator
  menu_item '0.  返回上一级'; printf '\n'
  menu_separator
}

render_migration_menu() {
  printf '%s站点迁移%s\n' "$BOLD" "$RESET"
  menu_separator
  menu_item '1.  更换域名迁移'; printf '\n'
  menu_item '2.  保留域名迁移'; printf '\n'
  menu_item '3.  查看最近一次迁移日志'; printf '\n'
  printf '\n'
  menu_item '0.  返回上一级'; printf '\n'
  menu_separator
}

header() {
  clear_screen
  printf '\n%s' "$BOLD"
  if (( $(terminal_columns) >= 38 )); then
    cat <<'EOF'
 _      ____   _   _   __  __   ____
| |    |  _ \ | \ | | |  \/  | |  _ \
| |    | | | ||  \| | | |\/| | | |_) |
| |___ | |_| || |\  | | |  | | |  __/
|_____||____/ |_| \_| |_|  |_| |_|
EOF
    printf '%s%s%s\n' "$BOLD" '--------------------------------------' "$RESET"
    printf '%s        单站备份恢复工具%s\n' "$BOLD" "$RESET"
    printf '%s%s%s\n' "$BOLD" '--------------------------------------' "$RESET"
  else
    printf 'LDNMP\n%s----------------\n单站备份恢复工具\n----------------%s\n' "$BOLD" "$RESET"
  fi
  printf '\n%s版本：%s%s%s\n' "$NUMBER" "$LIGHT_GREEN" "$VERSION" "$RESET"
  printf '%s站点目录：%s%s%s\n' "$NUMBER" "$LIGHT_GREEN" "$SITE_ROOT" "$RESET"
  printf '%s备份目录：%s%s%s\n' "$NUMBER" "$LIGHT_GREEN" "$BACKUP_DIR" "$RESET"
  printf '%s快照目录：%s%s%s  -  %s备注：%ssnapshot%s\n' "$NUMBER" "$LIGHT_GREEN" "$BACKUP_DIR" "$RESET" "$NUMBER" "$LIGHT_GREEN" "$RESET"
  printf '%sGitHub：%s%s%s%s%s%s\n\n' "$NUMBER" "$BLUE" "$NO_UNDERLINE" "$LINK_OPEN" "$PROJECT_URL" "$LINK_CLOSE" "$RESET"
}

valid_domain() {
  local domain="${1:-}"
  [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]
}

sanitize_domain() {
  local domain="$1"
  domain="${domain#http://}"
  domain="${domain#https://}"
  domain="${domain%%/*}"
  printf "%s" "$domain"
}

domain_to_db_name() {
  printf "%s" "$1" | sed 's/[^A-Za-z0-9]/_/g'
}

find_wp_config() {
  local dir="$1"
  local configs=() file
  # LDNMP installs WordPress below the domain directory.
  for file in "$dir/wp-config.php" "$dir/wordpress/wp-config.php"; do
    [[ ! -f "$file" ]] || configs+=("$file")
  done
  ((${#configs[@]} == 1)) || return 1
  printf '%s\n' "${configs[0]}"
}

wp_define_count() {
  local file="$1" key="$2"
  awk -v key="$key" '
    $0 ~ "^[[:space:]]*define[[:space:]]*\\([[:space:]]*[\"\047]" key "[\"\047][[:space:]]*," { count++ }
    END { print count + 0 }
  ' "$file"
}

wp_define_line() {
  local file="$1" key="$2"
  awk -v key="$key" '
    $0 ~ "^[[:space:]]*define[[:space:]]*\\([[:space:]]*[\"\047]" key "[\"\047][[:space:]]*," { print; exit }
  ' "$file"
}

parse_migration_wp_define() {
  local file="$1" key="$2"
  awk -v key="$key" '
    $0 ~ "^[[:space:]]*define[[:space:]]*\\([[:space:]]*[\"\047]" key "[\"\047][[:space:]]*," {
      line=$0
      sub(/^[^,]*,[[:space:]]*/, "", line)
      sub(/["\047][[:space:]]*\)[[:space:]]*;.*/, "", line)
      sub(/^[[:space:]]*["\047]/, "", line)
      print line
      exit
    }
  ' "$file"
}

parse_wp_table_prefix() {
  local file="$1"
  awk '
    /^[[:space:]]*\$table_prefix[[:space:]]*=/ {
      line=$0
      sub(/^[^=]*=[[:space:]]*/, "", line)
      sub(/["\047][[:space:]]*;.*$/, "", line)
      sub(/^[[:space:]]*["\047]/, "", line)
      print line
      exit
    }
  ' "$file"
}

validate_wp_table_prefix() {
  local file="$1" label="$2" count prefix
  count="$(awk '/^[[:space:]]*\$table_prefix[[:space:]]*=/ { count++ } END { print count + 0 }' "$file")"
  [[ "$count" == 1 ]] || { err "${label}的 table_prefix 必须存在且只能定义一次。"; return 1; }
  prefix="$(parse_wp_table_prefix "$file")"
  [[ "$prefix" =~ ^[A-Za-z0-9_]+$ ]] || { err "${label}的 table_prefix 不合法。"; return 1; }
  printf '%s' "$prefix"
}

validate_migration_wp_config() {
  local file="$1" label="$2" key count
  [[ -f "$file" ]] || { err "${label}缺少 wp-config.php。"; return 1; }
  for key in DB_NAME DB_USER DB_PASSWORD DB_HOST; do
    count="$(wp_define_count "$file" "$key")"
    if [[ "$count" != 1 ]]; then
      err "${label}的 ${key} 必须存在且只能定义一次。"
      return 1
    fi
  done
}

read_migration_db_config_file() {
  local wp_config="$1"
  validate_migration_wp_config "$wp_config" '目标 WordPress 配置' || return 1
  DB_NAME="$(parse_migration_wp_define "$wp_config" DB_NAME)"
  DB_USER="$(parse_migration_wp_define "$wp_config" DB_USER)"
  DB_PASSWORD="$(parse_migration_wp_define "$wp_config" DB_PASSWORD)"
  DB_HOST="$(parse_migration_wp_define "$wp_config" DB_HOST)"
  [[ -n "$DB_NAME" && -n "$DB_USER" && -n "$DB_HOST" ]] || { err '目标 WordPress 数据库配置不完整。'; return 1; }
}

list_sites_array() {
  local sites=()
  if [[ -d "$SITE_ROOT" ]]; then
    while IFS= read -r -d '' dir; do
      local name
      name="$(basename "$dir")"
      if find_wp_config "$dir" >/dev/null; then
        sites+=("$name")
      fi
    done < <(find "$SITE_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
  fi
  if ((${#sites[@]} > 0)); then
    printf "%s\n" "${sites[@]}"
  fi
}

select_domain() {
  local title="${1:-请选择站点}"
  local sites=()
  mapfile -t sites < <(list_sites_array)

  while true; do
    header >&2
    printf '%s%s：%s\n\n' "$BOLD" "$title" "$RESET" >&2
    if ((${#sites[@]} == 0)); then
      warn "未在 $SITE_ROOT 下找到 WordPress 站点。检查域名目录或其 wordpress 子目录中的 wp-config.php；同时存在两份配置时不自动选择。" >&2
      printf '\n' >&2
      menu_item '0. 返回上一级' >&2; printf '\n' >&2
    else
      local i
      for i in "${!sites[@]}"; do
        printf '%s%d.%s %s%s\n' "$NUMBER" "$((i + 1))" "$BLUE" "${sites[$i]}" "$RESET" >&2
      done
      menu_item '0. 返回上一级' >&2; printf '\n' >&2
    fi

    ui_prompt $'\n请输入编号，或直接输入域名：' >&2
    ui_read choice 2 || return 1
    choice="${choice//[[:space:]]/}"

    [[ "$choice" == "0" ]] && return 1

    if [[ "$choice" =~ ^[0-9]+$ ]]; then
      if ((choice >= 1 && choice <= ${#sites[@]})); then
        printf "%s" "${sites[$((choice - 1))]}"
        return 0
      fi
      warn "无效的编号，请重新选择。" >&2
      pause >&2
      continue
    fi

    local domain
    domain="$(sanitize_domain "$choice")"
    if valid_domain "$domain"; then
      printf "%s" "$domain"
      return 0
    fi

    warn "域名格式不正确。" >&2
    menu_item '1. 重新输入' >&2; printf '\n' >&2
    menu_item '0. 返回上一级' >&2; printf '\n' >&2
    ui_prompt '请选择：' >&2
    ui_read retry 2 || return 1
    [[ "$retry" == "0" ]] && return 1
  done
}

select_existing_domain() {
  local title="${1:-请选择目标站点}" choice number
  local sites=()
  mapfile -t sites < <(list_sites_array)

  while true; do
    header >&2
    printf '%s%s：%s\n\n' "$BOLD" "$title" "$RESET" >&2
    if ((${#sites[@]} == 0)); then
      warn "未在 $SITE_ROOT 下找到可用的 WordPress 目标站点。" >&2
      menu_item '0. 返回上一级' >&2; printf '\n' >&2
    else
      local i
      for i in "${!sites[@]}"; do
        printf '%s%d.%s %s%s\n' "$NUMBER" "$((i + 1))" "$BLUE" "${sites[$i]}" "$RESET" >&2
      done
      menu_item '0. 返回上一级' >&2; printf '\n' >&2
    fi

    ui_prompt $'\n请选择目标站点编号：' >&2
    ui_read choice 2 || return 1
    [[ "$choice" == 0 ]] && return 1
    if [[ "$choice" =~ ^[0-9]{1,9}$ ]]; then
      number=$((10#$choice))
      if ((number >= 1 && number <= ${#sites[@]})); then
        printf '%s' "${sites[$((number - 1))]}"
        return 0
      fi
    fi
    warn '无效的编号，请从当前站点列表中选择。' >&2
  done
}

site_path() {
  printf "%s/%s" "$SITE_ROOT" "$1"
}

parse_wp_define() {
  local file="$1"
  local key="$2"
  awk -v key="$key" '
    $0 ~ "define[[:space:]]*\\([[:space:]]*[\"\047]" key "[\"\047]" {
      line=$0
      sub(/^[^,]*,[[:space:]]*/, "", line)
      sub(/["\047][[:space:]]*\)[[:space:]]*;.*/, "", line)
      sub(/^[[:space:]]*["\047]/, "", line)
      print line
      exit
    }
  ' "$file"
}

read_db_config() {
  local domain="$1"
  local wp_config
  wp_config="$(find_wp_config "$(site_path "$domain")")" || {
    err "无法唯一确定 WordPress 配置：$(site_path "$domain")"
    return 1
  }

  read_db_config_file "$wp_config"
}

read_db_config_file() {
  local wp_config="$1"

  DB_NAME="$(parse_wp_define "$wp_config" "DB_NAME")"
  DB_USER="$(parse_wp_define "$wp_config" "DB_USER")"
  DB_PASSWORD="$(parse_wp_define "$wp_config" "DB_PASSWORD")"
  DB_HOST="$(parse_wp_define "$wp_config" "DB_HOST")"

  if [[ -z "$DB_NAME" || -z "$DB_USER" ]]; then
    err "无法从 wp-config.php 读取数据库名称或用户名。"
    return 1
  fi
  [[ -z "${DB_HOST:-}" ]] && DB_HOST="localhost"
  return 0
}

prepare_db_client() {
  local operation="$1" host="$DB_HOST" port='' binary state
  local candidates=()
  DB_CONTAINER="${SITEBAK_DB_CONTAINER:-}"
  DB_CLIENT=''
  DB_CONNECT_ARGS=()
  case "$operation" in
    dump) candidates=(mysqldump mariadb-dump) ;;
    mysql) candidates=(mysql mariadb) ;;
    *) err "未知数据库操作。"; return 1 ;;
  esac

  if [[ "$host" =~ ^([^:]+):([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
    if ((${#port} > 5)) || ((10#$port < 1 || 10#$port > 65535)); then
      err "数据库端口不合法。"
      return 1
    fi
  elif [[ "$host" == *:* ]]; then
    err "当前版本不支持此 DB_HOST 格式：$host"
    return 1
  fi

  # LDNMP uses DB_HOST=mysql and a container named mysql.
  if [[ -z "$DB_CONTAINER" && "$host" != localhost && "$host" != 127.0.0.1 ]] && command -v docker >/dev/null 2>&1; then
    if state="$(docker inspect --type container --format '{{.State.Running}}' "$host" 2>/dev/null)"; then
      DB_CONTAINER="$host"
    fi
  fi
  if [[ -n "$DB_CONTAINER" ]]; then
    if ! command -v docker >/dev/null 2>&1; then
      err "已指定数据库容器，但找不到 docker 命令。"
      return 1
    fi
    if ! state="$(docker inspect --type container --format '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null)" || [[ "$state" != true ]]; then
      err "数据库容器不存在或未运行：$DB_CONTAINER"
      return 1
    fi
    for binary in "${candidates[@]}"; do
      if docker exec "$DB_CONTAINER" sh -c 'command -v "$1" >/dev/null 2>&1' sh "$binary"; then
        DB_CLIENT="$binary"
        break
      fi
    done
    DB_CONNECT_ARGS=(-h 127.0.0.1 --protocol=TCP -P "${port:-3306}")
  else
    for binary in "${candidates[@]}"; do
      if command -v "$binary" >/dev/null 2>&1; then
        DB_CLIENT="$binary"
        break
      fi
    done
    DB_CONNECT_ARGS=(-h "$host")
    [[ -z "$port" ]] || DB_CONNECT_ARGS+=(--protocol=TCP -P "$port")
  fi
  if [[ -z "$DB_CLIENT" ]]; then
    err "未找到可用的数据库工具：${candidates[*]}。"
    err "数据库位置：${DB_CONTAINER:-$host}。LDNMP 请确认 mysql 容器已运行；自定义容器可设置 SITEBAK_DB_CONTAINER。"
    return 1
  fi
  info "数据库工具：${DB_CONTAINER:+容器 $DB_CONTAINER / }$DB_CLIENT" >&2
}

run_db_client() {
  if [[ -n "$DB_CONTAINER" ]]; then
    local flags=()
    [[ "$DB_CLIENT" != mysql && "$DB_CLIENT" != mariadb ]] || flags+=(-i)
    MYSQL_PWD="${DB_PASSWORD:-}" docker exec "${flags[@]}" -e MYSQL_PWD "$DB_CONTAINER" \
      "$DB_CLIENT" "${DB_CONNECT_ARGS[@]}" -u "$DB_USER" "$@"
  else
    MYSQL_PWD="${DB_PASSWORD:-}" "$DB_CLIENT" "${DB_CONNECT_ARGS[@]}" -u "$DB_USER" "$@"
  fi
}

run_mysqldump() {
  local client_version client_help
  local options=(--single-transaction --quick --default-character-set=utf8mb4 --no-tablespaces)
  client_version="$(run_db_client --version)" || return 1
  if [[ "$DB_CLIENT" == mysqldump && "$client_version" != *MariaDB* ]]; then
    options+=(--set-gtid-purged=OFF)
    client_help="$(run_db_client --help)" || return 1
    # Single-site archives do not include server-wide masking policies.
    if grep -Eq -- '(^|[[:space:]])--masking[-_]policies([=[:space:]\[]|$)' <<< "$client_help"; then
      options+=(--masking_policies=OFF)
    fi
  fi
  run_db_client "${options[@]}" "$@"
}

run_mysql() {
  run_db_client "$@"
}

find_nginx_files() {
  local domain="$1"
  local results=()
  local dir
  for dir in "${NGINX_CONF_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' file; do
      if grep -qE "(^|[[:space:]])${domain//./\\.}([[:space:];]|$)" "$file" 2>/dev/null; then
        results+=("$file")
      fi
    done < <(find "$dir" -maxdepth 2 -type f \( -name "*.conf" -o -name "*$domain*" \) -print0 2>/dev/null)
  done
  printf "%s\n" "${results[@]}" | awk 'NF && !seen[$0]++'
}

find_cert_dirs() {
  local domain="$1"
  local results=()
  local dir
  for dir in "${CERT_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' item; do
      results+=("$item")
    done < <(find "$dir" -maxdepth 4 \( -type d -o -type f \) -name "*$domain*" -print0 2>/dev/null)
  done
  printf "%s\n" "${results[@]}" | awk 'NF && !seen[$0]++'
}

json_escape() {
  printf "%s" "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_manifest() {
  local file="$1"
  local domain="$2"
  local created_at="$3"
  local site_dir="$4"
  local db_name="$5"
  local nginx_count="$6"
  local cert_count="$7"
  local archive_type="${8:-backup}" snapshot_reason="${9:-manual}"

  cat >"$file" <<EOF
{
  "tool": "sitebak",
  "version": "$(json_escape "$VERSION")",
  "archive_type": "$archive_type",
  "snapshot_reason": "$snapshot_reason",
  "created_at": "$(json_escape "$created_at")",
  "domain": "$(json_escape "$domain")",
  "site_dir": "$(json_escape "$site_dir")",
  "db_name": "$(json_escape "$db_name")",
  "db_host": "$(json_escape "$DB_HOST")",
  "web_root": "$(json_escape "$WEB_ROOT")",
  "site_root": "$(json_escape "$SITE_ROOT")",
  "nginx_files": $nginx_count,
  "cert_items": $cert_count
}
EOF
}

backup_site() (
  umask 077
  local domain="$1"
  local archive_type="${2:-backup}" snapshot_reason="${3:-manual}" label='备份'
  case "$archive_type" in
    backup) ;;
    snapshot) label='完整快照' ;;
    *) err "不支持的备份类型。"; return 1 ;;
  esac
  domain="$(sanitize_domain "$domain")"

  if ! valid_domain "$domain"; then
    err "域名格式不正确：$domain"
    return 1
  fi

  local dir
  dir="$(site_path "$domain")"
  if [[ ! -d "$dir" ]] || ! find_wp_config "$dir" >/dev/null; then
    err "未找到 WordPress 站点：$dir"
    return 1
  fi

  need_cmd tar gzip awk sed find grep date
  mkdir -p "$BACKUP_DIR"
  read_db_config "$domain"

  if [[ -z "${DB_USER:-}" || -z "${DB_NAME:-}" ]]; then
    err "无法从 wp-config.php 读取数据库信息。"
    return 1
  fi
  if [[ ! "$DB_NAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
    err "数据库名称包含不支持的字符。"
    return 1
  fi
  prepare_db_client dump

  local timestamp archive tmp created_at nginx_count cert_count partial=''
  timestamp="$(date +"%Y%m%d_%H%M%S")"
  created_at="$(date -Iseconds)"
  archive="$BACKUP_DIR/${domain}_${timestamp}.tar.gz"
  [[ "$archive_type" != snapshot ]] || archive="$BACKUP_DIR/${domain}_snapshot_${timestamp}.tar.gz"
  [[ ! -e "$archive" ]] || { err "同名备份已存在，请稍后重试。"; return 1; }
  tmp="$(mktemp -d "/tmp/sitebak.${domain}.XXXXXX")"

  trap 'rm -rf -- "$tmp"; [[ -z "$partial" ]] || rm -f -- "$partial"' EXIT

  info "正在备份站点文件..."
  mkdir -p "$tmp/files" "$tmp/database" "$tmp/nginx" "$tmp/certs" "$tmp/meta"
  tar -C "$dir" -czf "$tmp/files/site-files.tar.gz" .

  info "正在导出数据库：$DB_NAME"
  if ! run_mysqldump "$DB_NAME" 2>"$tmp/meta/database-stderr.log" | gzip >"$tmp/database/${DB_NAME}.sql.gz"; then
    cat "$tmp/meta/database-stderr.log" >&2
    err "数据库导出失败，未生成备份包。"
    return 1
  fi
  if [[ -s "$tmp/meta/database-stderr.log" ]]; then
    cat "$tmp/meta/database-stderr.log" >&2
    if grep -Eiq '(^|[^[:alnum:]_])(error|fatal)([^[:alnum:]_]|$)|couldn.t execute' "$tmp/meta/database-stderr.log"; then
      err "数据库工具报告错误，未生成备份包。"
      return 1
    fi
  fi

  info "正在收集 Nginx 配置..."
  mapfile -t nginx_files < <(find_nginx_files "$domain")
  nginx_count="${#nginx_files[@]}"
  if [[ "$archive_type" == snapshot ]] && ((nginx_count == 0)); then
    err "未找到站点 Nginx 配置，无法创建完整快照。"
    return 1
  fi
  if ((nginx_count > 0)); then
    printf "%s\n" "${nginx_files[@]}" >"$tmp/meta/nginx-files.txt"
    tar -czf "$tmp/nginx/nginx-files.tar.gz" -T "$tmp/meta/nginx-files.txt"
  fi

  info "正在收集 SSL 证书..."
  mapfile -t cert_items < <(find_cert_dirs "$domain")
  cert_count="${#cert_items[@]}"
  if [[ "$archive_type" == snapshot ]] && ((cert_count == 0)) && grep -Eq '^[[:space:]]*ssl_certificate(_key)?[[:space:]]' "${nginx_files[@]}"; then
    err "站点配置了 HTTPS，但未找到证书，无法创建完整快照。"
    return 1
  fi
  if ((cert_count > 0)); then
    printf "%s\n" "${cert_items[@]}" >"$tmp/meta/cert-items.txt"
    tar -czf "$tmp/certs/cert-items.tar.gz" -T "$tmp/meta/cert-items.txt"
  fi

  write_manifest "$tmp/manifest.json" "$domain" "$created_at" "$dir" "$DB_NAME" "$nginx_count" "$cert_count" "$archive_type" "$snapshot_reason"
  cat >"$tmp/restore-notes.txt" <<EOF
此备份由 sitebak 生成。

恢复建议：
1. 优先在同样的 LDNMP 环境中恢复。
2. 同域名恢复通常不需要修改 WordPress 设置。
3. 商业插件授权是否保持激活取决于插件厂商。
4. 恢复前 sitebak 会询问是否创建当前站点快照。
EOF

  info "正在生成压缩包：$archive"
  partial="$(mktemp "$BACKUP_DIR/.sitebak.${domain}.XXXXXX")"
  tar -C "$tmp" -czf "$partial" .
  ln "$partial" "$archive"
  ok "${label}完成：$archive"
)

archive_kind() {
  local name="${1##*/}" domain
  if [[ "$name" =~ ^(.+)_snapshot_[0-9]{8}_[0-9]{6}\.tar\.gz$ ]]; then
    domain="${BASH_REMATCH[1]}"; valid_domain "$domain" || return 1
    printf 'snapshot'
  elif [[ "$name" =~ ^(.+)_before_restore_[0-9]{8}_[0-9]{6}\.tar\.gz$ ]]; then
    domain="${BASH_REMATCH[1]}"; valid_domain "$domain" || return 1
    printf 'legacy'
  elif [[ "$name" =~ ^(.+)_[0-9]{8}_[0-9]{6}\.tar\.gz$ ]]; then
    domain="${BASH_REMATCH[1]}"; valid_domain "$domain" || return 1
    printf 'backup'
  else
    return 1
  fi
}

archive_label() {
  case "$(archive_kind "$1")" in
    snapshot) printf '完整快照' ;;
    legacy) printf '旧版文件快照（不可完整恢复）' ;;
    *) printf '普通备份' ;;
  esac
}

list_backups_for_domain() {
  local domain="${1:-}" filter="${2:-backup}" file kind name
  [[ -d "$BACKUP_DIR" ]] || return 0
  while IFS= read -r file; do
    kind="$(archive_kind "$file")" || continue
    name="${file##*/}"
    [[ -z "$domain" || "$name" == "${domain}_"* ]] || continue
    case "$filter:$kind" in
      all:*|backup:backup|snapshot:snapshot|snapshots:snapshot|snapshots:legacy) printf '%s\n' "$file" ;;
    esac
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)
}

select_backup() {
  local domain="${1:-}"
  local filter="${2:-backup}" action="${3:-恢复}" choice number title
  case "$filter" in
    backup) title='普通备份' ;;
    snapshot|snapshots) title='快照' ;;
    *) title='备份' ;;
  esac
  local backups=()
  mapfile -t backups < <(list_backups_for_domain "$domain" "$filter")

  while true; do
    header >&2
    if [[ -n "$domain" ]]; then
      printf '%s%s 可用%s：%s\n\n' "$BOLD" "$domain" "$title" "$RESET" >&2
    else
      printf '%s可用%s：%s\n\n' "$BOLD" "$title" "$RESET" >&2
    fi

    if ((${#backups[@]} == 0)); then
      if [[ -n "$domain" && "$filter" == backup ]]; then
        warn "当前域名无可用备份：$domain" >&2
      elif [[ -n "$domain" ]]; then
        warn "当前域名无可用${title}：$domain" >&2
      else
        warn "未找到${title}文件。" >&2
      fi
      printf '\n' >&2
      menu_item '0. 返回上一级' >&2; printf '\n' >&2
      ui_prompt '请选择：' >&2
      ui_read choice 2 || return 1
      [[ "$choice" == "0" ]] && return 1
      continue
    fi

    local i file size mtime
    for i in "${!backups[@]}"; do
      file="${backups[$i]}"
      size="$(du -h "$file" | awk '{print $1}')"
      mtime="$(date -r "$file" +"%Y-%m-%d %H:%M:%S")"
      printf '%s%d.%s [%s] %s    %s    %s%s\n' "$NUMBER" "$((i + 1))" "$BLUE" "$(archive_label "$file")" "$(basename "$file")" "$size" "$mtime" "$RESET" >&2
    done
    menu_item '0. 返回上一级' >&2; printf '\n\n' >&2
    ui_prompt "请选择要${action}的文件：" >&2
    ui_read choice 2 || return 1

    [[ "$choice" == "0" ]] && return 1
    if [[ "$choice" =~ ^[0-9]{1,9}$ ]]; then
      number=$((10#$choice))
      if ((number >= 1 && number <= ${#backups[@]})); then
        printf "%s" "${backups[$((number - 1))]}"
        return 0
      fi
    fi
    warn "无效的选择，请输入正确编号或 0 返回。" >&2
  done
}

extract_manifest_value() {
  local file="$1"
  local key="$2"
  sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$file" | head -n 1
}

manifest_string_once() {
  local file="$1" key="$2" occurrences
  local values=()
  occurrences="$(grep -o "\"$key\"[[:space:]]*:" "$file" | wc -l || true)"
  [[ "$occurrences" == 1 ]] || { err "manifest.json 中的 $key 必须存在且只能出现一次。"; return 1; }
  mapfile -t values < <(sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$file")
  if ((${#values[@]} != 1)); then
    err "manifest.json 中的 $key 必须存在且只能出现一次。"
    return 1
  fi
  printf '%s' "${values[0]}"
}

manifest_number_once() {
  local file="$1" key="$2" occurrences
  local values=()
  occurrences="$(grep -o "\"$key\"[[:space:]]*:" "$file" | wc -l || true)"
  [[ "$occurrences" == 1 ]] || { err "manifest.json 中的 $key 必须存在且只能出现一次。"; return 1; }
  mapfile -t values < <(sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p" "$file")
  if ((${#values[@]} != 1)); then
    err "manifest.json 中的 $key 必须存在且只能出现一次。"
    return 1
  fi
  printf '%s' "${values[0]}"
}

canonical_archive_member_path() {
  local path="$1" component canonical=''
  local components=()
  while [[ "$path" == ./* ]]; do path="${path#./}"; done
  IFS='/' read -r -a components <<< "$path"
  for component in "${components[@]}"; do
    case "$component" in
      ''|.) continue ;;
      ..) return 1 ;;
      *) canonical+="${canonical:+/}$component" ;;
    esac
  done
  printf '%s' "${canonical:-.}"
}

validate_tar_archive() {
  local archive="$1" label="$2" allow_symlinks="${3:-no}" listing verbose member canonical type line target
  local index part parent
  local members=() verbose_lines=() parts=()
  declare -A seen=() member_types=() required_parents=()
  if ! listing="$(tar --quoting-style=escape -tzf "$archive")"; then
    err "${label}无法读取。"
    return 1
  fi
  if ! verbose="$(tar --quoting-style=escape -tzvf "$archive")"; then
    err "${label}类型检查失败。"
    return 1
  fi
  mapfile -t members <<< "$listing"
  mapfile -t verbose_lines <<< "$verbose"
  ((${#members[@]} == ${#verbose_lines[@]})) || { err "${label}成员列表无法可靠解析。"; return 1; }

  for index in "${!members[@]}"; do
    member="${members[$index]}"
    line="${verbose_lines[$index]}"
    type="${line:0:1}"
    [[ -n "$member" ]] || { err "${label}包含空文件名。"; return 1; }
    if [[ "$member" == /* || "$member" == *$'\r'* ]] || ! canonical="$(canonical_archive_member_path "$member")"; then
      err "${label}包含越界路径：$member"
      return 1
    fi
    [[ -z "${seen[$canonical]+x}" ]] || { err "${label}包含重复成员路径：$member"; return 1; }
    case "$type" in
      -|d) ;;
      l)
        [[ "$allow_symlinks" == yes ]] || { err "${label}不允许包含符号链接。"; return 1; }
        ;;
      h) err "${label}包含不支持的硬链接。"; return 1 ;;
      *) err "${label}包含设备、管道或其他不支持的特殊文件。"; return 1 ;;
    esac

    if [[ "$canonical" != . ]]; then
      IFS='/' read -r -a parts <<< "$canonical"
      parent=''
      for ((part=0; part<${#parts[@]}-1; part++)); do
        parent+="${parent:+/}${parts[$part]}"
        case "${member_types[$parent]:-}" in
          l|-) err "${label}包含经由链接或文件父路径写入的成员：$member"; return 1 ;;
        esac
        required_parents[$parent]=1
      done
      if [[ "$type" != d && -n "${required_parents[$canonical]+x}" ]]; then
        err "${label}包含会覆盖既有父路径的成员：$member"
        return 1
      fi
    fi

    if [[ "$type" == l ]]; then
      [[ "$line" == *' -> '* ]] || { err "${label}包含无法识别的符号链接。"; return 1; }
      target="${line##* -> }"
      if [[ -z "$target" || "$target" == /* ]] || ! canonical_archive_member_path "$target" >/dev/null; then
        err "${label}包含指向目录外部的符号链接。"
        return 1
      fi
    fi
    seen[$canonical]=1
    member_types[$canonical]="$type"
  done
}

validate_extracted_tree() {
  local root="$1" label="$2" root_real link target resolved special
  root_real="$(realpath -e -- "$root")" || return 1
  special="$(find "$root" -mindepth 1 ! -type f ! -type d ! -type l -print -quit)"
  if [[ -n "$special" ]]; then
    err "${label}包含不支持的特殊文件：$special"
    return 1
  fi
  while IFS= read -r -d '' link; do
    target="$(readlink -- "$link")" || return 1
    [[ "$target" != /* ]] || { err "${label}包含绝对符号链接：$link"; return 1; }
    resolved="$(realpath -m -- "$(dirname -- "$link")/$target")" || return 1
    case "$resolved" in
      "$root_real"|"$root_real"/*) ;;
      *) err "${label}包含指向目录外部的符号链接：$link"; return 1 ;;
    esac
  done < <(find "$root" -type l -print0)
}

extract_safe_tar() {
  local archive="$1" destination="$2" label="$3" allow_symlinks="${4:-no}"
  validate_tar_archive "$archive" "$label" "$allow_symlinks" || return 1
  if [[ -e "$destination" ]]; then
    [[ -d "$destination" && -z "$(find "$destination" -mindepth 1 -print -quit)" ]] || {
      err "${label}的解压目标不是空目录。"
      return 1
    }
  else
    mkdir -p "$destination"
  fi
  tar --no-same-owner --delay-directory-restore -C "$destination" -xzf "$archive" || {
    err "${label}解压失败。"
    return 1
  }
  validate_extracted_tree "$destination" "$label"
}

inspect_migration_archive() {
  local archive="$1" package_dir="$2" source_site_dir="$3"
  local manifest tool archive_type version created_at source_site_dir_record source_db_host filename_domain db_name wp_config source_db_name component count payload
  [[ -f "$archive" ]] || { err "备份文件不存在：$archive"; return 1; }
  [[ "$(archive_kind "$archive" || true)" == backup ]] || { err '站点迁移只接受普通备份。'; return 1; }

  extract_safe_tar "$archive" "$package_dir" '外层备份包' no || return 1
  manifest="$package_dir/manifest.json"
  [[ -f "$manifest" ]] || { err '备份包缺少 manifest.json。'; return 1; }
  [[ -f "$package_dir/files/site-files.tar.gz" ]] || { err '备份包缺少站点文件。'; return 1; }
  [[ -f "$package_dir/restore-notes.txt" && -d "$package_dir/meta" ]] || { err '备份包结构不完整。'; return 1; }

  tool="$(manifest_string_once "$manifest" tool)" || return 1
  version="$(manifest_string_once "$manifest" version)" || return 1
  archive_type="$(manifest_string_once "$manifest" archive_type)" || return 1
  created_at="$(manifest_string_once "$manifest" created_at)" || return 1
  MIGRATION_SOURCE_DOMAIN="$(manifest_string_once "$manifest" domain)" || return 1
  source_site_dir_record="$(manifest_string_once "$manifest" site_dir)" || return 1
  db_name="$(manifest_string_once "$manifest" db_name)" || return 1
  source_db_host="$(manifest_string_once "$manifest" db_host)" || return 1
  [[ "$tool" == sitebak && -n "$version" && -n "$created_at" && -n "$source_site_dir_record" && -n "$source_db_host" && "$archive_type" == backup ]] || { err '所选文件不是 SiteBak 普通备份。'; return 1; }
  valid_domain "$MIGRATION_SOURCE_DOMAIN" || { err "备份包源域名不合法：$MIGRATION_SOURCE_DOMAIN"; return 1; }
  [[ "$db_name" =~ ^[A-Za-z0-9_-]+$ ]] || { err '备份包数据库名称不合法。'; return 1; }
  if [[ "${archive##*/}" =~ ^(.+)_[0-9]{8}_[0-9]{6}\.tar\.gz$ ]]; then
    filename_domain="${BASH_REMATCH[1]}"
  else
    err '普通备份文件名不合法。'
    return 1
  fi
  [[ "$filename_domain" == "$MIGRATION_SOURCE_DOMAIN" ]] || { err '备份文件名与 manifest 源域名不一致。'; return 1; }

  [[ -f "$package_dir/database/${db_name}.sql.gz" ]] || { err '备份包缺少清单指定的数据库文件。'; return 1; }
  gzip -t "$package_dir/database/${db_name}.sql.gz" || { err '数据库压缩文件校验失败。'; return 1; }
  MIGRATION_SOURCE_DB="$db_name"

  for component in nginx certs; do
    case "$component" in
      nginx) count="$(manifest_number_once "$manifest" nginx_files)" || return 1; payload="$package_dir/nginx/nginx-files.tar.gz" ;;
      certs) count="$(manifest_number_once "$manifest" cert_items)" || return 1; payload="$package_dir/certs/cert-items.tar.gz" ;;
    esac
    if ((count > 0)); then
      [[ -f "$payload" ]] || { err "备份清单声明了 $component 载荷，但文件不存在。"; return 1; }
    fi
    [[ ! -f "$payload" ]] || tar -tzf "$payload" >/dev/null || { err "备份中的 $component 载荷无法读取。"; return 1; }
  done

  extract_safe_tar "$package_dir/files/site-files.tar.gz" "$source_site_dir" '站点文件包' yes || return 1
  wp_config="$(find_wp_config "$source_site_dir")" || { err '备份包中无法唯一确定 WordPress Root。'; return 1; }
  validate_migration_wp_config "$wp_config" '源站 WordPress 配置' || return 1
  source_db_name="$(parse_migration_wp_define "$wp_config" DB_NAME)"
  [[ "$source_db_name" == "$db_name" ]] || { err 'manifest 与源站 WordPress 数据库名称不一致。'; return 1; }
  MIGRATION_SOURCE_TABLE_PREFIX="$(validate_wp_table_prefix "$wp_config" '源站 WordPress 配置')" || return 1
  MIGRATION_SOURCE_WP_ROOT="$(dirname -- "$wp_config")"
}

replace_migration_wp_define() {
  local config="$1" key="$2" replacement_file="$3" output mode
  mode="$(stat -c '%a' "$config")" || return 1
  output="$(mktemp "$(dirname -- "$config")/.wp-config.${key}.XXXXXX")" || return 1
  if ! awk -v key="$key" -v replacement_file="$replacement_file" '
    BEGIN {
      if ((getline replacement < replacement_file) <= 0) exit 40
      close(replacement_file)
    }
    $0 ~ "^[[:space:]]*define[[:space:]]*\\([[:space:]]*[\"\047]" key "[\"\047][[:space:]]*," {
      print replacement
      replaced++
      next
    }
    { print }
    END { if (replaced != 1) exit 41 }
  ' "$config" > "$output"; then
    rm -f -- "$output"
    err "暂存 wp-config.php 时无法替换 $key。"
    return 1
  fi
  chmod "$mode" "$output"
  mv -f -- "$output" "$config"
}

prepare_migration_stage() {
  local source_wp_root="$1" target_wp_config="$2" stage_root="$3" key replacement_file staged_config source_prefix staged_prefix
  source_prefix="$(validate_wp_table_prefix "$source_wp_root/wp-config.php" '源站 WordPress 配置')" || return 1
  mkdir -p "$stage_root"
  cp -a -- "$source_wp_root/." "$stage_root/"
  staged_config="$stage_root/wp-config.php"
  [[ -f "$staged_config" ]] || { err '暂存 WordPress Root 缺少 wp-config.php。'; return 1; }
  for key in DB_NAME DB_USER DB_PASSWORD DB_HOST; do
    replacement_file="$(mktemp "$stage_root/.target-${key}.XXXXXX")" || return 1
    chmod 0600 "$replacement_file"
    wp_define_line "$target_wp_config" "$key" > "$replacement_file"
    replace_migration_wp_define "$staged_config" "$key" "$replacement_file" || { rm -f -- "$replacement_file"; return 1; }
    rm -f -- "$replacement_file"
  done
  validate_migration_wp_config "$staged_config" '暂存 WordPress 配置' || return 1
  for key in DB_NAME DB_USER DB_PASSWORD DB_HOST; do
    if [[ "$(parse_migration_wp_define "$staged_config" "$key")" != "$(parse_migration_wp_define "$target_wp_config" "$key")" ]]; then
      err "暂存 WordPress 配置中的 $key 与目标站点不一致。"
      return 1
    fi
  done
  staged_prefix="$(validate_wp_table_prefix "$staged_config" '暂存 WordPress 配置')" || return 1
  [[ "$staged_prefix" == "$source_prefix" ]] || { err '暂存 WordPress 配置的 table_prefix 发生变化。'; return 1; }
}

validate_migration_target_scope() {
  local domain="$1" wp_config="$2" site_root_real target_dir_real wp_config_real wp_root_real expected
  site_root_real="$(realpath -e -- "$SITE_ROOT")" || { err "无法解析站点目录：$SITE_ROOT"; return 1; }
  target_dir_real="$(realpath -e -- "$(site_path "$domain")")" || { err '无法解析目标域名目录。'; return 1; }
  expected="$site_root_real/$domain"
  [[ "$target_dir_real" == "$expected" ]] || { err '目标域名目录解析结果超出站点目录。'; return 1; }
  wp_config_real="$(realpath -e -- "$wp_config")" || { err '无法解析目标 wp-config.php。'; return 1; }
  wp_root_real="$(dirname -- "$wp_config_real")"
  case "$wp_root_real" in
    "$target_dir_real"|"$target_dir_real"/*) ;;
    *) err '目标 WordPress Root 解析结果超出所选域名目录。'; return 1 ;;
  esac
  MIGRATION_TARGET_WP_ROOT="$wp_root_real"
}

verify_empty_target_database() {
  local tables
  [[ "$DB_NAME" =~ ^[A-Za-z0-9_-]+$ ]] || { err '目标数据库名称包含不支持的字符。'; return 1; }
  prepare_db_client mysql || return 1
  if ! tables="$(run_mysql --batch --skip-column-names -e 'SHOW TABLES' "$DB_NAME")"; then
    err '无法连接并检查目标数据库。'
    return 1
  fi
  if [[ -n "${tables//[[:space:]]/}" ]]; then
    err "目标数据库不是空库，检测到数据表：$DB_NAME"
    return 1
  fi
}

classify_nginx_domain_blocks() {
  local file="$1" domain="$2"
  awk -v domain="$domain" '
    function brace_delta(text, copy, opens, closes) {
      copy=text
      opens=gsub(/\{/, "{", copy)
      copy=text
      closes=gsub(/\}/, "}", copy)
      return opens - closes
    }
    function classify_block(text, directives, directive_count, directive_index, normalized, fields, field_count, field_index, endpoint, scan_index) {
      matched=has_443=has_443_ssl=has_http=has_cert=has_key=has_any_ssl=0
      directive_count=split(text, directives, /;/)
      for (directive_index=1; directive_index<=directive_count; directive_index++) {
        normalized=directives[directive_index]
        gsub(/[{}\t\r]/, " ", normalized)
        field_count=split(normalized, fields, /[[:space:]]+/)
        for (field_index=1; field_index<=field_count; field_index++) {
          if (fields[field_index] == "server_name") {
            for (scan_index=field_index+1; scan_index<=field_count; scan_index++) {
              if (fields[scan_index] == domain) matched=1
            }
          } else if (fields[field_index] == "listen") {
            endpoint=fields[field_index+1]
            if (endpoint ~ /(^|:)443$/) {
              has_443=1
              for (scan_index=field_index+2; scan_index<=field_count; scan_index++) {
                if (fields[scan_index] == "ssl") has_443_ssl=1
              }
            }
            if (endpoint ~ /(^|:)80$/) has_http=1
            for (scan_index=field_index+2; scan_index<=field_count; scan_index++) {
              if (fields[scan_index] == "ssl") has_any_ssl=1
            }
          } else if (fields[field_index] == "ssl_certificate") {
            has_cert=1
          } else if (fields[field_index] == "ssl_certificate_key") {
            has_key=1
          }
        }
      }
      if (!matched) return
      if (has_443 || has_any_ssl || has_cert || has_key) {
        if (has_443 && has_443_ssl && has_cert && has_key) print "HTTPS"
        else print "TLS_INCOMPLETE"
      } else if (has_http) {
        print "HTTP"
      } else {
        print "NO_LISTEN"
      }
    }
    {
      line=$0
      sub(/#.*/, "", line)
      if (!inside && line ~ /^[[:space:]]*server[[:space:]]*\{/) {
        inside=1
        block=line
        depth=brace_delta(line)
        if (depth == 0) { classify_block(block); block=""; inside=0 }
        next
      }
      if (inside) {
        block=block "\n" line
        depth+=brace_delta(line)
        if (depth == 0) { classify_block(block); block=""; inside=0 }
      }
    }
    END { if (inside) exit 42 }
  ' "$file"
}

detect_target_scheme() {
  local domain="$1" file statuses block_status
  local has_https=0 has_http=0 has_incomplete=0 matching_blocks=0
  local nginx_files=()
  mapfile -t nginx_files < <(find_nginx_files "$domain")
  ((${#nginx_files[@]} > 0)) || { err "未找到目标域名 Nginx 配置：$domain"; return 1; }
  for file in "${nginx_files[@]}"; do
    if ! statuses="$(classify_nginx_domain_blocks "$file" "$domain")"; then
      err "目标域名的 Nginx server 块无法解析：$file"
      return 1
    fi
    while IFS= read -r block_status; do
      [[ -n "$block_status" ]] || continue
      ((matching_blocks+=1))
      case "$block_status" in
        HTTPS) has_https=1 ;;
        HTTP) has_http=1 ;;
        TLS_INCOMPLETE) has_incomplete=1 ;;
        NO_LISTEN) ;;
        *) err 'Nginx server 块分类结果异常。'; return 1 ;;
      esac
    done <<< "$statuses"
  done
  ((matching_blocks > 0)) || { err "未找到目标域名的有效 Nginx server 块：$domain"; return 1; }
  if ((has_incomplete)); then
    err "目标域名的 HTTPS 配置不完整或存在冲突：$domain"
    return 1
  fi
  if ((has_https)); then
    printf 'https'
    return 0
  fi
  if ((has_http)); then
    printf 'http'
    return 0
  fi
  err "无法从 Nginx 配置确定目标协议：$domain"
  return 1
}

get_target_server_identity() {
  local host machine_id_file='' machine_fingerprint
  host="$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)"
  [[ -n "$host" ]] || { err '无法读取目标服务器主机名。'; return 1; }
  if [[ -s /etc/machine-id ]]; then
    machine_id_file=/etc/machine-id
  elif [[ -s /var/lib/dbus/machine-id ]]; then
    machine_id_file=/var/lib/dbus/machine-id
  else
    err '无法读取目标服务器 machine-id，拒绝建立迁移目标身份。'
    return 1
  fi
  machine_fingerprint="$(sha256sum "$machine_id_file" | awk '{print substr($1, 1, 16)}')"
  [[ "$machine_fingerprint" =~ ^[0-9a-f]{16}$ ]] || { err '目标服务器 machine-id 指纹生成失败。'; return 1; }
  printf '%s / machine:%s' "$host" "$machine_fingerprint"
}

nginx_target_config_fingerprint() {
  local domain="$1" file
  local files=()
  mapfile -t files < <(find_nginx_files "$domain" | sort)
  ((${#files[@]} > 0)) || return 1
  {
    for file in "${files[@]}"; do
      printf '%s\n' "$file"
      sha256sum "$file"
    done
  } | sha256sum | awk '{print $1}'
}

capture_migration_target_identity() {
  local domain="$1" wp_config="$2" scheme="$3" migration_prefix="$4"
  local server_identity target_prefix config_real root_state config_hash nginx_hash db_endpoint identity_record
  validate_migration_target_scope "$domain" "$wp_config" || return 1
  target_prefix="$(validate_wp_table_prefix "$wp_config" '目标 WordPress 配置')" || return 1
  [[ "$migration_prefix" =~ ^[A-Za-z0-9_]+$ ]] || { err '迁移表前缀不合法。'; return 1; }
  server_identity="$(get_target_server_identity)" || return 1
  config_real="$(realpath -e -- "$wp_config")" || return 1
  root_state="$(stat -c '%d:%i:%u:%g' "$MIGRATION_TARGET_WP_ROOT")" || return 1
  config_hash="$(sha256sum "$config_real" | awk '{print $1}')" || return 1
  nginx_hash="$(nginx_target_config_fingerprint "$domain")" || { err '目标 Nginx 配置指纹生成失败。'; return 1; }
  db_endpoint="${DB_CONTAINER:+docker:$DB_CONTAINER|}${DB_HOST}|${DB_CONNECT_ARGS[*]}"
  identity_record="$(printf '%s\n' \
    "server=$server_identity" \
    "domain=$domain" \
    "scheme=$scheme" \
    "wordpress_root=$MIGRATION_TARGET_WP_ROOT" \
    "root_state=$root_state" \
    "wp_config=$config_real" \
    "wp_config_sha256=$config_hash" \
    "db_endpoint=$db_endpoint" \
    "db_user=$DB_USER" \
    "db_name=$DB_NAME" \
    "target_table_prefix=$target_prefix" \
    "migration_table_prefix=$migration_prefix" \
    "nginx_sha256=$nginx_hash")"
  MIGRATION_TARGET_IDENTITY="$(printf '%s' "$identity_record" | sha256sum | awk '{print $1}')"
  MIGRATION_TARGET_SERVER="$server_identity"
  MIGRATION_TARGET_DOMAIN="$domain"
  MIGRATION_TARGET_SCHEME="$scheme"
  MIGRATION_TARGET_DB_ENDPOINT="$db_endpoint"
  MIGRATION_TARGET_DB_NAME="$DB_NAME"
  MIGRATION_TARGET_DB_USER="$DB_USER"
  MIGRATION_TARGET_ORIGINAL_PREFIX="$target_prefix"
  MIGRATION_TARGET_MIGRATION_PREFIX="$migration_prefix"
  MIGRATION_TARGET_CONFIG_REAL="$config_real"
}

revalidate_migration_target_identity() {
  local domain="$1" expected_identity="$2" migration_prefix="$3"
  local wp_config scheme
  wp_config="$(find_wp_config "$(site_path "$domain")")" || { err '重新验证时无法唯一确定目标 WordPress Root。'; return 1; }
  validate_migration_target_scope "$domain" "$wp_config" || return 1
  read_migration_db_config_file "$wp_config" || return 1
  verify_empty_target_database || return 1
  scheme="$(detect_target_scheme "$domain")" || return 1
  capture_migration_target_identity "$domain" "$wp_config" "$scheme" "$migration_prefix" || return 1
  if [[ "$MIGRATION_TARGET_IDENTITY" != "$expected_identity" ]]; then
    err '目标身份或操作范围在预检期间发生变化，已停止。'
    return 1
  fi
}

restore_site() (
  umask 077
  local archive="$1"
  local expected_type="${2:-}"
  if [[ "$(archive_kind "$archive" || true)" == legacy ]]; then
    err "这是旧版文件快照，不含数据库，不能用于完整站点恢复。"
    return 1
  fi
  if [[ ! -f "$archive" ]]; then
    err "备份文件不存在：$archive"
    return 1
  fi

  need_cmd tar gzip awk sed find date

  local tmp manifest domain db_name target_dir component count snapshot_choice payload
  tmp="$(mktemp -d "/tmp/sitebak.restore.XXXXXX")"
  trap 'rm -rf -- "$tmp"' EXIT

  tar -C "$tmp" -xzf "$archive"
  manifest="$tmp/manifest.json"
  if [[ ! -f "$manifest" ]]; then
    err "备份包缺少 manifest.json，无法安全恢复。"
    return 1
  fi
  if [[ "$expected_type" == snapshot && "$(extract_manifest_value "$manifest" archive_type)" != snapshot ]]; then
    err "所选文件不是新版完整快照。"
    return 1
  fi
  for component in nginx certs; do
    case "$component" in
      nginx) count="$(sed -n 's/.*"nginx_files": *\([0-9][0-9]*\).*/\1/p' "$manifest")"; payload="$tmp/nginx/nginx-files.tar.gz" ;;
      certs) count="$(sed -n 's/.*"cert_items": *\([0-9][0-9]*\).*/\1/p' "$manifest")"; payload="$tmp/certs/cert-items.tar.gz" ;;
    esac
    if [[ "$count" =~ ^[0-9]+$ ]] && ((count > 0)); then
      [[ -f "$payload" ]] || { err "备份缺少 $component 文件，已停止恢复。"; return 1; }
    fi
    [[ ! -f "$payload" ]] || tar -tzf "$payload" >/dev/null
  done

  domain="$(extract_manifest_value "$manifest" "domain")"
  db_name="$(extract_manifest_value "$manifest" "db_name")"
  target_dir="$(site_path "$domain")"

  if ! valid_domain "$domain"; then
    err "备份包中的域名不合法：$domain"
    return 1
  fi

  if [[ ! "$db_name" =~ ^[A-Za-z0-9_-]+$ ]] || [[ ! -f "$tmp/database/${db_name}.sql.gz" ]]; then
    err "备份包数据库名称不合法或缺少 SQL 文件。"
    return 1
  fi
  gzip -t "$tmp/database/${db_name}.sql.gz"
  mkdir -p "$tmp/staged-site"
  tar -C "$tmp/staged-site" -xzf "$tmp/files/site-files.tar.gz"
  local wp_config
  wp_config="$(find_wp_config "$tmp/staged-site")" || { err "备份包中无法唯一确定 WordPress 配置。"; return 1; }
  read_db_config_file "$wp_config"
  [[ "$DB_NAME" == "$db_name" ]] || { err "备份清单与 WordPress 数据库名称不一致。"; return 1; }
  prepare_db_client mysql
  run_mysql --batch --skip-column-names -e 'SELECT 1' >/dev/null

  header
  warn "即将恢复站点：$domain"
  printf '%s备份文件：%s%s\n' "$BLUE" "$archive" "$RESET"
  printf '%s目标目录：%s%s\n\n' "$BLUE" "$target_dir" "$RESET"
  ui_prompt '恢复会覆盖当前站点文件，并导入数据库。是否继续？请输入 yes 确认：'
  ui_read confirm || return 1
  [[ "$confirm" == "yes" ]] || { warn "已取消恢复。"; return 1; }

  if [[ -d "$target_dir" ]]; then
    while true; do
      ui_prompt '恢复前是否创建完整快照（包含数据库）？[Y/n，0 返回] '
      ui_read snapshot_choice || return 1
      case "$snapshot_choice" in
        ''|Y|y)
          info "正在保存当前站点完整快照，失败将停止恢复。"
          backup_site "$domain" snapshot before_restore
          break ;;
        N|n) break ;;
        0) warn "已取消恢复。"; return 0 ;;
        *) warn "请输入 Y、n 或 0。" ;;
      esac
    done
  fi

  mkdir -p "$target_dir"
  info "正在恢复站点文件及原始权限..."
  find "$target_dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  tar --numeric-owner --same-owner --same-permissions -C "$target_dir" -xzf "$tmp/files/site-files.tar.gz"

  if find_wp_config "$target_dir" >/dev/null; then
    read_db_config "$domain"
  else
    DB_NAME="$db_name"
  fi

  if [[ -f "$tmp/database/${db_name}.sql.gz" ]]; then
    info "正在导入数据库：$db_name"
    run_mysql -e "CREATE DATABASE IF NOT EXISTS \`$db_name\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    gzip -dc "$tmp/database/${db_name}.sql.gz" | run_mysql "$db_name"
  else
    warn "未找到数据库导出文件，跳过数据库导入。"
  fi

  if [[ -f "$tmp/nginx/nginx-files.tar.gz" ]]; then
    info "正在恢复 Nginx 配置..."
    tar -xzf "$tmp/nginx/nginx-files.tar.gz" -C /
  fi

  if [[ -f "$tmp/certs/cert-items.tar.gz" ]]; then
    info "正在恢复 SSL 证书..."
    tar -xzf "$tmp/certs/cert-items.tar.gz" -C /
  fi

  reload_services
  ok "恢复完成：$domain"
)

reload_services() {
  info "正在重载相关服务..."
  if command -v docker >/dev/null 2>&1; then
    docker ps --format '{{.Names}}' | grep -E 'nginx|php|mysql|mariadb' | xargs -r -n1 docker restart >/dev/null 2>&1 || true
  fi
  systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
}

show_sites() {
  header
  local sites=()
  mapfile -t sites < <(list_sites_array)
  if ((${#sites[@]} == 0)); then
    warn "未在 $SITE_ROOT 下找到 WordPress 站点。"
    printf '%s检查路径：域名/wp-config.php 或 域名/wordpress/wp-config.php%s\n' "$BLUE" "$RESET"
    printf '%s同时存在两份配置的目录不会自动选择。%s\n' "$BLUE" "$RESET"
  else
    printf '%s当前 WordPress 站点：%s\n\n' "$BOLD" "$RESET"
    local i
    for i in "${!sites[@]}"; do
      printf '%s%d.%s %s%s\n' "$NUMBER" "$((i + 1))" "$BLUE" "${sites[$i]}" "$RESET"
    done
  fi
}

show_backups() {
  header
  local backups=() filter="${1:-backup}" title
  case "$filter" in
    backup) title='普通备份' ;;
    snapshot|snapshots) title='快照' ;;
    *) title='备份' ;;
  esac
  printf '%s%s文件：%s\n\n' "$BOLD" "$title" "$RESET"
  mapfile -t backups < <(list_backups_for_domain "" "$filter")
  if ((${#backups[@]} == 0)); then
    warn "未找到${title}文件。"
  else
    local file
    for file in "${backups[@]}"; do
      printf '%s[%s] %s    %s    %s%s\n' "$BLUE" "$(archive_label "$file")" "$(basename "$file")" "$(du -h "$file" | awk '{print $1}')" "$(date -r "$file" +"%Y-%m-%d %H:%M:%S")" "$RESET"
    done
  fi
}

delete_backup_menu() {
  local file
  file="$(select_backup "" "${1:-backup}" 删除)" || return 0
  header
  warn "即将删除$(archive_label "$file")：$file"
  ui_prompt '请输入 yes 确认删除：'
  ui_read confirm || return 1
  if [[ "$confirm" == "yes" ]]; then
    rm -f "$file"
    ok "已删除：$file"
  else
    warn "已取消删除。"
  fi
}

return_to_menu() {
  local choice
  while true; do
    printf '\n'
    menu_item '0. 返回上一级'; printf '\n'
    ui_prompt '请输入：'
    ui_read choice || return 0
    [[ "$choice" == "0" ]] && return 0
    warn "请输入 0 返回上一级。"
  done
}

run_menu_action() {
  local status
  # Keep errexit inside the task; conditional calls would disable it in Bash.
  set +e
  ( set -Eeuo pipefail; "$@" )
  status=$?
  set -e
  if ((status != 0)); then
    err "操作未完成（退出码：$status），请查看上方错误信息。"
  fi
  return_to_menu
}

resolve_update_url() {
  local api_url api_response latest_commit
  if [[ "$UPDATE_URL" == 'https://raw.githubusercontent.com/hajimi2024/ldnmp-sitebak/main/sitebak.sh' ]]; then
    api_url="https://api.github.com/repos/hajimi2024/ldnmp-sitebak/commits/main?sitebak_nocache=$(date +%s)"
    api_response="$(curl -fsSL --connect-timeout 15 --max-time 120 -H 'Accept: application/vnd.github+json' "$api_url")" || return 1
    latest_commit="$(sed -n 's/^[[:space:]]*"sha":[[:space:]]*"\([0-9a-f]\{40\}\)",[[:space:]]*$/\1/p' <<< "$api_response" | head -n 1)"
    [[ "$latest_commit" =~ ^[0-9a-f]{40}$ ]] || return 1
    printf 'https://raw.githubusercontent.com/hajimi2024/ldnmp-sitebak/%s/sitebak.sh' "$latest_commit"
  else
    printf '%s' "$UPDATE_URL"
  fi
}

update_self() {
  need_cmd curl date sed head grep bash install mv mktemp rm
  info "正在从 GitHub 更新脚本..."
  local tmp request_url downloaded_version
  tmp="$(mktemp)"
  if ! request_url="$(resolve_update_url)"; then
    rm -f "$tmp"
    err "无法确认 GitHub main 最新提交，当前脚本未更新。"
    return 1
  fi
  if ! curl -fsSL --connect-timeout 15 --max-time 120 "$request_url" -o "$tmp"; then
    rm -f "$tmp"
    err "下载失败，当前脚本未更新。请检查网络后重试。"
    return 1
  fi
  downloaded_version="$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$tmp" | head -n 1)"
  if [[ ! -s "$tmp" ]] || ! bash -n "$tmp" || ! grep -q '^APP_NAME="LDNMP 单站备份恢复工具"$' "$tmp" || [[ -z "$downloaded_version" ]]; then
    rm -f "$tmp"
    err "下载内容不是有效的 sitebak 脚本，当前脚本未更新。"
    return 1
  fi
  local staged
  staged="$(mktemp "${INSTALL_PATH}.XXXXXX")" || { rm -f "$tmp"; return 1; }
  if ! install -m 0755 "$tmp" "$staged" || ! mv -f "$staged" "$INSTALL_PATH"; then
    rm -f "$tmp" "$staged"
    err "安装更新失败。"
    return 1
  fi
  rm -f "$tmp"
  ok "更新完成：$INSTALL_PATH（版本 $downloaded_version）"
}

update_and_reload() {
  local status
  set +e
  ( set -Eeuo pipefail; update_self )
  status=$?
  set -e
  if ((status != 0)); then
    err "操作未完成（退出码：$status），请查看上方错误信息。"
    return_to_menu
    return 0
  fi

  info "正在自动载入新版菜单..."
  if exec "$INSTALL_PATH"; then
    return 0
  fi
  err "新版脚本已安装，但自动载入失败。请退出后重新输入 kk。"
  return_to_menu
}

backup_menu() {
  local domain
  domain="$(select_domain "请选择要备份的站点")" || return 0
  header
  backup_site "$domain"
}

restore_menu() {
  local domain archive
  # Scan current sites first, then limit the restore list to the chosen domain.
  domain="$(select_domain "请选择要恢复的站点")" || return 0
  archive="$(select_backup "$domain" backup)" || return 0
  restore_site "$archive"
}

create_snapshot_menu() {
  local domain
  domain="$(select_domain "请选择要创建完整快照的站点")" || return 0
  header
  backup_site "$domain" snapshot
}

restore_snapshot_menu() {
  local archive
  archive="$(select_backup "" snapshot)" || return 0
  restore_site "$archive" snapshot
}

snapshots_menu() {
  local choice
  while true; do
    header
    render_snapshot_menu
    ui_prompt '请输入你的选择：'
    ui_read choice || return 0
    case "$choice" in
      1) run_menu_action create_snapshot_menu ;;
      2) run_menu_action show_backups snapshots ;;
      3) run_menu_action restore_snapshot_menu ;;
      4) run_menu_action delete_backup_menu snapshots ;;
      0) return 0 ;;
      *) warn "无效的选择，请输入 0 至 4。" ;;
    esac
  done
}

migration_preflight() (
  umask 077
  local mode="$1" archive target_domain target_dir target_wp_config target_wp_root target_scheme target_url
  local tmp='' status=0 target_owner locked_identity archive_sha256
  case "$mode" in
    change-domain|keep-domain) ;;
    *) err '未知迁移模式。'; return 1 ;;
  esac

  migration_log_init "$mode"
  trap '
    status=$?
    set +e
    if [[ -n "$tmp" && -d "$tmp" ]]; then
      rm -rf -- "$tmp"
      migration_log INFO "已清理本次迁移临时目录。"
    fi
    migration_log_finish "$status"
  ' EXIT

  migration_log INFO '阶段二只执行只读预检和临时暂存，不修改目标站点或数据库。'
  need_cmd tar gzip awk sed grep find cut realpath readlink dirname stat cp mv chmod mktemp hostname sha256sum sort
  archive="$(select_backup '' backup 迁移)" || {
    migration_log INFO '用户取消了备份选择。'
    return 0
  }
  migration_log INFO "已选择普通备份：${archive##*/}"

  [[ -d "$MIGRATION_TMP_ROOT" ]] || { err "迁移临时目录根路径不存在：$MIGRATION_TMP_ROOT"; migration_log ERROR '迁移临时目录根路径不存在。'; return 1; }
  tmp="$(mktemp -d "$MIGRATION_TMP_ROOT/sitebak.migrate.XXXXXX")"
  chmod 0700 "$tmp"
  if ! inspect_migration_archive "$archive" "$tmp/package" "$tmp/source-site"; then
    migration_log ERROR '普通备份结构或内容预检失败。'
    return 1
  fi
  archive_sha256="$(sha256sum "$archive" | awk '{print $1}')"
  migration_log INFO "备份预检通过；源域名=$MIGRATION_SOURCE_DOMAIN；源数据库=$MIGRATION_SOURCE_DB；迁移表前缀=$MIGRATION_SOURCE_TABLE_PREFIX；备份指纹=$archive_sha256"

  target_domain="$(select_existing_domain '请选择已预建的空 WordPress 目标站点')" || {
    migration_log INFO '用户取消了目标站点选择。'
    return 0
  }
  case "$mode" in
    change-domain)
      [[ "$target_domain" != "$MIGRATION_SOURCE_DOMAIN" ]] || { err '更换域名迁移要求源域名与目标域名不同。'; migration_log ERROR '源域名与目标域名相同。'; return 1; }
      ;;
    keep-domain)
      [[ "$target_domain" == "$MIGRATION_SOURCE_DOMAIN" ]] || { err '保留域名迁移要求源域名与目标域名完全一致。'; migration_log ERROR '源域名与目标域名不一致。'; return 1; }
      ;;
  esac

  target_dir="$(site_path "$target_domain")"
  target_wp_config="$(find_wp_config "$target_dir")" || { err '无法唯一确定目标 WordPress Root。'; migration_log ERROR '目标 WordPress Root 不唯一。'; return 1; }
  validate_migration_target_scope "$target_domain" "$target_wp_config" || { migration_log ERROR '目标 WordPress Root 路径范围检查失败。'; return 1; }
  target_wp_root="$MIGRATION_TARGET_WP_ROOT"
  read_migration_db_config_file "$target_wp_config" || { migration_log ERROR '无法读取目标数据库配置。'; return 1; }
  verify_empty_target_database || { migration_log ERROR "目标数据库空库检查失败；目标数据库=$DB_NAME"; return 1; }
  migration_log INFO "目标数据库连接与空库检查通过；目标数据库=$DB_NAME"

  target_scheme="$(detect_target_scheme "$target_domain")" || { migration_log ERROR '目标 Nginx 协议检查失败。'; return 1; }
  target_url="${target_scheme}://${target_domain}"
  target_owner="$(stat -c '%u:%g' "$target_wp_root")" || { err '无法读取目标 WordPress Root 属主。'; migration_log ERROR '目标属主检查失败。'; return 1; }
  capture_migration_target_identity "$target_domain" "$target_wp_config" "$target_scheme" "$MIGRATION_SOURCE_TABLE_PREFIX" || {
    migration_log ERROR '无法建立完整的迁移目标身份。'
    return 1
  }
  locked_identity="$MIGRATION_TARGET_IDENTITY"

  prepare_migration_stage "$MIGRATION_SOURCE_WP_ROOT" "$target_wp_config" "$tmp/staged-wordpress" || {
    migration_log ERROR 'WordPress Root 暂存构建失败。'
    return 1
  }
  [[ "$(parse_migration_wp_define "$tmp/staged-wordpress/wp-config.php" DB_NAME)" == "$DB_NAME" ]] || {
    err '暂存 WordPress 配置未正确使用目标数据库。'
    migration_log ERROR '暂存配置目标数据库复核失败。'
    return 1
  }
  revalidate_migration_target_identity "$target_domain" "$locked_identity" "$MIGRATION_SOURCE_TABLE_PREFIX" || {
    migration_log ERROR '暂存完成后的目标身份重新验证失败。'
    return 1
  }

  migration_log INFO "目标预检通过；服务器=$MIGRATION_TARGET_SERVER；目标域名=$target_domain；目标协议=$target_scheme；目标属主=$target_owner；数据库=$MIGRATION_TARGET_DB_NAME；目标身份=$locked_identity"
  migration_log INFO '阶段二暂存构建完成；没有导入数据库或替换目标文件。'
  header
  printf '%s迁移预检结果%s\n\n' "$BOLD" "$RESET"
  printf '%s迁移模式：%s%s%s\n' "$NUMBER" "$BLUE" "$mode" "$RESET"
  printf '%s普通备份：%s%s%s\n' "$NUMBER" "$BLUE" "${archive##*/}" "$RESET"
  printf '%s源域名：%s%s%s\n' "$NUMBER" "$BLUE" "$MIGRATION_SOURCE_DOMAIN" "$RESET"
  printf '%s目标域名：%s%s%s\n' "$NUMBER" "$BLUE" "$target_domain" "$RESET"
  printf '%s目标服务器：%s%s%s\n' "$NUMBER" "$BLUE" "$MIGRATION_TARGET_SERVER" "$RESET"
  printf '%s目标 WordPress Root：%s%s%s\n' "$NUMBER" "$BLUE" "$target_wp_root" "$RESET"
  printf '%s数据库连接：%s%s%s\n' "$NUMBER" "$BLUE" "$MIGRATION_TARGET_DB_ENDPOINT" "$RESET"
  printf '%s目标数据库：%s%s%s\n' "$NUMBER" "$BLUE" "$MIGRATION_TARGET_DB_NAME" "$RESET"
  printf '%s目标原表前缀：%s%s%s\n' "$NUMBER" "$BLUE" "$MIGRATION_TARGET_ORIGINAL_PREFIX" "$RESET"
  printf '%s迁移表前缀：%s%s%s\n' "$NUMBER" "$BLUE" "$MIGRATION_TARGET_MIGRATION_PREFIX" "$RESET"
  printf '%s目标网址：%s%s%s\n' "$NUMBER" "$BLUE" "$target_url" "$RESET"
  printf '%s目标身份指纹：%s%s%s\n\n' "$NUMBER" "$BLUE" "$locked_identity" "$RESET"
  ok '阶段二预检和临时暂存已通过。'
  warn '当前阶段未导入数据库、未替换目标文件，也未修改 Nginx 或 SSL。'
  ok "迁移日志已保存：$MIGRATION_LOG_FILE"
)

migration_menu() {
  local choice
  while true; do
    header
    render_migration_menu
    ui_prompt '请输入你的选择：'
    ui_read choice || return 0
    case "$choice" in
      1) run_menu_action migration_preflight change-domain ;;
      2) run_menu_action migration_preflight keep-domain ;;
      3) run_menu_action show_recent_migration_log ;;
      0) return 0 ;;
      *) warn '无效的选择，请输入 0 至 3。' ;;
    esac
  done
}

main_menu() {
  need_root
  while true; do
    header
    render_main_menu
    ui_prompt '请输入你的选择：'
    ui_read choice || exit 0
    case "$choice" in
      1) run_menu_action show_sites ;;
      2) run_menu_action backup_menu ;;
      3) run_menu_action show_backups backup ;;
      4) run_menu_action restore_menu ;;
      5) snapshots_menu ;;
      6) run_menu_action delete_backup_menu backup ;;
      7) update_and_reload ;;
      8) migration_menu ;;
      0) exit 0 ;;
      *) warn "无效的选择，请重试。"; sleep 1 ;;
    esac
  done
}

usage() {
  cat <<EOF
$APP_NAME v$VERSION

用法：
  kk
  kk list
  kk backup example.com
  kk restore example.com
  kk restore /home/example.com_20260912_153000.tar.gz
  kk list-backups [example.com]
  kk snapshot example.com
  kk list-snapshots [example.com]
  kk restore-snapshot example.com
  kk migrate
  kk update

环境变量：
  SITEBAK_WEB_ROOT       默认 /home/web
  SITEBAK_SITE_ROOT      默认 /home/web/html
  SITEBAK_BACKUP_DIR     默认 /home
  SITEBAK_UPDATE_URL     默认 GitHub raw 地址
  SITEBAK_DB_CONTAINER   可选，指定数据库容器名称
  SITEBAK_MIGRATION_LOG_DIR  默认 /var/log/sitebak
  SITEBAK_MIGRATION_TMP_ROOT 默认 /tmp
  NO_COLOR              设置后关闭彩色输出
EOF
}

main() {
  case "${1:-}" in
    "")
      main_menu
      ;;
    list)
      list_sites_array
      ;;
    backup)
      need_root
      [[ -n "${2:-}" ]] || { err "请提供域名。"; exit 1; }
      backup_site "$2"
      ;;
    restore)
      need_root
      [[ -n "${2:-}" ]] || { err "请提供域名或备份文件路径。"; exit 1; }
      if [[ -f "$2" ]]; then
        restore_site "$2"
      else
        domain="$(sanitize_domain "$2")"
        valid_domain "$domain" || { err "域名格式不正确：$2"; exit 1; }
        archive="$(select_backup "$domain")" || exit 1
        restore_site "$archive"
      fi
      ;;
    list-backups)
      list_backups_for_domain "${2:-}"
      ;;
    snapshot)
      need_root
      [[ -n "${2:-}" ]] || { err "请提供域名。"; exit 1; }
      backup_site "$2" snapshot
      ;;
    list-snapshots)
      list_backups_for_domain "${2:-}" snapshots
      ;;
    restore-snapshot)
      need_root
      [[ -n "${2:-}" ]] || { err "请提供域名或快照文件路径。"; exit 1; }
      if [[ -f "$2" ]]; then
        archive="$2"
      else
        domain="$(sanitize_domain "$2")"
        valid_domain "$domain" || { err "域名格式不正确：$2"; exit 1; }
        archive="$(select_backup "$domain" snapshot)" || exit 1
      fi
      restore_site "$archive" snapshot
      ;;
    migrate)
      need_root
      migration_menu
      ;;
    update)
      need_root
      update_self
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      err "未知命令：$1"
      usage
      exit 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
