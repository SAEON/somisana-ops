#!/usr/bin/env bash
# download/download_HYCOM.sh — download HYCOM analysis+forecast via the HYCOM THREDDS
# server, native conda on mims3 (D21).
#
# HYCOM is an OGCM shared across BLK=GFS and BLK=SAWS combos, so its download window
# must cover the LONGEST FDAYS in the table, not one derived value (D14's warning) —
# hence max_fdays_for_ogcm rather than fdays_for_blk.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/lock.sh"
source "$ROOT/lib/gates.sh"
source "$ROOT/lib/cycle_env.sh"

HYCOM_DIR="${DOWNLOADS_DIR}/HYCOM"
HYCOM_FILE="${HYCOM_DIR}/HYCOM_${RUN_DATE}.nc"   # §7.5

if is_done "$HYCOM_FILE"; then
  log "HYCOM already downloaded for ${RUN_DATE} — skipping"
  exit 0
fi

with_lock HYCOM || exit 0

mkdir -p "$HYCOM_DIR"

FDAYS="$(max_fdays_for_ogcm HYCOM "$COMBOS_FILE")"
log "downloading HYCOM: bbox=${DOWNLOAD_BBOX} run_date=$(run_date_iso) hdays=${HDAYS} fdays=${FDAYS} (max over combos table, D14)"

activate_conda_env "$DOWNLOAD_ENV"
python "${DOWNLOAD_REPO}/cli.py" download_hycom_ops \
  --domain "$DOWNLOAD_BBOX" \
  --run_date "$(run_date_iso)" \
  --hdays "$HDAYS" \
  --fdays "$FDAYS" \
  --outputDir "$HYCOM_DIR"
deactivate_conda_env

if ! is_done "$HYCOM_FILE"; then
  log "HYCOM download completed but expected file is missing: $HYCOM_FILE"
  exit 1
fi
log "HYCOM ready for ${RUN_DATE}"
