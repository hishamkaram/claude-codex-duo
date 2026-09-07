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
#   phase-gate.sh release         <ART> <prefix>
#   phase-gate.sh confirm-terminated <ART> <prefix>
#
# Every gate rechecks the frozen scope, blind brief and participants file, the schema
# marker (00-schema = codex-pr-review/5: an older directory is never reinterpreted), then
# verifies the accept ledger (00-accepted.sha256): every artifact a gate has accepted or
# generated is recorded there once and may never change afterwards. Launch gates take an
# atomic claim as their last step — pre-codex one per participant of 00-participants.tsv
# (prefixes 02-p1..02-pN). See SKILL.md §Phase gate and §Participants.
set -u
USAGE='usage: phase-gate.sh pre-codex <ART> <REPO> | phase-gate.sh pre-phase3|pre-consultation|pre-verification|pre-resolution|pre-report|post-join <ART> | phase-gate.sh release|confirm-terminated <ART> <prefix>'
die2() { echo "phase-gate.sh: $1" >&2; echo "$USAGE" >&2; exit 2; }
CMD="${1:-}"; ART="${2:-}"; REPO="${3:-}"
case "$CMD" in
  pre-codex) [ $# -eq 3 ] || die2 "pre-codex takes <ART> <REPO>";;
  pre-phase3|pre-consultation|pre-verification|pre-resolution|pre-report|post-join) [ $# -eq 2 ] || die2 "$CMD takes <ART>";;
  release|confirm-terminated) [ $# -eq 3 ] || die2 "$CMD takes <ART> <prefix>";;
  *) die2 "unknown or missing subcommand '${CMD}'";;
