#!/bin/bash
# codex-run.sh — run one read-only Codex task in the background, monitor it, return its result.
#
# Usage:
#   codex-run.sh <out-prefix> [--fresh|--resume-last] --prompt-file <file> [--stall-min N] [--max-min M] [--poll-sec S] [--claim <token>]
#
#   --claim <token>: the launch was authorized by a gate that created <out-prefix>.claim/ (the
#   two-model review's phase-gate.sh) and printed claim=<token>. The runner then writes NOTHING
#   under the prefix — not even .exit — before it owns <out-prefix>.claim/runner, and it takes
#   only the claim whose owner file carries that token (a rotated or replaced claim is refused,
#   round-36 CX-03): a missing, replaced or already-taken claim, and any argument error, exit 4
#   with a stderr message only. The claim a runner took is the review's one record
#   of a launch; sidecars are derived from it. Without --claim (codex-debate, codex-deep-plan) a
#   claim directory is still honoured when present, but its absence is not an error.
#
# Writes:
#   <out-prefix>.progress   one line per poll: elapsed, status, last log line   (tail this while waiting)
#   <out-prefix>.stdout     Codex final message (from `result`), verbatim
#   <out-prefix>.stderr     launch + result stderr
#   <out-prefix>.joblog     copy of the plugin's job log at the end
#   <out-prefix>.meta       job id, thread id, outcome, timings, exact command
#   <out-prefix>.exit       0 COMPLETED · 1 FAILED · 2 STALLED · 3 TIMEOUT · 4 LAUNCH-ERROR
#   Exit 4 with NO sidecar written: another runner already took <out-prefix>.claim/, or (--claim)
#   no claim exists / the arguments are invalid.
#
# Safety: refuses --write. Cancels the job on STALLED/TIMEOUT so nothing is left running.
# Run it with the caller's background execution (Claude Code: run_in_background) so a foreground
# shell limit can never kill the Codex worker mid-turn.

set -u
if [ "${1:-}" = "--probe" ]; then
  CODEX_ROOT=$(python3 -c 'import json,os,glob
p=os.path.expanduser("~/.claude/plugins/installed_plugins.json")
try: print(json.load(open(p))["plugins"]["codex@openai-codex"][0]["installPath"]); raise SystemExit
except Exception: pass
c=sorted(glob.glob(os.path.expanduser("~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs")))
print(os.path.dirname(os.path.dirname(c[-1])) if c else "")')
  [ -n "$CODEX_ROOT" ] || { echo "PROBE UNAVAILABLE: codex plugin not found"; exit 1; }
  OUT=$(node "$CODEX_ROOT/scripts/codex-companion.mjs" setup --json 2>&1) || { echo "PROBE FAILED: setup exited non-zero"; printf '%s\n' "$OUT" | tail -5; exit 1; }
  printf '%s' "$OUT" | python3 -c 'import sys,json
d=json.load(sys.stdin); ok=bool(d.get("ready")) and bool(d.get("auth",{}).get("loggedIn"))
label="PROBE SUCCEEDED" if ok else "PROBE UNAVAILABLE"
print(label, "ready=%s loggedIn=%s codex=%s" % (d.get("ready"), d.get("auth",{}).get("loggedIn"), d.get("codex",{}).get("detail")))
raise SystemExit(0 if ok else 1)'
  exit $?
fi
USAGE='usage: codex-run.sh <out-prefix> [--fresh|--resume-last] --prompt-file <file> [--stall-min N] [--max-min M] [--poll-sec S] [--claim <token>]
       codex-run.sh --probe'
# Every invocation error exits 4 (LAUNCH-ERROR). Never exit 1 for a bad command line:
# 1 means "Codex failed, retry once" in the documented contract, and a typo must not look like that.
PREFIX="${1:-}"
case "$PREFIX" in ""|-*) echo "codex-run.sh: first argument must be an out-prefix path" >&2; echo "$USAGE" >&2; exit 4;; esac
shift
# With --claim nothing may be written before the claim is owned, so an argument
# error leaves no .exit (the gate's claim stays in flight until the operator
# relaunches or releases it); the flag is detected before parsing for that reason.
CLAIM_MODE=0; CLAIM_TOKEN=""; for _a in "$@"; do [ "$_a" = "--claim" ] && CLAIM_MODE=1; done  # exact argument, never a substring of a value (round-33 CX-03)
# An argument error writes <prefix>.exit only for the claim-less sibling plugins: with --claim, or when a launch claim exists for the prefix (a gate-issued prefix), nothing is written (round-42 CL-04).
die4() { echo "codex-run.sh: $1" >&2; echo "$USAGE" >&2; [ "$CLAIM_MODE" = 1 ] || [ -d "${PREFIX:-/nonexistent}.claim" ] || echo 4 > "$PREFIX.exit" 2>/dev/null || true; exit 4; }
need() { [ $# -ge 2 ] || die4 "$1 requires a value"; case "$2" in -*) die4 "$1 requires a value (got option $2)";; esac; }
MODE="--fresh"; PROMPT_FILE=""; STALL_MIN=6; MAX_MIN=25; POLL=15
while [ $# -gt 0 ]; do
  case "$1" in
    --fresh|--resume-last) MODE="$1";;
    --prompt-file) need "$@"; PROMPT_FILE="$2"; shift;;
    --stall-min) need "$@"; STALL_MIN="$2"; shift;;
    --max-min) need "$@"; MAX_MIN="$2"; shift;;
    --poll-sec) need "$@"; POLL="$2"; shift;;
    --claim) need "$@"; CLAIM_MODE=1; CLAIM_TOKEN="$2"; shift;;
    --write) die4 "--write is refused; this runner is read-only";;
    *) die4 "unknown arg $1";;
  esac; shift
