#!/usr/bin/env bash
set -Eeuo pipefail

python3 - "$(dirname "$0")/../sitebak.sh" <<'PY'
import errno
import os
import pty
import subprocess
import sys
import time

source = sys.argv[1]
script = r'''
source "$1"
ui_prompt '请输入你的选择：'
ui_read value
printf '\nVALUE:%s\n' "$value"
ui_confirm_prompt '请输入 yes 确认：'
ui_read confirmation
printf '\nCONFIRM:%s\n' "$confirmation"
'''
env = os.environ.copy()
env.pop('NO_COLOR', None)
env.update(TERM='xterm-256color', COLUMNS='80')
master, slave = pty.openpty()
process = subprocess.Popen(
    ['bash', '-c', script, 'readline-test', source],
    env=env,
    stdin=slave,
    stdout=slave,
    stderr=slave,
)
os.close(slave)
chunks = []
try:
    time.sleep(0.1)
    # 删除两个字符后提交，验证 Readline 只重绘输入区，不擦除中文提示。
    os.write(master, b'abc\x7f\x7f\n')
    time.sleep(0.1)
    os.write(master, b'yes\x7f\n')
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
output = b''.join(chunks).decode(errors='replace')
assert 'VALUE:a' in output, output
assert 'CONFIRM:ye' in output, output
assert output.count('请输入你的选择：') >= 1, output
assert output.count('请输入 yes 确认：') >= 1, output
PY

printf 'PASS: Readline keeps every colored prompt intact while editing and deleting input\n'
