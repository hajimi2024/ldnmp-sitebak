#!/usr/bin/env bash
set -Eeuo pipefail
export NO_COLOR=1
export SITEBAK_PUBLIC_IPV4=203.0.113.10
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
      grep -Eq "${checkpoint}% 阶段(1|2)/8" "$file"
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

write_target_cert() {
  local domain="$1"
  : > "${CERT_DIRS[0]}/${domain}_cert.pem"
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
return_to_menu wide < <(printf '0\n') >> "$fixture/change-output"
grep -Fq '✅ 站点 new.example 已成功导入。' "$fixture/change-output"
grep -Fq '源站域名：old.example' "$fixture/change-output"
grep -Fq '目标域名：http://new.example' "$fixture/change-output"
! grep -Fq '目标网址：' "$fixture/change-output"
grep -Fq '🚨 警告：即将为 < new.example > 注入站点文件 & 数据库。' "$fixture/change-output"
grep -Fq '✅ 已验证目标站点 < new.example > 为空站点，允许继续导入。' "$fixture/change-output"
grep -Fq 'WordPress 后台：http://new.example/wp-admin' "$fixture/change-output"
grep -Fq 'WordPress 前台：http://new.example' "$fixture/change-output"
python3 - "$fixture/change-output" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding='utf-8').read()
pattern = re.compile(
    r'\[OK\] ✅ 站点 new\.example 已成功导入。\n'
    r'\[OK\] 操作日志已保存：[^\n]+\.log\n'
    r'---------------------------------------------------\n\n'
    r'WordPress 后台：http://new\.example/wp-admin\n\n'
    r'WordPress 前台：http://new\.example\n\n'
    r'---------------------------------------------------\n'
    r'0\.  返回上一级\n'
    r'---------------------------------------------------\n'
)
assert pattern.search(text), text
PY
! grep -Fq '本阶段未修改 Nginx、SSL' "$fixture/change-output"
grep -Fq '适用于跨服务器导入并更换域名' "$fixture/change-output"
assert_progress_output "$fixture/change-output" yes
[[ $(< "$fixture/finalize-call") == 'change-domain|old.example|new.example|http://new.example' ]]
grep -Fq '正在检查备份包' "$fixture/change-output"
grep -Fq '正在导入目标数据库：target_db' "$fixture/change-output"
grep -Fq '正在替换目标 WordPress 路径' "$fixture/change-output"
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
grep -Fq 'WordPress 前台：http://new.example' "$fixture/confirm-retry-output"

# SQL that can switch or create databases is rejected before confirmation and writes.
printf 'USE another_database;\n' | gzip > "$fixture/forbidden.sql.gz"
expect_failure validate_migration_sql_payload "$fixture/forbidden.sql.gz"
grep -Fq '创建、删除或切换数据库语句' "$fixture/failure-output"
latest_log="$(find "$MIGRATION_LOG_DIR" -type f -name '*_import-change_*.log' -print -quit)"
grep -Fq '目标数据库导入完成：target_db' "$latest_log"
grep -Fq '目标 WordPress 路径导入完成' "$latest_log"
grep -Fq '站点导入写入状态；数据库已导入=yes；文件已替换=yes' "$latest_log"

# Keep-domain import permits different servers but requires the same source and target domain.
start_case keep-success
create_source_backup same.example nested same_source_db
create_target_site same.example direct same_target_db
write_target_nginx same.example
write_target_cert same.example
if ! migration_preflight keep-domain < <(printf '%s\n' 1 yes yes) > "$fixture/keep-output" 2>&1; then
  cat "$fixture/keep-output" >&2
  exit 1