done
for v in STALL_MIN MAX_MIN POLL; do
  eval "val=\$$v"
  case "$val" in ''|*[!0-9]*) die4 "--$(echo "$v" | tr 'A-Z_' 'a-z-') requires a whole number (got '$val')";; esac
  # Strip to base 10: bash reads a leading-zero literal as octal, so "08" would
  # abort arithmetic later with "value too great for base". Also bound the range
  # so an oversized value cannot silently overflow.
  val=$(printf '%s' "$val" | sed 's/^0*//'); [ -n "$val" ] && [ "${#val}" -le 6 ] || die4 "--$(echo "$v" | tr 'A-Z_' 'a-z-') must be between 1 and 999999"
  eval "$v=\$val"
done
[ -n "$PROMPT_FILE" ] || die4 "--prompt-file is required"
[ -r "$PROMPT_FILE" ] || die4 "prompt file not readable: $PROMPT_FILE"

CODEX_ROOT=$(python3 -c 'import json,os,glob
p=os.path.expanduser("~/.claude/plugins/installed_plugins.json")
try: print(json.load(open(p))["plugins"]["codex@openai-codex"][0]["installPath"]); raise SystemExit
except Exception: pass
c=sorted(glob.glob(os.path.expanduser("~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs")))
print(os.path.dirname(os.path.dirname(c[-1])) if c else "")')
rotate_previous_attempt() {
  # never clobber a previous attempt: rotate its sidecars to <prefix>.attemptN.*
  # A launch error leaves .exit without .meta, and a runner killed mid-flight
  # leaves .progress without either, so all three are attempt markers and an
  # orphaned attempt is rotated as a unit, never truncated.
  if [ -e "$PREFIX.meta" ] || [ -e "$PREFIX.exit" ] || [ -e "$PREFIX.progress" ]; then
    N=1; while ls "$PREFIX.attempt$N."* >/dev/null 2>&1; do N=$((N+1)); done
    for ext in stdout stderr progress joblog meta exit; do [ -e "$PREFIX.$ext" ] && mv "$PREFIX.$ext" "$PREFIX.attempt$N.$ext"; done
    echo "codex-run.sh: previous attempt rotated to $PREFIX.attempt$N.*"
  fi
}
stamp_claim() {
  # A launch gate that hands off to this runner records its claim in
  # <prefix>.claim/. One claim authorizes ONE runner: the runner takes the claim
  # with an atomic mkdir of <prefix>.claim/runner BEFORE it touches any sidecar,
  # so two runners handed the same prefix (a delayed launcher whose claim was
  # reclaimed, a retry without a fresh gate, a double launch) cannot both start
  # or rotate each other's files (round-28 CX-02, round-29 CX-02). The loser
  # exits 4 and writes nothing under the prefix.
  if [ ! -d "$PREFIX.claim" ] && [ "$CLAIM_MODE" != 1 ]; then return 0; fi
  # Taking the claim (token check, mkdir runner, pid) is serialized against the
  # gate rotating or replacing it by <prefix>.claim.lock, the same atomic-mkdir
  # lock the gate holds while it rotates (round-38 CX-03). The lock stays held
  # until the previous attempt's sidecars are rotated away (unlock_claim), so a
  # stale <prefix>.exit can never make a concurrent gate treat this runner's
  # claim as finished and rotate it (round-39 CX-01). A lock older than a
  # minute belongs to a dead process.
  local lock="$PREFIX.claim.lock" i=0 now m
  while ! mkdir "$lock" 2>/dev/null; do
    now=$(date +%s); m=$(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || echo "$now")
    if [ $(( now - m )) -ge 60 ] && rmdir "$lock" 2>/dev/null; then continue; fi  # stale and reclaimed; an unremovable one is retried like a held one (bounded)
    i=$((i+1)); [ "$i" -lt 50 ] || { echo "codex-run.sh: $lock is held by a launch gate or another runner (a claim is being taken or rotated right now), or is stale and cannot be removed; retry in a moment (no sidecar was written)" >&2; exit 4; }
    sleep 0.1
  done
  if [ ! -d "$PREFIX.claim" ]; then
    rmdir "$lock" 2>/dev/null
    [ "$CLAIM_MODE" = 1 ] || return 0
    echo "codex-run.sh: --claim given but $PREFIX.claim does not exist; run the launch gate first (no sidecar was written)" >&2
    exit 4
  fi
  if [ "$CLAIM_MODE" = 1 ] && ! grep -qxF "token=$CLAIM_TOKEN" "$PREFIX.claim/owner" 2>/dev/null; then
    rmdir "$lock" 2>/dev/null
    echo "codex-run.sh: $PREFIX.claim does not carry token $CLAIM_TOKEN (the claim was rotated or replaced since the gate printed it); re-run the launch gate and use its new token (no sidecar was written)" >&2
    exit 4
  fi
  if ! mkdir "$PREFIX.claim/runner" 2>/dev/null; then
    rmdir "$lock" 2>/dev/null
    echo "codex-run.sh: $PREFIX.claim is already taken by runner $(cat "$PREFIX.claim/runner/pid" 2>/dev/null || echo unknown); re-run the launch gate before launching again (no sidecar was written)" >&2
    exit 4
  fi
  printf '%s\n' "$$" > "$PREFIX.claim/runner/pid"
  printf 'runner_pid=%s\nstarted=%s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$PREFIX.claim/owner" 2>/dev/null
  HELD_LOCK="$lock"
  return 0
}
HELD_LOCK=""
unlock_claim() { [ -z "$HELD_LOCK" ] || rmdir "$HELD_LOCK" 2>/dev/null; HELD_LOCK=""; }
[ -n "$CODEX_ROOT" ] && [ -f "$CODEX_ROOT/scripts/codex-companion.mjs" ] || {
  stamp_claim; rotate_previous_attempt; unlock_claim
  MSG="codex-run.sh: cannot locate the codex plugin (installed_plugins.json or ~/.claude/plugins/cache/openai-codex/codex/*)"
  echo "$MSG" >&2; printf 'LAUNCH-ERROR\n%s\n' "$MSG" > "$PREFIX.stderr"; printf '0s LAUNCH-ERROR: codex plugin not found\n' > "$PREFIX.progress"
  printf 'outcome=LAUNCH-ERROR\nlast_error=codex plugin not found\nmode=%s\ncommand=task %s --background --prompt-file %s\n' "$MODE" "$MODE" "$PROMPT_FILE" > "$PREFIX.meta"; echo 4 > "$PREFIX.exit"; exit 4; }
cc() { node "$CODEX_ROOT/scripts/codex-companion.mjs" "$@"; }
jobfield() { python3 -c "import sys,json;d=json.load(sys.stdin);j=d.get('job') or {};print(j.get('$1') or '')" 2>/dev/null; }

START=$(date +%s); now() { date +%s; }; elapsed() { echo $(( $(now) - START )); }
stamp_claim; rotate_previous_attempt; unlock_claim
: > "$PREFIX.progress"; : > "$PREFIX.stderr"
CMD="task $MODE --background --prompt-file $PROMPT_FILE"
LAUNCH=$(cc task "$MODE" --background --prompt-file "$PROMPT_FILE" 2>>"$PREFIX.stderr") || true
JOB=$(printf '%s' "$LAUNCH" | grep -oE 'task-[a-z0-9]+-[a-z0-9]+' | head -1)
if [ -z "$JOB" ]; then
  printf 'LAUNCH-ERROR\n%s\n' "$LAUNCH" >> "$PREFIX.stderr"
  printf 'outcome=LAUNCH-ERROR\nmode=%s\ncommand=%s\n' "$MODE" "$CMD" > "$PREFIX.meta"; echo 4 > "$PREFIX.exit"
  echo "codex-run.sh: LAUNCH-ERROR (see $PREFIX.stderr)"; exit 4
fi
echo "$(elapsed)s launched job=$JOB" >> "$PREFIX.progress"

OUTCOME=""; LOGFILE=""; LAST_ACTIVITY=$(now); PREV_SIG=""
while :; do
  sleep "$POLL"
  SJ=$(cc status "$JOB" --json 2>/dev/null || true)
  STATUS=$(printf '%s' "$SJ" | jobfield status); PID=$(printf '%s' "$SJ" | jobfield pid)
  [ -z "$LOGFILE" ] && LOGFILE=$(printf '%s' "$SJ" | jobfield logFile)
  LASTLINE=""; SIG=""
  if [ -n "$LOGFILE" ] && [ -r "$LOGFILE" ]; then
    LASTLINE=$(tail -n 1 "$LOGFILE" 2>/dev/null | cut -c1-140)
    SIG=$(stat -f '%z:%m' "$LOGFILE" 2>/dev/null || stat -c '%s:%Y' "$LOGFILE" 2>/dev/null)
  fi
  if [ "$SIG" != "$PREV_SIG" ]; then LAST_ACTIVITY=$(now); PREV_SIG="$SIG"; fi
  IDLE=$(( $(now) - LAST_ACTIVITY ))
  echo "$(elapsed)s status=${STATUS:-?} idle=${IDLE}s | $LASTLINE" >> "$PREFIX.progress"

  case "$STATUS" in
    completed) OUTCOME=COMPLETED; break;;
    failed|cancelled|canceled) OUTCOME=FAILED; break;;
    running|queued|"")
      # dead worker: status says running but no task-worker process carries this job id
      if [ "$STATUS" = "running" ] && ! pgrep -f "task-worker.*--job-id $JOB" >/dev/null 2>&1; then
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then :; else
          # give the plugin one poll to flip the status itself
          sleep "$POLL"; ST2=$(cc status "$JOB" --json 2>/dev/null | jobfield status)
          case "$ST2" in completed) OUTCOME=COMPLETED; break;; failed|cancelled|canceled) OUTCOME=FAILED; break;; esac
          echo "$(elapsed)s WORKER-DEAD (status=$ST2, no task-worker process)" >> "$PREFIX.progress"; OUTCOME=FAILED; break
        fi
      fi
      if [ "$IDLE" -ge $(( STALL_MIN * 60 )) ]; then OUTCOME=STALLED; break; fi
      if [ "$(elapsed)" -ge $(( MAX_MIN * 60 )) ]; then OUTCOME=TIMEOUT; break; fi;;
    *) echo "$(elapsed)s unknown status '$STATUS'" >> "$PREFIX.progress";;
  esac
