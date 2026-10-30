#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../sitebak.sh"
SITEBAK_DB_READY_INITIAL_WAIT=5
SITEBAK_DB_READY_RETRIES=10
SITEBAK_DB_READY_INTERVAL=3
attempts=0
verify_empty_target_database() {
  ((attempts += 1))
  ((attempts >= 3))
}
migration_stage_status() { :; }
sleep() { :; }
wait_for_empty_target_database
[[ $attempts == 3 ]]
attempts=0
verify_empty_target_database() { return 1; }
if wait_for_empty_target_database >/dev/null 2>&1; then
  exit 1
fi
printf 'PASS: bounded database readiness polling\n'
