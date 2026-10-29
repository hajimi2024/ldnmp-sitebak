#!/usr/bin/env bash
set -Eeuo pipefail
export NO_COLOR=1
source "$(dirname "$0")/../sitebak.sh"

fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
fixture_stamp=20261026_130000
db_tables_file=''
import_status=0
finalize_status=0
wpcli_status=0
wpcli_preflight_done=no
fixture_server_identity='target-vps / machine:0123456789abcdef'

clear_screen() { :; }
need_root() { :; }
date() {
  case "${1:-}" in
    +%Y%m%d_%H%M%S) printf '%s\n' "$fixture_stamp" ;;
    *) command date "$@" ;;
  esac
}
prepare_db_client() {
  DB_CONTAINER=mysql
  DB_CLIENT=mysql
  DB_CONNECT_ARGS=(-h 127.0.0.1 --protocol=TCP -P 3306)
}
get_target_server_identity() { printf '%s' "$fixture_server_identity"; }
get_target_server_username() { printf '%s' fixture-user; }
get_target_server_display() { printf '%s' '@target-vps 2c4g'; }
prepare_wp_cli_environment() {
  ((wpcli_status == 0)) || return "$wpcli_status"
  wpcli_preflight_done=yes
  migration_log INFO 'MOCK WP-CLI 环境检查通过。'
}
finalize_wordpress_migration() {
  printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" > "$fixture/finalize-call"
  ((finalize_status == 0)) || return "$finalize_status"
  migration_log INFO "MOCK WordPress 收尾：$1 / $2 / $3"
}
run_mysqldump() { printf '%s\n' 'CREATE TABLE `source_options` (`option_id` bigint);'; }
run_mysql() {
  if [[ " $* " == *' SHOW TABLES '* ]]; then
    cat "$db_tables_file"
  elif [[ " $* " == *' SELECT 1 '* || " $* " == *' -e '* ]]; then
    :
  elif [[ "${1:-}" == "$DB_NAME" ]]; then
    [[ "$wpcli_preflight_done" == yes ]] || return 92
    ((import_status == 0)) || return "$import_status"
    cat > "$fixture/imported.sql"
    printf 'source_options\n' > "$db_tables_file"
  else
    return 91
  fi
}

expect_failure() {
  local status
  set +e
  ( set -Eeuo pipefail; "$@" ) > "$fixture/failure-output" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
}

