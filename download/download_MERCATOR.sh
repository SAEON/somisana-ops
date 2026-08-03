#!/usr/bin/env bash
# download/download_MERCATOR.sh — runs on the saeonapps runner, NOT mims3 (D14's
# saeonapps hop: copernicusmarine cannot reach Copernicus from the MIMS network).
# Docker, not native conda, on this host (D21) — saeonapps is borrowed, so we avoid
# maintaining a conda env we don't control.
#
# MERCATOR is an OGCM shared across BLK=GFS and BLK=SAWS combos, so its window must
# cover the LONGEST FDAYS in the table (D14) — max_fdays_for_ogcm, not fdays_for_blk.
#
# ⚠ This script has not been run on saeonapps itself in this session (this session is
# on mims3) — the paths below come straight from plan §7.5 and haven't been verified
# against the live host. In particular:
#   - DATA_DIR/LOCK_DIR default to a mims3 path (lib/cycle_env.sh); saeonapps should
#     set LOCK_DIR explicitly in its .env rather than relying on that default.
#   - COPERNICUS_USERNAME / COPERNICUS_PASSWORD come from saeonapps' own .env (D19) —
#     mims3 never holds these.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/lock.sh"
source "$ROOT/lib/gates.sh"
source "$ROOT/lib/cycle_env.sh"

: "${COPERNICUS_USERNAME:?COPERNICUS_USERNAME must be set (saeonapps .env, D19)}"
: "${COPERNICUS_PASSWORD:?COPERNICUS_PASSWORD must be set (saeonapps .env, D19)}"

STAGING_FILE="${MERCATOR_STAGING_DIR}/MERCATOR_${RUN_DATE}.nc"
SHARED_FILE="${SHARED_MOUNT_WRITE}/MERCATOR_${RUN_DATE}.nc"
DOCKER_IMAGE="ghcr.io/saeon/somisana-download_main:latest"

if archived "$STAGING_FILE" "$SHARED_FILE"; then
  log "MERCATOR already downloaded and on the shared mount for ${RUN_DATE} — skipping"
  exit 0
fi

with_lock MERCATOR || exit 0

mkdir -p "$MERCATOR_STAGING_DIR" "$SHARED_MOUNT_WRITE"

if ! is_done "$STAGING_FILE"; then
  FDAYS="$(max_fdays_for_ogcm MERCATOR "$COMBOS_FILE")"
  log "downloading MERCATOR: bbox=${DOWNLOAD_BBOX} run_date=$(run_date_iso) hdays=${HDAYS} fdays=${FDAYS} (max over combos table, D14)"

  docker pull "$DOCKER_IMAGE"
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    -v "${MERCATOR_STAGING_DIR}:${MERCATOR_STAGING_DIR}" \
    -e COPERNICUS_USERNAME \
    -e COPERNICUS_PASSWORD \
    "$DOCKER_IMAGE" \
    cli.py download_mercator_ops \
      --usrname "$COPERNICUS_USERNAME" \
      --passwd "$COPERNICUS_PASSWORD" \
      --domain "$DOWNLOAD_BBOX" \
      --run_date "$(run_date_iso)" \
      --hdays "$HDAYS" \
      --fdays "$FDAYS" \
      --outputDir "$MERCATOR_STAGING_DIR"
  # the image's own files land root-owned without --user above; if that ever
  # regresses, clean up with the image itself rather than sudo on the host (D21):
  #   docker run --rm -v "${MERCATOR_STAGING_DIR}:${MERCATOR_STAGING_DIR}" \
  #     "$DOCKER_IMAGE" rm -rf <root-owned-paths>
fi

if ! is_done "$STAGING_FILE"; then
  log "MERCATOR download completed but expected file is missing: $STAGING_FILE"
  exit 1
fi

log "staging MERCATOR onto the shared mount: $SHARED_FILE"
tmp_file="${SHARED_FILE}.partial"
cp "$STAGING_FILE" "$tmp_file"
mv "$tmp_file" "$SHARED_FILE"   # atomic commit (D4) — the mv IS the success signal

if ! archived "$STAGING_FILE" "$SHARED_FILE"; then
  log "copy to shared mount completed but sizes don't match: $STAGING_FILE vs $SHARED_FILE"
  exit 1
fi
log "MERCATOR ready on the shared mount for ${RUN_DATE}"
