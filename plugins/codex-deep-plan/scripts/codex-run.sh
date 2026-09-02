#!/bin/bash
# codex-run.sh — run one read-only Codex task in the background, monitor it, return its result.
#
# Usage:
#   codex-run.sh <out-prefix> [--fresh|--resume-last] --prompt-file <file> [--stall-min N] [--max-min M] [--poll-sec S]
#
# Writes:
#   <out-prefix>.progress   one line per poll: elapsed, status, last log line   (tail this while waiting)
#   <out-prefix>.stdout     Codex final message (from `result`), verbatim
#   <out-prefix>.stderr     launch + result stderr
#   <out-prefix>.joblog     copy of the plugin's job log at the end
#   <out-prefix>.meta       job id, thread id, outcome, timings, exact command
#   <out-prefix>.exit       0 COMPLETED · 1 FAILED · 2 STALLED · 3 TIMEOUT · 4 LAUNCH-ERROR
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
USAGE='usage: codex-run.sh <out-prefix> [--fresh|--resume-last] --prompt-file <file> [--stall-min N] [--max-min M] [--poll-sec S]
       codex-run.sh --probe'
# Every invocation error exits 4 (LAUNCH-ERROR). Never exit 1 for a bad command line:
# 1 means "Codex failed, retry once" in the documented contract, and a typo must not look like that.
PREFIX="${1:-}"
case "$PREFIX" in ""|-*) echo "codex-run.sh: first argument must be an out-prefix path" >&2; echo "$USAGE" >&2; exit 4;; esac
shift
die4() { echo "codex-run.sh: $1" >&2; echo "$USAGE" >&2; echo 4 > "$PREFIX.exit" 2>/dev/null || true; exit 4; }
need() { [ $# -ge 2 ] || die4 "$1 requires a value"; case "$2" in -*) die4 "$1 requires a value (got option $2)";; esac; }
MODE="--fresh"; PROMPT_FILE=""; STALL_MIN=6; MAX_MIN=25; POLL=15
while [ $# -gt 0 ]; do
  case "$1" in
    --fresh|--resume-last) MODE="$1";;
    --prompt-file) need "$@"; PROMPT_FILE="$2"; shift;;
    --stall-min) need "$@"; STALL_MIN="$2"; shift;;
    --max-min) need "$@"; MAX_MIN="$2"; shift;;
    --poll-sec) need "$@"; POLL="$2"; shift;;
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
[ -n "$CODEX_ROOT" ] && [ -f "$CODEX_ROOT/scripts/codex-companion.mjs" ] || { echo "codex-run.sh: cannot locate the codex plugin (installed_plugins.json or ~/.claude/plugins/cache/openai-codex/codex/*)" >&2; echo 4 > "$PREFIX.exit"; exit 4; }
cc() { node "$CODEX_ROOT/scripts/codex-companion.mjs" "$@"; }
jobfield() { python3 -c "import sys,json;d=json.load(sys.stdin);j=d.get('job') or {};print(j.get('$1') or '')" 2>/dev/null; }

START=$(date +%s); now() { date +%s; }; elapsed() { echo $(( $(now) - START )); }
# never clobber a previous attempt: rotate its sidecars to <prefix>.attemptN.*
if [ -e "$PREFIX.meta" ]; then
  N=1; while ls "$PREFIX.attempt$N."* >/dev/null 2>&1; do N=$((N+1)); done
  for ext in stdout stderr progress joblog meta exit; do [ -e "$PREFIX.$ext" ] && mv "$PREFIX.$ext" "$PREFIX.attempt$N.$ext"; done
  echo "codex-run.sh: previous attempt rotated to $PREFIX.attempt$N.*"
fi
: > "$PREFIX.progress"; : > "$PREFIX.stderr"
CMD="task $MODE --background --prompt-file $PROMPT_FILE"
LAUNCH=$(cc task "$MODE" --background --prompt-file "$PROMPT_FILE" 2>>"$PREFIX.stderr") || true
JOB=$(printf '%s' "$LAUNCH" | grep -oE 'task-[a-z0-9]+-[a-z0-9]+' | head -1)
if [ -z "$JOB" ]; then
  printf 'LAUNCH-ERROR\n%s\n' "$LAUNCH" >> "$PREFIX.stderr"
  printf 'outcome=LAUNCH-ERROR\ncommand=%s\n' "$CMD" > "$PREFIX.meta"; echo 4 > "$PREFIX.exit"
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
  echo "command=$CMD"; echo "stdout_bytes=$(wc -c < "$PREFIX.stdout" | tr -d ' ')"
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
