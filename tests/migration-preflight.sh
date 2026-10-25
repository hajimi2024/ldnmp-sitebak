#!/usr/bin/env bash
set -Eeuo pipefail
export NO_COLOR=1
source "$(dirname "$0")/../sitebak.sh"

fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
SITE_ROOT="$fixture/html"
BACKUP_DIR="$fixture/backups"
MIGRATION_LOG_DIR="$fixture/logs"
MIGRATION_TMP_ROOT="$fixture/tmp"
NGINX_CONF_DIRS=("$fixture/nginx")
CERT_DIRS=("$fixture/certs")
mkdir -p "$SITE_ROOT" "$BACKUP_DIR" "$MIGRATION_TMP_ROOT" "${NGINX_CONF_DIRS[0]}" "${CERT_DIRS[0]}"
clear_screen() { :; }
need_root() { :; }
fixture_stamp=20261026_120000
db_tables=''

date() {
  case "${1:-}" in
    +%Y%m%d_%H%M%S) printf '%s\n' "$fixture_stamp" ;;
    *) command date "$@" ;;
  esac
}
prepare_db_client() { :; }
run_mysqldump() { printf '%s\n' 'CREATE TABLE `wp_options` (`option_id` bigint);'; }
run_mysql() {
  printf '%s' "$db_tables"
}

write_wp_config() {
  local file="$1" db="$2" user="$3" password="$4" host="$5"
  mkdir -p "$(dirname "$file")"
  printf '%s\n' \
    '<?php' \
    "define('DB_NAME', '$db');" \
    "define('DB_USER', '$user');" \
    "define('DB_PASSWORD', '$password');" \
    "define('DB_HOST', '$host');" \
    '\$table_prefix = '\''wp_'\'';' > "$file"
}

create_source_backup() {
  local domain="$1" layout="$2" db="$3"
  local root="$SITE_ROOT/$domain"
  if [[ "$layout" == nested ]]; then root="$root/wordpress"; fi
  write_wp_config "$root/wp-config.php" "$db" source_user 'source secret' mysql
  mkdir -p "$root/wp-content/uploads"
  printf 'source:%s\n' "$domain" > "$root/index.php"
  printf 'media\n' > "$root/wp-content/uploads/file.txt"
  backup_site "$domain" >/dev/null
  rm -rf -- "$SITE_ROOT/$domain"
}

create_target_site() {
  local domain="$1" layout="$2" db="$3"
  local root="$SITE_ROOT/$domain"
  mkdir -p "$root"
  printf 'outside target root\n' > "$root/outside.keep"
  if [[ "$layout" == nested ]]; then root="$root/wordpress"; fi
  write_wp_config "$root/wp-config.php" "$db" target_user 'target secret with spaces' mysql
  printf 'blank target\n' > "$root/index.php"
}

write_https_nginx() {
  local domain="$1"
  cat > "${NGINX_CONF_DIRS[0]}/$domain.conf" <<EOF
server {
  listen 80;
  listen 443 ssl;
  server_name $domain;
  ssl_certificate /etc/nginx/certs/$domain.pem;
  ssl_certificate_key /etc/nginx/certs/$domain.key;
}
EOF
}

expect_failure() {
  local status
  set +e
  ( set -Eeuo pipefail; "$@" ) > "$fixture/failure-output" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
}

# Build a real ordinary SiteBak archive with a direct source WordPress Root.
create_source_backup source.example direct source_db
archive="$BACKUP_DIR/source.example_${fixture_stamp}.tar.gz"
[[ -f "$archive" ]]
create_target_site target.example nested target_db
write_https_nginx target.example

