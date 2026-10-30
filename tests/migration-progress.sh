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
MIGRATION_STAGE_INDEX=7
migration_stage_begin '站点配置检查'
migration_progress_set 10 '目标身份、WordPress 与数据库连接检查完成'
migration_progress_set 20 '当前网址状态检查完成'
migration_progress_set 30 'HTTPS 网址替换完成'
migration_progress_set 40 'HTTP 网址替换完成'
migration_progress_set 50 '协议相对网址替换完成'
migration_progress_set 65 '裸域名替换及域名处理完成'
migration_progress_set 75 'Elementor 检查和修复完成'
migration_progress_set 85 '站点瞬态缓存清理完成'
migration_progress_set 92 'WordPress 实际运行网址校验完成'
migration_progress_set 97 '表前缀、安装状态和目标身份最终复核完成'
migration_stage_complete '站点配置与目标网址校验完成'
ok '站点已成功导入'
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
stage_values = [int(value) for value in re.findall(r'([0-9]{1,3})% 阶段8/8', plain)]
assert stage_values == [0, 10, 20, 30, 40, 50, 65, 75, 85, 92, 97, 100], stage_values
stage_lines = [line for line in plain.splitlines() if '阶段8/8' in line]
assert len(stage_lines) == 1, stage_lines
assert '100% 阶段8/8：站点配置与目标网址校验完成' in stage_lines[0], stage_lines
PY

python3 - "$(dirname "$0")/../sitebak.sh" <<'PY'
import os
import pty
import re
import subprocess
import sys
import time

source = sys.argv[1]
script = r'''
source "$1"
MIGRATION_LOG_FILE=''
MIGRATION_STAGE_INDEX=5
MIGRATION_STAGE_HISTORY=(
  '1|备份包检查完成'
  '2|目标站点与空数据库验证完成'
  '3|WordPress 文件暂存完成'
  '4|待导入 SQL 安全检查完成'
  '5|WP-CLI 环境检查完成'
)
get_target_server_display() { printf '@test-vps 2c4g'; }
get_public_ipv4() { printf '203.0.113.10'; }
confirm_target_operation change-domain old.example https://old.example new.example https://new.example server root /target/root target_db /backup.tar.gz
'''
env = os.environ.copy()
env.pop('NO_COLOR', None)
env.update(TERM='xterm-256color', COLUMNS='100')
master, slave = pty.openpty()
process = subprocess.Popen(['bash', '-c', script, 'confirmation-layout', source],
                           env=env, stdin=slave, stdout=slave, stderr=slave)
os.close(slave)
os.write(master, b'yes\n')
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
plain = re.sub(r'\x1b\[[0-9;]*[mK]', '', output).replace('\r', '')
header = plain.index('即将执行站点操作，请核对：')
stage_one = plain.index('100% 阶段1/8：备份包检查完成')
stage_five = plain.index('100% 阶段5/8：WP-CLI 环境检查完成')
assert header < stage_one < stage_five, plain
PY

printf 'PASS: monotonic migration progress, adaptive width, colors, success and failure boundaries\n'
