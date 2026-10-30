#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../sitebak.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
MIGRATION_LOG_FILE="$fixture/migration.log"
: > "$MIGRATION_LOG_FILE"
getent() { printf '%s\n' '198.51.100.10 STREAM example'; }
verify_domain_dns_ipv4 example.test 198.51.100.10
! verify_domain_dns_ipv4 example.test 198.51.100.11 2>"$fixture/mismatch"
grep -Fq '不是当前服务器' "$fixture/mismatch"
getent() { return 0; }
! verify_domain_dns_ipv4 example.test 198.51.100.10 2>"$fixture/missing"
grep -Fq '没有解析到 IPv4' "$fixture/missing"
printf 'PASS: DNS A record validation and fail-closed behavior\n'
