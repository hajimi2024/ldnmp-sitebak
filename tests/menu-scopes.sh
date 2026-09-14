#!/usr/bin/env bash
set -Eeuo pipefail
export NO_COLOR=1
source "$(dirname "$0")/../sitebak.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
BACKUP_DIR="$fixture/backup files"
mkdir -p "$BACKUP_DIR"
clear_screen() { :; }
normal="$BACKUP_DIR/example.com_20260914_100000.tar.gz"
snapshot="$BACKUP_DIR/example.com_snapshot_20260914_110000.tar.gz"
legacy="$BACKUP_DIR/example.com_before_restore_20260914_090000.tar.gz"
touch -t 202609141000 "$normal"
touch -t 202609141100 "$snapshot"
touch -t 202609140900 "$legacy"

show_backups > "$fixture/normal-list"
grep -Fq "$(basename "$normal")" "$fixture/normal-list"
! grep -Eq '_snapshot_|_before_restore_' "$fixture/normal-list"
show_backups snapshots > "$fixture/snapshot-list"
grep -Fq "$(basename "$snapshot")" "$fixture/snapshot-list"
grep -Fq "$(basename "$legacy")" "$fixture/snapshot-list"
! grep -Fq "$(basename "$normal")" "$fixture/snapshot-list"

# Capture restore choices without unpacking archives or touching a database.
restore_site() { printf '%s\n%s\n' "$1" "${2:-}" > "$fixture/restore-choice"; }
restore_menu < <(printf '1\n') > "$fixture/normal-restore" 2>&1
mapfile -t choice < "$fixture/restore-choice"
[[ ${choice[0]} == "$normal" && -z ${choice[1]} ]]
! grep -Eq '_snapshot_|_before_restore_' "$fixture/normal-restore"
restore_snapshot_menu < <(printf '1\n') > "$fixture/snapshot-restore" 2>&1
mapfile -t choice < "$fixture/restore-choice"
[[ ${choice[0]} == "$snapshot" && ${choice[1]} == snapshot ]]
! grep -Fq "$(basename "$legacy")" "$fixture/snapshot-restore"
! grep -Fq "$(basename "$normal")" "$fixture/snapshot-restore"

delete_backup_menu < <(printf '1\nno\n') > "$fixture/cancel" 2>&1
[[ -f "$normal" && -f "$snapshot" && -f "$legacy" ]]
delete_backup_menu < <(printf '1\nyes\n') > "$fixture/delete-normal" 2>&1
[[ ! -e "$normal" && -f "$snapshot" && -f "$legacy" ]]
! grep -Eq '_snapshot_|_before_restore_' "$fixture/delete-normal"
show_backups > "$fixture/empty"
grep -q '未找到普通备份文件' "$fixture/empty"

touch "$normal"
delete_backup_menu snapshots < <(printf '1\nyes\n') > "$fixture/delete-snapshot" 2>&1
[[ -f "$normal" && ! -e "$snapshot" && -f "$legacy" ]]
delete_backup_menu snapshots < <(printf '1\nyes\n') > "$fixture/delete-legacy" 2>&1
[[ -f "$normal" && ! -e "$legacy" ]]
printf 'PASS: separate backup/snapshot listing, restore choices, deletion, cancellation and legacy scope\n'
