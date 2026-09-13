#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../sitebak.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT

COLUMNS=80 render_main_menu > "$fixture/main-wide"
COLUMNS=80 render_snapshot_menu > "$fixture/snapshots-wide"
COLUMNS=57 render_main_menu > "$fixture/main-narrow"

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
    ('3.  恢复单个站点', '4.  查看备份文件'),
    ('5.  删除旧备份', '6.  更新脚本'),
])
assert_layout('snapshots-wide', [
    ('1.  创建完整快照', '2.  查看快照'),
    ('3.  恢复完整快照', '4.  删除快照'),
])

narrow = (root / 'main-narrow').read_text()
assert '1.  列出 WordPress 站点\n2.  备份单个站点' in narrow
assert '2.  备份单个站点\n3.  恢复单个站点' in narrow
assert '                 2.  备份单个站点' not in narrow
PY

printf 'PASS: Kejilion-style fixed two-column layout and narrow-terminal fallback\n'
