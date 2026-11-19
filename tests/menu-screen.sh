#!/usr/bin/env bash
set -Eeuo pipefail
python3 - "$(dirname "$0")/../sitebak.sh" <<'PY'
import errno
import os
import pty
import select
import signal
import subprocess
import sys
import time

source = sys.argv[1]
script = r'''
source "$1"
need_root() { :; }
header() { printf 'PAGE\n'; }
if [[ $2 == missing ]]; then
  tput() { [[ $1 == smcup ]] && printf '<ENTER>'; }
else
  tput() { if [[ $1 == smcup ]]; then printf '<ENTER>'; else printf '<LEAVE>'; fi; }
fi
if [[ $2 == redirected ]]; then exec 2>/dev/null; fi
show_sites() (
  trap 'printf "TASK_CLEANUP\n"' EXIT
  printf 'TASK_RUNNING\n'
  sleep 30
)
update_mode=$2
update_self() { [[ $update_mode != update-fail ]]; }
if [[ $2 == update-ok ]]; then INSTALL_PATH=/bin/true; fi
shift 2
main "$@"
'''

def run(actions, status=0, screens=1, mode='', args=(), term='xterm'):
    pid, fd = pty.fork()
    if pid == 0:
        os.environ['TERM'] = term
        os.execvp('bash', ['bash', '-ec', script, 'test', source, mode, *args])
    output = b''
    deadline = time.monotonic() + 12
    try:
        for marker, action in [*actions, (None, None)]:
            start = len(output)
            while marker is None or marker not in output[start:]:
                if not select.select([fd], [], [], max(0, deadline - time.monotonic()))[0]:
                    raise AssertionError(output)
                try:
                    output += os.read(fd, 8192)
                except OSError as error:
                    if error.errno != errno.EIO or marker is not None:
                        raise
                    break
            if isinstance(action, bytes):
                os.write(fd, action)
            elif action is not None:
                os.kill(pid, action)
        _, result = os.waitpid(pid, 0)
        pid = None
        assert os.waitstatus_to_exitcode(result) == status, output
        assert output.count(b'<ENTER>') == output.count(b'<LEAVE>') == screens, output
        clear_view = b'\x1b[H\x1b[2J\x1b[3J'
        should_clear = term != 'dumb' and mode not in ('redirected', 'update-ok')
        assert output.count(clear_view) == int(should_clear), output
        assert output.count(b'\x1b[3J') == int(should_clear), output
        if should_clear:
            assert output.endswith(clear_view), output
        if screens:
            assert output.index(b'<ENTER>') < output.index(b'PAGE') < output.rindex(b'<LEAVE>'), output
        return output
    finally:
        os.close(fd)
        if pid is not None:
            try:
                os.killpg(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)

prompt = '请输入你的选择'.encode()
run([(prompt, b'7\n'), (prompt, b'0\n'), (prompt, b'0\n')])
run([(prompt, b'0\n')], args=('migrate',))
run([(prompt, b'\x04')])
run([(prompt, b'\x03')], status=130)
run([(prompt, signal.SIGTERM)], status=143)
assert b'TASK_CLEANUP' in run([(prompt, b'1\n'), (b'TASK_RUNNING', b'\x03')], status=130)
run([(prompt, b'00\n')], mode='update-ok')
run([(prompt, b'00\n'), ('退出码'.encode(), b'0\n0\n')], mode='update-fail')
run([(prompt, b'0\n')], term='dumb', screens=0)
run([(prompt, b'0\n')], mode='missing', screens=0)
run([(b'PAGE', b'0\n')], mode='redirected', screens=0)
plain = subprocess.run(['bash', '-ec', script, 'test', source, ''],
                       input=b'0\n', capture_output=True, check=True)
assert b'<ENTER>' not in plain.stdout and b'<LEAVE>' not in plain.stdout
assert b'\x1b[2J' not in plain.stdout
print('PASS: interactive menu screen lifecycle')
PY
