#!/usr/bin/env bash
# lib/cycle_env.sh — defaults for everything that runs ONCE PER CYCLE, not once per
# combo (D12: downloads are cycle-level — one bbox covers both domains, so they sit
# outside any DOMAIN — and shared by every combo that runs that cycle).
#
# Sourced directly by download/*.sh and postprocess/build_latest_downloads.sh, which
# have no DOMAIN/OGCM/BLK to resolve. my_env.sh also sources this and layers
# combo-specific derivation on top, so there is exactly one definition of every
# cycle-level path — the same "one implementation" principle D11 applies to combos
# applies one level down, to the cycle itself.
#
# Source after lib/common.sh (set -u is active).

RUN_DATE="${RUN_DATE:-$(date -u +%Y%m%d)_00}"   # D15 — today's 00Z, not a nearest-12h
                                                 # guess; a Persistent=true timer
                                                 # catching up after 12:00 UTC must
                                                 # still run the 00Z cycle.

# --- the three D23 bring-up roots — the ONLY overrides cutover has to delete -------
DATA_DIR="${DATA_DIR:-/home/somisana/ops/main}"
PUBLIC_ROOT="${PUBLIC_ROOT:-/mnt/ocims-somisana/public-facing}"
SAFE_ROOT="${SAFE_ROOT:-/mnt/somisana_safe/models}"

# --- hosts / tooling (§7.2; confirmed on mims3 2026-08-03 — see plan §7.9) ---------
CROCO_REPO="${CROCO_REPO:-/home/somisana/code/somisana-croco}"
CROCO_SOURCE="${CROCO_SOURCE:-/home/${USER}/code/croco-v1.3.1/OCEAN/}"
CONDA_HOOK="${CONDA_HOOK:-/home/somisana/miniforge3/etc/profile.d/conda.sh}"
CROCO_ENV="${CROCO_ENV:-somisana_croco}"
DOWNLOAD_REPO="${DOWNLOAD_REPO:-/home/somisana/code/somisana-download}"
DOWNLOAD_ENV="${DOWNLOAD_ENV:-download}"
OPS_REPO="${OPS_REPO:-/home/somisana/code/somisana-ops}"
TPXO_DATA_DIR="${TPXO_DATA_DIR:-/home/somisana/data/TPXO10}"
SAWS_SOURCE_DIR="${SAWS_SOURCE_DIR:-/mnt/saws-data/ocims}"

# --- saeonapps-only paths (D14 hop; not present/used on mims3) ---------------------
MERCATOR_STAGING_DIR="${MERCATOR_STAGING_DIR:-/home/giles/mercator_download}"
SHARED_MOUNT_WRITE="${SHARED_MOUNT_WRITE:-/mnt/somisana/data/shared}"   # saeonapps side
SHARED_MOUNT_READ="${SHARED_MOUNT_READ:-/mnt/saeon-somisana/data/shared}"  # mims3 side

YORIG="2000"
HDAYS="0"                                       # D5 — raw archive only, no ncks

# --- download bbox (§7.5) — all sources, covers both domains ----------------------
DOWNLOAD_BBOX="${DOWNLOAD_BBOX:-11,36,-39,-25}"

# --- cycle-level layout (D12) -------------------------------------------------------
CYCLE_DIR="${DATA_DIR}/${RUN_DATE}"
DOWNLOADS_DIR="${CYCLE_DIR}/downloads"
YM="${RUN_DATE:0:6}"

# --- forcing archive roots (§7.6, D20) ----------------------------------------------
FORCING_CYCLE_DIR="${PUBLIC_ROOT}/sa-forcing/${RUN_DATE}"       # + /SOURCE
FORCING_SAFE_DIR="${SAFE_ROOT}/sa-forcing/${YM}/${RUN_DATE}"    # + /SOURCE
FORCING_LATEST_DIR="${PUBLIC_ROOT}/sa-forcing/latest"           # + /SOURCE, D20

# --- locks (D3) ----------------------------------------------------------------------
LOCK_DIR="${LOCK_DIR:-${DATA_DIR}/locks}"

# --- the operational matrix (D11) — read by max_fdays_for_ogcm (D14) --------------
COMBOS_FILE="${COMBOS_FILE:-${OPS_REPO}/combos_croco.txt}"

# --- CROCO ONLINE forcing variable sets (§7.5) ---------------------------------------
# One definition each, shared by download_GFS.sh and download_SAWS.sh (which both
# gate on GFS_VARS — download_GFS.sh on its own output, download_SAWS.sh on its
# --backupDir dependency) so the two can't drift apart (code review, 2026-08-03).
GFS_VARS=(
  Temperature_height_above_ground
  Specific_humidity
  Precipitation_rate
  Downward_Short-Wave_Rad_Flux_surface
  Upward_Short-Wave_Rad_Flux_surface
  Downward_Long-Wave_Rad_Flux
  Upward_Long-Wave_Rad_Flux_surface
  U-component_of_wind
  V-component_of_wind
  patm
)

# reformat_saws_atm writes 9 of the 10 — everything except patm, which SAWS doesn't
# provide and isn't in its existsSAWS/backfill variable dict at all (confirmed by
# reading crocotools_py/preprocess.py's reformat_saws_atm, 2026-08-03).
SAWS_VARS=(
  Temperature_height_above_ground
  U-component_of_wind
  V-component_of_wind
  Specific_humidity
  Precipitation_rate
  Downward_Short-Wave_Rad_Flux_surface
  Upward_Short-Wave_Rad_Flux_surface
  Downward_Long-Wave_Rad_Flux
  Upward_Long-Wave_Rad_Flux_surface
)
