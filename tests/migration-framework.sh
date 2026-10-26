#!/usr/bin/env bash
set -Eeuo pipefail
export NO_COLOR=1
source "$(dirname "$0")/../sitebak.sh"

fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
MIGRATION_LOG_DIR="$fixture/migration logs"
sentinel="$fixture/site-and-database-state"
printf 'unchanged\n' > "$sentinel"
clear_screen() { :; }
need_root() { :; }

migration_log_init change-domain
migration_log WARN '测试日志；未修改网站或数据库。'
migration_log_finish 0
[[ $(< "$sentinel") == unchanged ]]
[[ -d "$MIGRATION_LOG_DIR" ]]
[[ $(stat -c '%a' "$MIGRATION_LOG_DIR") == 700 ]]
[[ -f "$MIGRATION_LOG_FILE" ]]
[[ $(stat -c '%a' "$MIGRATION_LOG_FILE") == 600 ]]
grep -Fq '模式=change-domain' "$MIGRATION_LOG_FILE"
grep -Fq '未修改网站或数据库' "$MIGRATION_LOG_FILE"

migration_log INFO 'DB_PASSWORD=topsecret TOKEN=abc123 mysql://user:password@mysql/site --password=visible'
! grep -Eq 'topsecret|abc123|password@|--password=visible' "$MIGRATION_LOG_FILE"
[[ $(grep -o '\[REDACTED\]' "$MIGRATION_LOG_FILE" | wc -l) -ge 4 ]]

older_log="$MIGRATION_LOG_DIR/migration_old_20000101_000000.test.log"
printf 'OLDER LOG MUST NOT BE SELECTED\n' > "$older_log"
chmod 0600 "$older_log"
touch -d '2000-01-01 00:00:00 UTC' "$older_log"
show_recent_migration_log > "$fixture/recent"
grep -Fq "最近一次操作日志：$MIGRATION_LOG_FILE" "$fixture/recent"
grep -Fq 'DB_PASSWORD=[REDACTED]' "$fixture/recent"
! grep -Fq 'OLDER LOG MUST NOT BE SELECTED' "$fixture/recent"

(
  trap - EXIT
  header() { :; }
  migration_preflight() { printf 'ACTION:%s\n' "$1"; }
  continue_migration_finalize() { printf 'ACTION:continue-finalize\n'; }
  show_recent_migration_log() { printf 'ACTION:recent-log\n'; }
  migration_menu < <(printf '%s\n' invalid 1 0 2 0 3 0 4 0 0)
) > "$fixture/menu-routing"
grep -Fq '无效的选择，请输入 0 至 4' "$fixture/menu-routing"
mapfile -t actions < <(grep -o 'ACTION:[^[:space:]]*' "$fixture/menu-routing" | cut -d: -f2-)
[[ ${actions[*]} == 'change-domain keep-domain continue-finalize recent-log' ]]

(
  trap - EXIT
  migration_menu() { printf 'ACTION:command-migrate\n'; }
  main migrate
) > "$fixture/command-routing"
grep -Fxq 'ACTION:command-migrate' "$fixture/command-routing"

empty_log_dir="$fixture/no logs"
MIGRATION_LOG_DIR="$empty_log_dir" show_recent_migration_log > "$fixture/no-log"
grep -Fq '尚无操作日志' "$fixture/no-log"

printf 'PASS: migration menu, command entry, protected logs, recent selection and redaction\n'