done

UNCONFIRMED_CANCEL=0
if [ "$OUTCOME" = "STALLED" ] || [ "$OUTCOME" = "TIMEOUT" ] || { [ "$OUTCOME" = "FAILED" ] && [ "${STATUS:-}" = "running" ]; }; then
  CANCEL_RC=0; cc cancel "$JOB" >>"$PREFIX.stderr" 2>&1 || CANCEL_RC=$?
  # Verify the cancel instead of asserting it: re-read status and look for a live
  # worker. Report honestly if either still says running — a claimed cancel that
  # did not happen is worse than a reported one that failed.
  PHANTOM=""; i=0
  while [ $i -lt 5 ]; do
    sleep 1; i=$((i+1))
    ST3=$(cc status "$JOB" --json 2>/dev/null | jobfield status)
    case "$ST3" in cancelled|canceled|completed|failed) PHANTOM=""; break;; *) PHANTOM="status=$ST3";; esac
  done
  if pgrep -f "task-worker.*--job-id $JOB" >/dev/null 2>&1; then PHANTOM="${PHANTOM:+$PHANTOM }worker-process-alive"; fi
  if [ -n "$PHANTOM" ]; then
    # Exit 5, not the outcome's own code: a live worker must never be retried,
    # and 1/2/3 all tell the caller to retry or to treat the job as finished.
    UNCONFIRMED_CANCEL=1
    echo "$(elapsed)s $OUTCOME → cancel of $JOB NOT confirmed (cancel_rc=$CANCEL_RC $PHANTOM); a worker may still be running" >> "$PREFIX.progress"
    echo "codex-run.sh: cancel of $JOB not confirmed ($PHANTOM); DO NOT retry — a worker may still be running. Check with: node <codex-plugin>/scripts/codex-companion.mjs status $JOB --json" >&2
  else
    echo "$(elapsed)s $OUTCOME → cancelled $JOB (confirmed: no running job, no worker process)" >> "$PREFIX.progress"
  fi
