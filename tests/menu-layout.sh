#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../sitebak.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT

COLUMNS=80 render_main_menu > "$fixture/main-wide"
COLUMNS=80 render_snapshot_menu > "$fixture/snapshots-wide"
COLUMNS=80 render_migration_menu > "$fixture/migration-wide"
COLUMNS=57 render_main_menu > "$fixture/main-narrow"
mkdir -p "$fixture/html/example.com" "$fixture/html/second.example" "$fixture/backups"
touch "$fixture/html/example.com/wp-config.php" "$fixture/html/second.example/wp-config.php"
(
  set +e
  SITE_ROOT="$fixture/html"
  header() { :; }
  select_domain '请选择站点' < <(printf '0\n')
) > /dev/null 2> "$fixture/domain-selection" || true
(
  set +e
  SITE_ROOT="$fixture/html"
  header() { :; }
  select_domain '请选择要恢复的站点' '适用于在当前服务器恢复已有站点的普通备份。' < <(printf '0\n')
) > /dev/null 2> "$fixture/restore-domain-selection" || true
(
  set +e
  SITE_ROOT="$fixture/html"
  header() { :; }
  site_database_is_empty() { return 0; }
  select_existing_domain '请选择目标站点' < <(printf '0\n')
) > /dev/null 2> "$fixture/target-selection" || true
(
  set +e
  BACKUP_DIR="$fixture/backups"
  header() { :; }
  select_backup example.com backup < <(printf '0\n')
) > /dev/null 2> "$fixture/backup-selection" || true
return_to_menu < <(printf '0\n') > "$fixture/return-menu"
return_to_menu wide < <(printf '0\n') > "$fixture/return-menu-wide"

# Exercise the real menu dispatch without running backup, restore or deletion.
(
  trap - EXIT
  need_root() { :; }
  header() { :; }
  run_menu_action() { "$@"; }
  show_sites() { printf '\nACTION:sites\n'; }
  backup_menu() { printf '\nACTION:backup\n'; }
  show_backups() { [[ ${1:-} == backup ]]; printf '\nACTION:list-backups\n'; }
  restore_menu() { printf '\nACTION:restore\n'; }
  snapshots_menu() { printf '\nACTION:snapshots\n'; }
  delete_backup_menu() { [[ ${1:-} == backup ]]; printf '\nACTION:delete\n'; }
  update_and_reload() { printf '\nACTION:update\n'; }
  migration_menu() { printf '\nACTION:migration\n'; }
  main_menu < <(printf '%s\n' 1 2 3 4 5 6 7 8 0)
) > "$fixture/routing"

python3 - "$fixture" <<'PY'
import pathlib
import re
import sys
import unicodedata

root = pathlib.Path(sys.argv[1])

def read_plain(name):
    return re.sub(r'\x1b\[[0-9;]*m', '', (root / name).read_text())

def width(text):
    return sum(2 if unicodedata.east_asian_width(c) in 'WF' else 1 for c in text)

def assert_layout(name, pairs, separator_count=3):
    lines = read_plain(name).splitlines()
    assert lines.count('-' * 24) == separator_count, lines
    for index, (left, right) in enumerate(pairs):
        row_index = next(index for index, line in enumerate(lines) if line.startswith(left))
        line = lines[row_index]
        assert line.endswith(right), line
        assert width(line[:line.index(right)]) == 40, (line, width(line[:line.index(right)]))
        if index < len(pairs) - 1:
            assert lines[row_index + 1] == '', lines

assert_layout('main-wide', [
    ('1.  列出 WordPress 站点', '2.  备份单个站点'),
    ('3.  查看备份文件', '4.  恢复单个站点'),
    ('5.  快照管理', '6.  删除旧备份'),
], separator_count=3)
assert_layout('snapshots-wide', [
    ('1.  创建完整快照', '2.  查看快照'),
    ('3.  恢复完整快照', '4.  删除快照'),
])

main = read_plain('main-wide').splitlines()
assert main.count('-' * 24) == 3, main
operation_index = main.index('    操作')
assert main[operation_index:operation_index + 3] == ['    操作', '-' * 51, '1.  列出 WordPress 站点                 2.  备份单个站点'], main
site_import_index = main.index('8.  站点导入   📁')
assert main[site_import_index - 1:site_import_index + 2] == ['-' * 24, '8.  站点导入   📁', '-' * 24], main
assert main[-3:] == ['-' * 24, '0.  退出', '-' * 24], main

assert_layout('migration-wide', [
    ('1.  导入并更换域名', '2.  导入并保留域名'),
], separator_count=2)
migration = read_plain('migration-wide').splitlines()
title_index = migration.index('    站点导入')
assert migration[title_index + 1] == '-' * 51, migration
third_index = migration.index('3.  查看最近一次操作日志')
assert migration[third_index - 1] == '', migration
assert migration[third_index + 1:third_index + 4] == ['-' * 24, '0.  返回上一级', '-' * 24], migration

narrow = read_plain('main-narrow')
assert '1.  列出 WordPress 站点\n2.  备份单个站点' in narrow
assert '2.  备份单个站点\n\n3.  查看备份文件' in narrow
assert '7.  更新脚本   ♻️\n' in narrow
assert ('操作\n' + '-' * 51 + '\n1.  列出 WordPress 站点' in narrow), narrow
assert ('7.  更新脚本   ♻️\n\n' + '-' * 24 + '\n8.  站点导入   📁\n' +
        '-' * 24 + '\n0.  退出') in narrow
assert '                 2.  备份单个站点' not in narrow

actions = [line[len('ACTION:'):] for line in
           (root / 'routing').read_text().splitlines() if line.startswith('ACTION:')]
assert actions == ['sites', 'backup', 'list-backups', 'restore', 'snapshots', 'delete', 'update', 'migration'], actions

for name, title, body in [
    ('domain-selection', '请选择站点：', '1. example.com'),
    ('target-selection', '请选择目标站点：', '1. example.com'),
]:
    lines = read_plain(name).splitlines()
    title_index = lines.index(title)
    assert lines[title_index + 1] == '-' * 24, lines
    body_index = lines.index(body)
    assert lines[body_index + 1] == '', lines
    assert lines[body_index + 2] == '2. second.example', lines
    assert lines[body_index + 3:body_index + 6] == [
        '-' * 24, '0.  返回上一级', '-' * 24], lines

restore_lines = read_plain('restore-domain-selection').splitlines()
intro_index = restore_lines.index('适用于在当前服务器恢复已有站点的普通备份。')
title_index = restore_lines.index('请选择要恢复的站点：')
assert restore_lines[intro_index - 1] == '', restore_lines
assert restore_lines[intro_index + 1] == '', restore_lines
assert restore_lines[intro_index + 2] == '-' * 24, restore_lines
assert title_index == intro_index + 3, restore_lines

backup_selection = read_plain('backup-selection')
assert ('example.com 可用普通备份：\n' + '-' * 24 + '\n' in backup_selection), backup_selection
assert ('\n' + '-' * 24 + '\n0.  返回上一级\n' + '-' * 24 + '\n请选择：' in backup_selection), backup_selection
return_menu = read_plain('return-menu')
assert ('\n' + '-' * 24 + '\n0.  返回上一级\n' + '-' * 24 + '\n请输入：') in return_menu, return_menu
return_menu_wide = read_plain('return-menu-wide')
assert ('\n' + '-' * 51 + '\n0.  返回上一级\n' + '-' * 51 + '\n请输入：') in return_menu_wide, return_menu_wide
PY

printf 'PASS: fixed menu order, action routing, two-column layout and narrow-terminal fallback\n'
