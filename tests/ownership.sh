#!/usr/bin/env bash
set -Eeuo pipefail
# Runs the complete fixture restore with real Linux ownership and permissions.
export SITEBAK_TEST_OWNERSHIP=1
exec bash "$(dirname "$0")/database-backend.sh"