esac
[ -d "$ART" ] || die2 "run directory not found: $ART"
ART="$(cd "$ART" && pwd -P)"
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
VALIDATOR="$ROOT/scripts/validate-consultation.py"
PROVENANCE_VALIDATOR="$ROOT/scripts/validate-provenance.py"
# Bumped to /5: the terminal-state grammar gained NOT_RUN_POLICY and the brief gained a Tier line,
# so a directory written under /4 must be refused rather than reinterpreted by these gates.
SCHEMA_MARKER="codex-pr-review/5"
PACKET_VALIDATOR="$ROOT/scripts/validate-verifier-packets.py"
VERDICT_VALIDATOR="$ROOT/scripts/validate-verdicts.py"
PACKET_BUILDER="$ROOT/scripts/build-verifier-packets.py"
SCOPE_ATTRIBUTION="$ROOT/scripts/scope-attribution.py"
LEDGER="$ART/00-accepted.sha256"
# One scratch file for every validator dry run in this call; allocation failure
# is a gate failure, never a silently-unusable response (round-37 CX-02).
SCRATCH=$(mktemp "${TMPDIR:-/tmp}/phase-gate.XXXXXX") || { echo "GATE FAILED ($CMD): cannot allocate a scratch file in ${TMPDIR:-/tmp}" >&2; exit 1; }
LEAD_WAS_SEALED=0   # set by unseal_lead_for_hash, cleared by reseal_lead_after_hash; on_exit reseals the lead if a hashing helper failed in between
PST=""              # terminal state of the phase last parsed by phase_status
PST_POLICY=""       # the tier token a NOT_RUN_POLICY line cited, empty for every other state
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
  PST_POLICY=""   # cleared every call: a stale token from an earlier phase must never authorize this one
  last=$(lastline "$ART/$file")
  case "$last" in
    "STATUS: PHASE $phase COMPLETE") PST=COMPLETE;;
    "STATUS: PHASE $phase COMPLETE (SKIPPED — "*")") PST=SKIPPED;;
    # A third terminal state, distinct from SKIPPED on purpose. SKIPPED means the run TRIED and
    # could not get a usable response, or the phase was ineligible — both derived from what
    # happened. NOT_RUN_POLICY means the run CHOSE not to execute an eligible phase under a
    # frozen tier. Collapsing the two would make "we decided to skip this" indistinguishable
    # from "this broke" in the audit trail, which is the one thing the trail exists to prevent.
    "STATUS: PHASE $phase NOT_RUN_POLICY "*)
      # Phase 4 is the ONLY phase this state is defined for: it is the only one with a policy
      # checker (policy_omission_check), and the only omission SKILL.md authorizes. Admitting it
      # elsewhere puts a third value into guards written against COMPLETE/SKIPPED, where it falls
      # through every `= SKIPPED` branch — on Phase 6 that silently disables the round-17 CX-02
      # residual guard, and on Phase 2 it admits a blind review that never ran. Refuse the state
      # wherever nothing validates it, rather than trusting each consumer to remember.
      [ "$phase" = 4 ] || fail "$file records NOT_RUN_POLICY for phase $phase, but only Phase 4 may be omitted by policy (it is the only phase with a policy check); every other phase is COMPLETE or SKIPPED"
      PST=NOT_RUN_POLICY; PST_POLICY="${last#"STATUS: PHASE $phase NOT_RUN_POLICY "}";;
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
  for f in "$ART/$prefix".attempt*.exit "$ART/$prefix.exit"; do
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
# ---- Participants (4.0.0) ------------------------------------------------------------------
# 00-participants.tsv, written in Phase 0 and frozen with the packets: one row per blind
# second-model reviewer, `p<k><TAB>codex|ccr<TAB>alias-or-dash`, k = 1..N in order, 1 ≤ N ≤ 8,
# at most one codex row (the companion resumes only the last thread in a repository). Each
# participant owns the prefix 02-p<k>: its own claim, sidecars and terminal 02-p<k>.md.
PARTICIPANTS_FILE="$ART/00-participants.tsv"
participants_check() {
  local n=0 k id backend alias codex=0 line
  [ -s "$PARTICIPANTS_FILE" ] || fail "00-participants.tsv missing or empty: Phase 0 writes one row per participant (p<k><TAB>codex|ccr<TAB>alias-or-dash) before pre-codex"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    n=$((n+1)); k=$n
    id=$(printf '%s' "$line" | cut -f1); backend=$(printf '%s' "$line" | cut -f2); alias=$(printf '%s' "$line" | cut -f3)
    [ "$id" = "p$k" ] || fail "00-participants.tsv line $n: expected id p$k (rows are p1..pN in order), got '$id'"
    case "$backend" in
      codex) [ "$alias" = "-" ] || fail "00-participants.tsv line $n: a codex participant has alias '-' (got '$alias')"; codex=$((codex+1));;
      ccr) case "$alias" in ""|-|*[!A-Za-z0-9._-]*) fail "00-participants.tsv line $n: a ccr participant needs an alias of letters, digits, '.', '_' and '-' (got '$alias')";; esac;;
      *) fail "00-participants.tsv line $n: backend must be codex or ccr (got '$backend')";;
    esac
  done < "$PARTICIPANTS_FILE"
  [ "$n" -ge 1 ] && [ "$n" -le 8 ] || fail "00-participants.tsv must list 1 to 8 participants (got $n)"
  [ "$codex" -le 1 ] || fail "00-participants.tsv lists $codex codex participants; at most one (the companion resumes only the last thread in a repository)"
}
participant_ids() { cut -f1 "$PARTICIPANTS_FILE" 2>/dev/null | grep -E '^p[1-9][0-9]*$'; }
participant_field() {  # participant_field <id> backend|alias
  local col; case "$2" in backend) col=2;; alias) col=3;; *) return 1;; esac
  awk -F'\t' -v id="$1" -v c="$col" '$1 == id {print $c; exit}' "$PARTICIPANTS_FILE" 2>/dev/null
}
phase2_prefixes() { participant_ids | sed 's/^/02-/'; }
all_prefixes() { phase2_prefixes; printf '%s\n' 04-consultation 06-resolution; }
# The schema marker names the artifact contract of this directory. It is written once by
# pre-codex, hashed with the packets, accepted into the ledger after the seal, and checked by
# every gate: a directory written under another contract (3.0.0's 02-codex prefixes) is
# refused instead of being reinterpreted (round-1 X-4 of the 4.0.0 plan).
schema_check() {
  [ -s "$ART/00-schema" ] || fail "00-schema missing: this is a legacy run directory (or pre-codex never ran here) — start a fresh run directory under codex-pr-review 5.0.0"
  [ "$(cat "$ART/00-schema")" = "$SCHEMA_MARKER" ] || fail "00-schema is '$(head -1 "$ART/00-schema")', expected '$SCHEMA_MARKER': legacy run directory — start a fresh run"
}
# The tier is the authority for a policy omission, and it lives in the frozen brief: hashcheck
# already refuses a brief that changed after pre-codex, so no separate policy artifact is needed.
# Read it back from the brief rather than trusting a caller-supplied value.
brief_tier() { sed -n 's/^- Tier: //p' "$ART/00-brief.md" 2>/dev/null | head -1; }
tier_check() {
  local t; t=$(brief_tier)
  [ -n "$t" ] || fail "00-brief.md has no '- Tier:' line: rebuild the brief with build-brief.sh (the tier selects the reviewers' output contract and authorizes policy omissions)"
  case "$t" in
    compact-v1|full) ;;
    *) fail "00-brief.md names an unknown tier '$t': expected compact-v1 or full";;
  esac
}
# A phase recorded NOT_RUN_POLICY was ELIGIBLE and deliberately not executed under the frozen
# tier. Two things must hold, or the state is a bypass wearing a policy label: the tier must
# actually permit the omission, and nothing may have been launched — a run that started the phase
# and then relabelled the failure would otherwise launder it into a decision.
policy_omission_check() {  # policy_omission_check <prefix> <policy-token>
  local prefix="$1" token="$2" tier
  tier=$(brief_tier)
  [ "$token" = "$tier" ] || fail "$prefix.md is NOT_RUN_POLICY '$token' but the frozen brief names tier '$tier': the omission must cite the tier that authorized it"
  [ "$tier" != full ] || fail "$prefix.md is NOT_RUN_POLICY but the run is tier 'full', which omits no phase; record the real terminal state"
  # runner_count counts claims a RUNNER took, which is the fact that matters: something was
  # launched. The bare claim directory is not that fact — pre-consultation mints the claim as its
  # last step, so an authorized-but-unused reservation is present on every legal omission and
  # testing for it would make the state unreachable. A launch that left the runner directory
  # behind is caught here; one whose runner directory was deleted still leaves sidecars, which
  # launch_records_check reconciles against the claims.
  [ "$(runner_count "$prefix")" -eq 0 ] || fail "$prefix.md is NOT_RUN_POLICY but $(runner_count "$prefix") attempt(s) were recorded: a phase that ran and failed is SKIPPED, not a policy omission"
  [ ! -e "$ART/$prefix.exit" ] || fail "$prefix.md is NOT_RUN_POLICY but $prefix.exit records an attempt's outcome: a phase that ran is COMPLETE or SKIPPED, never a policy omission"
  # A tier may buy latency out of nits, never out of the merge decision. Consultation is the only
  # place the two models reconcile a disagreement, and the findings it is worth running for are
  # precisely the blocking ones: in the production run that motivated this work, the selected
  # candidates WERE the two genuine P1s. So a policy omission is legal only when nothing blocking
  # was selected — otherwise the tier would be trading away the answer, not the prose.
  if [ "$prefix" = 04-consultation ] && [ -s "$ART/03-debate-selection.tsv" ]; then
    local blocking
    blocking=$(awk -F'\t' '$4 == "INCLUDE" && ($3 == "P0" || $3 == "P1")' "$ART/03-debate-selection.tsv" | wc -l | tr -d ' ')
    [ "$blocking" -eq 0 ] || fail "04-consultation.md is NOT_RUN_POLICY but $blocking blocking finding(s) (P0/P1) were selected for consultation: a tier may omit an exchange over nits, never over the findings the merge decision turns on — run the consultation"
  fi
}
# participants_status: every participant's 02-p<k>.md is terminal. ST = COMPLETE when at
# least one participant completed (SKIPPED when none); EXCH = the lowest-k COMPLETE
# participant (the one consulted later); CX = its exit; PSTATUS = the per-participant list.
participants_status() {
  local id pst
  ST=SKIPPED; CX=skipped; EXCH=""; PSTATUS=""
  for id in $(participant_ids); do
    phase_status "02-$id.md" 2; pst=$PST
    # An exit-5 / unconfirmed-cancel sidecar on an initial review (current or rotated) means a
    # worker may still be alive, whether the phase was then recorded COMPLETE by a later
    # attempt or SKIPPED (round-19 CX-01).
    reject_unconfirmed_cancel "02-$id"
    if [ "$pst" = COMPLETE ]; then
      [ -s "$ART/02-$id.exit" ] || fail "02-$id.exit missing: participant $id has not finished"
      [ "$(cat "$ART/02-$id.exit")" = 0 ] || fail "02-$id.exit must be 0 for a completed blind review (got $(cat "$ART/02-$id.exit"))"
      [ -s "$ART/02-$id.stdout" ] || fail "02-$id.stdout is empty: an empty response is not a completed blind review; record Phase 2 SKIPPED (empty response) for $id or relaunch"
      ST=COMPLETE
      if [ -z "$EXCH" ]; then EXCH="$id"; CX=$(cat "$ART/02-$id.exit"); fi
    fi
    PSTATUS="${PSTATUS:+$PSTATUS,}$id:$pst"
  done
}
codex_status() { participants_status; }
exchange_drift_check() {  # the exchange participant is recorded at the join and must not drift afterwards; runs after the seal checks so tampering is reported first
  if [ -s "$ART/02-exchange-participant" ]; then
    [ "$(cat "$ART/02-exchange-participant")" = "$EXCH" ] || fail "02-exchange-participant records $(cat "$ART/02-exchange-participant") but the lowest completed participant is now ${EXCH:-none}: a participant's status changed after the join (start a fresh run directory)"
  fi
}
initial_packets() { hashcheck 00-brief.md; hashcheck 00-scope.md; hashcheck 00-participants.tsv; hashcheck 00-schema; hashcheck 00-brief.md.scope.json; }
# The seal attests the join for BOTH Phase-2 outcomes: a COMPLETE review hashes
# the raw Codex body, a SKIPPED one hashes the status file itself, so a later
# status edit or seal deletion is detectable either way (round-22 CX-02).
seal_contents() {  # lead body, then every participant's body (COMPLETE: raw stdout; SKIPPED: the status file), in order
  local destination="$1" codex_file id
  printf 'phase2=%s\n' "$ST" > "$destination"
  sha "$ART/01-lead.md" >> "$destination" || return 1
  printf '  01-lead.md\n' >> "$destination"
  for id in $(participant_ids); do
    case "$PSTATUS" in *"$id:COMPLETE"*) codex_file="02-$id.stdout";; *) codex_file="02-$id.md";; esac
    sha "$ART/$codex_file" >> "$destination" || return 1
    printf '  %s\n' "$codex_file" >> "$destination"
  done
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
  [ "$ST" = "$sealed_phase" ] || fail "a participant 02-p<k>.md status changed after JOIN-OK (sealed=$sealed_phase current=$ST)"
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
KNOWN_GATES=" pre-phase3 pre-consultation pre-verification pre-resolution pre-report confirm-terminated "
later_artifacts() {  # glob prefixes of artifacts that only exist once a later phase began
  case "$1" in
    pre-phase3) echo "03- 04- 05- 06- 07-";;  # the seal and 02-exchange-participant are minted before the ledger exists (round-40 CX-01)
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
# A repair prompt is minted after its phase's malformed response, so current
# phase sidecars must not look like post-phase artifacts. It is still refused
# once the next phase has started, preserving the normal draft-finalization bar.
repair_prompt_may_be_accepted() {  # <gate> <artifact>
  local gate="$1" name="$2" p f
  case "$gate:$name" in
    pre-consultation:04-consultation.prompt.retry.md) p='05- 06- 07-';;
    pre-resolution:06-resolution.prompt.retry.md) p='07-';;
    *) return 1;;
  esac
  shopt -s nullglob
  for p in $p; do
    for f in "$ART/$p"*; do
      [ -e "$f" ] && { shopt -u nullglob; return 1; }
    done
  done
  shopt -u nullglob
  return 0
}
write_review_seal() {  # pre-phase3: mint the seal once; on re-entry regenerate and compare
  local seal="$ART/02-review-seal.sha256" tmp
  [ ! -e "$seal" ] || { review_seal; return; }
  unseal_lead_for_hash
  [ -s "$ART/01-lead.md" ] || { reseal_lead_after_hash; fail "01-lead.md missing or empty"; }
  if [ "$ST" = COMPLETE ]; then [ -s "$ART/02-$EXCH.stdout" ] || { reseal_lead_after_hash; fail "02-$EXCH.stdout missing or empty"; }; fi
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
    case "$name" in [0-9][0-9]-*|02-p*.cancel-resolved|04-consultation.cancel-resolved|06-resolution.cancel-resolved) ;; *) fail "00-accepted.sha256 has a malformed row ($digest $name)";; esac
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
  elif later_artifact_exists "$CMD" "$name" && ! repair_prompt_may_be_accepted "$CMD" "$name"; then
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
  for prefix in $(all_prefixes); do
    if [ -d "$ART/$prefix.claim/runner" ] && [ ! -e "$ART/$prefix.exit" ]; then
      fail "$prefix runner is still in flight ($prefix.claim/runner exists and $prefix.exit does not): wait for it, or if it is dead run phase-gate.sh release $ART $prefix — a phase cannot be recorded or advanced past while its runner may still write"
    fi
  done
}
launch_records_check() {
  local prefix slots taken
  for prefix in $(all_prefixes); do
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
    --resume-last|--resume-session)  # a ccr exchange names the session explicitly; it is anchored the same way (review round 1: F-01)
      expected=$(expected_thread 2>/dev/null) || return 1
      [ "$actual" = "$expected" ];;
    *) return 1;;
  esac
}
# An exit-0, non-empty exchange reply that the canonical validator rejects is a
# completed transport attempt, not a usable response. One such reply gets one
# corrective resubmission; a second falls back to the existing SKIPPED path.
attempt_schema_invalid() {  # <stem> <validator args...>
  local stem="$1"; shift
  [ -s "$stem.exit" ] && [ "$(cat "$stem.exit")" = 0 ] || return 1
  [ -s "$stem.stdout" ] || return 1
  [ $# -gt 0 ] || return 1
  python3 "$VALIDATOR" "$@" --extract "$stem.stdout" --out "$SCRATCH" >/dev/null 2>&1 && return 1
  return 0
}
schema_invalid_count() {  # <prefix>; validator args are derived from present phase inputs
  local prefix="$1" n=0 f line
  local -a args=()
  while IFS= read -r line; do args+=("$line"); done < <(validator_args "$prefix")
  [ ${#args[@]} -gt 0 ] || { printf '0\n'; return; }
  shopt -s nullglob
  for f in "$ART/$prefix".attempt*.exit "$ART/$prefix.exit"; do
    attempt_schema_invalid "${f%.exit}" "${args[@]}" && n=$((n+1))
  done
  shopt -u nullglob
  printf '%s\n' "$n"
}
write_schema_repair_prompt() {  # <prefix>; write retry instructions plus validator diagnostics
  local prefix="$1" f stem line latest="" diagnostic="" prompt tmp status=0
  prompt="$ART/$prefix.prompt.retry.md"
  tmp="$ART/.$prefix.prompt.retry.XXXXXX"
  local -a args=()
  while IFS= read -r line; do args+=("$line"); done < <(validator_args "$prefix")
  [ ${#args[@]} -gt 0 ] || fail "could not derive validator inputs for $prefix repair"
  shopt -s nullglob
  for f in "$ART/$prefix".attempt*.exit "$ART/$prefix.exit"; do
    stem="${f%.exit}"
    if attempt_schema_invalid "$stem" "${args[@]}"; then latest="$stem"; fi
  done
  shopt -u nullglob
  [ -n "$latest" ] || fail "could not locate malformed $prefix response for repair"
  diagnostic=$(python3 "$VALIDATOR" "${args[@]}" --extract "$latest.stdout" --out "$SCRATCH" 2>&1 >/dev/null); status=$?
  [ "$status" -ne 0 ] || fail "malformed $prefix response unexpectedly passed validation during repair"
  diagnostic=$(printf '%s\n' "$diagnostic" | grep -E '^VALIDATION_CLASS=(envelope|schema|citation|content)$' | head -n 1)
  [ -n "$diagnostic" ] || fail "validator returned no stable diagnostic class for $prefix repair"
  [ -s "$ART/$prefix.prompt.md" ] || fail "$prefix.prompt.md missing: cannot construct repair prompt"
  # A prior invocation may have finished sealing the prompt but been interrupted
  # before its ledger row. Never replace that immutable artifact; complete the
  # ledger transition instead.
  if [ -e "$prompt" ]; then
    [ -s "$prompt" ] && [ "$(mode "$prompt")" = 400 ] || fail "$prefix.prompt.retry.md exists but is not a sealed repair prompt"
    accept "$(basename "$prompt")" final
    return
  fi
  tmp=$(mktemp "$tmp") || fail "could not allocate $prefix repair prompt"
  { cat "$ART/$prefix.prompt.md"; printf '\n\n## Canonical response repair\nYour prior response completed but was rejected by the local canonical validator. Reply again with exactly one corrected fenced `json` object and nothing else. Preserve the requested phase and exact IDs; do not discuss this notice or the diagnostic.\n\nValidator diagnostic:\n```text\n%s\n```\n' "$diagnostic"; } > "$tmp" || { rm -f "$tmp"; fail "could not write $prefix.prompt.retry.md"; }
  chmod 400 "$tmp" 2>/dev/null || { rm -f "$tmp"; fail "could not seal $prefix.prompt.retry.md"; }
  mv -f "$tmp" "$prompt" || { rm -f "$tmp"; fail "could not install $prefix.prompt.retry.md"; }
  accept "$(basename "$prompt")" final
}
# Once a malformed completed response triggers a repair, every subsequent
# attempt for that phase must use the sealed, gate-generated retry prompt.
# This checks runner control metadata only; it never parses model output.
schema_repair_prompt_check() {  # <prefix>
  local prefix="$1" f stem saw_invalid=0 prompt_file prompt line
  prompt="$ART/$prefix.prompt.retry.md"
  local -a args=()
  while IFS= read -r line; do args+=("$line"); done < <(validator_args "$prefix")
  [ ${#args[@]} -gt 0 ] || return 0
  # A normal gate-created repair always leaves this final receipt. Older
  # interrupted/legacy fixtures with malformed output but no receipt retain
  # their existing SKIPPED fallback rather than being reinterpreted.
  [ -e "$prompt" ] || return 0
  shopt -s nullglob
  for f in "$ART/$prefix".attempt*.exit "$ART/$prefix.exit"; do
    stem="${f%.exit}"
    if [ "$saw_invalid" = 1 ] && [ -e "$stem.exit" ]; then
      [ -s "$stem.meta" ] || { shopt -u nullglob; fail "$prefix repair attempt $(basename "$stem") has no .meta to prove it used $(basename "$prompt")"; }
      prompt_file=$(awk -F= '$1 == "prompt_file" {sub(/^[^=]*=/, ""); print; exit}' "$stem.meta" 2>/dev/null)
      [ -n "$prompt_file" ] && [ "$prompt_file" -ef "$prompt" ] || { shopt -u nullglob; fail "$prefix repair attempt $(basename "$stem") did not use the required $(basename "$prompt")"; }
    fi
    attempt_schema_invalid "$stem" "${args[@]}" && saw_invalid=1
  done
  shopt -u nullglob
}
# A terminal SKIPPED exchange cannot bypass the one corrective launch after a
# malformed completed response. A present retry prompt proves the gate already
# authorized it; legacy/interrupted runs without that artifact retain SKIPPED.
schema_repair_pending() {  # <prefix>; returns 0 only when one repair launch remains required
  local prefix="$1" f stem saw_invalid=0 line prompt="$ART/$1.prompt.retry.md"
  local -a args=()
  [ -e "$prompt" ] || return 1
  while IFS= read -r line; do args+=("$line"); done < <(validator_args "$prefix")
  [ ${#args[@]} -gt 0 ] || return 1
  shopt -s nullglob
  for f in "$ART/$prefix".attempt*.exit "$ART/$prefix.exit"; do
    stem="${f%.exit}"
    [ -e "$stem.exit" ] || continue
    if [ "$saw_invalid" = 1 ]; then shopt -u nullglob; return 1; fi
    attempt_schema_invalid "$stem" "${args[@]}" && saw_invalid=1
  done
  shopt -u nullglob
  [ "$saw_invalid" = 1 ]
}
usable_count() {  # usable_count <prefix>; runs the validator once per attempt per gate call — bounded (at most 5 attempts per phase, milliseconds each)
  local prefix="$1" n=0 f line
  local -a args=()
  while IFS= read -r line; do args+=("$line"); done < <(validator_args "$prefix")  # one argument per line: paths may contain spaces (round-38 CX-05)
  shopt -s nullglob
  for f in "$ART/$prefix".attempt*.exit "$ART/$prefix.exit"; do
    attempt_usable "$prefix" "${f%.exit}" ${args[@]+"${args[@]}"} && n=$((n+1))
  done
  shopt -u nullglob
  printf '%s\n' "$n"
}
response_count() { printf '%s\n' "$(( $(usable_count 04-consultation) + $(usable_count 06-resolution) ))"; }
expected_thread() {
  local anchor="$ART/04-consultation.thread" expected
  if [ -s "$anchor" ]; then cat "$anchor"; return; fi
  [ -n "${EXCH:-}" ] || EXCH=$(cat "$ART/02-exchange-participant" 2>/dev/null)
  [ -n "$EXCH" ] || { printf '%s\n' "no exchange participant recorded (02-exchange-participant)" >&2; return 1; }
  expected=$(awk -F= '$1 == "thread" {print $2; exit}' "$ART/02-$EXCH.meta")
  [ -n "$expected" ] && [ "$expected" != unknown ] || { printf '%s\n' "Phase-2 thread of participant $EXCH is unavailable" >&2; return 1; }
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
    --resume-last|--resume-session) ;;  # --resume-session (ccr) must name the exchange participant's session (review round 1: F-01)
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
# 03-provenance.tsv: who raised each canonical finding (lead|p<k>, original id). Validated
# against the matrix and the participants file, accepted as a draft; it never reaches a packet.
validate_provenance() {
  [ -x "$PROVENANCE_VALIDATOR" ] || fail "provenance validator missing or not executable: $PROVENANCE_VALIDATOR"
  [ -f "$ART/03-provenance.tsv" ] || fail "03-provenance.tsv missing: write one F-nn<TAB>lead|p<k><TAB>original-id row per raiser of every matrix ID before pre-consultation"
  python3 "$PROVENANCE_VALIDATOR" --matrix "$ART/03-matrix.tsv" --participants "$PARTICIPANTS_FILE" --provenance "$ART/03-provenance.tsv" >/dev/null || fail "03-provenance.tsv is invalid (every matrix id at least once, raisers lead|p<k> from 00-participants.tsv, origin consistent with the raiser set; run validate-provenance.py for the reasons)"
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
# ccr attempts run in their own process group and record it on the launch line
# (`launched backend=ccr pid=<pid> pgid=<pgid> alias=<alias>`). A claim is released only when
# the recorded pid is dead, no process of the group is left, and no descendant of the pid
# survives; a launch line without pgid= is refused (round-2 X-7 of the 4.0.0 plan).
descendants_alive() {  # descendants_alive <pid>: 0 when any descendant is alive
  local kids c
  kids=$(pgrep -P "$1" 2>/dev/null) || return 1
  for c in $kids; do kill -0 "$c" 2>/dev/null && return 0; descendants_alive "$c" && return 0; done
  return 1
}
ccr_release_check() {  # ccr_release_check <prefix> <launch line>
  local prefix="$1" launch="$2" pid pgid left
  pid=$(printf '%s' "$launch" | grep -oE ' pid=[0-9]+' | head -1 | cut -d= -f2)
  pgid=$(printf '%s' "$launch" | grep -oE ' pgid=[0-9]+' | head -1 | cut -d= -f2)
  [ -n "$pgid" ] || fail "release: ccr launch record of $prefix has no pgid= (launch line: ${launch:0:120}); cancel the process tree by hand (ps -o pid,pgid,command | grep 'ccr launch'), then re-run the gate"
  if kill -0 -- "-$pgid" 2>/dev/null; then
    fail "release: process group $pgid of $prefix is still alive ($(ps -o pid=,command= -g "$pgid" 2>/dev/null | head -3 | tr '\n' ';')); cancel it first (kill -TERM -- -$pgid)"
  fi
  left=$(ps -o pid= -g "$pgid" 2>/dev/null | tr -d ' \n')
  [ -z "$left" ] || fail "release: process group $pgid of $prefix still has members ($left); cancel them first"
  if [ -n "$pid" ] && descendants_alive "$pid"; then fail "release: a descendant of pid $pid ($prefix) is still alive; cancel it first"; fi
}
release_claim() {
  local prefix="$1" claim="$ART/$1.claim" pid job st root launch backend alias
  case "$prefix" in 04-consultation|06-resolution) ;; *)
    participant_ids | sed 's/^/02-/' | grep -qx -- "$prefix" || fail "release: unknown phase prefix '$prefix' (participants: $(participant_ids | tr '\n' ' '))";;
  esac
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
  if [ -n "$pid" ] && descendants_alive "$pid"; then fail "release: a descendant of runner $pid of $prefix is still alive; cancel it first"; fi
  job=$(grep -oE 'launched job=task-[a-z0-9-]+' "$ART/$prefix.progress" 2>/dev/null | head -1 | cut -d= -f2)
  launch=$(grep -E '^[0-9]+s launched backend=ccr ' "$ART/$prefix.progress" 2>/dev/null | head -1)
  # Which backend this attempt used: the launch line when there is one; otherwise the
  # participant's row (02-p<k>) or the exchange participant's (04-/06-).
  case "$prefix" in 02-*) backend=$(participant_field "${prefix#02-}" backend); alias=$(participant_field "${prefix#02-}" alias);;
    *) backend=$(participant_field "$(cat "$ART/02-exchange-participant" 2>/dev/null)" backend); alias=$(participant_field "$(cat "$ART/02-exchange-participant" 2>/dev/null)" alias);; esac
  if [ -n "$launch" ]; then
    ccr_release_check "$prefix" "$launch"   # never consults the companion: there is no Codex job
  elif [ -z "$job" ] && [ -e "$ART/$prefix.progress" ] && [ "$backend" = ccr ]; then
    # .progress exists with no launch line: a ccr runner killed between creating the file and
    # recording the launch. Fail closed while any ccr launch for that alias is running.
    ! pgrep -f "ccr launch --model ${alias:-__none__} " >/dev/null 2>&1 || fail "release: $prefix.progress records no launch line, and a ccr launch for alias ${alias} is still running (ps -o pid,pgid,command | grep 'ccr launch --model ${alias}'); cancel it first"
  elif [ -n "$job" ] || [ -e "$ART/$prefix.progress" ]; then
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
# runner's exit table. A later explicit confirmation may resolve that uncertainty,
# but it never removes or rewrites the original sidecars.
cancel_resolution_ok() {  # <attempt stem>, e.g. $ART/04-consultation.attempt1
  local stem="$1" receipt exit_sha meta_sha
  receipt="$stem.cancel-resolved"
  [ -s "$receipt" ] && [ "$(mode "$receipt")" = 400 ] || return 1
  exit_sha=$(sha "$stem.exit") || return 1
  meta_sha=$(sha "$stem.meta") || return 1
  grep -qxF "exit_sha256=$exit_sha" "$receipt" && grep -qxF "meta_sha256=$meta_sha" "$receipt"
}
reject_unconfirmed_cancel() {
  local prefix="$1" f stem exit_val cancel_val unresolved=""
  shopt -s nullglob
  for f in "$ART/$prefix".attempt*.exit "$ART/$prefix.exit"; do
    [ -s "$f" ] || continue
    stem="${f%.exit}"; exit_val=$(cat "$f" 2>/dev/null)
    [ "$exit_val" != 5 ] || cancel_resolution_ok "$stem" || unresolved="${unresolved:+$unresolved, }$(basename "$stem") exit 5"
  done
  for f in "$ART/$prefix.meta" "$ART/$prefix".attempt*.meta; do
    [ -s "$f" ] || continue
    stem="${f%.meta}"; cancel_val=$(awk -F= '$1 == "cancel_confirmed" {print $2; exit}' "$f" 2>/dev/null)
    [ "$cancel_val" != no ] || cancel_resolution_ok "$stem" || unresolved="${unresolved:+$unresolved, }$(basename "$stem") cancel_confirmed=no"
  done
  shopt -u nullglob
  [ -z "$unresolved" ] || fail "$prefix records unconfirmed cancellation ($unresolved; a worker may still be running; run phase-gate.sh confirm-terminated $ART $prefix only after it is dead)"
}

# The liveness bar is intentionally the same one release uses. Unlike release,
# this operates on a finished exit-5 attempt and produces only an additive receipt.
confirm_terminated() {  # <prefix>; only a current exit-5/cancel-confirmed=no attempt
  local prefix="$1" stem="$ART/$1" backend pid pgid job root st tmp
  case "$prefix" in 04-consultation|06-resolution) ;; *)
    participant_ids | sed 's/^/02-/' | grep -qx -- "$prefix" || fail "confirm-terminated: unknown phase prefix '$prefix'";;
  esac
  [ -s "$stem.exit" ] && [ -s "$stem.meta" ] || fail "confirm-terminated: $prefix needs current .exit and .meta sidecars"
  [ "$(cat "$stem.exit")" = 5 ] || [ "$(awk -F= '$1 == "cancel_confirmed" {print $2; exit}' "$stem.meta")" = no ] || fail "confirm-terminated: $prefix has no unconfirmed cancellation"
  [ ! -e "$stem.cancel-resolved" ] || fail "confirm-terminated: $prefix already has a cancellation-resolution receipt"
  backend=$(awk -F= '$1 == "backend" {print $2; exit}' "$stem.meta")
  case "$backend" in
    ccr)
      pid=$(awk -F= '$1 == "pid" {print $2; exit}' "$stem.meta"); pgid=$(awk -F= '$1 == "pgid" {print $2; exit}' "$stem.meta")
      # An unreadable pgid caused the runner to kill the child directly. It is
      # already a terminal safety failure, but cannot be proven dead later by a
      # fabricated group id; require a real recorded group for recovery.
      case "$pid" in ''|*[!0-9]*) fail "confirm-terminated: $prefix ccr attempt has no numeric pid";; esac
      case "$pgid" in ''|unknown|*[!0-9]*) fail "confirm-terminated: $prefix ccr attempt has no numeric pgid";; esac
      kill -0 "$pid" 2>/dev/null && fail "confirm-terminated: runner pid $pid is still alive"
      ccr_release_check "$prefix" "0s launched backend=ccr pid=$pid pgid=$pgid"
      ;;
    codex)
      job=$(awk -F= '$1 == "job" {print $2; exit}' "$stem.meta")
      [ -n "$job" ] || fail "confirm-terminated: $prefix codex attempt has no job id"
      root=$(python3 -c 'import json,os,glob
p=os.path.expanduser("~/.claude/plugins/installed_plugins.json")
try: print(json.load(open(p))["plugins"]["codex@openai-codex"][0]["installPath"]); raise SystemExit
except Exception: pass
c=sorted(glob.glob(os.path.expanduser("~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs")))
print(os.path.dirname(os.path.dirname(c[-1])) if c else "")' 2>/dev/null)
      [ -n "$root" ] && [ -f "$root/scripts/codex-companion.mjs" ] || fail "confirm-terminated: cannot locate the codex plugin to check $job"
      st=$(node "$root/scripts/codex-companion.mjs" status "$job" --json 2>/dev/null | python3 -c 'import sys,json
try: d=json.load(sys.stdin); print((d.get("job") or {}).get("status") or "")
except Exception: print("")')
      case "$st" in completed|failed|cancelled|canceled) ;; *) fail "confirm-terminated: job $job status is '${st:-unknown}', not provably finished";; esac
      ! pgrep -f "task-worker.*--job-id $job" >/dev/null 2>&1 || fail "confirm-terminated: a worker process for job $job is still alive"
      ;;
    *) fail "confirm-terminated: $prefix meta has unknown backend '${backend:-missing}'";;
  esac
  tmp=$(mktemp "$ART/.cancel-resolved.XXXXXX") || fail "confirm-terminated: could not allocate receipt"
  printf 'confirmed=%s\nconfirmed_by=phase-gate.sh confirm-terminated\nbackend=%s\nexit_sha256=%s\nmeta_sha256=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$backend" "$(sha "$stem.exit")" "$(sha "$stem.meta")" > "$tmp" || { rm -f "$tmp"; fail "confirm-terminated: could not write receipt"; }
  chmod 400 "$tmp" || { rm -f "$tmp"; fail "confirm-terminated: could not seal receipt"; }
  mv "$tmp" "$stem.cancel-resolved" || { rm -f "$tmp"; fail "confirm-terminated: could not install receipt"; }
  accept "$(basename "$stem.cancel-resolved")" final
  echo "TERMINATION-CONFIRMED $prefix backend=$backend receipt=$(basename "$stem.cancel-resolved")"
}
# Every post-join gate: the review seal is a generated artifact — regenerate it
# from the CURRENT status and bodies and compare, so a status edit on
# a participant 02-p<k>.md or a body edit is caught whichever branch the gate would take
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
codex_skip_check() {  # a SKIPPED participant over its own successful attempt is not skippable
  local id
  for id in $(participant_ids); do case "$PSTATUS" in *"$id:COMPLETE"*) ;; *) reject_skip_over_success "02-$id";; esac; done
}
# An accepted consultation response (final ledger rows) cannot later be
# recorded SKIPPED: that would discard dispositions the ledger holds (round-28 L-01).
reject_skipped_after_accept() {  # uses $consultation
  if [ "$consultation" = SKIPPED ]; then
    [ -z "$(ledger_row 04-consultation.stdout)" ] || fail "04-consultation.md is SKIPPED but the consultation response was already accepted (see 00-accepted.sha256); an accepted consultation cannot be skipped"
    schema_repair_pending 04-consultation && fail "04-consultation.md is SKIPPED but its malformed completed response still requires the one canonical repair launch"
    reject_skip_over_success 04-consultation --manifest "$ART/03-matrix.tsv" --selection "$ART/03-debate-selection.tsv" --phase consultation
  fi
}
reject_resolution_skip_over_success() {  # uses $resolution; pre-report only
  if [ "$resolution" = SKIPPED ]; then
    [ -z "$(ledger_row 06-resolution.stdout)" ] || fail "06-resolution.md is SKIPPED but the resolution response was already accepted (see 00-accepted.sha256); an accepted resolution cannot be skipped"
    schema_repair_pending 06-resolution && fail "06-resolution.md is SKIPPED but its malformed completed response still requires the one canonical repair launch"
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
confirm-terminated)
  [ -n "$REPO" ] || die2 "confirm-terminated takes <ART> <prefix>"
  confirm_terminated "$REPO"
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
  participants_check
  # The schema marker is written once, before the packets are hashed, and hashed with them.
  if [ ! -e "$ART/00-schema" ]; then
    ! later_artifact_exists pre-phase3 || fail "00-schema missing but post-join artifacts exist: legacy run directory — start a fresh run"
    printf '%s\n' "$SCHEMA_MARKER" > "$ART/00-schema" || fail "could not write 00-schema"
  fi
  schema_check
  TO_LAUNCH=""; ANY_TERMINAL=0
  for id in $(participant_ids); do
    reject_unconfirmed_cancel "02-$id"
    if [ ! -s "$ART/02-$id.md" ] && [ -s "$ART/02-$id.exit" ] && [ "$(cat "$ART/02-$id.exit")" = 0 ] && [ -s "$ART/02-$id.stdout" ]; then
      fail "02-$id.exit records an accepted attempt with no 02-$id.md yet; write 02-$id.md from the existing sidecars instead of relaunching participant $id"
    fi
    if [ -s "$ART/02-$id.md" ]; then ANY_TERMINAL=1; else TO_LAUNCH="$TO_LAUNCH $id"; fi
  done
  if [ "$ANY_TERMINAL" = 1 ]; then
    # Re-entry with terminal participants: a joined run must still be consistent; an unjoined
    # COMPLETE review must not be silently redone (round-23 CX-03). Only SKIPPED, unjoined
    # participants (probe failed, declined) may be retried — each on its own claim.
    for id in $(participant_ids); do [ -s "$ART/02-$id.md" ] || fail "02-$id.md missing while other participants are terminal: write every participant's terminal file (SKIPPED for the ones not launched) before re-entering pre-codex"; done
    codex_status; accepted_check; launch_records_check; live_claim_check; review_seal_check; exchange_drift_check; codex_skip_check
    [ ! -e "$ART/02-review-seal.sha256" ] || fail "this run is already joined (02-review-seal.sha256 exists, phase2=$ST); Phase 2 cannot be relaunched — continue from the next gate or start a fresh run directory"
    TO_LAUNCH=""
    for id in $(participant_ids); do case "$PSTATUS" in *"$id:COMPLETE"*) ;; *) TO_LAUNCH="$TO_LAUNCH $id";; esac; done
    if [ -z "$TO_LAUNCH" ]; then
      fail "02-$EXCH.md already records a completed blind review (every participant is terminal and complete); run pre-phase3 (or start a fresh run directory) instead of relaunching"
    fi
  fi
  # `01-lead*.md` alone misses `01-lead.md.part`, the staging file of the atomic publish: between
  # the agent's write and its chmod that file is a fully readable copy of the review, and the .part
  # suffix puts it outside the glob. It is a lead artifact and is held to the same rule.
  LEAD=absent
  for f in "$ART"/01-lead*.md "$ART"/01-lead*.md.part; do
    [ -e "$f" ] || continue
    [ "$(mode "$f")" = 0 ] || fail "$(basename "$f") exists and is not sealed (mode $(mode "$f")); chmod 000 it or remove it before launching Codex"
    case "$f" in *.part) ;; *) LEAD=sealed;; esac
  done
  # Order matters in both directions, and differs by whether a hash record exists yet.
  # BEFORE the first record: hashcheck RECORDS on first sight, and that record is what makes the
  # brief immutable — so failing after it while advising "rebuild the brief" would tell the
  # operator to do the one thing that then fails on the recorded hash, discarding all of Phase 0.
  # AFTER a record exists: the hash comparison must speak first, or a brief that was mutated (or
  # that names the run directory) is reported as a brief with no Tier line (round-38 CX-02).
  [ -e "$ART/00-brief.md.sha256" ] || tier_check
  initial_packets
  tier_check
  repo_check sidecars  # after the hash check: the Target lines of the FROZEN brief are the pin (round-38 CX-02)
  # Written only once every check passed, so a refused re-entry never rewrites
  # it (round-36 CX-06); accepted final at the join.
  printf 'repo=%s\nbase=%s\nhead=%s\n' "$REPO_CANON" "$(cat "$ART/00-brief.md.base")" "$(cat "$ART/00-brief.md.head")" > "$ART/00-repo.txt" || fail "could not record the repository"
  # Last: one claim per participant to launch; nothing after this can fail and leave a claim
  # (round-27 CX-02). Every launch takes its own token (claim.p<k>=…).
  CLAIMS=""
  for id in $TO_LAUNCH; do claim_phase "02-$id" "02-$id.md"; CLAIMS="$CLAIMS claim.$id=$CLAIM_TOKEN"; done
  echo "PREFLIGHT-OK lead=$LEAD participants=$(participant_ids | wc -l | tr -d ' ') brief=$(cut -c1-12 "$ART/00-brief.md.sha256") scope=$(cut -c1-12 "$ART/00-scope.md.sha256") schema=$SCHEMA_MARKER tier=$(brief_tier)$CLAIMS"
  ;;
