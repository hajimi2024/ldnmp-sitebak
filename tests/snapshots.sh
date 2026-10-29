#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../sitebak.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
SITE_ROOT="$fixture/html"
BACKUP_DIR="$fixture/backups"
NGINX_CONF_DIRS=("$fixture/conf")
CERT_DIRS=("$fixture/certs")
stamp=20260912_100000
dump_failure=0
clear_screen() { :; }
need_root() { :; }
reload_services() { :; }
date() {
  if [[ ${1:-} == +%Y%m%d_%H%M%S ]]; then printf '%s\n' "$stamp"; else command date "$@"; fi
}
prepare_db_client() { :; }
run_mysqldump() { cat "$fixture/db-state"; return "$dump_failure"; }
run_mysql() {
  if [[ " $* " == *' -e '* ]]; then return 0; fi
  cat > "$fixture/db-state"
}
mkdir -p "$SITE_ROOT/example.com/wordpress" "$BACKUP_DIR" "$fixture/conf" "$fixture/certs"
printf "<?php\ndefine('DB_NAME', 'fixture_db');\ndefine('DB_USER', 'fixture_user');\ndefine('DB_PASSWORD', 'fixture_password');\ndefine('DB_HOST', 'mysql');\n\$table_prefix = 'wp_';\n" > "$SITE_ROOT/example.com/wordpress/wp-config.php"
state() {
  printf '%s\n' "$1" > "$SITE_ROOT/example.com/wordpress/index.php"
  printf "SELECT '%s';\n" "$1" > "$fixture/db-state"
  printf '# %s\nserver {\n  listen 443 ssl;\n  server_name example.com;\n  ssl_certificate %s/certs/example.com_cert.pem;\n  ssl_certificate_key %s/certs/example.com_key.pem;\n}\n' "$1" "$fixture" "$fixture" > "$fixture/conf/example.com.conf"
  printf '%s\n' "$1" > "$fixture/certs/example.com_cert.pem"
}
assert_state() {
  [[ $(< "$SITE_ROOT/example.com/wordpress/index.php") == "$1" ]]
  [[ $(< "$fixture/db-state") == "SELECT '$1';" ]]
  grep -qx "# $1" "$fixture/conf/example.com.conf"
  [[ $(< "$fixture/certs/example.com_cert.pem") == "$1" ]]
}
expect_failure() {
  local status
  set +e
  (set -Eeuo pipefail; "$@") > "$fixture/failure.log" 2>&1
  status=$?
  set -e
  [[ $status != 0 ]]
}
state A
backup_site example.com > "$fixture/backup.log" 2>&1
backup="$BACKUP_DIR/example.com_${stamp}.tar.gz"
state B
expect_failure restore_site "$backup" < <(printf 'YES\n')
assert_state B
expect_failure restore_site "$backup" '' other.example
assert_state B
stamp=20260912_100100
restore_site "$backup" < <(printf 'yes\ny\n') > "$fixture/restore.log" 2>&1
assert_state A
grep -Fq '操作类型：站点还原' "$fixture/restore.log"
grep -Fq '源站域名：example.com' "$fixture/restore.log"
grep -Fq '目标域名：example.com' "$fixture/restore.log"
grep -Fq '目标网址：https://example.com' "$fixture/restore.log"
grep -Fq '目标 WordPress Root：' "$fixture/restore.log"
grep -Fq '目标数据库：fixture_db' "$fixture/restore.log"
grep -Fq '🚨 警告：即将写入目标网站文件及数据库。' "$fixture/restore.log"
snapshot="$BACKUP_DIR/example.com_snapshot_${stamp}.tar.gz"
[[ -f "$snapshot" ]]
mkdir "$fixture/payload"
tar -xzf "$snapshot" -C "$fixture/payload"
[[ $(extract_manifest_value "$fixture/payload/manifest.json" archive_type) == snapshot ]]
[[ $(extract_manifest_value "$fixture/payload/manifest.json" snapshot_reason) == before_restore ]]
for component in files/site-files.tar.gz database/fixture_db.sql.gz nginx/nginx-files.tar.gz certs/cert-items.tar.gz; do
  [[ -s "$fixture/payload/$component" ]]
done
gzip -dc "$fixture/payload/database/fixture_db.sql.gz" | grep -q "SELECT 'B';"
[[ $(list_backups_for_domain example.com) == "$backup" ]]
[[ $(list_backups_for_domain example.com snapshot) == "$snapshot" ]]

