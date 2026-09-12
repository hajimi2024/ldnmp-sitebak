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
printf "<?php\ndefine('DB_NAME', 'fixture_db');\ndefine('DB_USER', 'fixture_user');\ndefine('DB_PASSWORD', 'fixture_password');\ndefine('DB_HOST', 'mysql');\n" > "$SITE_ROOT/example.com/wordpress/wp-config.php"
state() {
  printf '%s\n' "$1" > "$SITE_ROOT/example.com/wordpress/index.php"
  printf "SELECT '%s';\n" "$1" > "$fixture/db-state"
  printf '# %s\nserver_name example.com;\nssl_certificate %s/certs/example.com_cert.pem;\n' "$1" "$fixture" > "$fixture/conf/example.com.conf"
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
stamp=20260912_100100
restore_site "$backup" < <(printf 'yes\ny\n') > "$fixture/restore.log" 2>&1
assert_state A
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
printf 'PASS: complete snapshots, protected restore, rollback, legacy filtering, validation, menus and deletion\n'