pre-phase3)
  [ -e "$ART/01-lead.md" ] || fail "01-lead.md missing: run Phase 1 in-context BEFORE opening any Codex output file"
  [ -s "$ART/01-lead.md" ] || fail "01-lead.md is empty"
  [ "$(mode "$ART/01-lead.md")" = 0 ] || fail "01-lead.md is not sealed (mode $(mode "$ART/01-lead.md")): it must stay mode 000 until this gate passes (mode 400 after an interrupted join means the seal hashing was cut short: chmod 000 it and re-run this gate)"
  schema_check; codex_status; initial_packets; tier_check; accepted_check; launch_records_check; live_claim_check; review_seal_check; exchange_drift_check; codex_skip_check
  [ -s "$ART/00-repo.txt" ] || fail "00-repo.txt missing: pre-codex was not run in this directory (it records the reviewed repository for citation checks)"
  repo_check file
  # The lead's terminal marker, checked BEFORE the review is sealed and accepted. post-join
  # checks the same string, but only after the seal is minted and the ledger rows are written —
  # by then an unfinished lead review has already been admitted as evidence. The checks above
  # test existence, size and mode; none of them tests that the agent actually finished. This is
  # its own unseal window rather than a line inside write_review_seal because that function
  # short-circuits when the seal already exists, and a re-entered join must re-check the marker.
  # fail() exits, and the EXIT trap reseals the lead, so a failure here cannot leave it readable.
  unseal_lead_for_hash
  LEAD_LAST=$(lastline "$ART/01-lead.md")   # read while unsealed: the diagnostic below cannot re-read a resealed file
  reseal_lead_after_hash
  [ "$LEAD_LAST" = "STATUS: PHASE 1 COMPLETE" ] || fail "01-lead.md does not end with STATUS: PHASE 1 COMPLETE: the lead review is unfinished (last non-blank line: $(printf '%s' "$LEAD_LAST" | cut -c1-80)). Do not seal or accept an incomplete review — rerun Phase 1."
  # Seal first, ledger rows second: each step is atomic and re-entrant, so a
  # join interrupted anywhere is completed by running this gate again
  # (round-40 CX-01), while a ledger that exists without a seal still means removal.
  write_review_seal
  # The exchange participant (lowest-numbered COMPLETE) is recorded once at the join; the
  # consultation and residual exchanges run on its session and its thread anchors them.
  if [ -n "$EXCH" ] && [ ! -e "$ART/02-exchange-participant" ]; then printf '%s\n' "$EXCH" > "$ART/02-exchange-participant" || fail "could not record the exchange participant"; fi
  # Completing an interrupted join (seal minted, its row missing) must leave the same ledger a
  # single pass writes: the rows accepted after the seal are re-accepted after it (round-40 CX-01).
  if [ -s "$LEDGER" ] && [ -z "$(ledger_row 02-review-seal.sha256)" ]; then
    tmp=$(mktemp "$ART/.accepted.XXXXXX") || fail "could not allocate ledger scratch file"
    awk '$2 != "00-schema" && $2 != "02-exchange-participant"' "$LEDGER" > "$tmp"
    chmod 400 "$tmp" && mv -f "$tmp" "$LEDGER" || { rm -f "$tmp"; fail "could not install the accept ledger"; }
  fi
  accept 00-repo.txt final
  accept 00-brief.md.scope.json final
  accept 02-review-seal.sha256 final
  accept 00-schema final
  [ -z "$EXCH" ] || accept 02-exchange-participant final
  # seal= is the out-of-band pin of the join: 00-run.md records this line
  # verbatim, so a join re-minted over edited bodies (indistinguishable from a
  # never-joined directory by the files alone — round-41 CX-01/CL-Q1) shows as
  # a changed fingerprint against the run record.
  echo "JOIN-OK lead=sealed codex=$ST codex_exit=$CX participants=$PSTATUS exchange=${EXCH:-none}${EXCH:+ via=$(participant_field "$EXCH" backend)$([ "$(participant_field "$EXCH" backend)" = ccr ] && printf ':%s' "$(participant_field "$EXCH" alias)")} brief=$(cut -c1-12 "$ART/00-brief.md.sha256") scope=$(cut -c1-12 "$ART/00-scope.md.sha256") seal=$(sha "$ART/02-review-seal.sha256" | cut -c1-12)"
  ;;