# A snapshot restore can protect the current state without recursive restores.
stamp=20260912_100200
restore_site "$snapshot" snapshot < <(printf 'yes\n\n') > "$fixture/rollback.log" 2>&1
assert_state B
mapfile -t snapshots < <(list_backups_for_domain example.com snapshot)
[[ ${#snapshots[@]} == 2 ]]
protective="$BACKUP_DIR/example.com_snapshot_${stamp}.tar.gz"
restore_site "$protective" snapshot < <(printf 'yes\nn\n') > "$fixture/second-rollback.log" 2>&1
assert_state A

state C
stamp=20260912_100300
dump_failure=2
expect_failure restore_site "$backup" < <(printf 'yes\ny\n')
assert_state C
[[ ! -e "$BACKUP_DIR/example.com_snapshot_${stamp}.tar.gz" ]]
dump_failure=0
mv "$fixture/certs/example.com_cert.pem" "$fixture/saved-cert"
expect_failure restore_site "$backup" < <(printf 'yes\ny\n')
grep -q '未找到证书' "$fixture/failure.log"
mv "$fixture/saved-cert" "$fixture/certs/example.com_cert.pem"
assert_state C
[[ ! -e "$BACKUP_DIR/example.com_snapshot_${stamp}.tar.gz" ]]

# Declared payloads must exist before changing the live site.
rm "$fixture/payload/certs/cert-items.tar.gz"
broken="$BACKUP_DIR/example.com_snapshot_20260912_100400.tar.gz"
tar -czf "$broken" -C "$fixture/payload" .
expect_failure restore_site "$broken" snapshot < <(printf 'yes\nn\n')
assert_state C
rm "$broken"

legacy="$BACKUP_DIR/example.com_before_restore_20260912_090000.tar.gz"
tar -czf "$legacy" -C "$SITE_ROOT/example.com" .
expect_failure restore_site "$legacy"
assert_state C
[[ $(list_backups_for_domain example.com snapshot | wc -l) == 2 ]]
[[ $(list_backups_for_domain example.com snapshots | wc -l) == 3 ]]
show_backups snapshots > "$fixture/list.log"
grep -q '旧版文件快照' "$fixture/list.log"
python3 - "$fixture/list.log" <<'PY'
import re, sys, unicodedata

def display_width(text):
    width = 0
    for char in text:
        width += 2 if unicodedata.east_asian_width(char) in ('W', 'F') else 1
    return width

columns = []
for raw in open(sys.argv[1], encoding='utf-8'):
    line = re.sub(r'\x1b\[[0-9;]*m', '', raw.rstrip('\n'))
    if line.startswith('['):
        match = re.search(r'  +(\S+)  +(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})$', line)
        if match:
            columns.append((display_width(line[:match.start(1)]), display_width(line[:match.start(2)])))
assert len(columns) >= 2, columns
assert len({column[0] for column in columns}) == 1, columns
assert len({column[1] for column in columns}) == 1, columns
PY

# Multiple versions, malformed numbers, and warnings must not pollute selection.
selected="$(select_backup example.com snapshot < <(printf 'x\n999999999999999999999\n01\n') 2> "$fixture/selection.log")"
[[ -f "$selected" && $(archive_kind "$selected") == snapshot ]]
! grep -q '_before_restore_' "$fixture/selection.log"
before="$(sha256sum "$snapshot")"
stamp=20260912_100100
expect_failure backup_site example.com snapshot
[[ $(sha256sum "$snapshot") == "$before" ]]

# Restoring from the menu must work even when the site directory is gone.
mv "$SITE_ROOT/example.com" "$fixture/saved-site"
restore_snapshot_menu < <(printf '1\nyes\n') > "$fixture/missing-site.log" 2>&1
[[ -f "$SITE_ROOT/example.com/wordpress/wp-config.php" ]]
snapshots_menu < <(printf 'invalid\n2\n0\n0\n') > "$fixture/menu.log"
grep -q '无效的选择' "$fixture/menu.log"
grep -q '完整快照' "$fixture/menu.log"
delete_backup_menu snapshots < <(printf '1\nno\n') > "$fixture/cancel-delete.log" 2>&1
[[ $(list_backups_for_domain example.com snapshots | wc -l) == 3 ]]
delete_backup_menu snapshots < <(printf '1\nyes\n') > "$fixture/delete.log" 2>&1
[[ $(list_backups_for_domain example.com snapshots | wc -l) == 2 ]]
[[ -z $(find "$BACKUP_DIR" -name '.sitebak.*' -print -quit) ]]

# A target configuration changed after yes must stop before file or database writes.
state C
TAMPER_TARGET_CONFIG_ON_CONFIRM=yes
ui_read() {
  local variable="$1" output_fd="${2:-1}" status
  if IFS= read -r "$variable"; then status=0; else status=$?; fi
  printf '%s' "$RESET" >&"$output_fd"
  if [[ "$variable" == confirm && "$TAMPER_TARGET_CONFIG_ON_CONFIRM" == yes ]]; then
    sed -i "s/define('DB_NAME', 'fixture_db')/define('DB_NAME', 'changed_fixture_db')/" "$SITE_ROOT/example.com/wordpress/wp-config.php"
  fi
  return "$status"
}
expect_failure restore_site "$backup" < <(printf 'yes\n')
grep -Fq '目标身份或操作范围在预检期间发生变化' "$fixture/failure.log"
[[ $(< "$SITE_ROOT/example.com/wordpress/index.php") == C ]]
printf 'PASS: complete snapshots, protected restore, rollback, legacy filtering, validation, menus and deletion\n'
