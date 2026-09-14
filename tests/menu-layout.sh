#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../sitebak.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT

COLUMNS=80 render_main_menu > "$fixture/main-wide"
COLUMNS=80 render_snapshot_menu > "$fixture/snapshots-wide"
COLUMNS=57 render_main_menu > "$fixture/main-narrow"

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
  update_self() { printf '\nACTION:update\n'; }
  main_menu < <(printf '%s\n' 1 2 3 4 5 6 7 0)
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

def assert_layout(name, pairs):
    lines = read_plain(name).splitlines()
    assert lines.count('-' * 24) == 3, lines
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
])
assert_layout('snapshots-wide', [
    ('1.  创建完整快照', '2.  查看快照'),
    ('3.  恢复完整快照', '4.  删除快照'),
])

narrow = read_plain('main-narrow')
assert '1.  列出 WordPress 站点\n2.  备份单个站点' in narrow
assert '2.  备份单个站点\n\n3.  查看备份文件' in narrow
assert '7.  更新脚本\n' in narrow
assert '                 2.  备份单个站点' not in narrow

actions = [line[len('ACTION:'):] for line in
           (root / 'routing').read_text().splitlines() if line.startswith('ACTION:')]
assert actions == ['sites', 'backup', 'list-backups', 'restore', 'snapshots', 'delete', 'update'], actions
PY

printf 'PASS: fixed menu order, action routing, two-column layout and narrow-terminal fallback\n'
