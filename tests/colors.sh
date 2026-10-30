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
get_target_server_display() { printf '@test-vps 2c4g'; }
get_current_server_label() { printf '@test-vps 2c4g'; }
header
render_main_menu
render_snapshot_menu
render_migration_menu
info 'Reading files'
ok 'Completed'
warn 'Overwrite confirmation'
err 'Failed'
ui_prompt '请输入你的选择：'
ui_read prompt_choice < <(printf '7\n')
printf '\n'
 ui_confirm_prompt '请输入 yes 确认删除：'
ui_read prompt_confirm < <(printf 'yes\n')
printf '\n'
site_database_is_empty() { return 0; }
site="$(select_domain < <(printf '1\n'))"
printf '\nSELECTED_SITE:%s\n' "$site"
archive="$(select_backup example.com backup < <(printf '1\n'))"
printf '\nSELECTED_ARCHIVE:%s\n' "$archive"
confirm_target_operation change-domain old.example https://old.example new.example https://new.example server user /target/root target_db /backup.tar.gz < <(printf '\n') || :
confirm_numeric_target_domain new.example < <(printf 'new.example\n')
ui_green_input_prompt '请输入目标站点编号或域名：'
ui_read green_domain < <(printf 'new.example\n')
printf '\n'
migration_empty_site_ok new.example
confirm_keep_domain_dns keep.example 203.0.113.10 < <(printf 'yes\n')
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

ansi = re.compile(r'\x1b(?:\[[0-9;]*m|\]8;;.*?\x1b\\)')
plain = run()
colored = run(terminal=True)
assert '\x1b' not in plain
assert ansi.sub('', colored).rstrip('\n') == plain.rstrip('\n')
for number in range(9):
    assert '\x1b[1;33m%d.\x1b[0;96m' % number in colored
for label in ['版本：', '备份目录：', '快照目录：', '日志目录：', '备注：']:
    assert '\x1b[1;33m' + label + '\x1b[0;92m' in colored
assert '\x1b[1;33m当前服务器：\x1b[1;35m' in colored
for value in ['0.7.26', fixture + '/backups', '/home/sitebak-logs', 'snapshot']:
    assert '\x1b[0;92m' + value + '\x1b[0m' in colored
assert '\x1b[0;92m' + fixture + '/html' + '\x1b[0m' not in colored
assert '\x1b[1;35m@' in colored
assert '-' * 51 in plain
assert '\x1b[1;96m    操作\x1b[0m' in colored
assert '\x1b[1;96m    站点导入\x1b[0m' in colored
project_url = 'https://github.com/hajimi2024/ldnmp-sitebak'
assert '\x1b[1;33mGitHub：\x1b[0;96m' in colored
assert ('\x1b[0;96m\x1b[24m\x1b]8;;' + project_url + '\x1b\\' + project_url
        + '\x1b]8;;\x1b\\\x1b[0m') in colored
assert project_url in plain
for code, message in [('96', '[INFO] Reading files'), ('32', '[OK] Completed'),
                      ('33', '[WARN] Overwrite confirmation'), ('31', '[ERROR] Failed')]:
    assert '\x1b[0;' + code + 'm' + message + '\x1b[0m' in colored
divider_count = colored.count('\x1b[1;96m' + '-' * 38 + '\x1b[0m\n')
assert divider_count >= 2 and divider_count % 2 == 0
assert '\x1b[1;96m        单站备份恢复工具\x1b[0m\n' in colored
assert '\x1b[1;96m请输入你的选择：\x1b[1;33m\x1b[0m' in colored
assert '\x1b[1;96m请输入 \x1b[1;92myes\x1b[1;96m 确认删除：\x1b[1;92m\x1b[0m' in colored
assert ('\x1b[0;31m🚨 警告：即将为 \x1b[1;92m< new.example >'
        '\x1b[0;31m 注入站点文件 & 数据库。\x1b[0m') in colored
assert ('\x1b[1;96m\n已选择目标站点 \x1b[1;92m< new.example >'
        '\x1b[1;96m 请输入完整域名确认：') in colored
assert '\x1b[1;96m请输入目标站点编号或域名：\x1b[1;92m' in colored
assert '\x1b[1;92m（空站点）\x1b[0m' in colored
assert ('\x1b[0;32m[OK] ✅ 已验证目标站点 \x1b[1;92m< new.example >'
        '\x1b[0;32m 为空站点，允许继续导入。\x1b[0m') in colored
assert ('\x1b[1;96m请将 \x1b[1;92m< keep.example >\x1b[1;96m 的 DNS 解析到当前服务器。\x1b[0m'
        in colored)
assert ('\x1b[1;33m当前服务器：\x1b[1;35m@test-vps 2c4g\x1b[0m  '
        '\x1b[1;33mIPv4：\x1b[0;92m203.0.113.10\x1b[0m') in colored
assert '\x1b[1;96m若 DNS 解析完成，请输入 \x1b[1;92myes\x1b[1;96m：\x1b[1;92m' in colored
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
assert '8.  站点导入 ♻️' in narrow
PY
printf 'PASS: terminal colors, resets, plain-output fallback, column alignment and clean selection values\n'
