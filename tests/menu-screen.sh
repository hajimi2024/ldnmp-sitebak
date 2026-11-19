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
if [[ $2 == navigation ]]; then
  get_public_ipv4() { printf '203.0.113.10'; }
  get_current_server_label() { printf '@test'; }
  list_sites_by_creation_array() {
    local index
    for ((index=1; index<=30; index++)); do printf 'site-%s.example\n' "$index"; done
  }
  site_database_is_empty() { return 1; }
  list_backups_for_domain() { :; }
else
  header() { printf 'PAGE\n'; }
  show_sites() (
    trap 'printf "TASK_CLEANUP\n"' EXIT
    printf 'TASK_RUNNING\n'
    sleep 30
  )
fi
if [[ $2 == missing ]]; then
  tput() { [[ $1 == smcup ]] && printf '<ENTER>'; }
else
  tput() { if [[ $1 == smcup ]]; then printf '<ENTER>'; else printf '<LEAVE>'; fi; }
fi
if [[ $2 == redirected ]]; then exec 2>/dev/null; fi
update_mode=$2
update_self() { [[ $update_mode != update-fail ]]; }
if [[ $2 == update-ok ]]; then INSTALL_PATH=/bin/true; fi
shift 2
main "$@"
'''

def run(actions, status=0, mode='', args=(), term='xterm', page_clears=0):
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
                # Wake Readline if the signal trap is deferred during input.
                os.write(fd, b'\n')
        _, result = os.waitpid(pid, 0)
        pid = None
        assert os.waitstatus_to_exitcode(result) == status, output
        assert b'<ENTER>' not in output and b'<LEAVE>' not in output, output
        assert b'\x1b[?1049' not in output, output
        clear_view = b'\x1b[H\x1b[2J\x1b[3J'
        should_clear = term != 'dumb' and mode not in ('redirected', 'update-ok')
        assert output.count(clear_view) == page_clears + int(should_clear), output
        assert output.count(b'\x1b[3J') == page_clears + int(should_clear), output
        if should_clear:
            assert output.endswith(clear_view), output
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
action_return = '请输入：'.encode()
run([(prompt, b'7\n'), (prompt, b'0\n'), (prompt, b'0\n')])
run([(prompt, b'0\n')], args=('migrate',))
run([(prompt, b'\x04')])
run([(prompt, b'\x03')], status=130)
run([(prompt, signal.SIGTERM)], status=143)
assert b'TASK_CLEANUP' in run([(prompt, b'1\n'), (b'TASK_RUNNING', b'\x03')], status=130)
run([(prompt, b'00\n')], mode='update-ok')
run([(prompt, b'00\n'), ('退出码'.encode(), b'0\n0\n')], mode='update-fail')
run([(prompt, b'0\n')], term='dumb')
run([(prompt, b'0\n')], mode='missing')
run([(b'PAGE', b'0\n')], mode='redirected')

# Use real headers on both stdout and stderr. A long current page can scroll,
# and returning home clears its scrollback before drawing the next header.
navigation = run([(prompt, b'1\n'), (action_return, b'0\n'), (prompt, b'0\n')],
                 mode='navigation', page_clears=3)
pages = navigation.split(b'\x1b[H\x1b[2J\x1b[3J')
assert len(pages) == 5, pages
assert b'site-1.example' in pages[2] and b'site-30.example' in pages[2], pages
assert b'site-1.example' not in pages[3] and '操作'.encode() in pages[3], pages
for choice in (b'2\n', b'4\n'):
    run([(prompt, choice), ('直接输入域名'.encode(), b'0\n'),
         (action_return, b'0\n'), (prompt, b'0\n')], mode='navigation', page_clears=3)
run([(prompt, b'3\n'), (action_return, b'0\n'), (prompt, b'0\n')],
    mode='navigation', page_clears=3)
run([(prompt, b'6\n'), ('请选择：'.encode(), b'0\n'),
     (action_return, b'0\n'), (prompt, b'0\n')], mode='navigation', page_clears=3)
run([(prompt, b'5\n'), (prompt, b'2\n'), (action_return, b'0\n'),
     (prompt, b'0\n'), (prompt, b'0\n')], mode='navigation', page_clears=5)
run([(prompt, b'7\n'), (prompt, b'0\n'), (prompt, b'0\n')],
    mode='navigation', page_clears=3)
plain = subprocess.run(['bash', '-ec', script, 'test', source, ''],
                       input=b'0\n', capture_output=True, check=True)
assert b'<ENTER>' not in plain.stdout and b'<LEAVE>' not in plain.stdout
assert b'\x1b[2J' not in plain.stdout
print('PASS: interactive menu screen lifecycle')
PY