fi
grep -Fq '操作类型：导入并保留域名' "$fixture/keep-output"
! grep -Fq '请选择已预建的空 WordPress 目标站点' "$fixture/keep-output"
grep -Fq '请将 < same.example > 的 DNS 解析到当前服务器' "$fixture/keep-output"
grep -Fq 'IPv4：203.0.113.10' "$fixture/keep-output"
grep -Fq '适用于跨服务器导入并保留域名' "$fixture/keep-output"
[[ $(< "$fixture/finalize-call") == 'keep-domain|same.example|same.example|http://same.example' ]]
[[ $(< "$SITE_ROOT/same.example/index.php") == source:same.example ]]
[[ $(parse_migration_wp_define "$SITE_ROOT/same.example/wp-config.php" DB_NAME) == same_target_db ]]
[[ $(parse_wp_table_prefix "$SITE_ROOT/same.example/wp-config.php") == source_ ]]

# Keep-domain can create the same-domain empty site through the verified k entrypoint.
start_case keep-auto-success
create_source_backup auto.example nested auto_source_db
mock_k="$fixture/mock-k"
cat > "$mock_k" <<'MOCKK'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${KJ_WEB_NONINTERACTIVE:-}" == 1 && "$1" == wp && "$2" == auto.example ]]
printf '%s|%s|%s\n' "${KJ_WEB_NONINTERACTIVE:-}" "$1" "$2" > "$AUTO_CALL_FILE"
printf 'KPANEL_PROGRESS 10 正在校验 WordPress 域名与现有站点\n'
printf 'DB_PASSWORD=must-not-enter-migration-log\n'
printf 'KPANEL_PROGRESS 35 正在签发并配置站点证书\n'
printf 'KPANEL_PROGRESS 75 正在获取并配置 WordPress 源码\n'
mkdir -p "$AUTO_SITE_ROOT/$2/wordpress" "$AUTO_NGINX_ROOT" "$AUTO_CERT_ROOT"
cat > "$AUTO_SITE_ROOT/$2/wordpress/wp-config.php" <<EOF
<?php
define('DB_NAME', 'auto_example');
define('DB_USER', 'target_user');
define('DB_PASSWORD', 'target_password');
define('DB_HOST', 'mysql');
\$table_prefix = 'target_';
EOF
printf 'blank target\n' > "$AUTO_SITE_ROOT/$2/wordpress/index.php"
printf 'server { listen 80; server_name %s; }\n' "$2" > "$AUTO_NGINX_ROOT/$2.conf"
: > "$AUTO_CERT_ROOT/${2}_cert.pem"
printf 'KPANEL_PROGRESS 100 kejilion.sh 原生建站产物已完成\n'
MOCKK
chmod 0755 "$mock_k"
AUTO_CALL_FILE="$fixture/auto-k-call"
AUTO_SITE_ROOT="$SITE_ROOT"
AUTO_NGINX_ROOT="${NGINX_CONF_DIRS[0]}"
AUTO_CERT_ROOT="${CERT_DIRS[0]}"
export AUTO_CALL_FILE AUTO_SITE_ROOT AUTO_NGINX_ROOT AUTO_CERT_ROOT
resolve_kejilion_command() { printf '%s' "$mock_k"; }
kejilion_database_exists() { return 1; }
if ! migration_preflight keep-domain < <(printf '%s\n' 1 yes yes) > "$fixture/keep-auto-output" 2>&1; then
  cat "$fixture/keep-auto-output" >&2
  exit 1
fi
[[ $(< "$AUTO_CALL_FILE") == '1|wp|auto.example' ]]
declare -f run_kejilion_wordpress_create | grep -Fq 'KJ_WEB_NONINTERACTIVE=1 "$command_path" wp "$domain"'
! declare -f run_kejilion_wordpress_create | grep -Eq '(^|[[:space:]])eval([[:space:]]|$)'
grep -Fq '10% 阶段2/8：正在校验 WordPress 域名与现有站点' "$fixture/keep-auto-output"
grep -Fq '99% 阶段2/8：kejilion.sh 原生建站产物已完成' "$fixture/keep-auto-output"
grep -Fq '100% 阶段2/8：同域名目标站点创建与空数据库验证完成' "$fixture/keep-auto-output"
[[ $(parse_migration_wp_define "$SITE_ROOT/auto.example/wordpress/wp-config.php" DB_NAME) == auto_example ]]
auto_log="$(find "$MIGRATION_LOG_DIR" -type f -name '*_import-keep_auto.example-to-auto.example_*.log' -print -quit)"
[[ -f "$auto_log" ]]
! grep -Fq 'must-not-enter-migration-log' "$auto_log"
[[ -z "$(find "$MIGRATION_TMP_ROOT" -mindepth 1 -print -quit)" ]]

