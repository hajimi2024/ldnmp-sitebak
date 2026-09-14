#!/usr/bin/env bash

set -Eeuo pipefail

VERSION="0.2.7"
APP_NAME="LDNMP 单站备份恢复工具"

WEB_ROOT="${SITEBAK_WEB_ROOT:-/home/web}"
SITE_ROOT="${SITEBAK_SITE_ROOT:-$WEB_ROOT/html}"
BACKUP_DIR="${SITEBAK_BACKUP_DIR:-/home}"
INSTALL_PATH="${SITEBAK_INSTALL_PATH:-/usr/local/bin/kk}"
UPDATE_URL="${SITEBAK_UPDATE_URL:-https://raw.githubusercontent.com/hajimi2024/ldnmp-sitebak/main/sitebak.sh}"

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
if [[ ${TERM:-} == dumb || -n ${NO_COLOR+x} ]] || [[ ! -t 1 && ! -t 2 ]]; then
  RED='' GREEN='' LIGHT_GREEN='' YELLOW='' BLUE='' CYAN='' NUMBER='' BOLD='' RESET=''
fi

info() { printf '%s[INFO] %s%s\n' "$BLUE" "$*" "$RESET"; }
ok() { printf '%s[OK] %s%s\n' "$GREEN" "$*" "$RESET"; }
warn() { printf '%s[WARN] %s%s\n' "$YELLOW" "$*" "$RESET"; }
err() { printf '%s[ERROR] %s%s\n' "$RED" "$*" "$RESET" >&2; }
ui_prompt() { printf '%s%s%s' "${2:-$BOLD}" "$1" "$RESET"; }

pause() {
  ui_prompt $'\n按回车键继续...'
  read -r _ || true
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
    printf '%s%s%s\n' "$CYAN" '--------------------------------------' "$RESET"
    printf '%s        单站备份恢复工具%s\n' "$CYAN" "$RESET"
    printf '%s%s%s\n' "$CYAN" '--------------------------------------' "$RESET"
  else
    printf 'LDNMP\n%s----------------\n%s单站备份恢复工具%s\n%s----------------%s\n' "$CYAN" "$BLUE" "$RESET" "$CYAN" "$RESET"
  fi
  printf '\n%s版本：%s%s%s\n' "$GREEN" "$LIGHT_GREEN" "$VERSION" "$RESET"
  printf '%s站点目录：%s%s%s\n' "$GREEN" "$LIGHT_GREEN" "$SITE_ROOT" "$RESET"
  printf '%s备份目录：%s%s%s\n\n' "$GREEN" "$LIGHT_GREEN" "$BACKUP_DIR" "$RESET"
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
    read -r choice || return 1
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
    read -r retry || return 1
    [[ "$retry" == "0" ]] && return 1
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
      read -r choice || return 1
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
    read -r choice || return 1

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
  ui_prompt '恢复会覆盖当前站点文件，并导入数据库。是否继续？请输入 yes 确认：' "$YELLOW"
  read -r confirm || return 1
  [[ "$confirm" == "yes" ]] || { warn "已取消恢复。"; return 1; }

  if [[ -d "$target_dir" ]]; then
    while true; do
      ui_prompt '恢复前是否创建完整快照（包含数据库）？[Y/n，0 返回] ' "$YELLOW"
      read -r snapshot_choice || return 1
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
  ui_prompt '请输入 yes 确认删除：' "$YELLOW"
  read -r confirm || return 1
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
    read -r choice || return 0
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

update_self() {
  need_cmd curl
  info "正在从 GitHub 更新脚本..."
  local tmp
  tmp="$(mktemp)"
  if ! curl -fsSL --connect-timeout 15 --max-time 120 "$UPDATE_URL" -o "$tmp"; then
    rm -f "$tmp"
    err "下载失败，当前脚本未更新。请检查网络后重试。"
    return 1
  fi
  if [[ ! -s "$tmp" ]] || ! bash -n "$tmp"; then
    rm -f "$tmp"
    err "下载的脚本为空或语法检查失败，当前脚本未更新。"
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
  ok "更新完成：$INSTALL_PATH"
  info "请退出当前菜单，输入 kk 打开新版菜单。"
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
    read -r choice || return 0
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

main_menu() {
  need_root
  while true; do
    header
    render_main_menu
    ui_prompt '请输入你的选择：'
    read -r choice || exit 0
    case "$choice" in
      1) run_menu_action show_sites ;;
      2) run_menu_action backup_menu ;;
      3) run_menu_action show_backups backup ;;
      4) run_menu_action restore_menu ;;
      5) snapshots_menu ;;
      6) run_menu_action delete_backup_menu backup ;;
      7) run_menu_action update_self ;;
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
  kk update

环境变量：
  SITEBAK_WEB_ROOT       默认 /home/web
  SITEBAK_SITE_ROOT      默认 /home/web/html
  SITEBAK_BACKUP_DIR     默认 /home
  SITEBAK_UPDATE_URL     默认 GitHub raw 地址
  SITEBAK_DB_CONTAINER   可选，指定数据库容器名称
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
