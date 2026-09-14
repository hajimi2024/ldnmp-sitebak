#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../sitebak.sh"
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
  while (($#)); do
    if [[ $1 == -o ]]; then output=$2; break; fi
    shift
  done
  printf '#!/bin/bash\nprintf updated\n' > "$output"
}
run_menu_action update_self < <(printf '0\n') >> "$fixture/output" 2>&1
[[ -x "$INSTALL_PATH" && $(bash "$INSTALL_PATH") == updated ]]
printf 'PASS: dependency exit, fail-fast, invalid input, menu return, failed and successful update\n'
