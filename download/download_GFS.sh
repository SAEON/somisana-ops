#!/usr/bin/env bash
# download/download_GFS.sh — download GFS atmospheric forcing and reformat it into
# CROCO ONLINE-format files (D14).
#
# Two steps, two conda envs (D21):
#   1. download_gfs_atm (DOWNLOAD_ENV)  — raw .grb files from NOMADS
#   2. reformat_gfs_atm (CROCO_ENV)     — grb -> for_croco/*.nc (crocotools_py, which
#                                          lives in the somisana-croco clone)
#
# Gate: the for_croco sentinel (§7.5). GFS's FDAYS is fixed at 5 (fdays_for_blk GFS) —
# unlike MERCATOR/HYCOM, GFS is itself a BLK, not an OGCM shared across BLKs, so no
# max-over-table computation is needed here (D14).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/lock.sh"
source "$ROOT/lib/gates.sh"
source "$ROOT/lib/cycle_env.sh"

GFS_RAW_DIR="${DOWNLOADS_DIR}/GFS/raw"
GFS_FOR_CROCO_DIR="${DOWNLOADS_DIR}/GFS/for_croco"

# GFS_VARS (the full CROCO ONLINE variable set reformat_gfs_atm writes, §7.5) comes
# from lib/cycle_env.sh — shared with download_SAWS.sh's dependency check so the two
# can't drift apart. Gate on ALL of them, not one sentinel — see lib/gates.sh's
# all_done() for why a single-file gate on multi-file output is unsafe (confirmed on
# mims3 2026-08-03).
if all_done "$GFS_FOR_CROCO_DIR" "${GFS_VARS[@]}"; then
  log "GFS already reformatted for ${RUN_DATE} — skipping"
  exit 0
fi

with_lock GFS || exit 0   # held -> another GFS download in flight, not a failure (D4)

mkdir -p "$GFS_RAW_DIR" "$GFS_FOR_CROCO_DIR"

FDAYS="$(fdays_for_blk GFS)"
log "downloading GFS: bbox=${DOWNLOAD_BBOX} run_date=$(run_date_iso) hdays=${HDAYS} fdays=${FDAYS}"

activate_conda_env "$DOWNLOAD_ENV"
python "${DOWNLOAD_REPO}/cli.py" download_gfs_atm \
  --domain "$DOWNLOAD_BBOX" \
  --run_date "$(run_date_iso)" \
  --hdays "$HDAYS" \
  --fdays "$FDAYS" \
  --outputDir "$GFS_RAW_DIR"
deactivate_conda_env

log "reformatting GFS grb -> CROCO ONLINE nc (Yorig=${YORIG})"
activate_conda_env "$CROCO_ENV"
python "${CROCO_REPO}/cli.py" reformat_gfs_atm \
  --gfsDir "$GFS_RAW_DIR" \
  --outputDir "$GFS_FOR_CROCO_DIR" \
  --Yorig "$YORIG"
deactivate_conda_env

if ! all_done "$GFS_FOR_CROCO_DIR" "${GFS_VARS[@]}"; then
  log "GFS reformat completed but not all expected variable files are present in $GFS_FOR_CROCO_DIR"
  exit 1
fi
log "GFS ready for ${RUN_DATE}"
