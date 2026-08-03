#!/usr/bin/env bash
# download/collect_MERCATOR.sh — mims3-side half of the saeonapps hop (D14): copy the
# already-downloaded MERCATOR file from the shared Samba mount into this cycle's
# DOWNLOADS_DIR, where the rest of the pipeline expects to find it alongside
# GFS/HYCOM/SAWS. Two jobs, two gates, as today (D14) — this one only ever reads.
#
# ⚠ The shared mount has different paths on the two hosts (§7.5) — this reads from
# SHARED_MOUNT_READ (mims3's mount point), NOT SHARED_MOUNT_WRITE (saeonapps' own,
# used by download_MERCATOR.sh). Easy to get backwards since it's the same physical
# share.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/lock.sh"
source "$ROOT/lib/gates.sh"
source "$ROOT/lib/cycle_env.sh"

SHARED_FILE="${SHARED_MOUNT_READ}/MERCATOR_${RUN_DATE}.nc"
MERCATOR_DIR="${DOWNLOADS_DIR}/MERCATOR"
LOCAL_FILE="${MERCATOR_DIR}/MERCATOR_${RUN_DATE}.nc"

if archived "$SHARED_FILE" "$LOCAL_FILE"; then
  log "MERCATOR already collected for ${RUN_DATE} — skipping"
  exit 0
fi

if ! is_done "$SHARED_FILE"; then
  log "MERCATOR not yet on the shared mount ($SHARED_FILE) — skipping"
  exit 0   # saeonapps hasn't finished (or hasn't started) this cycle's download
fi

with_lock MERCATOR || exit 0

mkdir -p "$MERCATOR_DIR"

log "collecting MERCATOR from shared mount: $SHARED_FILE -> $LOCAL_FILE"
tmp_file="${LOCAL_FILE}.partial"
cp "$SHARED_FILE" "$tmp_file"
mv "$tmp_file" "$LOCAL_FILE"   # atomic commit (D4) — the mv IS the success signal

if ! archived "$SHARED_FILE" "$LOCAL_FILE"; then
  log "collect completed but sizes don't match: $SHARED_FILE vs $LOCAL_FILE"
  exit 1
fi
log "MERCATOR collected for ${RUN_DATE}"