pre-consultation)
  phase_status 03-matrix.md 3
  # Phase 3 (reconciliation) has no SKIPPED form — it is always required.
  [ "$PST" = COMPLETE ] || fail "03-matrix.md was skipped; reconciliation is required"
  schema_check; codex_status; initial_packets; tier_check; accepted_check; launch_records_check; live_claim_check; review_seal_check; exchange_drift_check; codex_skip_check
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
  validate_provenance
  candidates=$(selection_count) || fail "could not count selected findings"
  # The selector, base packets and provenance are drafts until a Phase-4 artifact exists.
  accept 03-matrix.tsv draft
  accept 03-matrix.md draft
  accept 03-debate-selection.tsv draft
  accept 03-findings.ndjson draft
  accept 03-provenance.tsv draft
  if [ "$ST" = COMPLETE ]; then
    check_budget
    BUDGET=""
    schema_repair_prompt_check 04-consultation
    SCHEMA_INVALID=$(schema_invalid_count 04-consultation)
    if [ "$candidates" -gt 0 ]; then
      if [ "$SCHEMA_INVALID" -ge 2 ]; then BUDGET=" schema-repair=exhausted"
      elif budget_left; then
        if [ "$SCHEMA_INVALID" != 0 ]; then
          write_schema_repair_prompt 04-consultation
          BUDGET=" schema-repair=authorized prompt=04-consultation.prompt.retry.md"
        fi
        claim_phase 04-consultation 04-consultation.md
      else BUDGET=" budget=exhausted"; fi
    fi
    echo "CONSULTATION-OK codex=COMPLETE exchange=$EXCH via=$(participant_field "$EXCH" backend)$([ "$(participant_field "$EXCH" backend)" = ccr ] && printf ':%s' "$(participant_field "$EXCH" alias)") candidates=$candidates schema_invalid=$SCHEMA_INVALID seal=$(sha "$ART/02-review-seal.sha256" | cut -c1-12)${CLAIM_TOKEN:+ claim=$CLAIM_TOKEN}$BUDGET"
  else
    echo "CONSULTATION-OK codex=SKIPPED candidates=$candidates seal=$(sha "$ART/02-review-seal.sha256" | cut -c1-12)"
  fi
  ;;