assert_progress_output() {
  local file="$1" expect_complete="$2" values=() i
  mapfile -t values < <(grep -oE '[[:space:]][0-9]{1,3}%' "$file" | tr -d ' %')
  ((${#values[@]} > 0))
  if [[ "$expect_complete" == yes ]]; then
    for stage in {1..8}; do
      grep -Fq "0% 阶段${stage}/8" "$file"
    done
    for checkpoint in 25 50 75; do
      grep -Fq "${checkpoint}% 阶段2/8" "$file"
    done
    [[ $(grep -c '100% 阶段[1-8]/8：' "$file") == 8 ]]
    [[ $(grep -c '100% 阶段[1-8]/8：.*完成' "$file") == 8 ]]
  else
    [[ $(grep -c '100% 阶段[1-8]/8：' "$file") -lt 8 ]]
  fi
}

write_wp_config() {
  local file="$1" db="$2" user="$3" password="$4" prefix="$5"
  mkdir -p "$(dirname "$file")"
  printf '%s\n' \
    '<?php' \
    "define('DB_NAME', '$db');" \
    "define('DB_USER', '$user');" \
    "define('DB_PASSWORD', '$password');" \
    "define('DB_HOST', 'mysql');" \
    "\$table_prefix = '$prefix';" > "$file"
}

start_case() {
  local name="$1"
  SITE_ROOT="$fixture/$name/html"
  BACKUP_DIR="$fixture/$name/backups"
  MIGRATION_LOG_DIR="$fixture/$name/logs"
  MIGRATION_TMP_ROOT="$fixture/$name/tmp"
  NGINX_CONF_DIRS=("$fixture/$name/nginx")
  CERT_DIRS=("$fixture/$name/certs")
  db_tables_file="$fixture/$name/db-tables"
  import_status=0
  finalize_status=0
  wpcli_status=0
  wpcli_preflight_done=no
  fixture_server_identity='target-vps / machine:0123456789abcdef'
  rm -f -- "$fixture/imported.sql"
  rm -f -- "$fixture/finalize-call"
  mkdir -p "$SITE_ROOT" "$BACKUP_DIR" "$MIGRATION_TMP_ROOT" "${NGINX_CONF_DIRS[0]}" "${CERT_DIRS[0]}"
  : > "$db_tables_file"
}

create_source_backup() {
  local domain="$1" layout="$2" db="$3" url_constants="${4:-no}" root
  root="$SITE_ROOT/$domain"
  [[ "$layout" != nested ]] || root="$root/wordpress"
  write_wp_config "$root/wp-config.php" "$db" source_user source_password source_
  if [[ "$url_constants" == yes ]]; then
    printf "define('WP_HOME', 'https://%s');\ndefine('WP_SITEURL', 'https://%s');\n" "$domain" "$domain" >> "$root/wp-config.php"
  elif [[ "$url_constants" == dynamic ]]; then
    printf '%s\n' "define('WP_HOME', 'https://' . \$_SERVER['HTTP_HOST']);" >> "$root/wp-config.php"
  fi
  mkdir -p "$root/wp-content/uploads"
  printf 'source:%s\n' "$domain" > "$root/index.php"
  printf 'media\n' > "$root/wp-content/uploads/file.txt"
  backup_site "$domain" >/dev/null
  rm -rf -- "$SITE_ROOT/$domain"
}

create_target_site() {
  local domain="$1" layout="$2" db="$3" root
  root="$SITE_ROOT/$domain"
  mkdir -p "$root"
  printf 'outside target root\n' > "$root/outside.keep"
  [[ "$layout" != nested ]] || root="$root/wordpress"
  write_wp_config "$root/wp-config.php" "$db" target_user target_password target_
  printf 'blank target\n' > "$root/index.php"
}

write_target_nginx() {
  local domain="$1"
  printf 'server { listen 80; server_name %s; }\n' "$domain" > "${NGINX_CONF_DIRS[0]}/$domain.conf"
}

# Change-domain import writes only the selected target Root and target database.
start_case change-success
create_source_backup old.example direct source_db yes
archive="$BACKUP_DIR/old.example_${fixture_stamp}.tar.gz"
create_target_site new.example nested target_db
write_target_nginx new.example
nginx_before="$(sha256sum "${NGINX_CONF_DIRS[0]}/new.example.conf")"
mkdir -p "$SITE_ROOT/other.example/wordpress"
write_wp_config "$SITE_ROOT/other.example/wordpress/wp-config.php" other_db other_user other_password other_
printf 'other site\n' > "$SITE_ROOT/other.example/wordpress/index.php"
cp -a "$SITE_ROOT/other.example" "$fixture/other-before"
if ! migration_preflight change-domain < <(printf '%s\n' 1 1 new.example yes) > "$fixture/change-output" 2>&1; then
  cat "$fixture/change-output" >&2
  exit 1
fi
grep -Fq '✅ 站点 new.example 已成功导入。' "$fixture/change-output"
grep -Fq '🚨 警告：即将为 new.example 注入文件 & 数据库。' "$fixture/change-output"
grep -Fq '✅ 已验证目标站点 < new.example > 为空站点，允许继续导入。' "$fixture/change-output"
grep -Fq 'WordPress 后台：http://new.example/wp-admin' "$fixture/change-output"
grep -Fq '适用于跨服务器导入并更换域名' "$fixture/change-output"
assert_progress_output "$fixture/change-output" yes
[[ $(< "$fixture/finalize-call") == 'change-domain|old.example|new.example|http://new.example' ]]
grep -Fq '正在检查备份包' "$fixture/change-output"
grep -Fq '正在导入目标数据库：target_db' "$fixture/change-output"
grep -Fq '正在替换目标 WordPress Root' "$fixture/change-output"
[[ $(< "$SITE_ROOT/new.example/wordpress/index.php") == source:old.example ]]
[[ $(parse_migration_wp_define "$SITE_ROOT/new.example/wordpress/wp-config.php" DB_NAME) == target_db ]]
[[ $(parse_migration_wp_define "$SITE_ROOT/new.example/wordpress/wp-config.php" DB_USER) == target_user ]]
[[ $(parse_migration_wp_define "$SITE_ROOT/new.example/wordpress/wp-config.php" DB_PASSWORD) == target_password ]]
[[ $(parse_migration_wp_define "$SITE_ROOT/new.example/wordpress/wp-config.php" DB_HOST) == mysql ]]
[[ $(parse_wp_table_prefix "$SITE_ROOT/new.example/wordpress/wp-config.php") == source_ ]]
grep -Fq "define('WP_HOME', 'http://new.example');" "$SITE_ROOT/new.example/wordpress/wp-config.php"
grep -Fq "define('WP_SITEURL', 'http://new.example');" "$SITE_ROOT/new.example/wordpress/wp-config.php"
[[ $(< "$SITE_ROOT/new.example/outside.keep") == 'outside target root' ]]
grep -Fq 'CREATE TABLE' "$fixture/imported.sql"
[[ "$(sha256sum "${NGINX_CONF_DIRS[0]}/new.example.conf")" == "$nginx_before" ]]
diff -r "$fixture/other-before" "$SITE_ROOT/other.example"
[[ -z "$(find "$MIGRATION_TMP_ROOT" -mindepth 1 -print -quit)" ]]

# 错误确认值应停留在确认环节，后续输入 yes 才会继续。
start_case confirm-retry
create_source_backup old.example direct source_db
create_target_site new.example nested target_db
write_target_nginx new.example
if ! migration_preflight change-domain < <(printf '%s\n' 1 new.example yse yes) > "$fixture/confirm-retry-output" 2>&1; then
  cat "$fixture/confirm-retry-output" >&2
  exit 1
fi
grep -Fq '输入错误，请输入完整小写 yes' "$fixture/confirm-retry-output"
grep -Fq '✅ 站点 new.example 已成功导入。' "$fixture/confirm-retry-output"
grep -Fq 'WordPress 后台：http://new.example/wp-admin' "$fixture/confirm-retry-output"

# SQL that can switch or create databases is rejected before confirmation and writes.
printf 'USE another_database;\n' | gzip > "$fixture/forbidden.sql.gz"
expect_failure validate_migration_sql_payload "$fixture/forbidden.sql.gz"
grep -Fq '创建、删除或切换数据库语句' "$fixture/failure-output"
latest_log="$(find "$MIGRATION_LOG_DIR" -type f -name '*_import-change_*.log' -print -quit)"
grep -Fq '目标数据库导入完成：target_db' "$latest_log"
grep -Fq '目标 WordPress Root 导入完成' "$latest_log"
grep -Fq '站点导入写入状态；数据库已导入=yes；文件已替换=yes' "$latest_log"

# Keep-domain import permits different servers but requires the same source and target domain.
start_case keep-success
create_source_backup same.example nested same_source_db
create_target_site same.example direct same_target_db
write_target_nginx same.example
if ! migration_preflight keep-domain < <(printf '%s\n' 1 1 same.example yes) > "$fixture/keep-output" 2>&1; then
  cat "$fixture/keep-output" >&2
  exit 1
fi
grep -Fq '操作类型：导入并保留域名' "$fixture/keep-output"
grep -Fq '请选择已预建的空 WordPress 目标站点' "$fixture/keep-output"
grep -Fq '适用于跨服务器导入并保留域名' "$fixture/keep-output"
[[ $(< "$fixture/finalize-call") == 'keep-domain|same.example|same.example|http://same.example' ]]
[[ $(< "$SITE_ROOT/same.example/index.php") == source:same.example ]]
[[ $(parse_migration_wp_define "$SITE_ROOT/same.example/wp-config.php" DB_NAME) == same_target_db ]]
[[ $(parse_wp_table_prefix "$SITE_ROOT/same.example/wp-config.php") == source_ ]]

# A rejected confirmation performs no write.
start_case cancel
create_source_backup old.example direct source_db
create_target_site new.example nested target_db
write_target_nginx new.example
cp -a "$SITE_ROOT/new.example" "$fixture/cancel-before"
migration_preflight change-domain < <(printf '%s\n' 1 1 new.example no) > "$fixture/cancel-output" 2>&1
grep -Fq '已取消操作' "$fixture/cancel-output"
diff -r "$fixture/cancel-before" "$SITE_ROOT/new.example"
[[ ! -e "$fixture/imported.sql" ]]

# A dynamic source URL constant is rejected during staging, before confirmation or target writes.
start_case dynamic-url
create_source_backup old.example direct source_db dynamic
create_target_site new.example nested target_db
write_target_nginx new.example
cp -a "$SITE_ROOT/new.example" "$fixture/dynamic-before"
expect_failure migration_preflight change-domain < <(printf '%s\n' 1 1 new.example yes)
grep -Fq '不能唯一安全适配目标网址' "$fixture/failure-output"
diff -r "$fixture/dynamic-before" "$SITE_ROOT/new.example"
[[ ! -e "$fixture/imported.sql" ]]
[[ ! -s "$db_tables_file" ]]
[[ -z "$(find "$MIGRATION_TMP_ROOT" -mindepth 1 -print -quit)" ]]

# A non-empty database, an invalid mode target and an import failure all stop safely.
start_case nonempty
create_source_backup old.example direct source_db
create_target_site new.example nested target_db
write_target_nginx new.example
printf 'existing_table\n' > "$db_tables_file"
cp -a "$SITE_ROOT/new.example" "$fixture/nonempty-before"
migration_preflight change-domain < <(printf '%s\n' 1 1 new.example) > "$fixture/failure-output" 2>&1 || true
grep -Fq '空 WordPress 目标站点' "$fixture/failure-output"
diff -r "$fixture/nonempty-before" "$SITE_ROOT/new.example"

start_case wrong-target
create_source_backup same.example direct source_db
create_target_site same.example nested target_db
write_target_nginx same.example
cp -a "$SITE_ROOT/same.example" "$fixture/wrong-before"
expect_failure migration_preflight change-domain < <(printf '%s\n' 1 1 same.example)
grep -Fq '导入并更换域名要求源域名与目标域名不同' "$fixture/failure-output"
diff -r "$fixture/wrong-before" "$SITE_ROOT/same.example"

start_case import-failure
create_source_backup old.example direct source_db
create_target_site new.example nested target_db
write_target_nginx new.example
import_status=7
cp -a "$SITE_ROOT/new.example" "$fixture/import-failure-before"
expect_failure migration_preflight change-domain < <(printf '%s\n' 1 1 new.example yes)
grep -Fq '数据库导入失败' "$fixture/failure-output"
assert_progress_output "$fixture/failure-output" no
diff -r "$fixture/import-failure-before" "$SITE_ROOT/new.example"
[[ -z "$(find "$MIGRATION_TMP_ROOT" -mindepth 1 -print -quit)" ]]

# WP-CLI 容器预检失败必须发生在数据库导入和文件替换之前。
start_case wpcli-preflight-failure
create_source_backup old.example direct source_db
create_target_site new.example nested target_db
write_target_nginx new.example
wpcli_status=8
cp -a "$SITE_ROOT/new.example" "$fixture/wpcli-before"
expect_failure migration_preflight change-domain < <(printf '%s\n' 1 1 new.example)
wpcli_log="$(find "$MIGRATION_LOG_DIR" -type f -name '*_import-change_*.log' -print -quit)"
grep -Fq 'WP-CLI 环境检查失败，尚未写入目标站点' "$wpcli_log"
diff -r "$fixture/wpcli-before" "$SITE_ROOT/new.example"
[[ ! -e "$fixture/imported.sql" ]]
assert_progress_output "$fixture/failure-output" no

# 收尾失败不能报导入成功，已写入状态必须明确并清理临时目录。
start_case finalize-failure
create_source_backup old.example direct source_db
create_target_site new.example nested target_db
write_target_nginx new.example
finalize_status=9
expect_failure migration_preflight change-domain < <(printf '%s\n' 1 1 new.example yes)
[[ $(< "$fixture/finalize-call") == 'change-domain|old.example|new.example|http://new.example' ]]
grep -Fq '目标站点可能已部分写入，请重新准备空白目标站点后从头导入' "$fixture/failure-output"
[[ -f "$fixture/imported.sql" ]]
[[ -z "$(find "$MIGRATION_TMP_ROOT" -mindepth 1 -print -quit)" ]]

# A server identity change after yes stops before either database or file writes.
start_case identity-change
create_source_backup old.example direct source_db
create_target_site new.example nested target_db
write_target_nginx new.example
cp -a "$SITE_ROOT/new.example" "$fixture/identity-before"
ui_read() {
  local variable="$1" output_fd="${2:-1}" status
  if IFS= read -r "$variable"; then status=0; else status=$?; fi
  printf '%s' "$RESET" >&"$output_fd"
  if [[ "$variable" == confirm ]]; then fixture_server_identity='wrong-vps / machine:fedcba9876543210'; fi
  return "$status"
}
expect_failure migration_preflight change-domain < <(printf '%s\n' 1 1 new.example yes)
grep -Fq '目标身份或操作范围在预检期间发生变化' "$fixture/failure-output"
diff -r "$fixture/identity-before" "$SITE_ROOT/new.example"
[[ ! -e "$fixture/imported.sql" ]]
[[ -z "$(find "$MIGRATION_TMP_ROOT" -mindepth 1 -print -quit)" ]]

printf 'PASS: complete change/keep import, confirmation, identity, failure and cleanup safety\n'
