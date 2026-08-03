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

# The download/reformat CLIs' progress prints are only useful in a log if they
# actually appear while the process is running. Python block-buffers stdout when it
# isn't a tty (which it never is under `bash script.sh > log 2>&1` or in an Actions
# job), so without this a slow stage (HYCOM's THREDDS server, confirmed on mims3
# 2026-08-03 to sit silent for minutes at a time) looks indistinguishable from a hang
# until the process finally exits and the buffer flushes.
export PYTHONUNBUFFERED=1

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

# run_date_iso [RUN_DATE] — convert RUN_DATE (YYYYMMDD_HH, D15) to the
# "YYYY-MM-DD HH:MM:SS" format the somisana-download / somisana-croco CLIs expect.
run_date_iso() {
  local rd="${1:-$RUN_DATE}"
  printf '%s-%s-%s %s:00:00' "${rd:0:4}" "${rd:4:2}" "${rd:6:2}" "${rd:9:2}"
}

# activate_conda_env <env> — source the conda hook and activate an env.
#
# ⚠ Confirmed on mims3 (2026-08-03): conda's own activation hooks are not `set -u`
# clean — e.g. somisana_croco's gdal-activate.sh reads $GDAL_DATA unguarded and dies
# with "unbound variable" under our `set -u`. Bracket the activate/deactivate calls
# with `set +u`/`set -u` so this script's strict mode doesn't get blamed for a bug in
# someone else's activation script.
activate_conda_env() {
  local env="$1"
  # shellcheck disable=SC1090
  source "${CONDA_HOOK:?CONDA_HOOK not set}"
  set +u
  conda activate "$env"
  set -u
  log "activated conda env: $env"
}

deactivate_conda_env() {
  set +u
  conda deactivate
  set -u
}

# fdays_for_blk <BLK> — FDAYS is a property of BLK, not of the combination (D11).
# One implementation, reused by my_env.sh (combo-level) and download scripts
# (cycle-level, via max_fdays_for_ogcm).
fdays_for_blk() {
  case "$1" in
    SAWS) echo "2.45" ;;
    GFS)  echo "5" ;;
    *) echo "fdays_for_blk: unknown BLK '$1'" >&2; return 1 ;;
  esac
}

# max_fdays_for_ogcm <OGCM> <combos_file> — D14's warning: an OGCM download window
# must cover the LONGEST FDAYS among every BLK that uses it in the combos table, not
# just one derived value — MERCATOR feeds both MERCATOR_GFS (5d) and MERCATOR_SAWS
# (2.45d), so its download must cover 5d. Deriving this from the table means adding a
# BLK with a longer FDAYS can't silently leave an OGCM download short.
max_fdays_for_ogcm() {
  local ogcm="$1" combos_file="$2"
  # ⚠ A failure inside `< <(...)` process substitution does NOT propagate to this
  # function's exit status or trip `set -e` in the caller — a missing/unreadable
  # combos_file would otherwise fall straight through to the `echo "$max"` below and
  # return "0" silently (confirmed on mims3 via code review, 2026-08-03). A caller
  # doing `FDAYS="$(max_fdays_for_ogcm HYCOM "$COMBOS_FILE")"` would then pass
  # `--fdays 0` to a download CLI instead of erroring — exactly the silent
  # boundary-data-truncation failure D14's own comment warns about. So check
  # readability up front, and treat "zero rows matched" (e.g. a typo'd OGCM) the same
  # way — both are genuine breakage, not "not yet" (D4).
  if [ ! -r "$combos_file" ]; then
    echo "max_fdays_for_ogcm: combos file not readable: $combos_file" >&2
    return 1
  fi
  local max="0" row_domain row_ogcm row_blk f
  while read -r row_domain row_ogcm row_blk; do
    [ -z "$row_domain" ] && continue
    [ "$row_ogcm" = "$ogcm" ] || continue
    f="$(fdays_for_blk "$row_blk")"
    awk -v a="$f" -v b="$max" 'BEGIN{exit !(a>b)}' && max="$f"
  done < <(grep -Ev '^[[:space:]]*(#|$)' "$combos_file")
  if [ "$max" = "0" ]; then
    echo "max_fdays_for_ogcm: no combos_croco.txt rows found for OGCM '$ogcm'" >&2
    return 1
  fi
  echo "$max"
}