fi
# always try to collect whatever final message exists
cc result "$JOB" > "$PREFIX.stdout" 2>>"$PREFIX.stderr" || true
[ -n "$LOGFILE" ] && [ -r "$LOGFILE" ] && cp "$LOGFILE" "$PREFIX.joblog" 2>/dev/null
THREAD=$(grep -oE 'Codex session ID: [0-9a-f-]+' "$PREFIX.stdout" | head -1 | awk '{print $4}')
{
  echo "outcome=$OUTCOME"; echo "job=$JOB"; echo "thread=${THREAD:-unknown}"
  echo "elapsed_sec=$(elapsed)"; echo "idle_at_end_sec=$IDLE"; echo "stall_min=$STALL_MIN max_min=$MAX_MIN"
  echo "mode=$MODE"; echo "command=$CMD"; echo "stdout_bytes=$(wc -c < "$PREFIX.stdout" | tr -d ' ')"
  LASTERR=""; [ -n "$LOGFILE" ] && [ -r "$LOGFILE" ] && LASTERR=$(grep -E "Codex error:|Turn failed" "$LOGFILE" | tail -1 | cut -c1-300)
  echo "last_error=${LASTERR:-none}"; echo "cancel_confirmed=$([ "${UNCONFIRMED_CANCEL:-0}" = "1" ] && echo no || echo "$([ "$OUTCOME" = "STALLED" ] || [ "$OUTCOME" = "TIMEOUT" ] && echo yes || echo n/a)")"
} > "$PREFIX.meta"
case "$OUTCOME" in COMPLETED) RC=0;; FAILED) RC=1;; STALLED) RC=2;; TIMEOUT) RC=3;; *) RC=1;; esac
# An unconfirmed cancel outranks the outcome: 1, 2 and 3 all invite a retry or
# treat the job as finished, and neither is safe while a worker may be alive.
[ "${UNCONFIRMED_CANCEL:-0}" = "1" ] && RC=5
echo "$RC" > "$PREFIX.exit"
echo "codex-run.sh: $OUTCOME job=$JOB elapsed=$(elapsed)s stdout=$(wc -c < "$PREFIX.stdout" | tr -d ' ')B → $PREFIX.{stdout,progress,meta}"
exit "$RC"