pre-verification)
  schema_check; codex_status; initial_packets; tier_check; accepted_check; launch_records_check; live_claim_check; review_seal_check; exchange_drift_check; codex_skip_check
  [ -n "$(ledger_row 03-debate-selection.tsv)" ] && [ -n "$(ledger_row 03-findings.ndjson)" ] || fail "03-debate-selection.tsv / 03-findings.ndjson are not accepted; run pre-consultation first"
  phase_status 04-consultation.md 4
  consultation=$PST; consultation_policy=$PST_POLICY   # captured together: a later phase_status clears the global
  reject_unconfirmed_cancel 04-consultation  # any attempt, current or rotated (round-17 L-01)
  schema_repair_prompt_check 04-consultation
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
    elif [ "$consultation" = NOT_RUN_POLICY ]; then
      policy_omission_check 04-consultation "$consultation_policy"
    else
      fail "04-consultation.md has unknown terminal state"
    fi
  elif [ "$ST" = SKIPPED ]; then
    case "$consultation" in
      SKIPPED) ;;
      # Validated here too, not only at pre-resolution/pre-report: the earliest gate that can
      # see the state is the one that should reject a bypass wearing a policy label.
      NOT_RUN_POLICY) policy_omission_check 04-consultation "$consultation_policy";;
      *) fail "04-consultation.md is $consultation but Codex Phase 2 was SKIPPED; consultation cannot have run without Codex";;
    esac
  fi
  # The verifier inputs are generated here from the frozen base packets and the
  # accepted dispositions (round-26 CX-03); a draft until Phase 5 writes.
  write_packets
  accept 05-verifier-packets.ndjson draft
  check_budget
  echo "VERIFICATION-OK consultation=$consultation codex=$ST attempts=$(( $(runner_count 04-consultation) + $(runner_count 06-resolution) )) responses=$(response_count)"
  ;;
