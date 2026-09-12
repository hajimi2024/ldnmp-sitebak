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
command_text="$(sed -n '/^(set -o pipefail;/p' "$project/README.md")"
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
    grep -q '安装失败' "$fixture/output"
    ! grep -q '安装成功' "$fixture/output"
    [[ $(< "$fixture/kk") == 'old script' ]]
  fi
  [[ -z $(find "$fixture" -name 'kk.*' -print -quit) ]]
done
printf 'PASS: documented installer success/failure output, validation, permissions and old-file preservation\n'