# Inspect and stage independently: source direct Root maps only into the target nested Root.
inspect_root="$fixture/inspect"
inspect_migration_archive "$archive" "$inspect_root/package" "$inspect_root/source-site"
[[ "$MIGRATION_SOURCE_DOMAIN" == source.example ]]
[[ "$MIGRATION_SOURCE_DB" == source_db ]]
[[ "$MIGRATION_SOURCE_WP_ROOT" == "$inspect_root/source-site" ]]
target_config="$SITE_ROOT/target.example/wordpress/wp-config.php"
validate_migration_wp_config "$target_config" '目标配置'
sed -i '1a // define('\''DB_NAME'\'', '\''commented_fake_db'\'');' "$target_config"
read_migration_db_config_file "$target_config"
[[ "$DB_NAME" == target_db ]]
cp -a "$SITE_ROOT/target.example" "$fixture/target-before"
prepare_migration_stage "$MIGRATION_SOURCE_WP_ROOT" "$target_config" "$inspect_root/staged"
[[ $(< "$inspect_root/staged/index.php") == 'source:source.example' ]]
for key in DB_NAME DB_USER DB_PASSWORD DB_HOST; do
  [[ "$(parse_migration_wp_define "$inspect_root/staged/wp-config.php" "$key")" == "$(parse_migration_wp_define "$target_config" "$key")" ]]
done
[[ ! -e "$inspect_root/staged/outside.keep" ]]

# Target selection accepts only a listed numeric choice, never an arbitrary domain.
selected="$(select_existing_domain < <(printf '%s\n' arbitrary.example 1) 2> "$fixture/strict-selection")"
[[ "$selected" == target.example ]]
grep -Fq '请从当前站点列表中选择' "$fixture/strict-selection"

# Full phase-two preflight is read-only and cleans its temporary directory.
if ! migration_preflight change-domain < <(printf '%s\n' 1 1) > "$fixture/change-output" 2>&1; then
  cat "$fixture/change-output" >&2
  exit 1
fi
grep -Fq '阶段二预检和临时暂存已通过' "$fixture/change-output"
grep -Fq 'https://target.example' "$fixture/change-output"
grep -Fq '未导入数据库、未替换目标文件' "$fixture/change-output"
diff -r "$fixture/target-before" "$SITE_ROOT/target.example"
[[ -z "$(find "$MIGRATION_TMP_ROOT" -mindepth 1 -print -quit)" ]]
latest_log="$(find "$MIGRATION_LOG_DIR" -type f -name 'migration_change-domain_*.log' -print -quit)"
[[ -f "$latest_log" && $(stat -c '%a' "$latest_log") == 600 ]]
grep -Fq '源域名=source.example' "$latest_log"
grep -Fq '目标域名=target.example' "$latest_log"
! grep -Fq 'target secret with spaces' "$latest_log"

# A non-empty target database must stop before any target file change.
db_tables='wp_options'
expect_failure migration_preflight change-domain < <(printf '%s\n' 1 1)
if ! grep -Fq '目标数据库不是空库' "$fixture/failure-output"; then
  cat "$fixture/failure-output" >&2
  exit 1
fi
diff -r "$fixture/target-before" "$SITE_ROOT/target.example"
db_tables=''

# Preserve-domain mode requires the manifest and selected target domain to match.
expect_failure migration_preflight keep-domain < <(printf '%s\n' 1 1)
grep -Fq '要求源域名与目标域名完全一致' "$fixture/failure-output"

# Preserve-domain preflight also succeeds when the uploaded backup and target match.
fixture_stamp=20261026_120100
create_source_backup same.example nested same_db
create_target_site same.example direct same_target_db
printf 'server { listen 80; server_name same.example; }\n' > "${NGINX_CONF_DIRS[0]}/same.example.conf"
cp -a "$SITE_ROOT/same.example" "$fixture/same-before"
if ! migration_preflight keep-domain < <(printf '%s\n' 1 1) > "$fixture/keep-output" 2>&1; then
  cat "$fixture/keep-output" >&2
  exit 1
fi
grep -Fq '源域名：same.example' "$fixture/keep-output"
grep -Fq '目标域名：same.example' "$fixture/keep-output"
grep -Fq 'http://same.example' "$fixture/keep-output"
diff -r "$fixture/same-before" "$SITE_ROOT/same.example"

