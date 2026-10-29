#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../sitebak.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
SITE_ROOT="$tmp/html"
mkdir -p "$SITE_ROOT"
mapfile -t sites < <(list_sites_array)
[[ ${#sites[@]} == 0 ]]
clear_screen() { :; }
pause() { :; }
show_sites > "$tmp/empty"
grep -q 'wp-config.php' "$tmp/empty"
mkdir -p "$SITE_ROOT/direct.example" "$SITE_ROOT/nested.example/wordpress" "$SITE_ROOT/static.example"
for config in "$SITE_ROOT/direct.example/wp-config.php" "$SITE_ROOT/nested.example/wordpress/wp-config.php"; do
  printf "<?php\ndefine('DB_NAME', 'fixture_db');\ndefine('DB_USER', 'fixture_user');\ndefine('DB_PASSWORD', 'fixture_password');\ndefine('DB_HOST', 'mysql');\n" > "$config"
done
mapfile -t sites < <(list_sites_array)
[[ ${#sites[@]} == 2 ]]
[[ ${sites[0]} == direct.example && ${sites[1]} == nested.example ]]
for domain in "${sites[@]}"; do
  read_db_config "$domain"
  [[ $DB_NAME == fixture_db && $DB_USER == fixture_user && $DB_HOST == mysql ]]
done
selected="$(select_domain < <(printf 'x\n1\n99\n2\n') 2> "$tmp/menu")"
[[ $selected == nested.example ]]
cp "$SITE_ROOT/direct.example/wp-config.php" "$SITE_ROOT/nested.example/wp-config.php"
if find_wp_config "$SITE_ROOT/nested.example"; then exit 1; fi
SITE_ROOT="$tmp/missing"
mapfile -t sites < <(list_sites_array)
[[ ${#sites[@]} == 0 ]]
for columns in 80 30; do
  COLUMNS="$columns" header > "$tmp/header-$columns"
done
python3 - "$tmp" <<'PY'
import pathlib, re, sys, unicodedata
banner = r''' _      ____   _   _   __  __   ____
| |    |  _ \ | \ | | |  \/  | |  _ \
| |    | | | ||  \| | | |\/| | | |_) |
| |___ | |_| || |\  | | |  | | |  __/
|_____||____/ |_| \_| |_|  |_| |_|'''.splitlines()
for columns, expected in [(80, banner + ['-' * 38, '        单站备份恢复工具', '-' * 38]),
                          (30, ['LDNMP', '-' * 16, '单站备份恢复工具', '-' * 16])]:
    output = pathlib.Path(sys.argv[1], f'header-{columns}').read_text()
    lines = re.sub(r'\x1b\[[0-9;]*m', '', output).lstrip('\n').splitlines()
    assert lines[:len(expected)] == expected, lines
    widths = [sum(2 if unicodedata.east_asian_width(c) in 'WF' else 1 for c in line)
              for line in lines[:len(expected)]]
    assert max(widths) <= columns, widths
PY
# “列出 WordPress 站点”展示全部站点；零表站点在域名后标注空站点，并按创建时间从新到旧排列。
SITE_ROOT="$tmp/list-sites"
mkdir -p "$SITE_ROOT/older-empty.example" "$SITE_ROOT/nonempty.example"
write_fixture_config() {
  printf '%s\n' '<?php' "define('DB_NAME', '$2');" "define('DB_USER', 'fixture_user');" "define('DB_PASSWORD', 'fixture_password');" "define('DB_HOST', 'mysql');" > "$SITE_ROOT/$1/wp-config.php"
}
write_fixture_config older-empty.example empty_db
write_fixture_config nonempty.example nonempty_db
sleep 1
mkdir -p "$SITE_ROOT/newer-empty.example"
write_fixture_config newer-empty.example empty_db
prepare_db_client() { :; }
run_mysql() {
  if [[ " $* " == *' nonempty_db '* ]]; then
    printf '%s\n' wp_options
  fi
}
show_sites > "$tmp/empty-sites"
grep -Fq '1. newer-empty.example（空站点）' "$tmp/empty-sites"
grep -Fq '2. nonempty.example' "$tmp/empty-sites"
grep -Fq '3. older-empty.example（空站点）' "$tmp/empty-sites"
printf 'PASS: discovery, empty state, DB config, menu output, ambiguous config and approved Banner\n'
