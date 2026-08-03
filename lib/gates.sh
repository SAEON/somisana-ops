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
# (scratch/ then mv into place) — D4's rule 2 doesn't apply to these.
is_done() {
  [ -f "$1" ]
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
