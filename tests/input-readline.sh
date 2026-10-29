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
ui_prompt '请输入编号，或直接输入域名：'
ui_read domain
printf '\nDOMAIN:%s\n' "$domain"
ui_prompt '请输入目标站点编号或域名：'
ui_read target
printf '\nTARGET:%s\n' "$target"
ui_prompt '请选择要查看的文件：'
ui_read file
printf '\nFILE:%s\n' "$file"
ui_prompt '恢复前是否创建完整快照（包含数据库）？[Y/n，0 返回] '
ui_read snapshot
printf '\nSNAPSHOT:%s\n' "$snapshot"
ui_confirm_prompt '请输入 yes 确认：'
ui_read confirmation
printf '\nCONFIRM:%s\n' "$confirmation"
ui_confirm_prompt '请输入 yes 确认删除：'
ui_read deletion
printf '\nDELETION:%s\n' "$deletion"
ui_prompt $'\n已选择目标站点 < target.example > 请输入完整域名确认：'
ui_read target_confirmation
printf '\nTARGET_CONFIRM:%s\n' "$target_confirmation"
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
    # 每个输入都先输入内容再退格，验证 Readline 只重绘输入区，不擦除中文提示。
    os.write(master, 'abc\x7f\x7f\n'.encode())
    os.write(master, 'rovetree.com\x7f\n'.encode())
    os.write(master, '2\x7f\n'.encode())
    os.write(master, 'backup.tar.gz\x7f\x7f\n'.encode())
    os.write(master, 'Y\x7f' .encode() + b'n\n')
    time.sleep(0.1)
    os.write(master, b'yes\x7f\n')
    os.write(master, b'yes\x7f\x7f\n')
    os.write(master, 'target.example\x7f\n'.encode())
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
assert 'DOMAIN:rovetree.co' in output, output
assert 'TARGET:' in output, output
assert 'FILE:backup.tar.' in output, output
assert 'SNAPSHOT:n' in output, output
assert 'CONFIRM:ye' in output, output
assert 'DELETION:y' in output, output
assert 'TARGET_CONFIRM:target.exampl' in output, output
for prompt in [
    '请输入你的选择：',
    '请输入编号，或直接输入域名：',
    '请输入目标站点编号或域名：',
    '请选择要查看的文件：',
    '恢复前是否创建完整快照（包含数据库）？[Y/n，0 返回] ',
    '请输入 yes 确认：',
    '请输入 yes 确认删除：',
    '已选择目标站点 < target.example > 请输入完整域名确认：',
]:
    assert prompt in output, (prompt, output)
PY

printf 'PASS: Readline keeps all menu, domain, file, snapshot, confirmation and target prompts intact while editing input\n'
