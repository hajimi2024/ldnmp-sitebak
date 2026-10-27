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
fixture_server_identity='target-vps / machine:0123456789abcdef'

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
get_target_server_display() { printf '%s' 'target-vps（2C / 4G）'; }
prepare_wp_cli_environment() { migration_log INFO 'MOCK WP-CLI 环境检查通过。'; }
finalize_wordpress_migration() { migration_log INFO "MOCK WordPress 收尾：$1 / $2 / $3"; }
run_mysqldump() { printf '%s\n' 'CREATE TABLE `wp_options` (`option_id` bigint);'; }
run_mysql() {
  printf '%s' "$db_tables"
}

write_wp_config() {
  local file="$1" db="$2" user="$3" password="$4" host="$5" prefix="${6:-wp_}"
  mkdir -p "$(dirname "$file")"
  printf '%s\n' \
    '<?php' \
    "define('DB_NAME', '$db');" \
    "define('DB_USER', '$user');" \
    "define('DB_PASSWORD', '$password');" \
    "define('DB_HOST', '$host');" \
    "\$table_prefix = '$prefix';" > "$file"
}

create_source_backup() {
  local domain="$1" layout="$2" db="$3"
  local root="$SITE_ROOT/$domain"
  if [[ "$layout" == nested ]]; then root="$root/wordpress"; fi
  write_wp_config "$root/wp-config.php" "$db" source_user 'source secret' mysql source_
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
  write_wp_config "$root/wp-config.php" "$db" target_user 'target secret with spaces' mysql target_
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
create_target_site zzz.example nested zzz_db
printf 'server { listen 80; server_name zzz.example; }\n' > "${NGINX_CONF_DIRS[0]}/zzz.example.conf"
cp -a "$SITE_ROOT/zzz.example" "$fixture/unrelated-before"

# Inspect and stage independently: source direct Root maps only into the target nested Root.
inspect_root="$fixture/inspect"
inspect_migration_archive "$archive" "$inspect_root/package" "$inspect_root/source-site"
[[ "$MIGRATION_SOURCE_DOMAIN" == source.example ]]
[[ "$MIGRATION_SOURCE_DB" == source_db ]]
[[ "$MIGRATION_SOURCE_TABLE_PREFIX" == source_ ]]
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
[[ $(parse_wp_table_prefix "$inspect_root/staged/wp-config.php") == source_ ]]
[[ ! -e "$inspect_root/staged/outside.keep" ]]

# Target selection accepts a listed numeric choice or its exact domain, never an arbitrary domain.
selected="$(select_existing_domain < <(printf '%s\n' arbitrary.example 1) 2> "$fixture/strict-selection")"
[[ "$selected" == target.example ]]
grep -Fq '目标域名不在当前站点列表中' "$fixture/strict-selection"
selected="$(select_existing_domain < <(printf '%s\n' target.example) 2> "$fixture/domain-selection")"
[[ "$selected" == target.example ]]

# Numeric target selection requires exact full-domain confirmation; direct domain input does not.
if ! migration_preflight change-domain < <(printf '%s\n' 1 1 target.example no) > "$fixture/numeric-target-output" 2>&1; then
  cat "$fixture/numeric-target-output" >&2
  exit 1
fi
grep -Fq '已选择目标站点 target.example，请输入完整域名确认' "$fixture/numeric-target-output"
grep -Fq '✅ 已验证目标站点 target.example 为空站点。' "$fixture/numeric-target-output"

if ! migration_preflight change-domain < <(printf '%s\n' 1 target.example no) > "$fixture/domain-target-output" 2>&1; then
  cat "$fixture/domain-target-output" >&2
  exit 1
fi
! grep -Fq '已选择目标站点 target.example，请输入完整域名确认' "$fixture/domain-target-output"
grep -Fq '✅ 已验证目标站点 target.example 为空站点。' "$fixture/domain-target-output"

# A cancelled stage-three confirmation preserves phase-two's zero-write behavior.
if ! migration_preflight change-domain < <(printf '%s\n' 1 1 target.example no) > "$fixture/change-output" 2>&1; then
  cat "$fixture/change-output" >&2
  exit 1
fi
grep -Fq '已取消操作' "$fixture/change-output"
grep -Fq 'https://target.example' "$fixture/change-output"
grep -Fq '目标服务器：target-vps（2C / 4G）' "$fixture/change-output"
! grep -Fq 'machine:0123456789abcdef' "$fixture/change-output"
! grep -Fq 'fixture-user' "$fixture/change-output"
grep -Fq '操作类型：导入并更换域名' "$fixture/change-output"
diff -r "$fixture/target-before" "$SITE_ROOT/target.example"
diff -r "$fixture/unrelated-before" "$SITE_ROOT/zzz.example"
[[ -z "$(find "$MIGRATION_TMP_ROOT" -mindepth 1 -print -quit)" ]]
latest_log="$(find "$MIGRATION_LOG_DIR" -type f -name 'migration_change-domain_*.log' -print -quit)"
[[ -f "$latest_log" && $(stat -c '%a' "$latest_log") == 600 ]]
grep -Fq '源域名=source.example' "$latest_log"
grep -Fq '目标域名=target.example' "$latest_log"
! grep -Fq 'target secret with spaces' "$latest_log"

# The composite target identity must fail closed when the server or target config changes.
read_migration_db_config_file "$target_config"
prepare_db_client mysql
target_scheme="$(detect_target_scheme target.example)"
capture_migration_target_identity target.example "$target_config" "$target_scheme" source_
locked_identity="$MIGRATION_TARGET_IDENTITY"

fixture_server_identity='old-production-vps / machine:fedcba9876543210'
expect_failure revalidate_migration_target_identity target.example "$locked_identity" source_
grep -Fq '目标身份或操作范围在预检期间发生变化' "$fixture/failure-output"
fixture_server_identity='target-vps / machine:0123456789abcdef'

cp "$target_config" "$fixture/target-config-before-identity-test"
sed -i "s/define('DB_NAME', 'target_db')/define('DB_NAME', 'changed_target_db')/" "$target_config"
expect_failure revalidate_migration_target_identity target.example "$locked_identity" source_
grep -Fq '目标身份或操作范围在预检期间发生变化' "$fixture/failure-output"
cp "$fixture/target-config-before-identity-test" "$target_config"

printf '\n# identity change\n' >> "${NGINX_CONF_DIRS[0]}/target.example.conf"
expect_failure revalidate_migration_target_identity target.example "$locked_identity" source_
grep -Fq '目标身份或操作范围在预检期间发生变化' "$fixture/failure-output"
write_https_nginx target.example
diff -r "$fixture/target-before" "$SITE_ROOT/target.example"
diff -r "$fixture/unrelated-before" "$SITE_ROOT/zzz.example"

# A non-empty target database must stop before any target file change.
db_tables='wp_options'
expect_failure migration_preflight change-domain < <(printf '%s\n' 1 1 target.example)
if ! grep -Fq '目标数据库不是空库' "$fixture/failure-output"; then
  cat "$fixture/failure-output" >&2
  exit 1
fi
diff -r "$fixture/target-before" "$SITE_ROOT/target.example"
diff -r "$fixture/unrelated-before" "$SITE_ROOT/zzz.example"
db_tables=''

# Preserve-domain mode requires the manifest and selected target domain to match.
expect_failure migration_preflight keep-domain < <(printf '%s\n' 1 1 target.example)
grep -Fq '要求源域名与目标域名完全一致' "$fixture/failure-output"

# Preserve-domain preflight also succeeds when the uploaded backup and target match.
fixture_stamp=20261026_120100
create_source_backup same.example nested same_db
same_archive="$BACKUP_DIR/same.example_${fixture_stamp}.tar.gz"
create_target_site same.example direct same_target_db
printf 'server { listen 80; server_name same.example; }\n' > "${NGINX_CONF_DIRS[0]}/same.example.conf"
cp -a "$SITE_ROOT/same.example" "$fixture/same-before"
mapfile -t backup_options < <(list_backups_for_domain '' backup)
for i in "${!backup_options[@]}"; do
  [[ "${backup_options[$i]}" == "$same_archive" ]] && same_choice=$((i + 1))
done
if ! migration_preflight keep-domain < <(printf '%s\n' "$same_choice" 1 same.example no) > "$fixture/keep-output" 2>&1; then
  cat "$fixture/keep-output" >&2
  exit 1
fi
if ! grep -Fq '源站域名：same.example' "$fixture/keep-output" || ! grep -Fq '目标域名：same.example' "$fixture/keep-output" || ! grep -Fq 'http://same.example' "$fixture/keep-output"; then
  cat "$fixture/keep-output" >&2
  exit 1
fi
diff -r "$fixture/same-before" "$SITE_ROOT/same.example"
diff -r "$fixture/unrelated-before" "$SITE_ROOT/zzz.example"

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
cat > "${NGINX_CONF_DIRS[0]}/similar.example.conf" <<'EOF'
server {
  listen 443 ssl;
  server_name similar.example.evil;
  ssl_certificate /tmp/evil.crt;
  ssl_certificate_key /tmp/evil.key;
}
server { listen 80; server_name similar.example; }
EOF
[[ $(detect_target_scheme similar.example) == http ]]
cat > "${NGINX_CONF_DIRS[0]}/split.example.conf" <<'EOF'
server {
  listen 443 ssl;
  server_name split.example;
}
server {
  listen 80;
  server_name split.example;
  ssl_certificate /tmp/split.crt;
  ssl_certificate_key /tmp/split.key;
}
EOF
expect_failure detect_target_scheme split.example
grep -Fq 'HTTPS 配置不完整' "$fixture/failure-output"

cat > "${NGINX_CONF_DIRS[0]}/complete.example.conf" <<'EOF'
server { listen 80; server_name complete.example; }
server {
  listen 443 ssl;
  server_name complete.example;
  ssl_certificate /tmp/complete.crt;
  ssl_certificate_key /tmp/complete.key;
}
EOF
[[ $(detect_target_scheme complete.example) == https ]]
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

printf 'duplicate\n' > "$fixture/unsafe/source/duplicate"
tar -czf "$fixture/duplicate-member.tar.gz" -C "$fixture/unsafe/source" duplicate duplicate
expect_failure extract_safe_tar "$fixture/duplicate-member.tar.gz" "$fixture/unsafe/duplicate-extracted" '重复成员测试' yes
grep -Fq '重复成员路径' "$fixture/failure-output"
[[ ! -e "$fixture/unsafe/duplicate-extracted" ]]

mkdir -p "$fixture/unsafe/source/safe"
printf 'payload\n' > "$fixture/unsafe/source/safe/payload"
ln -s safe "$fixture/unsafe/source/link-parent"
tar -czf "$fixture/link-parent.tar.gz" -C "$fixture/unsafe/source" link-parent link-parent/payload
expect_failure extract_safe_tar "$fixture/link-parent.tar.gz" "$fixture/unsafe/link-parent-extracted" '链接父路径测试' yes
grep -Fq '经由链接或文件父路径写入' "$fixture/failure-output"
[[ ! -e "$fixture/unsafe/link-parent-extracted" ]]

ln -s second-link "$fixture/unsafe/source/first-link"
ln -s ../../outside "$fixture/unsafe/source/second-link"
tar -czf "$fixture/link-chain.tar.gz" -C "$fixture/unsafe/source" first-link second-link
expect_failure extract_safe_tar "$fixture/link-chain.tar.gz" "$fixture/unsafe/link-chain-extracted" '符号链接链测试' yes
grep -Fq '目录外部' "$fixture/failure-output"
[[ ! -e "$fixture/unsafe/link-chain-extracted" ]]

ln -s safe "$fixture/unsafe/source/overwritten"
tar -cf "$fixture/overwritten.tar" -C "$fixture/unsafe/source" overwritten
rm -f "$fixture/unsafe/source/overwritten"
printf 'later regular file\n' > "$fixture/unsafe/source/overwritten"
tar -rf "$fixture/overwritten.tar" -C "$fixture/unsafe/source" overwritten
gzip -c "$fixture/overwritten.tar" > "$fixture/overwritten.tar.gz"
expect_failure extract_safe_tar "$fixture/overwritten.tar.gz" "$fixture/unsafe/overwritten-extracted" '链接覆盖测试' yes
grep -Fq '重复成员路径' "$fixture/failure-output"
[[ ! -e "$fixture/unsafe/overwritten-extracted" ]]

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

diff -r "$fixture/unrelated-before" "$SITE_ROOT/zzz.example"

printf 'PASS: migration archive safety, composite target identity, strict scope, empty DB and per-block Nginx preflight\n'
