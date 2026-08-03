#!/usr/bin/env bash
# lib/gates.sh — shared is_done()/inputs_ready() predicates (D4).
#
# The SAME predicates answer "should I run this?" (dispatch.sh, pipelines) and
# "should this already be finished?" (check_cycle.sh) — D16's promise that the 12:00
# completeness check is the gate logic inverted only holds if there is one
# implementation. Add new gates here, not duplicated in the script that needs them.
#
# Two hard rules (D4):
#   1. "Not yet" is a normal, silent state (exit 0) — only genuine breakage is
#      non-zero. Getting this backwards produces junk emails until notifications get
#      muted, and the one real failure a month goes unseen.
#   2. Gate archive presence on SIZE, not just existence: `rsync --inplace` (used
#      because the network mount can't reliably overwrite/unlink) writes bytes
#      straight into the destination rather than temp-then-rename, so an interrupted
#      first write leaves a truncated file at the canonical name that would pass a
#      plain `[ -f ]` check forever.

# is_done <path> — plain presence gate, for local stage outputs written atomically
# (scratch/ then mv into place) — D4's rule 2 doesn't apply to these in the rsync
# sense. But crocotools_py's reformat functions write straight to the final filename
# (`ds.to_netcdf(fname_out)`, no temp-then-rename) rather than via scratch/, so a
# process killed mid-write leaves a real 0-byte or partial file at that path — the
# same class of trap D4's rsync rule exists for, just via a different write pattern.
# `[ -s ]` (exists AND non-empty) catches the 0-byte case for free at zero extra cost
# — confirmed against a real reproduction on mims3, 2026-08-03 (a killed SAWS reformat
# left an empty file that a plain `[ -f ]` would have read as "done" forever).
#
# ⚠ Residual gap: this does NOT catch a file that was killed after writing SOME real
# bytes but before finishing — a non-empty-but-truncated netCDF. Closing that fully
# would need real content validation (e.g. opening the file), which is a meaningfully
# heavier check to run on every gate lookup. Accepted for now; revisit if a truncated
# (not just empty) forcing file is ever actually seen in production.
is_done() {
  [ -s "$1" ]
}

# archived <src> <dst> — the archive gate (D4): dst must exist AND match src's size.
archived() {
  local src="$1" dst="$2"
  [ -f "$dst" ] && [ "$(stat -c%s "$src")" = "$(stat -c%s "$dst")" ]
}

# newer_than <a> <b> — local-file recency gate (D17): true if $a exists and is newer
# than $b. E.g. "is latest/ current?" == newer_than latest/croco_avg.nc <newest
# per-cycle file that EXISTS> — deliberately the newest EXISTING file, not "this
# cycle's" file, so a failed cycle reads as a clean skip rather than a false rebuild
# (D17's warning).
newer_than() {
  local a="$1" b="$2"
  [ -f "$a" ] && [ "$a" -nt "$b" ]
}

# all_done <dir> <var1> [var2 ...] — true iff every "${dir}/${var}_Y9999M1.nc" exists.
#
# ⚠ Confirmed the hard way on mims3 (2026-08-03): a reformat step that writes one file
# per variable can be killed partway through, leaving an early variable's file
# complete while later ones are still missing. Gating on a SINGLE sentinel file from
# a multi-file output is D4's truncated-file trap wearing a different hat — a partial
# run's first-written file passes `[ -f ]` forever and gets read back as "done".
# Always gate multi-file reformat output on the WHOLE expected set, not one name.
all_done() {
  local dir="$1"; shift
  local v
  for v in "$@"; do
    is_done "${dir}/${v}_Y9999M1.nc" || return 1
  done
}
