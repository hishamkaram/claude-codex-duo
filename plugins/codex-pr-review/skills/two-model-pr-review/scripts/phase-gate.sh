#!/bin/bash
# phase-gate.sh — state gates for the two-model review.
#
#   phase-gate.sh pre-codex       <ART> <REPO>
#   phase-gate.sh pre-phase3      <ART>
#   phase-gate.sh pre-consultation <ART>
#   phase-gate.sh pre-verification <ART>
#   phase-gate.sh pre-resolution  <ART>
#   phase-gate.sh pre-report      <ART>
#   phase-gate.sh post-join       <ART>       # legacy initial-packet consistency check
#
# Every gate rechecks the frozen scope and blind brief, then verifies the accept
# ledger (00-accepted.sha256): every artifact a gate has accepted or generated is
# recorded there once and may never change afterwards. Launch gates take an
# atomic claim as their last step. See SKILL.md §Phase gate.
set -u
USAGE='usage: phase-gate.sh pre-codex <ART> <REPO> | phase-gate.sh pre-phase3|pre-consultation|pre-verification|pre-resolution|pre-report|post-join <ART> | phase-gate.sh release <ART> <prefix>'
die2() { echo "phase-gate.sh: $1" >&2; echo "$USAGE" >&2; exit 2; }
CMD="${1:-}"; ART="${2:-}"; REPO="${3:-}"
case "$CMD" in
  pre-codex) [ $# -eq 3 ] || die2 "pre-codex takes <ART> <REPO>";;
  pre-phase3|pre-consultation|pre-verification|pre-resolution|pre-report|post-join) [ $# -eq 2 ] || die2 "$CMD takes <ART>";;
  release) [ $# -eq 3 ] || die2 "release takes <ART> <prefix>";;
  *) die2 "unknown or missing subcommand '${CMD}'";;