# DNS cancellation happens after safe inspection but before k, and SiteBak temporary files are removed.
start_case keep-dns-cancel
create_source_backup cancelkeep.example nested cancel_source_db
rm -f -- "$AUTO_CALL_FILE"
migration_preflight keep-domain < <(printf '%s\n' 1 '') > "$fixture/keep-cancel-output" 2>&1
grep -Fq '已取消本次导入' "$fixture/keep-cancel-output"
[[ ! -e "$AUTO_CALL_FILE" ]]
[[ ! -e "$SITE_ROOT/cancelkeep.example" ]]
[[ -z "$(find "$MIGRATION_TMP_ROOT" -mindepth 1 -print -quit)" ]]

# An invalid public IPv4 stops before k is called.
start_case keep-invalid-ip
create_source_backup invalidip.example nested invalid_source_db
rm -f -- "$AUTO_CALL_FILE"
SITEBAK_PUBLIC_IPV4=not-an-ip
expect_failure migration_preflight keep-domain < <(printf '%s\n' 1 yes)
grep -Fq '不是合法的 IPv4 地址' "$fixture/failure-output"
[[ ! -e "$AUTO_CALL_FILE" ]]
SITEBAK_PUBLIC_IPV4=203.0.113.10

# Private, CGNAT and failed public IPv4 lookups stop before k is called.
for invalid_ipv4 in 10.0.0.1 172.16.0.1 192.168.1.1 100.64.0.1; do
  ! valid_ipv4 "$invalid_ipv4"
done
start_case keep-ip-query-failure
create_source_backup noip.example nested noip_source_db
rm -f -- "$AUTO_CALL_FILE"
unset SITEBAK_PUBLIC_IPV4
ip() { printf '1.1.1.1 via 10.0.0.1 dev eth0 src 10.0.0.2\n'; }
curl() { return 22; }
expect_failure migration_preflight keep-domain < <(printf '%s\n' 1)
grep -Fq '无法取得当前服务器的合法公网 IPv4' "$fixture/failure-output"
[[ ! -e "$AUTO_CALL_FILE" ]]

# A public outbound source address is preferred without calling the external lookup.
ip() { printf '1.1.1.1 via 198.51.100.1 dev eth0 src 198.51.100.8\n'; }
curl() { printf 'curl-must-not-run\n' >> "$fixture/curl-called"; return 22; }
[[ $(get_public_ipv4) == 198.51.100.8 ]]
[[ ! -e "$fixture/curl-called" ]]
SITEBAK_PUBLIC_IPV4=203.0.113.10

# Partial same-domain resources are rejected without running k.
start_case keep-partial
create_source_backup partial.example nested partial_source_db
mkdir -p "$SITE_ROOT/partial.example"
rm -f -- "$AUTO_CALL_FILE"
expect_failure migration_preflight keep-domain < <(printf '%s\n' 1 yes)
grep -Fq '残留目录、Nginx 或证书资源' "$fixture/failure-output"
[[ ! -e "$AUTO_CALL_FILE" ]]

