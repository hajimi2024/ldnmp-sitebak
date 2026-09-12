#!/usr/bin/env bash

set -Eeuo pipefail

VERSION="0.1.2"
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

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
BOLD="\033[1m"
RESET="\033[0m"

info() { printf "${BLUE}[INFO]${RESET} %s\n" "$*"; }
ok() { printf "${GREEN}[OK]${RESET} %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${RESET} %s\n" "$*"; }
err() { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; }

pause() {
  printf "\n按回车键继续..."
  read -r _ || true
}

clear_screen() {
  command -v clear >/dev/null 2>&1 && clear || true
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

header() {
  clear_screen
  local width=44 padding border
  if [[ "${COLUMNS:-80}" =~ ^[0-9]+$ ]] && (( ${COLUMNS:-80} < 46 )); then
    width=22
  fi
  padding=$(((width - 22) / 2))
  printf -v border '%*s' "$width" ''
  border="${border// /-}"
  printf "${BOLD}+%s+${RESET}\n" "$border"
  printf "${BOLD}|%*s%s%*s|${RESET}\n" "$padding" '' "$APP_NAME" "$padding" ''
  printf "${BOLD}+%s+${RESET}\n" "$border"
  printf "版本：%s\n" "$VERSION"
  printf "站点目录：%s\n" "$SITE_ROOT"
  printf "备份目录：%s\n\n" "$BACKUP_DIR"
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
    printf "%s：\n\n" "$title" >&2
    if ((${#sites[@]} == 0)); then
      warn "未在 $SITE_ROOT 下找到 WordPress 站点。检查域名目录或其 wordpress 子目录中的 wp-config.php；同时存在两份配置时不自动选择。" >&2
      printf "\n0. 返回上一级\n" >&2
    else
      local i
      for i in "${!sites[@]}"; do
        printf "%d. %s\n" "$((i + 1))" "${sites[$i]}" >&2
      done
      printf "0. 返回上一级\n" >&2
    fi

    printf "\n请输入编号，或直接输入域名：" >&2
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
    printf "1. 重新输入\n0. 返回上一级\n请选择：" >&2
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

  DB_NAME="$(parse_wp_define "$wp_config" "DB_NAME")"
  DB_USER="$(parse_wp_define "$wp_config" "DB_USER")"
  DB_PASSWORD="$(parse_wp_define "$wp_config" "DB_PASSWORD")"
  DB_HOST="$(parse_wp_define "$wp_config" "DB_HOST")"

  [[ -z "${DB_NAME:-}" ]] && DB_NAME="$(domain_to_db_name "$domain")"
  [[ -z "${DB_HOST:-}" ]] && DB_HOST="localhost"
  return 0
}

run_mysqldump() {
  MYSQL_PWD="${DB_PASSWORD:-}" mysqldump -h "$DB_HOST" -u "$DB_USER" "$@"
}

run_mysql() {
  MYSQL_PWD="${DB_PASSWORD:-}" mysql -h "$DB_HOST" -u "$DB_USER" "$@"
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

  cat >"$file" <<EOF
{
  "tool": "sitebak",
  "version": "$(json_escape "$VERSION")",
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

backup_site() {
  local domain="$1"
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

  need_cmd tar gzip mysqldump awk sed find grep date
  mkdir -p "$BACKUP_DIR"
  read_db_config "$domain"

  if [[ -z "${DB_USER:-}" || -z "${DB_NAME:-}" ]]; then
    err "无法从 wp-config.php 读取数据库信息。"
    return 1
  fi

  local timestamp archive tmp created_at nginx_count cert_count
  timestamp="$(date +"%Y%m%d_%H%M%S")"
  created_at="$(date -Iseconds)"
  archive="$BACKUP_DIR/${domain}_${timestamp}.tar.gz"
  tmp="$(mktemp -d "/tmp/sitebak.${domain}.XXXXXX")"

  trap 'rm -rf "$tmp"' RETURN

  info "正在备份站点文件..."
  mkdir -p "$tmp/files" "$tmp/database" "$tmp/nginx" "$tmp/certs" "$tmp/meta"
  tar -C "$dir" -czf "$tmp/files/site-files.tar.gz" .

  info "正在导出数据库：$DB_NAME"
  run_mysqldump --single-transaction --quick --default-character-set=utf8mb4 "$DB_NAME" | gzip >"$tmp/database/${DB_NAME}.sql.gz"

  info "正在收集 Nginx 配置..."
  mapfile -t nginx_files < <(find_nginx_files "$domain")
  nginx_count="${#nginx_files[@]}"
  if ((nginx_count > 0)); then
    printf "%s\n" "${nginx_files[@]}" >"$tmp/meta/nginx-files.txt"
    tar -czf "$tmp/nginx/nginx-files.tar.gz" -T "$tmp/meta/nginx-files.txt" 2>/dev/null || true
  fi

  info "正在收集 SSL 证书..."
  mapfile -t cert_items < <(find_cert_dirs "$domain")
  cert_count="${#cert_items[@]}"
  if ((cert_count > 0)); then
    printf "%s\n" "${cert_items[@]}" >"$tmp/meta/cert-items.txt"
    tar -czf "$tmp/certs/cert-items.tar.gz" -T "$tmp/meta/cert-items.txt" 2>/dev/null || true
  fi

  write_manifest "$tmp/manifest.json" "$domain" "$created_at" "$dir" "$DB_NAME" "$nginx_count" "$cert_count"
  cat >"$tmp/restore-notes.txt" <<EOF
此备份由 sitebak 生成。

恢复建议：
1. 优先在同样的 LDNMP 环境中恢复。
2. 同域名恢复通常不需要修改 WordPress 设置。
3. 商业插件授权是否保持激活取决于插件厂商。
4. 恢复前 sitebak 会询问是否创建当前站点快照。
EOF

  info "正在生成压缩包：$archive"
  tar -C "$tmp" -czf "$archive" .
  ok "备份完成：$archive"
}

list_backups_for_domain() {
  local domain="${1:-}"
  if [[ -n "$domain" ]]; then
    find "$BACKUP_DIR" -maxdepth 1 -type f -name "${domain}_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9].tar.gz" -printf "%T@ %p\n" 2>/dev/null | sort -rn | cut -d' ' -f2-
  else
    find "$BACKUP_DIR" -maxdepth 1 -type f -name "*_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9].tar.gz" -printf "%T@ %p\n" 2>/dev/null | sort -rn | cut -d' ' -f2-
  fi
}

select_backup() {
  local domain="${1:-}"
  local backups=()
  mapfile -t backups < <(list_backups_for_domain "$domain")

  while true; do
    header >&2
    if [[ -n "$domain" ]]; then
      printf "%s 可用备份：\n\n" "$domain" >&2
    else
      printf "可用备份：\n\n" >&2
    fi

    if ((${#backups[@]} == 0)); then
      warn "未找到备份文件。"
      printf "\n0. 返回上一级\n请选择：" >&2
      read -r choice || return 1
      [[ "$choice" == "0" ]] && return 1
      continue
    fi

    local i file size mtime
    for i in "${!backups[@]}"; do
      file="${backups[$i]}"
      size="$(du -h "$file" | awk '{print $1}')"
      mtime="$(date -r "$file" +"%Y-%m-%d %H:%M:%S")"
      printf "%d. %s    %s    %s\n" "$((i + 1))" "$(basename "$file")" "$size" "$mtime" >&2
    done
    printf "0. 返回上一级\n\n请选择要恢复的版本：" >&2
    read -r choice || return 1

    [[ "$choice" == "0" ]] && return 1
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#backups[@]})); then
      printf "%s" "${backups[$((choice - 1))]}"
      return 0
    fi
    warn "无效的选择，请输入正确编号。"
    pause >&2
  done
}

extract_manifest_value() {
  local file="$1"
  local key="$2"
  sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$file" | head -n 1
}

restore_site() {
  local archive="$1"
  if [[ ! -f "$archive" ]]; then
    err "备份文件不存在：$archive"
    return 1
  fi

  need_cmd tar gzip mysql awk sed find date

  local tmp manifest domain db_name target_dir current_snapshot
  tmp="$(mktemp -d "/tmp/sitebak.restore.XXXXXX")"
  trap 'rm -rf "$tmp"' RETURN

  tar -C "$tmp" -xzf "$archive"
  manifest="$tmp/manifest.json"
  if [[ ! -f "$manifest" ]]; then
    err "备份包缺少 manifest.json，无法安全恢复。"
    return 1
  fi

  domain="$(extract_manifest_value "$manifest" "domain")"
  db_name="$(extract_manifest_value "$manifest" "db_name")"
  target_dir="$(site_path "$domain")"

  if ! valid_domain "$domain"; then
    err "备份包中的域名不合法：$domain"
    return 1
  fi

  header
  warn "即将恢复站点：$domain"
  printf "备份文件：%s\n" "$archive"
  printf "目标目录：%s\n\n" "$target_dir"
  printf "恢复会覆盖当前站点文件，并导入数据库。是否继续？请输入 yes 确认："
  read -r confirm || return 1
  [[ "$confirm" == "yes" ]] || { warn "已取消恢复。"; return 1; }

  if [[ -d "$target_dir" ]]; then
    printf "恢复前是否自动创建当前站点快照？[Y/n] "
    read -r snapshot_choice || true
    snapshot_choice="${snapshot_choice:-Y}"
    if [[ "$snapshot_choice" =~ ^[Yy]$ ]]; then
      current_snapshot="$BACKUP_DIR/${domain}_before_restore_$(date +"%Y%m%d_%H%M%S").tar.gz"
      info "正在创建当前站点快照：$current_snapshot"
      tar -C "$target_dir" -czf "$current_snapshot" .
    fi
  fi

  mkdir -p "$target_dir"
  info "正在恢复站点文件..."
  find "$target_dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  tar -C "$target_dir" -xzf "$tmp/files/site-files.tar.gz"

  if find_wp_config "$target_dir" >/dev/null; then
    read_db_config "$domain"
  else
    DB_NAME="$db_name"
  fi

  if [[ -f "$tmp/database/${db_name}.sql.gz" ]]; then
    info "正在导入数据库：$db_name"
    run_mysql -e "CREATE DATABASE IF NOT EXISTS \`$db_name\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    run_mysql "$db_name" < <(gzip -dc "$tmp/database/${db_name}.sql.gz")
  else
    warn "未找到数据库导出文件，跳过数据库导入。"
  fi

  if [[ -f "$tmp/nginx/nginx-files.tar.gz" ]]; then
    info "正在恢复 Nginx 配置..."
    tar -xzf "$tmp/nginx/nginx-files.tar.gz" -C / 2>/dev/null || warn "Nginx 配置恢复不完整，请手动检查。"
  fi

  if [[ -f "$tmp/certs/cert-items.tar.gz" ]]; then
    info "正在恢复 SSL 证书..."
    tar -xzf "$tmp/certs/cert-items.tar.gz" -C / 2>/dev/null || warn "SSL 证书恢复不完整，请手动检查。"
  fi

  info "正在修正权限..."
  chown -R 1000:1000 "$target_dir" 2>/dev/null || true

  reload_services
  ok "恢复完成：$domain"
}

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
    printf "检查路径：域名/wp-config.php 或 域名/wordpress/wp-config.php\n"
    printf "同时存在两份配置的目录不会自动选择。\n"
  else
    printf "当前 WordPress 站点：\n\n"
    printf "%s\n" "${sites[@]}" | nl -w1 -s'. '
  fi
  pause
}

show_backups() {
  header
  local backups=()
  mapfile -t backups < <(list_backups_for_domain "")
  if ((${#backups[@]} == 0)); then
    warn "未找到备份文件。"
  else
    local file
    for file in "${backups[@]}"; do
      printf "%-48s %8s %s\n" "$(basename "$file")" "$(du -h "$file" | awk '{print $1}')" "$(date -r "$file" +"%Y-%m-%d %H:%M:%S")"
    done
  fi
  pause
}

delete_backup_menu() {
  local file
  file="$(select_backup "")" || return 0
  header
  warn "即将删除备份：$file"
  printf "请输入 yes 确认删除："
  read -r confirm || return 1
  if [[ "$confirm" == "yes" ]]; then
    rm -f "$file"
    ok "已删除：$file"
  else
    warn "已取消删除。"
  fi
  pause
}

update_self() {
  need_cmd curl
  info "正在从 GitHub 更新脚本..."
  local tmp
  tmp="$(mktemp)"
  curl -fsSL "$UPDATE_URL" -o "$tmp"
  bash -n "$tmp"
  install -m 0755 "$tmp" "$INSTALL_PATH"
  rm -f "$tmp"
  ok "更新完成：$INSTALL_PATH"
  info "请退出当前菜单，输入 kk 打开新版菜单。"
}

backup_menu() {
  local domain
  domain="$(select_domain "请选择要备份的站点")" || return 0
  header
  backup_site "$domain"
  pause
}

restore_menu() {
  local domain archive
  domain="$(select_domain "请选择要恢复的站点")" || return 0
  archive="$(select_backup "$domain")" || return 0
  restore_site "$archive"
  pause
}

main_menu() {
  need_root
  while true; do
    header
    cat <<EOF
1. 列出 WordPress 站点
2. 备份单个站点
3. 恢复单个站点
4. 查看备份文件
5. 删除旧备份
6. 更新脚本
0. 退出

EOF
    printf "请输入你的选择："
    read -r choice || exit 0
    case "$choice" in
      1) show_sites ;;
      2) backup_menu ;;
      3) restore_menu ;;
      4) show_backups ;;
      5) delete_backup_menu ;;
      6) update_self; pause ;;
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
  kk update

环境变量：
  SITEBAK_WEB_ROOT       默认 /home/web
  SITEBAK_SITE_ROOT      默认 /home/web/html
  SITEBAK_BACKUP_DIR     默认 /home
  SITEBAK_UPDATE_URL     默认 GitHub raw 地址
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