# Nginx scheme detection accepts complete HTTP/HTTPS configs and rejects ambiguous TLS.
printf 'server { listen 80; server_name http.example; }\n' > "${NGINX_CONF_DIRS[0]}/http.example.conf"
[[ $(detect_target_scheme http.example) == http ]]
cat > "${NGINX_CONF_DIRS[0]}/mixed.example.conf" <<'EOF'
server { listen 80; server_name mixed.example; }
server {
  listen 443 ssl;
  server_name unrelated.example;
  ssl_certificate /tmp/unrelated.crt;
  ssl_certificate_key /tmp/unrelated.key;
}
EOF
[[ $(detect_target_scheme mixed.example) == http ]]
printf 'server { listen 443; server_name broken.example; ssl_certificate /tmp/cert; }\n' > "${NGINX_CONF_DIRS[0]}/broken.example.conf"
expect_failure detect_target_scheme broken.example
grep -Fq 'HTTPS 配置不完整' "$fixture/failure-output"

# Duplicate database definitions are never accepted for migration staging.
cp "$target_config" "$fixture/duplicate-config.php"
printf "define('DB_NAME', 'second_db');\n" >> "$fixture/duplicate-config.php"
expect_failure validate_migration_wp_config "$fixture/duplicate-config.php" '重复配置'
grep -Fq 'DB_NAME 必须存在且只能定义一次' "$fixture/failure-output"

# Unsafe member paths, special files and escaping symlinks are rejected.
mkdir -p "$fixture/unsafe/source"
printf 'unsafe\n' > "$fixture/unsafe/source/item"
tar -czf "$fixture/path-traversal.tar.gz" -C "$fixture/unsafe/source" --transform='s#item#../escape#' item 2>/dev/null
expect_failure validate_tar_archive "$fixture/path-traversal.tar.gz" '越界测试' no
grep -Fq '越界路径' "$fixture/failure-output"

mkfifo "$fixture/unsafe/source/pipe"
tar -czf "$fixture/special.tar.gz" -C "$fixture/unsafe/source" pipe
expect_failure validate_tar_archive "$fixture/special.tar.gz" '特殊文件测试' no
grep -Fq '特殊文件' "$fixture/failure-output"

ln -s ../../outside "$fixture/unsafe/source/escape-link"
tar -czf "$fixture/escape-link.tar.gz" -C "$fixture/unsafe/source" escape-link
expect_failure extract_safe_tar "$fixture/escape-link.tar.gz" "$fixture/unsafe/extracted" '链接测试' yes
grep -Fq '目录外部' "$fixture/failure-output"
[[ ! -e "$fixture/unsafe/extracted/escape-link" ]]

# A target wp-config symlink cannot escape the selected domain directory.
mkdir -p "$SITE_ROOT/escaped.example" "$fixture/outside-wordpress"
write_wp_config "$fixture/outside-wordpress/wp-config.php" escaped_db escaped_user escaped_password mysql
ln -s "$fixture/outside-wordpress/wp-config.php" "$SITE_ROOT/escaped.example/wp-config.php"
expect_failure validate_migration_target_scope escaped.example "$SITE_ROOT/escaped.example/wp-config.php"
grep -Fq '超出所选域名目录' "$fixture/failure-output"

# A snapshot manifest disguised with a normal filename is rejected.
mkdir -p "$fixture/disguised"
tar -xzf "$archive" -C "$fixture/disguised"
sed -i 's/"archive_type": "backup"/"archive_type": "snapshot"/' "$fixture/disguised/manifest.json"
disguised="$fixture/source.example_20261026_130000.tar.gz"
tar -czf "$disguised" -C "$fixture/disguised" .
expect_failure inspect_migration_archive "$disguised" "$fixture/disguised-package" "$fixture/disguised-site"
grep -Fq '不是 SiteBak 普通备份' "$fixture/failure-output"

rm -rf -- "$fixture/disguised" "$fixture/disguised-package" "$fixture/disguised-site"
mkdir -p "$fixture/disguised"
tar -xzf "$archive" -C "$fixture/disguised"
sed -i 's/"domain": "source.example"/"domain": "source.example", "domain": "evil.example"/' "$fixture/disguised/manifest.json"
duplicate_manifest="$fixture/source.example_20261026_140000.tar.gz"
tar -czf "$duplicate_manifest" -C "$fixture/disguised" .
expect_failure inspect_migration_archive "$duplicate_manifest" "$fixture/duplicate-package" "$fixture/duplicate-site"
grep -Fq 'domain 必须存在且只能出现一次' "$fixture/failure-output"

printf 'PASS: migration archive safety, strict target selection, root staging, empty DB and Nginx preflight\n'
