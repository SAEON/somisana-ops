#!/usr/bin/env bash
# lib/lock.sh — resource-scoped flock helpers (D3).
#
# One lock per contended resource — model.lock, postprocess.lock, download_<SOURCE>.lock
# — never one global lock. GFS downloading while CROCO runs is fine; they don't contend.
#
# The lock IN THE SCRIPT is authoritative; a dispatcher-side check is only an
# optimisation — there's an unavoidable multi-second window between the dispatcher's
# check and the runner starting, and the dispatcher can't see a script being run by
# hand at a prompt. Worst case with the script-side lock: an occasional extra green
# "skipped" run.
#
# Usage:
#   source lib/lock.sh
#   with_lock model || exit 0   # held -> "skip", not a failure (D4)
#   ... do work ...
#   # lock releases automatically when the process exits (fd 9 closes)

with_lock() {
  local name="$1"
  local lock_file="${LOCK_DIR:?LOCK_DIR not set}/${name}.lock"
  mkdir -p "$(dirname "$lock_file")"
  exec 9>"$lock_file"
  if ! flock -n 9; then
    log "${name}.lock held — skipping"
    return 1
  fi
  log "${name}.lock acquired"
  return 0
}