# A missing or unsafe k entrypoint stops before external resources or imports are written.
start_case keep-k-missing
create_source_backup nok.example nested nok_source_db
resolve_kejilion_command() { err '未找到科技 Lion 命令 k，尚未创建目标站点。'; return 1; }
expect_failure migration_preflight keep-domain < <(printf '%s\n' 1 yes)
grep -Fq '未找到科技 Lion 命令 k' "$fixture/failure-output"
[[ ! -e "$SITE_ROOT/nok.example" && ! -e "$fixture/imported.sql" ]]

start_case keep-k-unsafe
create_source_backup unsafe.example nested unsafe_source_db
resolve_kejilion_command() { err '科技 Lion 命令 k 可被组或其他用户写入，拒绝执行。'; return 1; }
expect_failure migration_preflight keep-domain < <(printf '%s\n' 1 yes)
grep -Fq '可被组或其他用户写入' "$fixture/failure-output"
[[ ! -e "$SITE_ROOT/unsafe.example" && ! -e "$fixture/imported.sql" ]]
resolve_kejilion_command() { printf '%s' "$mock_k"; }

# A successful k exit without complete WordPress, Nginx and certificate resources is rejected.
start_case keep-k-incomplete
create_source_backup incomplete.example nested incomplete_source_db
cat > "$mock_k" <<'MOCKKINCOMPLETE'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'KPANEL_PROGRESS 100 科技 Lion 报告完成\n'
mkdir -p "$AUTO_SITE_ROOT/$2"
MOCKKINCOMPLETE
chmod 0755 "$mock_k"
expect_failure migration_preflight keep-domain < <(printf '%s\n' 1 yes)
grep -Fq 'WordPress、Nginx 或证书产物不完整' "$fixture/failure-output"
[[ ! -e "$fixture/imported.sql" ]]

# An existing complete same-domain site with data is never reused or overwritten.
start_case keep-existing-nonempty
create_source_backup occupied.example nested occupied_source_db
create_target_site occupied.example nested occupied_target_db
write_target_nginx occupied.example
write_target_cert occupied.example
printf 'existing_table\n' > "$db_tables_file"
cp -a "$SITE_ROOT/occupied.example" "$fixture/occupied-before"
expect_failure migration_preflight keep-domain < <(printf '%s\n' 1 yes)
grep -Fq '目标数据库不是空库' "$fixture/failure-output"
diff -r "$fixture/occupied-before" "$SITE_ROOT/occupied.example"
[[ ! -e "$fixture/imported.sql" ]]

# A failed k command stops before import, retains external partial resources, and removes raw output.
start_case keep-k-failure
create_source_backup failed.example nested failed_source_db
cat > "$mock_k" <<'MOCKKFAIL'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s|%s|%s\n' "${KJ_WEB_NONINTERACTIVE:-}" "$1" "$2" > "$AUTO_CALL_FILE"
printf 'KPANEL_PROGRESS 20 正在准备 LDNMP 环境\n'
printf 'DB_PASSWORD=failed-secret\n'
mkdir -p "$AUTO_SITE_ROOT/$2"
exit 7
MOCKKFAIL
chmod 0755 "$mock_k"
AUTO_SITE_ROOT="$SITE_ROOT"
export AUTO_SITE_ROOT
rm -f -- "$AUTO_CALL_FILE"
expect_failure migration_preflight keep-domain < <(printf '%s\n' 1 yes)
grep -Fq '科技 Lion 创建站点失败（退出码：7）' "$fixture/failure-output"
[[ $(< "$AUTO_CALL_FILE") == '1|wp|failed.example' ]]
[[ -d "$SITE_ROOT/failed.example" ]]
[[ ! -e "$fixture/imported.sql" ]]
failed_log="$(find "$MIGRATION_LOG_DIR" -type f -name '*_import-keep_failed.example-to-failed.example_*.log' -print -quit)"
[[ -f "$failed_log" ]]
! grep -Fq 'failed-secret' "$failed_log"
[[ -z "$(find "$MIGRATION_TMP_ROOT" -mindepth 1 -print -quit)" ]]

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
