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
  show_backups() { printf '\nACTION:list-backups\n'; }
  restore_menu() { printf '\nACTION:restore\n'; }
  snapshots_menu() { printf '\nACTION:snapshots\n'; }
  delete_backup_menu() { printf '\nACTION:delete\n'; }
  update_self() { printf '\nACTION:update\n'; }
  main_menu < <(printf '%s\n' 1 2 3 4 5 6 7 0)
) > "$fixture/routing"

python3 - "$fixture" <<'PY'
import pathlib
import sys
import unicodedata

root = pathlib.Path(sys.argv[1])

def width(text):
    return sum(2 if unicodedata.east_asian_width(c) in 'WF' else 1 for c in text)

def assert_layout(name, pairs):
    lines = (root / name).read_text().splitlines()
    assert lines.count('-' * 24) == 3, lines
    for left, right in pairs:
        line = next(line for line in lines if line.startswith(left))
        assert line.endswith(right), line
        assert width(line[:line.index(right)]) == 40, (line, width(line[:line.index(right)]))

assert_layout('main-wide', [
    ('1.  列出 WordPress 站点', '2.  备份单个站点'),
    ('3.  查看备份文件', '4.  恢复单个站点'),
    ('5.  快照管理', '6.  删除旧备份'),
])
assert_layout('snapshots-wide', [
    ('1.  创建完整快照', '2.  查看快照'),
    ('3.  恢复完整快照', '4.  删除快照'),
])

narrow = (root / 'main-narrow').read_text()
assert '1.  列出 WordPress 站点\n2.  备份单个站点' in narrow
assert '2.  备份单个站点\n3.  查看备份文件' in narrow
assert '7.  更新脚本\n' in narrow
assert '                 2.  备份单个站点' not in narrow

actions = [line[len('ACTION:'):] for line in
           (root / 'routing').read_text().splitlines() if line.startswith('ACTION:')]
assert actions == ['sites', 'backup', 'list-backups', 'restore', 'snapshots', 'delete', 'update'], actions
PY

printf 'PASS: fixed menu order, action routing, two-column layout and narrow-terminal fallback\n'