pre-resolution)
  schema_check; initial_packets; tier_check; codex_status; accepted_check; launch_records_check; live_claim_check; review_seal_check; exchange_drift_check; codex_skip_check
  # Phase 4 must have reached a terminal state before Phase 5, and hence before
  # any Phase 6 launch (round-18 CX-04).
  phase_status 04-consultation.md 4
  consultation=$PST; consultation_policy=$PST_POLICY   # captured together: a later phase_status clears the global
  [ "$consultation" != NOT_RUN_POLICY ] || policy_omission_check 04-consultation "$consultation_policy"
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
      schema_repair_prompt_check 06-resolution
      SCHEMA_INVALID=$(schema_invalid_count 06-resolution)
      if [ "$SCHEMA_INVALID" -ge 2 ]; then
        BUDGET=" schema-repair=exhausted"
      elif budget_left; then
        if [ "$SCHEMA_INVALID" != 0 ]; then
          write_schema_repair_prompt 06-resolution
          BUDGET=" schema-repair=authorized prompt=06-resolution.prompt.retry.md"
        fi
        claim_phase 06-resolution 06-resolution.md
      else BUDGET=" budget=exhausted"; fi
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
  SCHEMA_INVALID=${SCHEMA_INVALID:-$(schema_invalid_count 06-resolution)}
  echo "RESOLUTION-OK codex=$ST residual=$residual attempts=$(( $(runner_count 04-consultation) + $(runner_count 06-resolution) )) responses=$(response_count) schema_invalid=$SCHEMA_INVALID${CLAIM_TOKEN:+ claim=$CLAIM_TOKEN}${BUDGET:-}"
  ;;
