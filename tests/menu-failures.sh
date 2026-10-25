#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../sitebak.sh"
project="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
clear_screen() { :; }
need_root() { :; }
missing_dependency() { need_cmd sitebak_nonexistent_test_command; touch "$fixture/continued"; }
run_menu_action missing_dependency < <(printf 'x\n0\n') > "$fixture/output" 2>&1
[[ ! -e "$fixture/continued" ]]
grep -q '请输入 0' "$fixture/output"
fail_mid_task() { false; touch "$fixture/continued"; }
run_menu_action fail_mid_task < <(printf '0\n') >> "$fixture/output" 2>&1
[[ ! -e "$fixture/continued" ]]
INSTALL_PATH="$fixture/kk"
printf 'old script\n' > "$INSTALL_PATH"
curl() { return 22; }
main_menu < <(printf '7\n0\n0\n') > "$fixture/main" 2>&1 &
menu_pid=$!
wait "$menu_pid"
[[ $(grep -c '7.  更新脚本' "$fixture/main") == 2 ]]
[[ $(< "$INSTALL_PATH") == 'old script' ]]
curl() {
  local output
  if [[ " $* " == *'https://api.github.com/repos/hajimi2024/ldnmp-sitebak/commits/main?'* ]]; then
    printf '  "sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",\n'
    return 0
  fi
  while (($#)); do
    if [[ $1 == -o ]]; then output=$2; break; fi
    shift
  done
  printf 'if then\n' > "$output"
}
run_menu_action update_self < <(printf '0\n') >> "$fixture/output" 2>&1
[[ $(< "$INSTALL_PATH") == 'old script' ]]
curl() {
  local output
  printf '%s\n' "$@" >> "$fixture/curl-args"
  if [[ " $* " == *'https://api.github.com/repos/hajimi2024/ldnmp-sitebak/commits/main?'* ]]; then
    printf '  "sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",\n'
    return 0
  fi
  while (($#)); do
    if [[ $1 == -o ]]; then output=$2; break; fi
    shift
  done
  cp "$project/sitebak.sh" "$output"
}
: > "$fixture/curl-args"
run_menu_action update_self < <(printf '0\n') >> "$fixture/output" 2>&1
[[ -x "$INSTALL_PATH" ]]
grep -q '^VERSION="0.3.4"$' "$INSTALL_PATH"
grep -Eq 'commits/main\?sitebak_nocache=[0-9]+' "$fixture/curl-args"
grep -q 'raw.githubusercontent.com/hajimi2024/ldnmp-sitebak/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/sitebak.sh' "$fixture/curl-args"
grep -q '版本 0.3.4' "$fixture/output"

exec() { printf '%s\n' "$1" > "$fixture/reloaded"; }
update_and_reload > "$fixture/reload-output" 2>&1
[[ $(< "$fixture/reloaded") == "$INSTALL_PATH" ]]
grep -q '正在自动载入新版菜单' "$fixture/reload-output"
printf 'PASS: dependency exit, fail-fast, cache bypass, version validation, menu return and automatic reload\n'