esac
[ -d "$ART" ] || die2 "run directory not found: $ART"
ART="$(cd "$ART" && pwd -P)"
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
VALIDATOR="$ROOT/scripts/validate-consultation.py"
PACKET_VALIDATOR="$ROOT/scripts/validate-verifier-packets.py"
VERDICT_VALIDATOR="$ROOT/scripts/validate-verdicts.py"
PACKET_BUILDER="$ROOT/scripts/build-verifier-packets.py"
LEDGER="$ART/00-accepted.sha256"
# One scratch file for every validator dry run in this call; allocation failure
# is a gate failure, never a silently-unusable response (round-37 CX-02).
SCRATCH=$(mktemp "${TMPDIR:-/tmp}/phase-gate.XXXXXX") || { echo "GATE FAILED ($CMD): cannot allocate a scratch file in ${TMPDIR:-/tmp}" >&2; exit 1; }
LEAD_WAS_SEALED=0   # set by unseal_lead_for_hash, cleared by reseal_lead_after_hash; on_exit reseals the lead if a hashing helper failed in between
HELD_LOCK=""        # claim lock held by claim_lock, released by claim_unlock or on_exit
PKT_TMP=""          # packet build/recheck scratch file, removed by on_exit on any failure
on_exit() { rm -f "$SCRATCH" "$PKT_TMP" 2>/dev/null; [ -z "$HELD_LOCK" ] || rmdir "$HELD_LOCK" 2>/dev/null; [ "$LEAD_WAS_SEALED" = 1 ] && chmod 000 "$ART/01-lead.md" 2>/dev/null; :; }
trap on_exit EXIT
# A launch claim whose runner has not yet written .progress is still in flight
# for this long (the gate -> runner handoff is seconds, but a consent prompt can
# hold the launch for minutes) (round-26 CX-01, round-27 debate C-11).
CLAIM_GRACE_SEC="${PHASE_GATE_CLAIM_GRACE_SEC:-600}"
CLAIM_TOKEN=""
fail() { echo "GATE FAILED ($CMD): $1"; exit 1; }
if stat --version >/dev/null 2>&1; then mode() { stat -c '%a' "$1" 2>/dev/null; }; mtime() { stat -c '%Y' "$1" 2>/dev/null; }
else mode() { stat -f '%Lp' "$1" 2>/dev/null; }; mtime() { stat -f '%m' "$1" 2>/dev/null; }; fi
lastline() { awk 'NF{l=$0} END{print l}' "$1"; }
sha() {
  local h=""
  h=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1" 2>/dev/null) \
    || h=$(shasum -a 256 "$1" 2>/dev/null | awk '{print $1}') \
    || h=$(sha256sum "$1" 2>/dev/null | awk '{print $1}')
  case "$h" in *[!0-9a-f]*|"") return 1;; esac
  [ "${#h}" -eq 64 ] || return 1
  printf '%s\n' "$h"
}
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
phase_status() {
  local file="$1" phase="$2" last
  [ -s "$ART/$file" ] || fail "$file missing or empty"
  last=$(lastline "$ART/$file")
  case "$last" in
    "STATUS: PHASE $phase COMPLETE") PST=COMPLETE;;
    "STATUS: PHASE $phase COMPLETE (SKIPPED — "*")") PST=SKIPPED;;
    *) fail "$file does not end with a Phase $phase STATUS line (last non-blank line: ${last:0:80})";;
  esac
}
# A phase may be recorded SKIPPED only when no attempt of it succeeded with a
# usable response (round-30 CX-01/CX-02): the blind review has no response
# validator, so any exit-0 attempt makes it un-skippable; an exchange phase may
# be skipped over an exit-0 attempt only if that attempt's stdout fails the
# response validator (the documented malformed-response fallback).
reject_skip_over_success() {  # reject_skip_over_success <prefix> [validator args...]
  local prefix="$1" f stem stdout tmp; shift
  shopt -s nullglob
  for f in "$ART/$prefix.exit" "$ART/$prefix".attempt*.exit; do
    [ -s "$f" ] && [ "$(cat "$f")" = 0 ] || continue
    stem="${f%.exit}"; stdout="$stem.stdout"
    # exit 0 with an empty response is a failed attempt (round-31 L-01).
    [ -s "$stdout" ] || continue
    if [ $# -eq 0 ]; then
      shopt -u nullglob; fail "$prefix.md is SKIPPED but attempt $(basename "$stem") succeeded (exit 0, non-empty response); write the terminal artifact from that attempt instead of skipping it"
    fi
    if attempt_usable "$prefix" "$stem" "$@"; then
      shopt -u nullglob
      fail "$prefix.md is SKIPPED but attempt $(basename "$stem") succeeded with a valid response on the expected thread; accept it (write the terminal artifact from it) instead of skipping"
    fi
  done
  shopt -u nullglob
}
codex_status() {
  phase_status 02-codex.md 2
  ST=$PST
  # An exit-5 / unconfirmed-cancel sidecar on the initial review (current or
  # rotated) means a Codex worker may still be alive, whether the phase was
  # then recorded COMPLETE by a later attempt or SKIPPED (round-19 CX-01).
  reject_unconfirmed_cancel 02-codex
  if [ "$ST" = COMPLETE ]; then
    [ -s "$ART/02-codex.exit" ] || fail "02-codex.exit missing: the Codex phase has not finished"
    CX=$(cat "$ART/02-codex.exit")
    [ "$CX" = 0 ] || fail "02-codex.exit must be 0 for a completed blind review (got $CX)"
    [ -s "$ART/02-codex.stdout" ] || fail "02-codex.stdout is empty: an empty response is not a completed blind review; record Phase 2 SKIPPED (empty response) or relaunch"
  else
    CX=skipped
  fi
}
initial_packets() { hashcheck 00-brief.md; hashcheck 00-scope.md; }
# The seal attests the join for BOTH Phase-2 outcomes: a COMPLETE review hashes
# the raw Codex body, a SKIPPED one hashes the status file itself, so a later
# status edit or seal deletion is detectable either way (round-22 CX-02).
seal_contents() {
  local destination="$1" codex_file
  printf 'phase2=%s\n' "$ST" > "$destination"
  sha "$ART/01-lead.md" >> "$destination" || return 1
  printf '  01-lead.md\n' >> "$destination"
  if [ "$ST" = COMPLETE ]; then codex_file=02-codex.stdout; else codex_file=02-codex.md; fi
  sha "$ART/$codex_file" >> "$destination" || return 1
  printf '  %s\n' "$codex_file" >> "$destination"
}
# 01-lead.md may still be mode-000 sealed (defense-in-depth against Codex
# reading it before JOIN-OK). Hashing it needs owner-read; these two helpers
# briefly restore that, then reseal it the same way, even on failure.
unseal_lead_for_hash() {
  LEAD_WAS_SEALED=0
  case "$(mode "$ART/01-lead.md" 2>/dev/null)" in
    0|000)
      chmod 400 "$ART/01-lead.md" || fail "could not unseal 01-lead.md to compute review seal"
      LEAD_WAS_SEALED=1  # on_exit reseals it if this call fails before reseal_lead_after_hash
      ;;
  esac
}
reseal_lead_after_hash() {
  if [ "$LEAD_WAS_SEALED" = 1 ]; then chmod 000 "$ART/01-lead.md"; LEAD_WAS_SEALED=0; fi
}
review_seal() {
  local seal="$ART/02-review-seal.sha256" tmp sealed_phase
  [ -s "$seal" ] || fail "02-review-seal.sha256 missing: run pre-consultation after JOIN-OK"
  [ -r "$seal" ] || fail "02-review-seal.sha256 is unreadable"
  case "$(mode "$seal")" in 400|440|444) ;; *) fail "02-review-seal.sha256 must be read-only (mode $(mode "$seal"))";; esac
  sealed_phase=$(awk -F= '$1 == "phase2" {print $2; exit}' "$seal")
  case "$sealed_phase" in COMPLETE|SKIPPED) ;; *) fail "02-review-seal.sha256 does not attest to a terminal blind Codex review (phase2=${sealed_phase:-missing})";; esac
  [ "$ST" = "$sealed_phase" ] || fail "02-codex.md status changed after JOIN-OK (sealed=$sealed_phase current=$ST)"
  unseal_lead_for_hash
  tmp=$(mktemp "$ART/.review-seal.XXXXXX") || { reseal_lead_after_hash; fail "could not allocate review-seal scratch file"; }
  seal_contents "$tmp" || { rm -f "$tmp"; reseal_lead_after_hash; fail "cannot hash initial review bodies"; }
  cmp -s "$seal" "$tmp" || { rm -f "$tmp"; reseal_lead_after_hash; fail "initial review bodies changed since JOIN-OK"; }
  rm -f "$tmp"
  reseal_lead_after_hash
}
# ---- Accept ledger (round-27 debate, amended option B) -------------------
# 00-accepted.sha256 (mode 400, rewritten atomically) holds one row per accepted
# artifact: "<sha256>  <artifact>  <gate>  <final|draft>". Every gate verifies
# every row on entry (accepted_check). A FINAL row never changes. A DRAFT row
# (orchestrator-authored or regenerated inputs) may be replaced only by the gate
# that accepted it and only while no artifact of a later phase exists — the
# selector may be corrected before consultation launches, never after. Rows
# are never removed once final, and a draft row is retired only by its gate
# inside the same window; a missing ledger once post-join artifacts exist is fatal.
# Generated artifacts (review seal, consultation/resolution JSON, verifier
# packets) are regenerated and compared by the gate that owns them, then their
# digests are accepted like any other artifact.
KNOWN_GATES=" pre-phase3 pre-consultation pre-verification pre-resolution pre-report "
later_artifacts() {  # glob prefixes of artifacts that only exist once a later phase began
  case "$1" in
    pre-phase3) echo "03- 04- 05- 06- 07-";;  # the seal itself is minted before the ledger exists (round-40 CX-01)
    pre-consultation) echo "04-consultation.md 04-consultation.progress 04-consultation.stdout 04-consultation.stderr 04-consultation.exit 04-consultation.meta 04-consultation.attempt 04-consultation.thread 04-consultation.json 05- 06- 07-";;
    pre-verification) echo "05-verification.md 05-verdicts.tsv 06- 07-";;
    pre-resolution) echo "06-resolution.md 06-resolution.progress 06-resolution.stdout 06-resolution.stderr 06-resolution.exit 06-resolution.meta 06-resolution.attempt 06-resolution.json 07-";;
    pre-report) echo "07-";;
    *) echo "";;
  esac
}
later_artifact_exists() {  # later_artifact_exists <gate> [artifact being accepted, ignored]
  local p f
  shopt -s nullglob
  for p in $(later_artifacts "$1"); do
    for f in "$ART/$p"*; do [ -e "$f" ] && [ "$f" != "$ART/${2:-}" ] && { shopt -u nullglob; return 0; }; done
  done
  shopt -u nullglob; return 1
}
write_review_seal() {  # pre-phase3: mint the seal once; on re-entry regenerate and compare
  local seal="$ART/02-review-seal.sha256" tmp
  [ ! -e "$seal" ] || { review_seal; return; }
  unseal_lead_for_hash
  [ -s "$ART/01-lead.md" ] || { reseal_lead_after_hash; fail "01-lead.md missing or empty"; }
  if [ "$ST" = COMPLETE ]; then [ -s "$ART/02-codex.stdout" ] || { reseal_lead_after_hash; fail "02-codex.stdout missing or empty"; }; fi
  tmp=$(mktemp "$ART/.review-seal.XXXXXX") || { reseal_lead_after_hash; fail "could not allocate review-seal scratch file"; }
  seal_contents "$tmp" || { rm -f "$tmp"; reseal_lead_after_hash; fail "cannot hash initial review bodies"; }
  chmod 400 "$tmp" || { rm -f "$tmp"; reseal_lead_after_hash; fail "could not make review seal read-only"; }
  mv "$tmp" "$seal" || { rm -f "$tmp"; reseal_lead_after_hash; fail "could not install review seal"; }
  reseal_lead_after_hash
}
ledger_row() { awk -v n="$1" '$2 == n {print; exit}' "$LEDGER" 2>/dev/null; }
repo_field() { sed -n "s/^$1=//p" "$ART/00-repo.txt" 2>/dev/null | head -1; }
# The frozen brief's Target section is the one record of what Codex reviewed;
# 00-repo.txt must restate it, at pre-codex (from the builder's sidecars), at
# the join (before it is accepted) and at every later gate (round-38 CX-02).
brief_target() {  # brief_target repo|base|head
  case "$1" in
    repo) sed -n 's/^- Repository: //p' "$ART/00-brief.md" 2>/dev/null | head -1;;
    base) sed -n 's/^- Base: `[^`]*` (\([0-9a-f]\{40\}\))$/\1/p' "$ART/00-brief.md" 2>/dev/null | head -1;;
    head) sed -n 's/^- Head: `[^`]*` (\([0-9a-f]\{40\}\))$/\1/p' "$ART/00-brief.md" 2>/dev/null | head -1;;
  esac
}
repo_check() {  # repo_check file|sidecars: 00-repo.txt (or 00-brief.md.repo/.base/.head) must equal the brief's Target
  local f b r
  for f in repo base head; do
    b=$(brief_target "$f"); [ -n "$b" ] || fail "00-brief.md has no Target $f line (- Repository: / - Base: / - Head:): build the brief with build-brief.sh"
    if [ "$1" = sidecars ]; then r=$(cat "$ART/00-brief.md.$f" 2>/dev/null); else r=$(repo_field "$f"); fi
    [ "$r" = "$b" ] || fail "recorded $f ($r) differs from the frozen brief's Target $f ($b): citation checks must pin the repository and revisions Codex reviewed (start a fresh run directory)"
  done
}
accepted_check() {
  local digest name gate kind seen=" " skip
  if [ ! -e "$LEDGER" ]; then
    ! later_artifact_exists pre-phase3 || fail "00-accepted.sha256 is missing but post-join artifacts exist; the accept ledger was removed (start a fresh run directory)"
    return 0
  fi
  [ -s "$LEDGER" ] || fail "00-accepted.sha256 is empty"
  case "$(mode "$LEDGER")" in 400|440|444) ;; *) fail "00-accepted.sha256 must be read-only (mode $(mode "$LEDGER"))";; esac
  while read -r digest name gate kind; do
    [ -n "$digest" ] || continue
    case "$digest" in *[!0-9a-f]*) fail "00-accepted.sha256 has a malformed row ($digest $name)";; esac
    [ "${#digest}" -eq 64 ] || fail "00-accepted.sha256 has a malformed row ($digest $name)"
    case "$name" in [0-9][0-9]-*) ;; *) fail "00-accepted.sha256 has a malformed row ($digest $name)";; esac
    case "$name" in */*) fail "00-accepted.sha256 has a malformed row ($digest $name)";; esac
    case "$KNOWN_GATES" in *" $gate "*) ;; *) fail "00-accepted.sha256 names an unknown gate for $name (${gate:-missing})";; esac
    case "$kind" in final|draft) ;; *) fail "00-accepted.sha256 has a malformed row for $name (kind ${kind:-missing})";; esac
    case "$seen" in *" $name "*) fail "00-accepted.sha256 lists $name twice";; esac
    seen="$seen$name "
    # A draft row owned by this gate is re-acceptable while its phase is still
    # open; anything else must be exactly as accepted.
    skip=0
    if [ "$kind" = draft ] && [ "$gate" = "$CMD" ] && ! later_artifact_exists "$CMD"; then skip=1; fi
    [ "$skip" = 1 ] && continue
    [ -e "$ART/$name" ] || fail "$name was accepted by $gate but is missing"
    [ "$(sha "$ART/$name")" = "$digest" ] || fail "$name changed after it was accepted by $gate"
  done < "$LEDGER"
}
accept() {  # accept <artifact> final|draft   (gate = $CMD)
  local name="$1" kind="${2:-final}" digest row tmp
  [ -e "$ART/$name" ] || fail "$name missing: cannot accept it"
  digest=$(sha "$ART/$name") || fail "cannot hash $name"
  row=$(ledger_row "$name")
  if [ -n "$row" ]; then
    set -- $row
    [ "$1" != "$digest" ] || return 0
    [ "$4" = draft ] && [ "$3" = "$CMD" ] && ! later_artifact_exists "$CMD" "$name" || fail "$name changed after it was accepted by $3"
  elif later_artifact_exists "$CMD" "$name"; then
    fail "$name was never accepted by $CMD but later-phase artifacts exist (start a fresh run directory)"
  fi
  tmp=$(mktemp "$ART/.accepted.XXXXXX") || fail "could not allocate ledger scratch file"
  { [ -s "$LEDGER" ] && awk -v n="$name" '$2 != n' "$LEDGER"; printf '%s  %s  %s  %s\n' "$digest" "$name" "$CMD" "$kind"; } > "$tmp"
  chmod 400 "$tmp" || { rm -f "$tmp"; fail "could not make the accept ledger read-only"; }
  mv -f "$tmp" "$LEDGER" || { rm -f "$tmp"; fail "could not install the accept ledger"; }
}
retire() {  # retire <artifact>: drop a draft row of this gate whose artifact was legitimately removed
  local name="$1" row tmp
  row=$(ledger_row "$name"); [ -n "$row" ] || return 0
  set -- $row
  [ "$4" = draft ] && [ "$3" = "$CMD" ] && ! later_artifact_exists "$CMD" || fail "$name was accepted by $3 but is missing"
  tmp=$(mktemp "$ART/.accepted.XXXXXX") || fail "could not allocate ledger scratch file"
  awk -v n="$name" '$2 != n' "$LEDGER" > "$tmp"
  chmod 400 "$tmp" || { rm -f "$tmp"; fail "could not make the accept ledger read-only"; }
  mv -f "$tmp" "$LEDGER" || { rm -f "$tmp"; fail "could not install the accept ledger"; }
}
selection_count() {
  local selection="$ART/03-debate-selection.tsv" count
  [ -x "$VALIDATOR" ] || { printf 'consultation validator missing or not executable: %s\n' "$VALIDATOR" >&2; return 1; }
  count=$(python3 "$VALIDATOR" --manifest "$ART/03-matrix.tsv" --selection "$selection" --validate-selection) || return 1
  case "$count" in
    OK\ selected=[0-9]*) ;;
    *) printf 'consultation validator returned an invalid count: %s\n' "$count" >&2; return 1;;
  esac
  printf '%s\n' "${count#OK selected=}"
}
# The claim a runner took (<prefix>.claim/runner, or a rotated
# <prefix>.claim.spentN/runner) is the ONE record of a launch (round-32
# debate): the runner creates it atomically before it writes anything, spent
# claims are never deleted, and the sidecars are derived from it. A sidecar
# attempt slot (.meta, .exit or .progress, current or rotated) without a
# runner-taken claim means a runner was launched without the gate (or a claim
# was deleted) and is fatal in every gate.
runner_count() {  # launches of <prefix> = claims a runner took
  local prefix="$1" d n=0
  shopt -s nullglob
  for d in "$ART/$prefix.claim" "$ART/$prefix".claim.spent*; do [ -d "$d/runner" ] && n=$((n+1)); done
  shopt -u nullglob
  printf '%s\n' "$n"
}
sidecar_slots() {
  local prefix="$1" f
  shopt -s nullglob
  for f in "$ART/$prefix".meta "$ART/$prefix".exit "$ART/$prefix".progress "$ART/$prefix".attempt*.meta "$ART/$prefix".attempt*.exit "$ART/$prefix".attempt*.progress; do
    [ -e "$f" ] && printf '%s\n' "${f%.*}"
  done | sort -u | wc -l | tr -d ' '
  shopt -u nullglob
}
# A runner that took a claim and has not finished (no <prefix>.exit) is in
# flight: no later gate may advance past its phase, whatever the phase's
# terminal artifact says (round-36 CX-01). Recovery is `release`.
live_claim_check() {
  local prefix
  for prefix in 02-codex 04-consultation 06-resolution; do
    if [ -d "$ART/$prefix.claim/runner" ] && [ ! -e "$ART/$prefix.exit" ]; then
      fail "$prefix runner is still in flight ($prefix.claim/runner exists and $prefix.exit does not): wait for it, or if it is dead run phase-gate.sh release $ART $prefix — a phase cannot be recorded or advanced past while its runner may still write"
    fi
  done
}
launch_records_check() {
  local prefix slots taken
  for prefix in 02-codex 04-consultation 06-resolution; do
    slots=$(sidecar_slots "$prefix"); taken=$(runner_count "$prefix")
    [ "$slots" -le "$taken" ] || fail "$prefix has sidecars for $slots attempt(s) but only $taken claim(s) taken by a runner: a runner was launched without the gate's claim (always pass --claim) or a claim directory was deleted (never remove $prefix.claim*; use phase-gate.sh release); a lone attemptN.exit=4 with no claim is a claim-less argument error — the runner no longer writes one when a claim exists, but an older one can only be resolved by a fresh run directory"
  done
}
# A usable response is an exit-0 attempt whose stdout is non-empty and, for
# the exchange phases, passes the response validator when its inputs exist
# (round-36 CX-05): an empty or malformed exit-0 body is a failed attempt — it
# consumed a launch, never a response, and never blocks a relaunch.
validator_args() {  # validator_args <prefix>: prints the response-validator arguments when the phase's inputs exist
  case "$1" in
    04-consultation) [ -s "$ART/03-matrix.tsv" ] && [ -s "$ART/03-debate-selection.tsv" ] && printf '%s\n' --manifest "$ART/03-matrix.tsv" --selection "$ART/03-debate-selection.tsv" --phase consultation;;
    06-resolution) [ -s "$ART/03-matrix.tsv" ] && [ -s "$ART/05-verdicts.tsv" ] && [ -s "$ART/06-resolution-selection.ids" ] && printf '%s\n' --manifest "$ART/03-matrix.tsv" --verdicts "$ART/05-verdicts.tsv" --ids "$ART/06-resolution-selection.ids" --phase resolution;;
  esac
  return 0
}
# attempt_usable <prefix> <attempt-stem> [validator args...]: exit 0, a
# non-empty body that passes the validator (when its inputs exist), and — for
# a --resume-last exchange — the expected Codex thread (round-37 CX-04): a
# valid answer on the wrong thread is a failed attempt, so it neither blocks
# the documented --fresh retry nor forbids a skip.
attempt_usable() {
  local prefix="$1" stem="$2" mode_val actual expected; shift 2
  [ -s "$stem.exit" ] && [ "$(cat "$stem.exit")" = 0 ] || return 1
  [ -s "$stem.stdout" ] || return 1
  if [ $# -gt 0 ]; then
    python3 "$VALIDATOR" "$@" --extract "$stem.stdout" --out "$SCRATCH" >/dev/null 2>&1 || return 1
  fi
  case "$prefix" in 04-consultation|06-resolution) ;; *) return 0;; esac
  # An exchange whose runner could not record its Codex thread (thread=unknown)
  # can never be anchored or accepted, so it is a failed attempt: the skip and
  # --fresh relaunch paths stay open instead of dead-ending (round-39 CL-02).
  actual=$(awk -F= '$1 == "thread" {print $2; exit}' "$stem.meta" 2>/dev/null)
  [ "$actual" != unknown ] || return 1
  mode_val=$(awk -F= '$1 == "mode" {print $2; exit}' "$stem.meta" 2>/dev/null)
  if [ -z "$mode_val" ]; then  # same fallback as check_thread: the command's second token
    set -- $(awk -F= '$1 == "command" {sub(/^[^=]*=/, ""); print; exit}' "$stem.meta" 2>/dev/null); mode_val=${2:-}
  fi
  case "$mode_val" in
    --fresh) return 0;;
    --resume-last)
      expected=$(expected_thread 2>/dev/null) || return 1
      [ "$actual" = "$expected" ];;
    *) return 1;;
  esac
}
usable_count() {  # usable_count <prefix>; runs the validator once per attempt per gate call — bounded (at most 5 attempts per phase, milliseconds each)
  local prefix="$1" n=0 f line
  local -a args=()
  while IFS= read -r line; do args+=("$line"); done < <(validator_args "$prefix")  # one argument per line: paths may contain spaces (round-38 CX-05)
  shopt -s nullglob
  for f in "$ART/$prefix.exit" "$ART/$prefix".attempt*.exit; do
    attempt_usable "$prefix" "${f%.exit}" ${args[@]+"${args[@]}"} && n=$((n+1))
  done
  shopt -u nullglob
  printf '%s\n' "$n"
}
response_count() { printf '%s\n' "$(( $(usable_count 04-consultation) + $(usable_count 06-resolution) ))"; }
expected_thread() {
  local anchor="$ART/04-consultation.thread" expected
  if [ -s "$anchor" ]; then cat "$anchor"; return; fi
  expected=$(awk -F= '$1 == "thread" {print $2; exit}' "$ART/02-codex.meta")
  [ -n "$expected" ] && [ "$expected" != unknown ] || { printf '%s\n' "Phase-2 Codex thread is unavailable" >&2; return 1; }
  printf '%s\n' "$expected"
}
check_thread() {
  local prefix="$1" expected actual command mode_val
  # Prefer the runner's explicit mode= field; fall back to the command's second
  # token. Never substring-match the whole command: a prompt path could contain
  # " --fresh " (round-17 CX-06).
  mode_val=$(awk -F= '$1 == "mode" {print $2; exit}' "$ART/$prefix.meta")
  if [ -z "$mode_val" ]; then
    command=$(awk -F= '$1 == "command" {sub(/^[^=]*=/, ""); print; exit}' "$ART/$prefix.meta")
    set -- $command; mode_val=${2:-}
  fi
  case "$mode_val" in
    --fresh) return 0;; # A documented self-contained retry cannot preserve thread continuity (and needs no prior thread).
    --resume-last) ;;
    *) fail "$prefix.meta records no recognisable launch mode (mode=${mode_val:-missing})";;
  esac
  expected=$(expected_thread) || fail "cannot determine expected Codex thread"
  actual=$(awk -F= '$1 == "thread" {print $2; exit}' "$ART/$prefix.meta")
  [ "$actual" = "$expected" ] || fail "$prefix resumed unexpected Codex thread (wanted $expected, got ${actual:-missing})"
}
write_thread_anchor() {
  local thread temporary
  thread=$(awk -F= '$1 == "thread" {print $2; exit}' "$ART/04-consultation.meta")
  [ -n "$thread" ] && [ "$thread" != unknown ] || fail "04-consultation.meta has no accepted Codex thread"
  temporary=$(mktemp "$ART/.consultation-thread.XXXXXX") || fail "could not allocate consultation thread scratch file"
  printf '%s\n' "$thread" > "$temporary"
  chmod 400 "$temporary" || { rm -f "$temporary"; fail "could not make consultation thread anchor read-only"; }
  mv "$temporary" "$ART/04-consultation.thread" || { rm -f "$temporary"; fail "could not install consultation thread anchor"; }
}
check_budget() {
  local attempts responses phase4 phase6
  attempts=$(( $(runner_count 04-consultation) + $(runner_count 06-resolution) ))
  responses=$(response_count)
  phase4=$(sidecar_success_count 04-consultation)
  phase6=$(sidecar_success_count 06-resolution)
  [ "$attempts" -le 4 ] || fail "Codex exchange attempt cap exceeded ($attempts > 4)"
  [ "$responses" -le 2 ] || fail "Codex successful-response cap exceeded ($responses > 2)"
  [ "$phase4" -le 1 ] || fail "consultation successful-response cap exceeded ($phase4 > 1)"
  [ "$phase6" -le 1 ] || fail "resolution successful-response cap exceeded ($phase6 > 1)"
}
sidecar_success_count() { usable_count "$1"; }
# Residual selector check shared by pre-resolution and pre-report: every ID in
# 06-resolution-selection.ids must be in the matrix and marked UNVERIFIABLE in
# 05-verdicts.tsv. CONFLICT is a Phase-3 origin, never a Phase-5 verdict, so
# it is not a residual state (round-15 L-03).
validate_residual_ids() {  # the same check the response validator applies (--ids), so the rule exists once
  python3 "$VALIDATOR" --manifest "$ART/03-matrix.tsv" --verdicts "$ART/05-verdicts.tsv" --ids "$ART/06-resolution-selection.ids" --validate-selection >/dev/null 2>&1
}
# Number of Phase-5 verdicts still UNVERIFIABLE (column-based, comment-safe).
residual_count() {
  python3 - "$ART/05-verdicts.tsv" <<'PYRES'
import sys
n = 0
for line in open(sys.argv[1]):
    line = line.strip()
    if not line or line.startswith("#"): continue
    parts = line.split("\t")
    if len(parts) >= 2 and parts[1].strip() == "UNVERIFIABLE": n += 1
print(n)
PYRES
}
# Phase-3 base packets: one strict normalized packet per matrix ID, the input
# every later packet is built from. Validated before it is frozen.
validate_base_findings() {
  [ -x "$PACKET_VALIDATOR" ] || fail "verifier packet validator missing or not executable: $PACKET_VALIDATOR"
  [ -f "$ART/03-findings.ndjson" ] || fail "03-findings.ndjson missing: write the normalized base packet for every 03-matrix.tsv ID before pre-consultation"
  python3 "$PACKET_VALIDATOR" --matrix "$ART/03-matrix.tsv" --packets "$ART/03-findings.ndjson" --match-matrix-severity >/dev/null || fail "03-findings.ndjson is invalid (one provenance-free normalized packet per matrix ID, severity equal to the matrix's, is required)"
}
# 05-verifier-packets.ndjson is generated, never hand-written: the frozen base
# packets with the validated consultation dispositions applied by
# build-verifier-packets.py (round-26 CX-03). pre-verification writes it;
# every later gate rebuilds it and rejects any difference, so the verifiers
# saw exactly what the consultation produced.
build_packets() {  # build_packets <out> ; uses $ST and $consultation
  local out="$1"
  [ -x "$PACKET_BUILDER" ] || fail "verifier packet builder missing or not executable: $PACKET_BUILDER"
  if [ "$ST" = COMPLETE ] && [ "$consultation" = COMPLETE ]; then
    [ -s "$ART/04-consultation.json" ] || fail "04-consultation.json missing after completed consultation"
    python3 "$PACKET_BUILDER" --matrix "$ART/03-matrix.tsv" --base "$ART/03-findings.ndjson" --consultation "$ART/04-consultation.json" --out "$out" >/dev/null || fail "could not build verifier packets from 03-findings.ndjson and 04-consultation.json"
  else
    python3 "$PACKET_BUILDER" --matrix "$ART/03-matrix.tsv" --base "$ART/03-findings.ndjson" --out "$out" >/dev/null || fail "could not build verifier packets from 03-findings.ndjson"
  fi
}
check_packets() {  # the installed packet file must equal a fresh rebuild
  local rebuilt
  [ -s "$ART/05-verifier-packets.ndjson" ] || fail "05-verifier-packets.ndjson missing: pre-verification generates it from 03-findings.ndjson and the consultation response"
  python3 "$PACKET_VALIDATOR" --matrix "$ART/03-matrix.tsv" --packets "$ART/05-verifier-packets.ndjson" >/dev/null || fail "Phase-5 verifier packet set is invalid"
  rebuilt=$(mktemp "$ART/.packets-recheck.XXXXXX") || fail "could not allocate packet recheck file"
  PKT_TMP="$rebuilt"
  build_packets "$rebuilt"
  cmp -s "$rebuilt" "$ART/05-verifier-packets.ndjson" || { rm -f "$rebuilt"; fail "05-verifier-packets.ndjson differs from the packets built from 03-findings.ndjson and the consultation response (it is generated by pre-verification and never edited; a mismatch after Phase 5 began means the consultation's terminal status or the base packets were changed after acceptance, which the gates forbid — start a fresh run directory)"; }
  rm -f "$rebuilt"; PKT_TMP=""
}
write_packets() {  # pre-verification: install the generated packets, or verify an existing copy
  local built
  if [ -e "$ART/05-verifier-packets.ndjson" ]; then check_packets; return; fi
  built=$(mktemp "$ART/.packets-build.XXXXXX") || fail "could not allocate packet build file"
  PKT_TMP="$built"
  build_packets "$built"
  chmod 444 "$built" 2>/dev/null
  mv "$built" "$ART/05-verifier-packets.ndjson" || { rm -f "$built"; fail "could not install 05-verifier-packets.ndjson"; }
  PKT_TMP=""
}
# A launch gate must never authorize a second launch for a phase that already
# has its terminal artifact or an accepted (exit 0) current attempt — e.g. the
# orchestrator died between the runner finishing and the .md being written.
# Resume by writing the terminal artifact from the existing sidecars instead
# (round-24 CX-01).
refuse_relaunch() {  # refuse_relaunch <prefix> <terminal.md> <next-gate>
  local prefix="$1" terminal="$2" next="$3"
  [ ! -e "$ART/$terminal" ] || fail "$terminal already exists: this phase is terminal; run $next instead of relaunching Codex"
  if [ "$(sidecar_success_count "$prefix")" -gt 0 ]; then
    fail "$prefix has a usable response (exit 0 with a valid body, current or rotated) with no $terminal yet; write $terminal from the existing sidecars instead of relaunching Codex"
  fi
}
# Atomic per-phase launch claim (round-25 CX-02, simplified by the round-27
# debate): a launch gate's LAST step creates <prefix>.claim/ with mkdir (atomic
# on every POSIX filesystem), so no failed check can leave a claim behind. The
# claim is in flight — and a second caller fails instead of launching a
# duplicate — while its attempt has neither finished (<prefix>.exit) nor produced
# the terminal artifact AND either the runner has started (<prefix>.claim/runner,
# taken by the runner before it writes anything, or <prefix>.progress) or
# the claim directory is younger than CLAIM_GRACE_SEC (the gate exits before the
# runner starts; a directory with no owner file yet is a claim being created).
# No pid heuristics. A spent claim is rotated to <prefix>.claim.spentN, at most
# CLAIM_SPENT_MAX of them. Recovery beyond the grace window is explicit: remove
# <prefix>.claim/ only after confirming that launcher, its runner and its Codex
# job are all dead.
CLAIM_SPENT_MAX=9
# Rotating or creating a claim and a runner taking one are serialized by
# <prefix>.claim.lock (an atomic mkdir held for milliseconds), so a runner can
# never take a claim the gate is rotating out from under it (round-38 CX-03).
# The runner uses the same lock. A lock older than CLAIM_LOCK_STALE_SEC belongs
# to a dead process and is reclaimed.
CLAIM_LOCK_STALE_SEC=60
claim_lock() {  # claim_lock <prefix>
  local lock="$ART/$1.claim.lock" i=0 now
  while ! mkdir "$lock" 2>/dev/null; do
    now=$(date +%s)
    if [ $(( now - $(mtime "$lock" || echo "$now") )) -ge "$CLAIM_LOCK_STALE_SEC" ] && rmdir "$lock" 2>/dev/null; then continue; fi  # an unremovable stale lock is retried like a held one (bounded)
    i=$((i+1)); [ "$i" -lt 50 ] || fail "$1.claim.lock is held by another launcher or runner (a claim is being taken or rotated right now), or is stale and cannot be removed (is it empty?); retry in a moment"
    sleep 0.1
  done
  HELD_LOCK="$lock"
}
claim_unlock() { [ -z "$HELD_LOCK" ] || rmdir "$HELD_LOCK" 2>/dev/null; HELD_LOCK=""; }
rotate_claim() {  # rotate_claim <prefix>: <prefix>.claim -> <prefix>.claim.spentN (never deleted; a runner-taken one stays a counted launch)
  local prefix="$1" claim="$ART/$1.claim" n=1
  while [ -e "$claim.spent$n" ]; do n=$((n+1)); done
  [ "$n" -le "$CLAIM_SPENT_MAX" ] || fail "$prefix has $CLAIM_SPENT_MAX spent claims already ($prefix.claim.spent1..$CLAIM_SPENT_MAX): this phase has been relaunched too often; start a fresh run directory"
  mv "$claim" "$claim.spent$n" || fail "could not rotate the spent $prefix claim"
  ROTATED_TO="$prefix.claim.spent$n"
}
# release <ART> <prefix>: the only recovery for a claim whose runner started
# and then died without writing <prefix>.exit. It never deletes: it proves the
# runner and its Codex job are dead, then rotates the claim to spent, where a
# runner-taken claim still counts as a launch (round-32 debate, X-10).
release_claim() {
  local prefix="$1" claim="$ART/$1.claim" pid job st root
  case "$prefix" in 02-codex|04-consultation|06-resolution) ;; *) fail "release: unknown phase prefix '$prefix'";; esac
  claim_lock "$prefix"
  [ -d "$claim" ] || fail "release: no live claim for $prefix (nothing to release)"
  [ ! -e "$ART/$prefix.exit" ] || fail "release: $prefix.exit exists, so that attempt finished; the next launch gate rotates the claim itself"
  pid=$(cat "$claim/runner/pid" 2>/dev/null || true)
  if [ -d "$claim/runner" ] && [ -z "$pid" ]; then
    # The runner records its pid right after the atomic mkdir; a runner/ with
    # no pid is a runner mid-acquisition unless it is old (round-37 CX-03).
    [ $(( $(date +%s) - $(mtime "$claim/runner" || date +%s) )) -ge 60 ] || fail "release: a runner is taking the $prefix claim right now (runner/ exists, pid not yet recorded); retry in a minute"
  fi
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then fail "release: runner $pid of $prefix is still alive"; fi
  job=$(grep -oE 'launched job=task-[a-z0-9-]+' "$ART/$prefix.progress" 2>/dev/null | head -1 | cut -d= -f2)
  if [ -n "$job" ] || [ -e "$ART/$prefix.progress" ]; then
    # A job was launched, or may have been (the runner creates .progress just
    # before `task` and records the job id just after it, so a runner killed in
    # between leaves .progress without an id — round-34 CX-01): the job must be
    # provably finished. Fail closed when the codex plugin cannot be asked.
    root=$(python3 -c 'import json,os,glob
p=os.path.expanduser("~/.claude/plugins/installed_plugins.json")
try: print(json.load(open(p))["plugins"]["codex@openai-codex"][0]["installPath"]); raise SystemExit
except Exception: pass
c=sorted(glob.glob(os.path.expanduser("~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs")))
print(os.path.dirname(os.path.dirname(c[-1])) if c else "")' 2>/dev/null)
    [ -n "$root" ] && [ -f "$root/scripts/codex-companion.mjs" ] || fail "release: cannot locate the codex plugin to check job ${job:-(unrecorded)}; refusing to release a claim whose job may be running"
    if [ -n "$job" ]; then
      st=$(node "$root/scripts/codex-companion.mjs" status "$job" --json 2>/dev/null | python3 -c 'import sys,json
try: d=json.load(sys.stdin); print((d.get("job") or {}).get("status") or "")
except Exception: print("")')
      case "$st" in completed|failed|cancelled|canceled) ;; *) fail "release: job $job status is '${st:-unknown}', not provably finished; cancel it first (node $root/scripts/codex-companion.mjs cancel $job)";; esac
      ! pgrep -f "task-worker.*--job-id $job" >/dev/null 2>&1 || fail "release: a worker process for job $job is still alive"
    else
      # No id recorded: any job still running in the reviewed repository could
      # be this claim's. Refuse while one exists; list them so the operator
      # can cancel the right one.
      live=$(node "$root/scripts/codex-companion.mjs" status --all --json 2>/dev/null | python3 -c 'import sys,json
repo=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: print("?"); raise SystemExit
import os
same=lambda a,b: os.path.realpath(a)==os.path.realpath(b)
print(" ".join(j.get("id","?") for j in (d.get("running") or []) if not repo or same(j.get("workspaceRoot") or "", repo)))' "$(repo_field repo)")
      [ -z "$live" ] || fail "release: $prefix.progress records no job id, and a Codex job is still running in the reviewed repository (${live}); cancel it first (node $root/scripts/codex-companion.mjs cancel <id>) or wait for it"
    fi
  fi
  rotate_claim "$prefix"
  printf 'released=%s\nreleased_by=phase-gate.sh release\njob=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${job:-none}" >> "$ART/$ROTATED_TO/owner" 2>/dev/null
  claim_unlock
  echo "RELEASED $prefix -> $ROTATED_TO launches=$(runner_count "$prefix")"
}
claim_in_flight_check() {  # claim_in_flight_check <prefix> <terminal.md>: read-only; fails while an authorized launch is in flight
  local prefix="$1" terminal="$2" claim="$ART/$1.claim" age=0 now
  if [ -d "$claim" ] && [ ! -e "$ART/$prefix.exit" ] && [ ! -e "$ART/$terminal" ]; then
    if [ -e "$ART/$prefix.progress" ] || [ -d "$claim/runner" ]; then
      fail "$prefix is already claimed and its runner has started ($prefix.claim/runner or $prefix.progress exists, no $prefix.exit; $(tr '\n' ' ' < "$claim/owner" 2>/dev/null)); if that runner and its Codex job are dead, run: phase-gate.sh release $ART $prefix — it verifies that and rotates the claim to a spent (still counted) launch; never remove the directory"
    fi
    now=$(date +%s); age=$(( now - $(mtime "$claim" || echo "$now") ))
    [ "$age" -ge "$CLAIM_GRACE_SEC" ] || fail "$prefix is already claimed and may still be launching (claimed ${age}s ago, grace ${CLAIM_GRACE_SEC}s; $(tr '\n' ' ' < "$claim/owner" 2>/dev/null)); wait for the runner to start or, if that launcher is dead, wait out the grace window (an unstarted claim is then reclaimed)"
  fi
}
claim_phase() {  # claim_phase <prefix> <terminal.md>
  local prefix="$1" terminal="$2" claim="$ART/$1.claim" n=1
  claim_lock "$prefix"
  claim_in_flight_check "$prefix" "$terminal"
  [ ! -d "$claim" ] || rotate_claim "$prefix"
  mkdir "$claim" 2>/dev/null || fail "$prefix was claimed concurrently by another launcher; do not launch"
  # The token binds one runner to THIS claim: the runner is launched with
  # --claim <token> and refuses a claim whose owner file does not carry it, so a
  # delayed runner cannot attach to a replacement claim (round-36 CX-03).
  CLAIM_TOKEN=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  printf 'pid=%s\nat=%s\ngate=%s\ntoken=%s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CMD" "$CLAIM_TOKEN" > "$claim/owner"
  claim_unlock
}
# budget_left: 0 while another exchange may launch (fewer than 4 runner-taken
# claims and fewer than 2 usable responses); otherwise 1. An exhausted budget is
# not a gate failure: the gate prints its OK line with budget=exhausted and no
# claim, and the orchestrator records the phase SKIPPED (round-38 CX-04).
budget_left() {
  [ $(( $(runner_count 04-consultation) + $(runner_count 06-resolution) )) -lt 4 ] && [ "$(response_count)" -lt 2 ]
}
# Validate the Phase-5 verdict ledger: one F-nn<TAB>verdict per matrix ID,
# verdict must be CONFIRMED, REFUTED, or UNVERIFIABLE. Called unconditionally
# in pre-resolution (not only when resolution runs) so the ledger is enforced
# in the common no-residual path too.
validate_verdicts() {
  local verdicts="$ART/05-verdicts.tsv" matrix="$ART/03-matrix.tsv"
  [ -e "$verdicts" ] || return 1  # must exist; may be empty if the matrix has no IDs
  [ -x "$VERDICT_VALIDATOR" ] || { printf 'verdict validator missing or not executable: %s\n' "$VERDICT_VALIDATOR" >&2; return 1; }
  # Citations must resolve in the reviewed repository (round-33 CX-01); the
  # repository path is recorded by pre-codex and accepted at the join.
  [ -s "$ART/00-repo.txt" ] || { printf '00-repo.txt missing: verdict citations cannot be resolved without the recorded repository\n' >&2; return 1; }
  set -- --matrix "$matrix" --verdicts "$verdicts" --repo "$(repo_field repo)" --head "$(repo_field head)" --base "$(repo_field base)"
  python3 "$VERDICT_VALIDATOR" "$@" >/dev/null || return 1
}
# Exit 5 means "DO NOT retry: a Codex worker may still be running" per the
# runner's exit table. Reject any sidecar (current or rotated) that records
# exit 5 or an unconfirmed cancel before allowing a downstream Codex launch.
reject_unconfirmed_cancel() {
  local prefix="$1" f exit_val cancel_val
  shopt -s nullglob
  for f in "$ART/$prefix.exit" "$ART/$prefix".attempt*.exit; do
    [ -s "$f" ] || continue
    exit_val=$(cat "$f" 2>/dev/null)
    [ "$exit_val" = 5 ] && fail "$prefix recorded exit 5 (unconfirmed cancel: a Codex worker may still be running; do not launch another)"
  done
  for f in "$ART/$prefix.meta" "$ART/$prefix".attempt*.meta; do
    [ -s "$f" ] || continue
    cancel_val=$(awk -F= '$1 == "cancel_confirmed" {print $2; exit}' "$f" 2>/dev/null)
    [ "$cancel_val" = "no" ] && fail "$prefix recorded cancel_confirmed=no (a Codex worker may still be running; do not launch another)"
  done
  shopt -u nullglob
}
# Every post-join gate: the review seal is a generated artifact — regenerate it
# from the CURRENT status and bodies and compare, so a status edit on
# 02-codex.md or a body edit is caught whichever branch the gate would take
# (round-22 CX-02). Its digest is a final ledger row, so a deleted seal is
# reported by accepted_check before this runs.
review_seal_check() {
  if [ ! -e "$ART/02-review-seal.sha256" ]; then
    # The seal is minted BEFORE the ledger is created, so a ledger without a
    # seal means the seal was removed after the join; a seal is minted once and
    # never regenerated (round-38 CX-01).
    [ ! -e "$LEDGER" ] || fail "00-accepted.sha256 exists but 02-review-seal.sha256 does not: the join was recorded and its seal removed; a seal is minted once and never regenerated (start a fresh run directory)"
    return 0
  fi
  if [ -z "$(ledger_row 02-review-seal.sha256)" ]; then
    # A seal with no row is a join interrupted between minting the seal and
    # recording it (round-40 CX-01). Only pre-phase3 completes it, and only
    # while nothing beyond the join exists (a later gate's ledger row implies a
    # later artifact). The seal is still verified against the bodies.
    if [ "$CMD" = pre-phase3 ] && ! later_artifact_exists pre-phase3; then
      review_seal; return 0
    fi
    fail "02-review-seal.sha256 exists but has no row in 00-accepted.sha256: if the join was interrupted and no later artifact exists, re-run pre-phase3 to complete it; otherwise its row was removed (start a fresh run directory)"
  fi
  # The repository attestation is part of the join (round-36 CX-02).
  [ -s "$ART/00-repo.txt" ] && [ -n "$(ledger_row 00-repo.txt)" ] || fail "00-repo.txt or its ledger row is missing after the join: citation checks would run unpinned (start a fresh run directory)"
  repo_check file
  review_seal
}
# Runs after the seal/ledger checks so tampering is reported first.
codex_skip_check() { [ "$ST" = COMPLETE ] || reject_skip_over_success 02-codex; }
# An accepted consultation response (final ledger rows) cannot later be
# recorded SKIPPED: that would discard dispositions the ledger holds (round-28 L-01).
reject_skipped_after_accept() {  # uses $consultation
  if [ "$consultation" = SKIPPED ]; then
    [ -z "$(ledger_row 04-consultation.stdout)" ] || fail "04-consultation.md is SKIPPED but the consultation response was already accepted (see 00-accepted.sha256); an accepted consultation cannot be skipped"
    reject_skip_over_success 04-consultation --manifest "$ART/03-matrix.tsv" --selection "$ART/03-debate-selection.tsv" --phase consultation
  fi
}
reject_resolution_skip_over_success() {  # uses $resolution; pre-report only
  if [ "$resolution" = SKIPPED ]; then
    [ -z "$(ledger_row 06-resolution.stdout)" ] || fail "06-resolution.md is SKIPPED but the resolution response was already accepted (see 00-accepted.sha256); an accepted resolution cannot be skipped"
    if [ -s "$ART/06-resolution-selection.ids" ]; then
      reject_skip_over_success 06-resolution --manifest "$ART/03-matrix.tsv" --verdicts "$ART/05-verdicts.tsv" --ids "$ART/06-resolution-selection.ids" --phase resolution
    else
      reject_skip_over_success 06-resolution
    fi
  fi
}
case "$CMD" in
release)
  [ -n "$REPO" ] || die2 "release takes <ART> <prefix>"
  release_claim "$REPO"
  ;;
pre-codex)
  [ -s "$ART/00-brief.md" ] || fail "00-brief.md missing or empty: build the brief before launching Codex"
  [ -s "$ART/00-scope.md" ] || fail "00-scope.md missing or empty"
  grep -q -F -- "$ART" "$ART/00-brief.md" && fail "00-brief.md mentions the run directory; it must never reach Codex"
  if [ -s "$ART/00-brief.md.tree" ]; then git -C "$REPO" cat-file -e "$(cat "$ART/00-brief.md.tree")^{tree}" 2>/dev/null || fail "snapshot tree $(cat "$ART/00-brief.md.tree") no longer resolves in $REPO; recapture"; fi
  # Record the reviewed repository and the two reviewed revisions so Phase-5
  # citations can be resolved and pinned by gates that take only <ART>
  # (round-33 CX-01, round-34 CX-02); accepted final at the join.
  [ -d "$REPO/.git" ] || git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || fail "repository not found: $REPO"
  [ -s "$ART/00-brief.md.base" ] && [ -s "$ART/00-brief.md.head" ] && [ -s "$ART/00-brief.md.repo" ] || fail "00-brief.md.repo / 00-brief.md.base / 00-brief.md.head missing: build the brief with build-brief.sh (they record the reviewed repository and revisions)"
  REPO_CANON=$(cd "$REPO" && pwd -P)
  [ "$REPO_CANON" = "$(cat "$ART/00-brief.md.repo")" ] || fail "repository $REPO_CANON differs from the one the brief was built for ($(cat "$ART/00-brief.md.repo")); Codex must review and the gates must verify the same repository (round-36 CX-06)"
  for r in base head; do git -C "$REPO" cat-file -e "$(cat "$ART/00-brief.md.$r")^{tree}" 2>/dev/null || fail "recorded $r revision $(cat "$ART/00-brief.md.$r") does not resolve in $REPO"; done
  # If a prior Phase 2 exists (a re-entry to pre-codex mid-run), check the
  # seal hasn't been tampered with; on a fresh directory this is a no-op.
  # Any prior Phase-2 attempt with an unconfirmed cancel is a hard stop, seal
  # or no seal (round-22 CX-01).
  reject_unconfirmed_cancel 02-codex
  if [ ! -s "$ART/02-codex.md" ] && [ -s "$ART/02-codex.exit" ] && [ "$(cat "$ART/02-codex.exit")" = 0 ] && [ -s "$ART/02-codex.stdout" ]; then
    fail "02-codex.exit records an accepted attempt with no 02-codex.md yet; write 02-codex.md from the existing sidecars instead of relaunching Codex"
  fi
  if [ -s "$ART/02-codex.md" ]; then
    # Re-entry with a terminal Phase 2: a joined run must still be consistent;
    # an unjoined COMPLETE review must not be silently redone (round-23 CX-03).
    # Only a SKIPPED, unjoined Phase 2 (probe failed, declined) may be retried.
    codex_status; accepted_check; launch_records_check; live_claim_check; review_seal_check; codex_skip_check
    [ ! -e "$ART/02-review-seal.sha256" ] || fail "this run is already joined (02-review-seal.sha256 exists, phase2=$ST); Phase 2 cannot be relaunched — continue from the next gate or start a fresh run directory"
    if [ "$ST" = COMPLETE ]; then
      fail "02-codex.md already records a completed blind review; run pre-phase3 (or start a fresh run directory) instead of relaunching Codex"
    fi
  fi
  LEAD=absent
  for f in "$ART"/01-lead*.md; do
    [ -e "$f" ] || continue
    [ "$(mode "$f")" = 0 ] || fail "$(basename "$f") exists and is not sealed (mode $(mode "$f")); chmod 000 it or remove it before launching Codex"
    LEAD=sealed
  done
  initial_packets
  repo_check sidecars  # after the hash check: the Target lines of the FROZEN brief are the pin (round-38 CX-02)
  # Written only once every check passed, so a refused re-entry never rewrites
  # it (round-36 CX-06); accepted final at the join.
  printf 'repo=%s\nbase=%s\nhead=%s\n' "$REPO_CANON" "$(cat "$ART/00-brief.md.base")" "$(cat "$ART/00-brief.md.head")" > "$ART/00-repo.txt" || fail "could not record the repository"
  claim_phase 02-codex 02-codex.md  # last: nothing after this can fail and leave a claim (round-27 CX-02)
  echo "PREFLIGHT-OK lead=$LEAD brief=$(cut -c1-12 "$ART/00-brief.md.sha256") scope=$(cut -c1-12 "$ART/00-scope.md.sha256") claim=$CLAIM_TOKEN"
  ;;
pre-phase3)
  [ -e "$ART/01-lead.md" ] || fail "01-lead.md missing: run Phase 1 in-context BEFORE opening any Codex output file"
  [ -s "$ART/01-lead.md" ] || fail "01-lead.md is empty"
  [ "$(mode "$ART/01-lead.md")" = 0 ] || fail "01-lead.md is not sealed (mode $(mode "$ART/01-lead.md")): it must stay mode 000 until this gate passes (mode 400 after an interrupted join means the seal hashing was cut short: chmod 000 it and re-run this gate)"
  codex_status; initial_packets; accepted_check; launch_records_check; live_claim_check; review_seal_check; codex_skip_check
  [ -s "$ART/00-repo.txt" ] || fail "00-repo.txt missing: pre-codex was not run in this directory (it records the reviewed repository for citation checks)"
  repo_check file
  # Seal first, ledger rows second: each step is atomic and re-entrant, so a
  # join interrupted anywhere is completed by running this gate again
  # (round-40 CX-01), while a ledger that exists without a seal still means removal.
  write_review_seal
  accept 00-repo.txt final
  accept 02-review-seal.sha256 final
  # seal= is the out-of-band pin of the join: 00-run.md records this line
  # verbatim, so a join re-minted over edited bodies (indistinguishable from a
  # never-joined directory by the files alone — round-41 CX-01/CL-Q1) shows as
  # a changed fingerprint against the run record.
  echo "JOIN-OK lead=sealed codex=$ST codex_exit=$CX brief=$(cut -c1-12 "$ART/00-brief.md.sha256") scope=$(cut -c1-12 "$ART/00-scope.md.sha256") seal=$(sha "$ART/02-review-seal.sha256" | cut -c1-12)"
  ;;
pre-consultation)
  phase_status 03-matrix.md 3
  # Phase 3 (reconciliation) has no SKIPPED form — it is always required.
  [ "$PST" = COMPLETE ] || fail "03-matrix.md was skipped; reconciliation is required"
  codex_status; initial_packets; accepted_check; launch_records_check; live_claim_check; review_seal_check; codex_skip_check
  [ -e "$ART/02-review-seal.sha256" ] || fail "02-review-seal.sha256 missing: run pre-phase3 after the join"
  # Never authorize a Phase-4 launch while an earlier attempt may still be
  # alive (round-21 CX-01).
  reject_unconfirmed_cancel 04-consultation
  reject_unconfirmed_cancel 06-resolution
  refuse_relaunch 04-consultation 04-consultation.md pre-verification
  # An authorized launch in flight freezes the drafts it was authorized against
  # (round-39/40 CL-01): check before any draft is (re-)accepted.
  claim_in_flight_check 04-consultation 04-consultation.md
  validate_base_findings
  candidates=$(selection_count) || fail "could not count selected findings"
  # The selector and base packets are drafts until a Phase-4 artifact exists.
  accept 03-matrix.tsv draft
  accept 03-matrix.md draft
  accept 03-debate-selection.tsv draft
  accept 03-findings.ndjson draft
  if [ "$ST" = COMPLETE ]; then
    check_budget
    BUDGET=""
    if [ "$candidates" -gt 0 ]; then if budget_left; then claim_phase 04-consultation 04-consultation.md; else BUDGET=" budget=exhausted"; fi; fi
    echo "CONSULTATION-OK codex=COMPLETE candidates=$candidates seal=$(sha "$ART/02-review-seal.sha256" | cut -c1-12)${CLAIM_TOKEN:+ claim=$CLAIM_TOKEN}$BUDGET"
  else
    echo "CONSULTATION-OK codex=SKIPPED candidates=$candidates seal=$(sha "$ART/02-review-seal.sha256" | cut -c1-12)"
  fi
  ;;
pre-verification)
  codex_status; initial_packets; accepted_check; launch_records_check; live_claim_check; review_seal_check; codex_skip_check
  [ -n "$(ledger_row 03-debate-selection.tsv)" ] && [ -n "$(ledger_row 03-findings.ndjson)" ] || fail "03-debate-selection.tsv / 03-findings.ndjson are not accepted; run pre-consultation first"
  phase_status 04-consultation.md 4
  consultation=$PST
  reject_unconfirmed_cancel 04-consultation  # any attempt, current or rotated (round-17 L-01)
  reject_skipped_after_accept
  if [ "$ST" = COMPLETE ]; then
    candidates=$(selection_count) || fail "could not count selected findings"
    if [ "$consultation" = COMPLETE ]; then
      [ "$candidates" -gt 0 ] || fail "04-consultation.md completed with no selected findings"
      [ -s "$ART/04-consultation.meta" ] || fail "04-consultation.meta missing after completed consultation"
      if [ ! -s "$ART/04-consultation.exit" ] || [ "$(cat "$ART/04-consultation.exit")" != 0 ]; then
        fail "04-consultation.exit must be 0 after completed consultation"
      fi
      check_thread 04-consultation
      [ -s "$ART/04-consultation.stdout" ] || fail "04-consultation.stdout missing after completed consultation"
      python3 "$VALIDATOR" --manifest "$ART/03-matrix.tsv" --selection "$ART/03-debate-selection.tsv" --phase consultation --extract "$ART/04-consultation.stdout" --out "$ART/04-consultation.json" >/dev/null || fail "consultation response is invalid"
      write_thread_anchor
      # The accepted response, its normalized form and the thread anchor are final.
      accept 04-consultation.stdout final
      accept 04-consultation.json final
      accept 04-consultation.thread final
    elif [ "$consultation" = SKIPPED ]; then
      # A failed/malformed/declined consultation falls back to the original
      # normalized findings — but only after it was actually attempted. With
      # candidates and a successful Phase 2, a skip with no runner sidecar is
      # a bypass, not a fallback (round-21 CX-02).
      if [ "$candidates" -gt 0 ] && [ "$(runner_count 04-consultation)" -eq 0 ]; then
        fail "04-consultation.md is SKIPPED with $candidates selected finding(s) but no consultation attempt was recorded"
      fi
    else
      fail "04-consultation.md has unknown terminal state"
    fi
  elif [ "$ST" = SKIPPED ]; then
    [ "$consultation" = SKIPPED ] || fail "04-consultation.md is COMPLETE but Codex Phase 2 was SKIPPED; consultation cannot have run without Codex"
  fi
  # The verifier inputs are generated here from the frozen base packets and the
  # accepted dispositions (round-26 CX-03); a draft until Phase 5 writes.
  write_packets
  accept 05-verifier-packets.ndjson draft
  check_budget
  echo "VERIFICATION-OK consultation=$consultation codex=$ST attempts=$(( $(runner_count 04-consultation) + $(runner_count 06-resolution) )) responses=$(response_count)"
  ;;
pre-resolution)
  initial_packets; codex_status; accepted_check; launch_records_check; live_claim_check; review_seal_check; codex_skip_check
  # Phase 4 must have reached a terminal state before Phase 5, and hence before
  # any Phase 6 launch (round-18 CX-04).
  phase_status 04-consultation.md 4
  consultation=$PST
  [ -n "$(ledger_row 05-verifier-packets.ndjson)" ] || fail "05-verifier-packets.ndjson is not accepted; run pre-verification first"
  reject_skipped_after_accept
  [ "$ST" = SKIPPED ] && [ "$consultation" = COMPLETE ] && fail "04-consultation.md is COMPLETE but Codex Phase 2 was SKIPPED; consultation cannot have run without Codex"
  if [ "$ST" = COMPLETE ] && [ "$consultation" = COMPLETE ]; then [ -n "$(ledger_row 04-consultation.stdout)" ] || fail "04-consultation.stdout is not accepted; run pre-verification first"; fi
  phase_status 05-verification.md 5
  [ "$PST" = COMPLETE ] || fail "05-verification.md was skipped; verification is required"
  # 05-verifier-packets.ndjson is ledger-frozen once 05-verification.md exists (accepted_check above proves it byte-identical
  # to the validated generation at pre-verification), so it is not rebuilt here (cycle-debate follow-up).
  claim_in_flight_check 06-resolution 06-resolution.md  # before any draft is (re-)accepted (round-39/40 CL-01)
  validate_verdicts || fail "05-verdicts.tsv is missing or invalid (expected one F-nn<TAB>verdict per matrix ID, verdict = CONFIRMED|REFUTED|UNVERIFIABLE)"
  accept 05-verdicts.tsv draft
  residual=$(residual_count) || fail "could not count residual verdicts"
  if [ "$ST" = COMPLETE ]; then
    check_budget
    reject_unconfirmed_cancel 04-consultation
    reject_unconfirmed_cancel 06-resolution
    # Remaining-budget checks only matter when a residual exchange is actually
    # needed; a run with nothing left UNVERIFIABLE never launches Phase 6 and
    # must not be blocked by an exhausted budget (round-15 CX-02).
    if [ "$residual" -gt 0 ]; then
      # Residuals remain: the selector is part of the audit trail whether or
      # not a launch follows (round-21 CX-03, round-24/25 CX-02/CX-04), so it
      # is required, validated and attested BEFORE the budget decides.
      [ -s "$ART/06-resolution-selection.ids" ] || fail "06-resolution-selection.ids missing or empty: write the residual ID list before pre-resolution"
      validate_residual_ids || fail "06-resolution-selection.ids is invalid (empty, duplicate, non-residual or non-manifest IDs)"
      accept 06-resolution-selection.ids draft
      refuse_relaunch 06-resolution 06-resolution.md pre-report
      if budget_left; then claim_phase 06-resolution 06-resolution.md; else BUDGET=" budget=exhausted"; fi
    fi
  fi
  # A residual selector present in the no-Codex or no-residual path must still
  # be valid; it is accepted as a draft so pre-report can hold it. One that was
  # legitimately removed while Phase 6 has not begun is retired from the ledger.
  if [ -e "$ART/06-resolution-selection.ids" ]; then
    validate_residual_ids || fail "06-resolution-selection.ids is invalid (empty, duplicate, non-residual or non-manifest IDs)"
    accept 06-resolution-selection.ids draft
  else
    retire 06-resolution-selection.ids
  fi
  echo "RESOLUTION-OK codex=$ST residual=$residual attempts=$(( $(runner_count 04-consultation) + $(runner_count 06-resolution) )) responses=$(response_count)${CLAIM_TOKEN:+ claim=$CLAIM_TOKEN}${BUDGET:-}"
  ;;
pre-report)
  initial_packets; codex_status; accepted_check; launch_records_check; live_claim_check; review_seal_check; codex_skip_check
  phase_status 04-consultation.md 4
  consultation=$PST
  # Both exchange phases, first: a SKIPPED consultation may still hide an
  # exit-5 / unconfirmed-cancel sidecar (round-16 CX-03), and a possibly live
  # worker outranks every other inconsistency.
  reject_unconfirmed_cancel 04-consultation
  reject_unconfirmed_cancel 06-resolution
  [ -n "$(ledger_row 05-verdicts.tsv)" ] || fail "05-verdicts.tsv is not accepted; run pre-resolution first"
  reject_skipped_after_accept
  phase_status 05-verification.md 5
  [ "$PST" = COMPLETE ] || fail "05-verification.md was skipped; verification is required"
  # Re-validate the verdict ledger (its citations resolve against the repository, which can change);
  # the packets are ledger-frozen since pre-verification and are not rebuilt here (cycle-debate follow-up).
  validate_verdicts || fail "05-verdicts.tsv is missing or invalid (expected one F-nn<TAB>verdict per matrix ID, verdict = CONFIRMED|REFUTED|UNVERIFIABLE)"
  # Re-validate consultation artifacts when both Codex and consultation completed,
  # so tampering with 04-consultation between pre-verification and pre-report is caught.
  if [ "$ST" = COMPLETE ] && [ "$consultation" = SKIPPED ]; then
    candidates=$(selection_count) || fail "could not count selected findings"
    if [ "$candidates" -gt 0 ] && [ "$(runner_count 04-consultation)" -eq 0 ]; then
      fail "04-consultation.md is SKIPPED with $candidates selected finding(s) but no consultation attempt was recorded"
    fi
  fi
  if [ "$ST" = COMPLETE ] && [ "$consultation" = COMPLETE ]; then
    [ -s "$ART/04-consultation.meta" ] || fail "04-consultation.meta missing after completed consultation"
    if [ ! -s "$ART/04-consultation.exit" ] || [ "$(cat "$ART/04-consultation.exit")" != 0 ]; then
      fail "04-consultation.exit must be 0 after completed consultation"
    fi
    check_thread 04-consultation
    [ -n "$(ledger_row 04-consultation.stdout)" ] && [ -n "$(ledger_row 04-consultation.json)" ] || fail "04-consultation.stdout / .json are not accepted; run pre-verification first"
  fi
  phase_status 06-resolution.md 6
  resolution=$PST
  reject_resolution_skip_over_success
  if [ "$ST" = COMPLETE ]; then
    if [ "$resolution" = COMPLETE ]; then
      [ -s "$ART/06-resolution.meta" ] || fail "06-resolution.meta missing after completed resolution"
      if [ ! -s "$ART/06-resolution.exit" ] || [ "$(cat "$ART/06-resolution.exit")" != 0 ]; then
        fail "06-resolution.exit must be 0 after completed resolution"
      fi
      check_thread 06-resolution
      [ -s "$ART/06-resolution-selection.ids" ] || fail "06-resolution-selection.ids missing after completed resolution"
      [ -s "$ART/06-resolution.stdout" ] || fail "06-resolution.stdout missing after completed resolution"
      python3 "$VALIDATOR" --manifest "$ART/03-matrix.tsv" --verdicts "$ART/05-verdicts.tsv" --ids "$ART/06-resolution-selection.ids" --phase resolution --extract "$ART/06-resolution.stdout" --out "$ART/06-resolution.json" >/dev/null || fail "resolution response is invalid"
      # The accepted residual response is final (round-27 CX-03).
      accept 06-resolution.stdout final
      accept 06-resolution.json final
    fi
  elif [ "$ST" = SKIPPED ]; then
    [ "$consultation" = SKIPPED ] || fail "04-consultation.md is COMPLETE but Codex Phase 2 was SKIPPED; consultation cannot have run without Codex"
    [ "$resolution" = SKIPPED ] || fail "06-resolution.md is COMPLETE but Codex Phase 2 was SKIPPED; resolution cannot have run without Codex"
  fi
  # If resolution was SKIPPED and Codex Phase 2 SUCCEEDED, verify no UNVERIFIABLE
  # findings remain — a "no residual" skip is only valid when every verdict is
  # CONFIRMED or REFUTED. When Codex was SKIPPED, UNVERIFIABLE findings follow
  # the UNRESOLVED default and the report proceeds.
  # A skipped Phase 6 with residuals is the documented fallback only when the
  # exchange was actually attempted (a 06-resolution sidecar exists — failed,
  # stalled, or its response was rejected) or the shared budget is exhausted;
  # otherwise the residuals were simply never handled (round-17 CX-02).
  if [ "$resolution" = SKIPPED ] && [ "$ST" = COMPLETE ] && [ "$(residual_count)" -gt 0 ]; then
    attempts=$(( $(runner_count 04-consultation) + $(runner_count 06-resolution) ))
    if [ "$(runner_count 06-resolution)" -eq 0 ] && [ "$attempts" -lt 4 ] && [ "$(response_count)" -lt 2 ]; then
      fail "06-resolution.md is SKIPPED but 05-verdicts.tsv contains UNVERIFIABLE findings and no residual exchange was attempted (budget remains: attempts=$attempts/4 responses=$(response_count)/2)"
    fi
  fi
  # With residuals and a successful Phase 2 the selector is part of the audit
  # trail whether or not the exchange ran: it must exist, validate, and match
  # the attestation written at pre-resolution (round-24 CX-02).
  if [ "$ST" = COMPLETE ] && [ "$(residual_count)" -gt 0 ]; then
    [ -s "$ART/06-resolution-selection.ids" ] || fail "06-resolution-selection.ids missing or empty: residual findings remain but no residual selector is recorded"
    validate_residual_ids || fail "06-resolution-selection.ids is invalid"
    [ -n "$(ledger_row 06-resolution-selection.ids)" ] || fail "06-resolution-selection.ids is not accepted; run pre-resolution first"
  elif [ -e "$ART/06-resolution-selection.ids" ]; then
    validate_residual_ids || fail "06-resolution-selection.ids is invalid"
  fi
  check_budget
  echo "REPORT-OK codex=$ST resolution=$resolution attempts=$(( $(runner_count 04-consultation) + $(runner_count 06-resolution) )) responses=$(response_count)"
  ;;
post-join)
  initial_packets
  [ -s "$ART/01-lead.md" ] || fail "01-lead.md missing or empty"
  [ -r "$ART/01-lead.md" ] || fail "01-lead.md is still sealed (mode $(mode "$ART/01-lead.md")); Phase 3 restores it to 600"
  [ "$(lastline "$ART/01-lead.md")" = "STATUS: PHASE 1 COMPLETE" ] || fail "01-lead.md does not end with STATUS: PHASE 1 COMPLETE"
  codex_status; accepted_check; launch_records_check; live_claim_check; review_seal_check; codex_skip_check
  # The snapshot tree must still resolve after Codex returns, or Phase-5 citations at the head cannot be verified (codex-protocol.md).
  if [ -s "$ART/00-brief.md.tree" ]; then git -C "$(repo_field repo)" cat-file -e "$(cat "$ART/00-brief.md.tree")^{tree}" 2>/dev/null || fail "snapshot tree $(cat "$ART/00-brief.md.tree") no longer resolves in $(repo_field repo); it was garbage-collected or the repository moved"; fi
  echo "POST-JOIN-OK lead=complete codex=$ST brief=$(cut -c1-12 "$ART/00-brief.md.sha256") scope=$(cut -c1-12 "$ART/00-scope.md.sha256")"
  ;;
esac
