#!/usr/bin/env bash
# my_env.sh — resolved defaults for ONE combo run (D11).
#
# ⚠ ONE FRESH PROCESS PER COMBO. Source this after lib/common.sh (set -u is active).
# Never `source my_env.sh` twice in the same shell for different combos — every guard
# below is `${VAR:-default}`, which only fires on unset/empty, so a second sourcing
# inherits the first combo's exported values. Always invoke as:
#   DOMAIN=... OGCM=... BLK=... bash some_script.sh
# not a loop that exports and re-sources in one process (see run_all_combos.sh).
#
# Layers combo-specific derivation on top of lib/cycle_env.sh's cycle-level defaults
# (roots, hosts, RUN_DATE) — download scripts and other cycle-level stages source
# cycle_env.sh directly and never need DOMAIN/OGCM/BLK (D12: downloads are cycle-level,
# shared across both domains).
#
# Inputs, all optional (an unset workflow_call input arrives as ''; ${VAR:-default}
# treats unset and empty the same, so GitHub Actions defaults and prompt defaults
# resolve identically — D1):
#   DOMAIN, OGCM, BLK, RUN_DATE

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/cycle_env.sh"

# --- inputs -------------------------------------------------------------------
DOMAIN="${DOMAIN:-}"
OGCM="${OGCM:-}"
BLK="${BLK:-}"

# --- validate every row before acting (D11 robustness guard) -------------------
: "${DOMAIN:?DOMAIN must be set (sa_west_02 | sa_southeast_01)}"
: "${OGCM:?OGCM must be set (MERCATOR | HYCOM)}"
: "${BLK:?BLK must be set (GFS | SAWS)}"

case "$DOMAIN" in
  sa_west_02|sa_southeast_01) ;;
  *) echo "my_env.sh: unknown DOMAIN '$DOMAIN'" >&2; exit 1 ;;
esac
case "$OGCM" in
  MERCATOR|HYCOM) ;;
  *) echo "my_env.sh: unknown OGCM '$OGCM'" >&2; exit 1 ;;
esac
case "$BLK" in
  GFS|SAWS) ;;
  *) echo "my_env.sh: unknown BLK '$BLK'" >&2; exit 1 ;;
esac

# --- model identifiers, identical across all 8 combos (§7.3) -------------------
MODEL="croco_v1.3.1"
VERSION="v1.0"
COMP="C06"
INP="I99"
TIDE_FRC="TPXO10"

# --- derived from BLK: a property of BLK, not of the combination (D11) ----------
FDAYS="$(fdays_for_blk "$BLK")"

# --- derived from DOMAIN (§7.4) -------------------------------------------------
case "$DOMAIN" in
  sa_west_02)
    ARCHIVE_NAME="sa-west"
    MPI_NUM_X=5
    MPI_NUM_Y=18
    CLIM_FILE="${PUBLIC_ROOT}/sa-west/v1.0/hindcasts/GLORYS-ERA5/climatology/monthly_climatology.nc"
    ;;
  sa_southeast_01)
    ARCHIVE_NAME="sa-southeast"
    MPI_NUM_X=6
    MPI_NUM_Y=4
    CLIM_FILE=""                                # no anomalies outside sa-west
    ;;
esac
CROCO_MPI_NUM_PROCS=$(( MPI_NUM_X * MPI_NUM_Y ))

RUN_NAME="${COMP}_${INP}_${OGCM}_${BLK}_${TIDE_FRC}"
COMBO_KEY="${OGCM}-${BLK}"

# --- restart fallback (D13) -----------------------------------------------------
RST_FALLBACK_BLK="${RST_FALLBACK_BLK:-GFS}"

# --- D12 layout: read-only configs, per-cycle data, compile every cycle --------
CONFIG_DIR="${CROCO_REPO}/configs/${DOMAIN}/${MODEL}"
DOMAIN_DIR="${CYCLE_DIR}/${DOMAIN}/croco_ops"
COMPILE_DIR="${DOMAIN_DIR}/${COMP}"
CROCO_BIN="${COMPILE_DIR}/croco"                 # per-cycle copy IS the compile gate
BRY_INI_DIR="${DOMAIN_DIR}/${OGCM}"
TIDE_DIR="${DOMAIN_DIR}/${TIDE_FRC}"
RUN_DIR="${DOMAIN_DIR}/${RUN_NAME}"
SCRATCH_DIR="${RUN_DIR}/scratch"
OUTPUT_DIR="${RUN_DIR}/output"

# --- archive roots (§7.6) --------------------------------------------------------
PUBLIC_CYCLE_DIR="${PUBLIC_ROOT}/${ARCHIVE_NAME}/${VERSION}/forecasts/${RUN_DATE}/${COMBO_KEY}"
PUBLIC_LATEST_DIR="${PUBLIC_ROOT}/${ARCHIVE_NAME}/${VERSION}/forecasts/latest/${COMBO_KEY}"
SAFE_DIR="${SAFE_ROOT}/${ARCHIVE_NAME}/${VERSION}/forecasts/${YM}/${RUN_DATE}/${COMBO_KEY}"

print_env_banner
