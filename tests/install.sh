#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID == 0 ]] || { printf 'Installer test requires root\n' >&2; exit 1; }
project="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
export INSTALL_FIXTURE_SOURCE="$project/sitebak.sh"
export SITEBAK_INSTALL_PATH="$fixture/kk"
export MOCK_DOWNLOAD=ok
curl() {
  local output=''
  if [[ " $* " == *'https://api.github.com/repos/hajimi2024/ldnmp-sitebak/commits/main?'* ]]; then
    printf '  "sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",\n'
    return 0
  fi
  while (($#)); do
    [[ $1 != -o ]] || { output=$2; break; }
    shift
  done
  # The first curl serves the installer; the second downloads the application.
  if [[ -z "$output" ]]; then
    [[ $MOCK_DOWNLOAD != bootstrap-failure ]] || return 7
    cat "${INSTALL_FIXTURE_SOURCE%/*}/install.sh"
  else
    case "$MOCK_DOWNLOAD" in
      failure) return 22 ;;
      empty) : > "$output" ;;
      invalid) printf 'if then\n' > "$output" ;;
      wrong-file) printf '#!/bin/bash\nprintf wrong\n' > "$output" ;;
      *) cp "$INSTALL_FIXTURE_SOURCE" "$output" ;;
    esac
  fi
}
export -f curl
command_text="$(sed -n '/^bash <(curl /p' "$project/README.md")"
[[ -n "$command_text" ]]
for mode in bootstrap-failure failure empty invalid wrong-file bad-destination ok; do
  export MOCK_DOWNLOAD="$mode"
  export SITEBAK_INSTALL_PATH="$fixture/kk"
  printf 'old script\n' > "$SITEBAK_INSTALL_PATH"
  [[ $mode != bad-destination ]] || export SITEBAK_INSTALL_PATH="$fixture/missing/kk"
  set +e
  bash -c "$command_text" > "$fixture/output" 2>&1
  status=$?
  set -e
  if [[ $mode == ok ]]; then
    [[ $status == 0 && -x "$SITEBAK_INSTALL_PATH" ]]
    cmp "$INSTALL_FIXTURE_SOURCE" "$SITEBAK_INSTALL_PATH"
    grep -q '安装成功' "$fixture/output"
    ! grep -q '安装失败' "$fixture/output"
  else
    [[ $status != 0 ]]
    ! grep -q '安装成功' "$fixture/output"
    [[ $mode == bootstrap-failure ]] || grep -q '安装失败' "$fixture/output"
    [[ $(< "$fixture/kk") == 'old script' ]]
  fi
  [[ -z $(find "$fixture" -name 'kk.*' -print -quit) ]]
done

# In an interactive terminal, the separated result line uses bold yellow.
export SITEBAK_INSTALL_PATH="$fixture/kk"
python3 - "$command_text" "$fixture" <<'PY'
import errno
import os
import pty
import subprocess
import sys

command, output_dir = sys.argv[1:]
for mode, succeeds in [('ok', True), ('invalid', False)]:
    env = os.environ.copy()
    env['MOCK_DOWNLOAD'] = mode
    master, slave = pty.openpty()
    process = subprocess.Popen(['bash', '-c', command], env=env,
                               stdin=subprocess.DEVNULL, stdout=slave, stderr=slave)
    os.close(slave)
    chunks = []
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
    os.close(master)
    status = process.wait()
    assert (status == 0) == succeeds, (mode, status)
    with open(os.path.join(output_dir, 'tty-' + mode), 'wb') as stream:
        stream.write(b''.join(chunks).replace(b'\r\n', b'\n'))
PY
grep -Fq $'\n\033[1;33m安装成功，输入 kk 进入菜单。\033[0m\n' "$fixture/tty-ok"
grep -Fq $'\n\033[1;33m安装失败，请查看上方报错。\033[0m\n' "$fixture/tty-invalid"
printf 'PASS: concise documented installer, yellow separated result, validation, permissions and old-file preservation\n'
