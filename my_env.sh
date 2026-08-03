#!/usr/bin/env bash
# my_env.sh — resolved defaults for ONE run (D11).
#
# ⚠ ONE FRESH PROCESS PER COMBO. Source this after lib/common.sh (set -u is active).
# Never `source my_env.sh` twice in the same shell for different combos — every guard
# below is `${VAR:-default}`, which only fires on unset/empty, so a second sourcing
# inherits the first combo's exported values. Always invoke as:
#   DOMAIN=... OGCM=... BLK=... bash some_script.sh
# not a loop that exports and re-sources in one process (see run_all_combos.sh).
#
# Inputs, all optional (an unset workflow_call input arrives as ''; ${VAR:-default}
# treats unset and empty the same, so GitHub Actions defaults and prompt defaults
# resolve identically — D1):
#   DOMAIN, OGCM, BLK, RUN_DATE

# --- inputs -------------------------------------------------------------------
DOMAIN="${DOMAIN:-}"
OGCM="${OGCM:-}"
BLK="${BLK:-}"
RUN_DATE="${RUN_DATE:-$(date -u +%Y%m%d)_00}"   # today's 00Z (D15) — not oceanmotion's
                                                 # nearest-12h auto-compute; a
                                                 # Persistent=true timer catching up
                                                 # after 12:00 UTC must still run the
                                                 # 00Z cycle, not chase an unpublished 12Z.

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

# --- the three D23 bring-up roots — the ONLY overrides cutover has to delete ----
DATA_DIR="${DATA_DIR:-/home/somisana/ops/main}"
PUBLIC_ROOT="${PUBLIC_ROOT:-/mnt/ocims-somisana/public-facing}"
SAFE_ROOT="${SAFE_ROOT:-/mnt/somisana_safe/models}"

# --- model identifiers, identical across all 8 combos (§7.3) -------------------
MODEL="croco_v1.3.1"
VERSION="v1.0"
COMP="C06"
INP="I99"
TIDE_FRC="TPXO10"
YORIG="2000"
HDAYS="0"                                       # D5 — raw archive only, no ncks

# --- derived from BLK: a property of BLK, not of the combination (D11) ----------
case "$BLK" in
  SAWS) FDAYS="2.45" ;;
  GFS)  FDAYS="5" ;;
esac

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

# --- hosts / tooling (§7.2, confirmed on mims3 2026-08-03) ----------------------
CROCO_REPO="${CROCO_REPO:-/home/somisana/code/somisana-croco}"
CROCO_SOURCE="${CROCO_SOURCE:-/home/${USER}/code/croco-v1.3.1/OCEAN/}"
CONDA_HOOK="${CONDA_HOOK:-/home/somisana/miniforge3/etc/profile.d/conda.sh}"
CROCO_ENV="${CROCO_ENV:-somisana_croco}"
DOWNLOAD_REPO="${DOWNLOAD_REPO:-/home/somisana/code/somisana-download}"
DOWNLOAD_ENV="${DOWNLOAD_ENV:-download}"
OPS_REPO="${OPS_REPO:-/home/somisana/code/somisana-ops}"
TPXO_DATA_DIR="${TPXO_DATA_DIR:-/home/somisana/data/TPXO10}"
SAWS_SOURCE_DIR="${SAWS_SOURCE_DIR:-/mnt/saws-data/ocims}"

# --- D12 layout: read-only configs, per-cycle data, compile every cycle --------
CONFIG_DIR="${CROCO_REPO}/configs/${DOMAIN}/${MODEL}"
CYCLE_DIR="${DATA_DIR}/${RUN_DATE}"
DOWNLOADS_DIR="${CYCLE_DIR}/downloads"           # cycle-level, shared by both domains
DOMAIN_DIR="${CYCLE_DIR}/${DOMAIN}/croco_ops"
COMPILE_DIR="${DOMAIN_DIR}/${COMP}"
CROCO_BIN="${COMPILE_DIR}/croco"                 # per-cycle copy IS the compile gate
BRY_INI_DIR="${DOMAIN_DIR}/${OGCM}"
TIDE_DIR="${DOMAIN_DIR}/${TIDE_FRC}"
RUN_DIR="${DOMAIN_DIR}/${RUN_NAME}"
SCRATCH_DIR="${RUN_DIR}/scratch"
OUTPUT_DIR="${RUN_DIR}/output"

# --- archive roots (§7.6) --------------------------------------------------------
YM="${RUN_DATE:0:6}"
PUBLIC_CYCLE_DIR="${PUBLIC_ROOT}/${ARCHIVE_NAME}/${VERSION}/forecasts/${RUN_DATE}/${COMBO_KEY}"
PUBLIC_LATEST_DIR="${PUBLIC_ROOT}/${ARCHIVE_NAME}/${VERSION}/forecasts/latest/${COMBO_KEY}"
SAFE_DIR="${SAFE_ROOT}/${ARCHIVE_NAME}/${VERSION}/forecasts/${YM}/${RUN_DATE}/${COMBO_KEY}"
FORCING_CYCLE_DIR="${PUBLIC_ROOT}/sa-forcing/${RUN_DATE}"       # per SOURCE subdir
FORCING_SAFE_DIR="${SAFE_ROOT}/sa-forcing/${YM}/${RUN_DATE}"
FORCING_LATEST_DIR="${PUBLIC_ROOT}/sa-forcing/latest"           # per SOURCE subdir, D20

# --- locks (D3, D17) --------------------------------------------------------------
LOCK_DIR="${LOCK_DIR:-${DATA_DIR}/locks}"

print_env_banner
