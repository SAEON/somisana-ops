#!/usr/bin/env bash
# download/download_SAWS.sh — reformat SAWS UM atmospheric data into CROCO ONLINE
# format (D14). SAWS is NOT a download: reformat_saws_atm reads directly from the
# SAWS mount and only provides a subset of variables, backfilling the rest from
# GFS/for_croco — so this script genuinely depends on download_GFS.sh having run
# first, both for the backfill variables and as the grid template.
#
# ⚠ D16 nuance confirmed by reading crocotools_py/preprocess.py directly (2026-08-03):
# reformat_saws_atm's OWN internal checks are not exit-0-friendly —
#   - files[0] on an empty glob of SAWS input raises an unhandled IndexError
#   - a latest-file-older-than-12h check raises ValueError("...aborting SAWS forced
#     run")
# Both of those are "not yet" in D16's sense (absence and staleness are normal at
# 00:15 UTC), not genuine breakage. This script duplicates the SAME 12h staleness
# check reformat_saws_atm uses internally, so we exit 0 BEFORE ever calling into a
# path that would otherwise look like a crash. Only a reformat call made on input
# that passed both checks — i.e. genuinely present and fresh — is allowed to fail
# non-zero.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/lock.sh"
source "$ROOT/lib/gates.sh"
source "$ROOT/lib/cycle_env.sh"

GFS_FOR_CROCO_DIR="${DOWNLOADS_DIR}/GFS/for_croco"
SAWS_FOR_CROCO_DIR="${DOWNLOADS_DIR}/SAWS/for_croco"

# GFS_VARS / SAWS_VARS (§7.5) come from lib/cycle_env.sh — shared with
# download_GFS.sh so the two variable-set definitions can't drift apart.
# reformat_saws_atm's --backupDir reads several of GFS_VARS (grid template +
# backfill for variables SAWS doesn't provide), so a PARTIAL GFS reformat isn't a
# safe dependency either — gate on the whole set, same reasoning as GFS's own gate.
# SAWS_VARS is 9 of GFS's 10 — everything except patm, which SAWS doesn't provide and
# isn't in its existsSAWS/backfill variable dict at all (confirmed by reading
# crocotools_py/preprocess.py's reformat_saws_atm, 2026-08-03). Combos with BLK=SAWS
# still need patm from somewhere — that's a bry/ini-stage concern (later phase), not
# this script's.

if all_done "$SAWS_FOR_CROCO_DIR" "${SAWS_VARS[@]}"; then
  log "SAWS already reformatted for ${RUN_DATE} — skipping"
  exit 0
fi

if ! all_done "$GFS_FOR_CROCO_DIR" "${GFS_VARS[@]}"; then
  log "waiting on GFS (backupDir not fully reformatted yet) — skipping"
  exit 0   # ordering dependency (D14): SAWS needs GFS reformatted first
fi

# --- SAWS input presence + staleness, checked ourselves so we never hit
#     reformat_saws_atm's internal hard-fail paths for a normal "not yet" state ----
#
# ⚠ SAWS_SOURCE_DIR is a network mount (/mnt/saws-data, autofs — the plan's own §7.9
# notes it "can hang"). If it's unmounted, `find` exits non-zero even with the
# directory itself missing; under `pipefail` that fails the whole pipe, and under
# `set -e` that would kill this script BEFORE the "not yet" log line below is ever
# reached (confirmed via code review, 2026-08-03 — reproduced directly: no output,
# exit 1). `|| true` makes any find failure fall through to the same "no input yet"
# path as a genuinely empty directory — correct per D16, since an unmounted share at
# 00:15 UTC is exactly as unremarkable as an empty one.
latest_saws_file="$(find "$SAWS_SOURCE_DIR" -maxdepth 1 -name 'SAWSUM_SA4-*.nc' 2>/dev/null | sort | tail -n1 || true)"
if [ -z "$latest_saws_file" ]; then
  log "no SAWS input present yet (or ${SAWS_SOURCE_DIR} not accessible) — skipping"
  exit 0
fi

ts="$(basename "$latest_saws_file" .nc)"; ts="${ts##*-}"   # YYYYMMDDHH
latest_epoch="$(date -u -d "${ts:0:8} ${ts:8:2}:00:00" +%s)"
run_epoch="$(date -u -d "$(run_date_iso)" +%s)"
cutoff_epoch=$(( run_epoch - 12*3600 ))   # matches reformat_saws_atm's own 12h check
if [ "$latest_epoch" -lt "$cutoff_epoch" ]; then
  log "latest SAWS file ($ts) is more than 12h older than RUN_DATE — not yet, skipping"
  exit 0
fi

with_lock SAWS || exit 0

mkdir -p "$SAWS_FOR_CROCO_DIR"

log "reformatting SAWS (latest input: $(basename "$latest_saws_file")) hdays=${HDAYS} Yorig=${YORIG}"
activate_conda_env "$CROCO_ENV"
python "${CROCO_REPO}/cli.py" reformat_saws_atm \
  --sawsDir "$SAWS_SOURCE_DIR" \
  --backupDir "$GFS_FOR_CROCO_DIR" \
  --outputDir "$SAWS_FOR_CROCO_DIR" \
  --run_date "$(run_date_iso)" \
  --hdays "$HDAYS" \
  --Yorig "$YORIG"
deactivate_conda_env

if ! all_done "$SAWS_FOR_CROCO_DIR" "${SAWS_VARS[@]}"; then
  log "SAWS reformat completed but not all expected variable files are present in $SAWS_FOR_CROCO_DIR"
  exit 1
fi
log "SAWS ready for ${RUN_DATE}"
