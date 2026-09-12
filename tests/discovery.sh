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
for columns, expected in [(80, 46), (30, 24)]:
    lines = pathlib.Path(sys.argv[1], f'header-{columns}').read_text().splitlines()[:3]
    lines = [re.sub(r'\x1b\[[0-9;]*m', '', line) for line in lines]
    widths = [sum(2 if unicodedata.east_asian_width(c) in 'WF' else 1 for c in line) for line in lines]
    assert widths == [expected] * 3, (lines, widths)
    assert lines[1].startswith('|') and lines[1].endswith('|')
PY
printf 'PASS: discovery, empty state, DB config, menu output, ambiguous config, header widths\n'