pre-report)
  schema_check; initial_packets; tier_check; codex_status; accepted_check; launch_records_check; live_claim_check; review_seal_check; exchange_drift_check; codex_skip_check
  phase_status 04-consultation.md 4
  consultation=$PST; consultation_policy=$PST_POLICY   # captured together: a later phase_status clears the global
  # Both exchange phases, first: a SKIPPED consultation may still hide an
  # exit-5 / unconfirmed-cancel sidecar (round-16 CX-03), and a possibly live
  # worker outranks every other inconsistency.
  reject_unconfirmed_cancel 04-consultation
  reject_unconfirmed_cancel 06-resolution
  schema_repair_prompt_check 04-consultation
  schema_repair_prompt_check 06-resolution
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
  [ "$consultation" != NOT_RUN_POLICY ] || policy_omission_check 04-consultation "$consultation_policy"
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
  # 05-scope-attribution.tsv: per finding, whether its evidence path was in the requested
  # base's comparison, the reviewed one, or neither — so "would the old two-dot scope have
  # produced this finding?" is a lookup instead of archaeology. Descriptive only: it never
  # fails a run (anchor_error in validate-verdicts.py is the blocking rule), and it is written
  # once from inputs the ledger already froze, so a re-entered pre-report reuses it.
  if [ ! -e "$ART/05-scope-attribution.tsv" ]; then
    python3 "$SCOPE_ATTRIBUTION" --matrix "$ART/03-matrix.tsv" --verdicts "$ART/05-verdicts.tsv" \
      --scope "$ART/00-brief.md.scope.json" --repo "$(repo_field repo)" \
      --out "$ART/05-scope-attribution.tsv" >/dev/null || fail "could not write 05-scope-attribution.tsv"
  fi
  accept 05-scope-attribution.tsv final
  check_budget
  echo "REPORT-OK codex=$ST resolution=$resolution attempts=$(( $(runner_count 04-consultation) + $(runner_count 06-resolution) )) responses=$(response_count)"
  ;;
