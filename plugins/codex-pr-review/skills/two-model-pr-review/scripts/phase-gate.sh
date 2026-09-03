#!/bin/bash
# phase-gate.sh — the join gates of the two-model review.
#
#   phase-gate.sh pre-codex  <ART> <REPO>   may Codex (and the lead) be launched?   (Phase 0 end)
#   phase-gate.sh pre-phase3 <ART>          may Codex output be read?               (Phase 3 start)
#   phase-gate.sh post-join  <ART>          did the run stay consistent?            (completion gate)
#
# pre-codex  : 00-brief.md and 00-scope.md exist, the brief never names the run directory, the
#              worktree snapshot (if any) still resolves, every 01-lead*.md present is SEALED
#              (mode 000), and the sha256 of both packets is recorded ONCE (later calls compare).
# pre-phase3 : 01-lead.md exists, is non-empty and sealed; 02-codex.md is non-empty and ends with a
#              Phase 2 STATUS line; for the COMPLETE form 02-codex.exit exists (the SKIPPED form —
#              probe failed, declined, unavailable — has no runner sidecars); hashes unchanged.
# post-join  : hashes unchanged; 01-lead.md non-empty and ending with STATUS: PHASE 1 COMPLETE (any
#              mode: Phase 3 unseals it); 02-codex.md ends with its STATUS line.
# Exit 0 gate passed (one PREFLIGHT-OK / JOIN-OK / POST-JOIN-OK line) · 1 gate failed (one-line
# reason) · 2 usage.
set -u
USAGE='usage: phase-gate.sh pre-codex <ART> <REPO> | phase-gate.sh pre-phase3 <ART> | phase-gate.sh post-join <ART>'
die2() { echo "phase-gate.sh: $1" >&2; echo "$USAGE" >&2; exit 2; }
CMD="${1:-}"; ART="${2:-}"; REPO="${3:-}"
case "$CMD" in
  pre-codex)  [ $# -eq 3 ] || die2 "pre-codex takes <ART> <REPO>";;
  pre-phase3|post-join) [ $# -eq 2 ] || die2 "$CMD takes <ART>";;
  *) die2 "unknown or missing subcommand '${CMD}'";;
esac
[ -d "$ART" ] || die2 "run directory not found: $ART"
ART="$(cd "$ART" && pwd -P)"   # absolute: the brief is grepped for this path, and "." would match everything
fail() { echo "GATE FAILED ($CMD): $1"; exit 1; }
mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }
lastline() { awk 'NF{l=$0} END{print l}' "$1"; }   # last non-blank line
sha() {
  local h=""
  h=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1" 2>/dev/null) \
    || h=$(shasum -a 256 "$1" 2>/dev/null | awk '{print $1}') \
    || h=$(sha256sum "$1" 2>/dev/null | awk '{print $1}')
  case "$h" in *[!0-9a-f]*|"") return 1;; esac
  [ "${#h}" -eq 64 ] || return 1
  printf '%s\n' "$h"
}
# record-once: the first pre-codex call writes <file>.sha256; every later call compares, never rewrites.
hashcheck() {
  local f="$ART/$1" h
  [ -s "$f" ] || fail "$1 missing or empty"
  h=$(sha "$f") || fail "cannot hash $1 (python3, shasum and sha256sum all unavailable or failed)"
  if [ -s "$f.sha256" ]; then
    [ "$(cat "$f.sha256")" = "$h" ] || fail "$1 changed since its hash was recorded (packets are frozen once Codex is launched; run records belong in 00-run.md; otherwise start a fresh run directory)"
  else
    [ "$CMD" = "pre-codex" ] || fail "no recorded hash for $1 (pre-codex never ran in this directory)"
    printf '%s\n' "$h" > "$f.sha256"
  fi
}
codex_status() {  # sets ST=COMPLETE|SKIPPED, or fails (no subshell: fail must reach the caller)
  local last
  [ -s "$ART/02-codex.md" ] || fail "02-codex.md missing: write the Phase 2 artifact (outcome, command, meta, STATUS) first"
  last=$(lastline "$ART/02-codex.md")
  case "$last" in
    "STATUS: PHASE 2 COMPLETE") ST=COMPLETE;;
    "STATUS: PHASE 2 COMPLETE (SKIPPED — "*")") ST=SKIPPED;;
    *) fail "02-codex.md does not end with a Phase 2 STATUS line (last non-blank line: ${last:0:80})";;
  esac
}
case "$CMD" in
pre-codex)
  [ -s "$ART/00-brief.md" ] || fail "00-brief.md missing or empty: build the brief before launching Codex"
  [ -s "$ART/00-scope.md" ] || fail "00-scope.md missing or empty"
  grep -q -F -- "$ART" "$ART/00-brief.md" && fail "00-brief.md mentions the run directory; it must never reach Codex"
  if [ -s "$ART/00-brief.md.tree" ]; then
    git -C "$REPO" cat-file -e "$(cat "$ART/00-brief.md.tree")^{tree}" 2>/dev/null || fail "snapshot tree $(cat "$ART/00-brief.md.tree") no longer resolves in $REPO; recapture"
  fi
  LEAD=absent
  for f in "$ART"/01-lead*.md; do
    [ -e "$f" ] || continue
    [ "$(mode "$f")" = "0" ] || fail "$(basename "$f") exists and is not sealed (mode $(mode "$f")); chmod 000 it or remove it before launching Codex"
    LEAD=sealed
  done
  hashcheck 00-brief.md; hashcheck 00-scope.md
  echo "PREFLIGHT-OK lead=$LEAD brief=$(cut -c1-12 "$ART/00-brief.md.sha256") scope=$(cut -c1-12 "$ART/00-scope.md.sha256")"
  ;;
pre-phase3)
  [ -e "$ART/01-lead.md" ] || fail "01-lead.md missing: run Phase 1 in-context BEFORE opening any Codex output file"
  [ -s "$ART/01-lead.md" ] || fail "01-lead.md is empty"
  [ "$(mode "$ART/01-lead.md")" = "0" ] || fail "01-lead.md is not sealed (mode $(mode "$ART/01-lead.md")): it must stay mode 000 until this gate passes"
  codex_status
  if [ "$ST" = COMPLETE ]; then
    [ -s "$ART/02-codex.exit" ] || fail "02-codex.exit missing: the Codex phase has not finished"
    CX=$(cat "$ART/02-codex.exit")
  else CX=skipped; fi
  hashcheck 00-brief.md; hashcheck 00-scope.md
  echo "JOIN-OK lead=sealed codex=$ST codex_exit=$CX brief=$(cut -c1-12 "$ART/00-brief.md.sha256") scope=$(cut -c1-12 "$ART/00-scope.md.sha256")"
  ;;
post-join)
  hashcheck 00-brief.md; hashcheck 00-scope.md
  [ -s "$ART/01-lead.md" ] || fail "01-lead.md missing or empty"
  [ -r "$ART/01-lead.md" ] || fail "01-lead.md is still sealed (mode $(mode "$ART/01-lead.md")); Phase 3 restores it to 600"
  L=$(lastline "$ART/01-lead.md")
  [ "$L" = "STATUS: PHASE 1 COMPLETE" ] || fail "01-lead.md does not end with STATUS: PHASE 1 COMPLETE (last non-blank line: ${L:0:80})"
  codex_status
  echo "POST-JOIN-OK lead=complete codex=$ST brief=$(cut -c1-12 "$ART/00-brief.md.sha256") scope=$(cut -c1-12 "$ART/00-scope.md.sha256")"
  ;;
esac
exit 0
