#!/usr/bin/env bash
set -Eeuo pipefail
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/html/example.com" "$fixture/backups"
touch "$fixture/html/example.com/wp-config.php" "$fixture/backups/example.com_20260914_100000.tar.gz"

python3 - "$(dirname "$0")/../sitebak.sh" "$fixture" <<'PY'
import errno
import os
import pty
import re
import subprocess
import sys
import unicodedata

source, fixture = sys.argv[1:]
script = r'''
source "$1"
clear_screen() { :; }
header
render_main_menu
render_snapshot_menu
info 'Reading files'
ok 'Completed'
warn 'Overwrite confirmation'
err 'Failed'
ui_prompt '请输入你的选择：'
printf '\n'
ui_prompt '请输入 yes 确认删除：' "$YELLOW"
printf '\n'
site="$(select_domain < <(printf '1\n'))"
printf '\nSELECTED_SITE:%s\n' "$site"
archive="$(select_backup example.com backup < <(printf '1\n'))"
printf '\nSELECTED_ARCHIVE:%s\n' "$archive"
'''

def run(terminal=False, **changes):
    env = os.environ.copy()
    env.pop('NO_COLOR', None)
    env.update(TERM='xterm-256color', COLUMNS='80',
               SITEBAK_SITE_ROOT=fixture + '/html', SITEBAK_BACKUP_DIR=fixture + '/backups')
    env.update(changes)
    command = ['bash', '-c', script, 'color-test', source]
    if not terminal:
        return subprocess.check_output(command, env=env, stderr=subprocess.STDOUT).decode()
    master, slave = pty.openpty()
    process = subprocess.Popen(command, env=env, stdin=subprocess.DEVNULL, stdout=slave, stderr=slave)
    os.close(slave)
    chunks = []
    try:
        while True:
            try:
                chunk = os.read(master, 65536)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            chunks.append(chunk)
    finally:
        os.close(master)
    assert process.wait() == 0
    return b''.join(chunks).decode().replace('\r\n', '\n')

ansi = re.compile(r'\x1b\[[0-9;]*m')
plain = run()
colored = run(terminal=True)
assert '\x1b' not in plain
assert ansi.sub('', colored).rstrip('\n') == plain.rstrip('\n')
for number in range(8):
    assert '\x1b[1;33m%d.\x1b[0;96m' % number in colored
for label in ['版本：', '站点目录：', '备份目录：']:
    assert '\x1b[0;32m' + label + '\x1b[0;92m' in colored
for value in ['0.2.7', fixture + '/html', fixture + '/backups']:
    assert '\x1b[0;92m' + value + '\x1b[0m' in colored
for code, message in [('96', '[INFO] Reading files'), ('32', '[OK] Completed'),
                      ('33', '[WARN] Overwrite confirmation'), ('31', '[ERROR] Failed')]:
    assert '\x1b[0;' + code + 'm' + message + '\x1b[0m' in colored
divider_count = colored.count('\x1b[0;36m' + '-' * 38 + '\x1b[0m\n')
assert divider_count >= 2 and divider_count % 2 == 0
assert '\x1b[0;33m请输入 yes 确认删除：\x1b[0m' in colored
assert run(terminal=True, NO_COLOR='1') == plain
assert run(terminal=True, TERM='dumb') == plain
assert '\nSELECTED_SITE:example.com\n' in colored
assert '\nSELECTED_ARCHIVE:' + fixture + '/backups/example.com_20260914_100000.tar.gz\n' in colored

width = lambda text: sum(2 if unicodedata.east_asian_width(c) in 'WF' else 1 for c in text)
lines = ansi.sub('', colored).splitlines()
for right in ['2.  备份单个站点', '4.  恢复单个站点', '6.  删除旧备份']:
    row = next(line for line in lines if right in line)
    assert width(row[:row.index(right)]) == 40, row
narrow = ansi.sub('', run(terminal=True, COLUMNS='32'))
assert '\nLDNMP\n----------------\n单站备份恢复工具\n----------------\n' in narrow
assert '1.  列出 WordPress 站点\n2.  备份单个站点' in narrow
assert '2.  备份单个站点\n\n3.  查看备份文件' in narrow
PY
printf 'PASS: terminal colors, resets, plain-output fallback, column alignment and clean selection values\n'