post-join)
  initial_packets
  [ -s "$ART/01-lead.md" ] || fail "01-lead.md missing or empty"
  [ -r "$ART/01-lead.md" ] || fail "01-lead.md is still sealed (mode $(mode "$ART/01-lead.md")); Phase 3 restores it to 600"
  [ "$(lastline "$ART/01-lead.md")" = "STATUS: PHASE 1 COMPLETE" ] || fail "01-lead.md does not end with STATUS: PHASE 1 COMPLETE"
  schema_check; tier_check; codex_status; accepted_check; launch_records_check; live_claim_check; review_seal_check; exchange_drift_check; codex_skip_check
  # The snapshot tree must still resolve after Codex returns, or Phase-5 citations at the head cannot be verified (codex-protocol.md).
  if [ -s "$ART/00-brief.md.tree" ]; then git -C "$(repo_field repo)" cat-file -e "$(cat "$ART/00-brief.md.tree")^{tree}" 2>/dev/null || fail "snapshot tree $(cat "$ART/00-brief.md.tree") no longer resolves in $(repo_field repo); it was garbage-collected or the repository moved"; fi
  echo "POST-JOIN-OK lead=complete codex=$ST participants=$PSTATUS brief=$(cut -c1-12 "$ART/00-brief.md.sha256") scope=$(cut -c1-12 "$ART/00-scope.md.sha256")"
  ;;
esac
