#!/usr/bin/env bash
# lib/common.sh — shared shell setup: strict mode, logging, resolved-env banner.
#
# Source this FIRST in every script, before my_env.sh:
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
#   source "$(dirname "${BASH_SOURCE[0]}")/../my_env.sh"
#
# set -u is why my_env.sh guards every input with ${VAR:-default} — that guard is
# deliberate, not defensive clutter (D11).
set -euo pipefail

log() {
  printf '%s [%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "${RUN_NAME:-$$}" "$*" >&2
}

# Called by my_env.sh once all derivations are resolved. Prints the whole resolved
# environment so a leaked variable or typo'd combo is visible in the log after the
# fact (D11 robustness guard) rather than causing a silent wrong-combo run.
print_env_banner() {
  log "--- resolved environment ---"
  log "DOMAIN=${DOMAIN} OGCM=${OGCM} BLK=${BLK} RUN_DATE=${RUN_DATE}"
  log "FDAYS=${FDAYS} HDAYS=${HDAYS} CLIM_FILE=${CLIM_FILE:-<empty>}"
  log "RUN_NAME=${RUN_NAME} COMBO_KEY=${COMBO_KEY} ARCHIVE_NAME=${ARCHIVE_NAME}"
  log "MPI=${MPI_NUM_X}x${MPI_NUM_Y}=${CROCO_MPI_NUM_PROCS} procs"
  log "DATA_DIR=${DATA_DIR}"
  log "PUBLIC_ROOT=${PUBLIC_ROOT}"
  log "SAFE_ROOT=${SAFE_ROOT}"
  log "--- end resolved environment ---"
}
