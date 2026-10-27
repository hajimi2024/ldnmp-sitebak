#!/usr/bin/env bash
set -Eeuo pipefail
export NO_COLOR=1 TERM=dumb COLUMNS=46
source "$(dirname "$0")/../sitebak.sh"

fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT

MIGRATION_LOG_FILE="$fixture/failure.log"
: > "$MIGRATION_LOG_FILE"
{
  migration_progress_begin '准备站点导入。'
  migration_progress_set 10 '目标数据库空库检查完成。'
  migration_progress_set 40 '备份包检查完成。'
  if migration_progress_set 39 '错误的倒退进度。'; then
    exit 1
  fi
  migration_progress '正在构建 WordPress 文件暂存区。'
  migration_progress_end
} > "$fixture/failure-output"

mapfile -t failure_values < <(grep -oE '[[:space:]][0-9]{1,3}%' "$fixture/failure-output" | tr -d ' %')
[[ "${failure_values[*]}" == '0 10 40 40' ]]
for ((i = 1; i < ${#failure_values[@]}; i++)); do
  ((failure_values[i] >= failure_values[i - 1]))
done
! grep -Fq '100%' "$fixture/failure-output"
! grep -Fq '进度=100%' "$MIGRATION_LOG_FILE"

MIGRATION_LOG_FILE="$fixture/success.log"
: > "$MIGRATION_LOG_FILE"
{
  migration_progress_begin '准备站点导入。'
  migration_progress_set 50 'WordPress 文件暂存完成。'
  migration_progress_set 99 'WordPress 配置检查完成。'
  migration_progress_set 100 '站点导入及 WordPress 收尾全部完成。'
  migration_progress_end
} > "$fixture/success-output"
grep -Fq '100% 站点导入及 WordPress 收尾全部完成。' "$fixture/success-output"
grep -Fq '进度=100%；站点导入及 WordPress 收尾全部完成。' "$MIGRATION_LOG_FILE"

(
  COLUMNS=20
  MIGRATION_LOG_FILE=''
  migration_progress_begin '窄终端'
  migration_progress_set 50 '处理中'
  migration_progress_end
) > "$fixture/narrow-output"
grep -Fq '[>>>>>>......]  50% 处理中' "$fixture/narrow-output"

python3 - "$(dirname "$0")/../sitebak.sh" <<'PY'
import os
import pty
import re
import subprocess
import sys

source = sys.argv[1]
script = r'''
source "$1"
MIGRATION_LOG_FILE=''
COLUMNS=50
migration_progress_begin '准备'
migration_progress_set 60 '正在解压站点文件'
migration_progress_end
'''
env = os.environ.copy()
env.pop('NO_COLOR', None)
env.update(TERM='xterm-256color', COLUMNS='50')
master, slave = pty.openpty()
process = subprocess.Popen(['bash', '-c', script, 'progress-color', source],
                           env=env, stdin=subprocess.DEVNULL, stdout=slave, stderr=slave)
os.close(slave)
chunks = []
try:
    while True:
        try:
            chunk = os.read(master, 65536)
        except OSError:
            break
        if not chunk:
            break
        chunks.append(chunk)
finally:
    os.close(master)
assert process.wait() == 0
output = b''.join(chunks).decode()
assert '\x1b[0;32m' in output, output
assert '\x1b[0;90m' in output, output
plain = re.sub(r'\x1b\[[0-9;]*[mK]', '', output).replace('\r', '')
assert '60% 正在解压站点文件' in plain, plain
PY

printf 'PASS: monotonic migration progress, adaptive width, colors, success and failure boundaries\n'
