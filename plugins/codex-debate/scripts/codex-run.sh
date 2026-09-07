#!/bin/bash
# codex-run.sh — run one read-only second-model task in the background, monitor it, return its result.
#
# Usage:
#   codex-run.sh <out-prefix> [--via codex|ccr:<alias>] [--fresh|--resume-last] --prompt-file <file>
#                [--stall-min N] [--max-min M] [--poll-sec S] [--claim <token>]
#                [--max-turns N] [--resume-session <id>]          (ccr backend only)
#   codex-run.sh --probe [--via ccr:<alias> [--record-dir <dir>]]
#
#   --via codex (default): the Codex CLI plugin's companion (task/status/result/cancel).
#   --via ccr:<alias>: a headless Claude Code launched through the claude-code-router gateway
#   (`ccr launch --model <alias>`), routed to whatever provider the alias names on this machine.
#   Both backends honour the same contract: prompt file in, the six sidecars out, exit 0-5, the
#   claim directory, and the refusal of --write. The ccr backend is kept read-only by
#   `--permission-mode plan` (Claude Code's own permission engine), an empty strict MCP config,
#   and the disallowed edit tools — a disallow-list alone does not stop Bash from writing.
#   Every ccr launch requires a recorded read-only smoke for the alias in the prefix's directory
#   (`<dir>/.ccr-smoke.<alias>`, written by `--probe --via ccr:<alias> --record-dir <dir>`);
#   without a matching record the launch is refused (exit 4) — fail closed, one smoke per alias
#   per run directory.
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
#   <out-prefix>.stdout     final message (Codex `result`, or the ccr child's `result` event text), verbatim
#   <out-prefix>.stderr     launch + result stderr
#   <out-prefix>.joblog     copy of the plugin's job log (codex) or the raw stream-json (ccr)
#   <out-prefix>.meta       backend, job/session ids, thread id, outcome, timings, exact command
#   <out-prefix>.exit       0 COMPLETED · 1 FAILED · 2 STALLED · 3 TIMEOUT · 4 LAUNCH-ERROR · 5 UNCONFIRMED-CANCEL
#   Exit 4 with NO sidecar written: another runner already took <out-prefix>.claim/, or (--claim)
#   no claim exists / the arguments are invalid.
#   ccr backend also writes <dir>/.ccr-last-session (the session id --resume-last resumes).
#
# Safety: refuses --write. Cancels the job on STALLED/TIMEOUT so nothing is left running; a ccr
# child runs in its own process group so the whole tree is signalled and its pgid is recorded.
# Run it with the caller's background execution (Claude Code: run_in_background) so a foreground
# shell limit can never kill the worker mid-turn.

set -u
CCR_MIN_VERSION="0.4.11"
CCR_MAX_TURNS_DEFAULT=100
# The exact read-only launch line for the ccr backend. It is the one line every ccr participant
# runs and the one line the probe's smoke verifies; its digest is part of the smoke record so a
# changed line invalidates every earlier smoke.
ccr_launch_argv() {  # <alias> <max-turns> [session-id]
  printf '%s\n' ccr launch --model "$1" --permission-mode plan -p --no-lifecycle --no-statusline -- \
    --output-format stream-json --verbose --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
    --disallowedTools Write,Edit,MultiEdit,NotebookEdit,Agent --max-turns "$2"
  [ -z "${3:-}" ] || printf '%s\n' --resume "$3"
}
ccr_launch_digest() { ccr_launch_argv ALIAS N | shasum -a 256 | cut -c1-16; }
codex_root() {
  python3 -c 'import json,os,glob
p=os.path.expanduser("~/.claude/plugins/installed_plugins.json")
try: print(json.load(open(p))["plugins"]["codex@openai-codex"][0]["installPath"]); raise SystemExit
except Exception: pass
c=sorted(glob.glob(os.path.expanduser("~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs")))
print(os.path.dirname(os.path.dirname(c[-1])) if c else "")'
}
# --- ccr helpers (shared by the probe and the launch path) -----------------------------------
ccr_version() { ccr version 2>/dev/null | head -1 | sed -nE 's/^ccr[[:space:]]+v?([0-9]+\.[0-9]+\.[0-9]+).*$/\1/p'; }
version_ge() {  # X.Y.Z >= A.B.C
  python3 -c 'import sys
a=[int(x) for x in sys.argv[1].split(".")]; b=[int(x) for x in sys.argv[2].split(".")]
raise SystemExit(0 if a>=b else 1)' "$1" "$2"
}
ccr_model_json() { ccr model show "$1" --json 2>/dev/null; }
ccr_model_field() {  # <json> <field>: alias provider provider_model claude_model_id compatibility tools
  printf '%s' "$1" | python3 -c 'import sys,json
d=json.load(sys.stdin); f=sys.argv[1]
def find(o,k):
    if isinstance(o,dict):
        if k in o: return o[k]
        for v in o.values():
            r=find(v,k)
            if r is not None: return r
    if isinstance(o,list):
        for v in o:
            r=find(v,k)
            if r is not None: return r
    return None
if f=="tools":
    v=find(d.get("effective_capabilities",d),"supports_tools"); print("true" if v is True else "false")
else:
    v=d.get(f); print("" if v is None else v)' "$2" 2>/dev/null
}
# Read the parts of the ccr backend's precondition that do not depend on the run directory.
# Sets CCR_VER, MODEL_JSON, PROVIDER, PROVIDER_MODEL, CLAUDE_MODEL, COMPAT, TOOLS; on failure sets REASON and returns 1.
# (Not run in a command substitution: the variables must reach the caller.)
ccr_preflight() {  # <alias>
  command -v ccr >/dev/null 2>&1 || { REASON="ccr not found on PATH (install claude-code-router >= $CCR_MIN_VERSION)"; return 1; }
  CCR_VER=$(ccr_version); [ -n "$CCR_VER" ] || { REASON="cannot parse 'ccr version' output"; return 1; }
  version_ge "$CCR_VER" "$CCR_MIN_VERSION" || { REASON="requires ccr >= $CCR_MIN_VERSION (found $CCR_VER)"; return 1; }
  MODEL_JSON=$(ccr_model_json "$1") && [ -n "$MODEL_JSON" ] || { REASON="ccr model show $1 --json failed (unknown alias on this machine?)"; return 1; }
  PROVIDER=$(ccr_model_field "$MODEL_JSON" provider); PROVIDER_MODEL=$(ccr_model_field "$MODEL_JSON" provider_model)
  CLAUDE_MODEL=$(ccr_model_field "$MODEL_JSON" claude_model_id); COMPAT=$(ccr_model_field "$MODEL_JSON" compatibility); TOOLS=$(ccr_model_field "$MODEL_JSON" tools)
  [ -n "$PROVIDER" ] || { REASON="ccr model show $1 --json has no provider field"; return 1; }
  [ "$TOOLS" = true ] || { REASON="alias $1 reports supports_tools=$TOOLS; a reviewer needs tool calls"; return 1; }
  return 0
}
# Match the recorded smoke against the current alias: version, model and launch line must all agree.
ccr_smoke_check() {  # <dir> <alias>  (needs ccr_preflight first)
  local f="$1/.ccr-smoke.$2"
  [ -r "$f" ] || { REASON="ccr smoke missing for $2: run 'codex-run.sh --probe --via ccr:$2 --record-dir $1' first (smoke record $f)"; return 1; }
  grep -qxF "readonly=verified" "$f" || { REASON="ccr smoke for $2 is not 'readonly=verified' ($f)"; return 1; }
  grep -qxF "ccr=$CCR_VER" "$f" || { REASON="ccr smoke for $2 was recorded with another ccr version (now $CCR_VER); re-run the probe"; return 1; }
  grep -qxF "model=$PROVIDER_MODEL" "$f" || { REASON="ccr smoke for $2 was recorded for another model (now $PROVIDER_MODEL); re-run the probe"; return 1; }
  grep -qxF "launch_sha256=$(ccr_launch_digest)" "$f" || { REASON="ccr smoke for $2 was recorded for another launch line; re-run the probe"; return 1; }
  return 0
}
# Start a command in its own process group; echoes nothing, sets CHILD (pid) — pgid == pid.
# exec, so that when it is called as `start_in_own_group … &` the background pid IS the child (and its pgid).
start_in_own_group() { exec python3 -c 'import os,sys; os.setpgrp(); os.execvp(sys.argv[1], sys.argv[1:])' "$@"; }
pgid_of() { ps -o pgid= -p "$1" 2>/dev/null | tr -d ' '; }
group_alive() { kill -0 -- "-$1" 2>/dev/null; }
# TERM then KILL the whole group; return 0 when nothing in it is left, 1 when something survives.
kill_group() {  # <pgid>
  local i
  kill -TERM -- "-$1" 2>/dev/null || true
  for i in 1 2 3 4 5; do group_alive "$1" || return 0; sleep 1; done
  kill -KILL -- "-$1" 2>/dev/null || true
  for i in 1 2 3 4 5; do group_alive "$1" || return 0; sleep 1; done
  return 1
}
# stream-json readers
stream_field() {  # <joblog> init-session|init-model|result-text|has-result
  python3 - "$1" "$2" <<'PY' 2>/dev/null
import sys,json
path,what=sys.argv[1],sys.argv[2]; sid=model=""; res=None
for line in open(path,encoding="utf-8",errors="replace"):
    line=line.strip()
    if not line.startswith("{"): continue
    try: e=json.loads(line)
    except Exception: continue
    if e.get("type")=="system" and e.get("subtype")=="init":
        sid=sid or e.get("session_id","") or ""; model=model or e.get("model","") or ""
    if e.get("type")=="result": res=e
if what=="init-session": print(sid)
elif what=="init-model": print(model)
elif what=="has-result": print("yes" if res is not None else "no")
elif what=="result-ok": print("yes" if res is not None and not res.get("is_error") and res.get("subtype","success")=="success" else "no")
elif what=="result-subtype": print("" if res is None else "%s is_error=%s" % (res.get("subtype","success"), bool(res.get("is_error"))))
elif what=="result-text":
    if res is not None:
        r=res.get("result")
        if r is None: r=""
        sys.stdout.write(r if isinstance(r,str) else json.dumps(r))
PY
}

# --- probe -----------------------------------------------------------------------------------
if [ "${1:-}" = "--probe" ]; then
  shift; VIA=codex; RECORD_DIR=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --via) [ $# -ge 2 ] || { echo "PROBE UNAVAILABLE: --via requires a value"; exit 1; }; VIA="$2"; shift;;
      --record-dir) [ $# -ge 2 ] || { echo "PROBE UNAVAILABLE: --record-dir requires a value"; exit 1; }; RECORD_DIR="$2"; shift;;
      *) echo "PROBE UNAVAILABLE: unknown probe arg $1"; exit 1;;
    esac; shift
  done
  case "$VIA" in
    codex)
      CODEX_ROOT=$(codex_root)
      [ -n "$CODEX_ROOT" ] || { echo "PROBE UNAVAILABLE: codex plugin not found"; exit 1; }
      OUT=$(node "$CODEX_ROOT/scripts/codex-companion.mjs" setup --json 2>&1) || { echo "PROBE FAILED: setup exited non-zero"; printf '%s\n' "$OUT" | tail -5; exit 1; }
      printf '%s' "$OUT" | python3 -c 'import sys,json
d=json.load(sys.stdin); ok=bool(d.get("ready")) and bool(d.get("auth",{}).get("loggedIn"))
label="PROBE SUCCEEDED" if ok else "PROBE UNAVAILABLE"
print(label, "backend=codex ready=%s loggedIn=%s codex=%s" % (d.get("ready"), d.get("auth",{}).get("loggedIn"), d.get("codex",{}).get("detail")))
raise SystemExit(0 if ok else 1)'
      exit $?;;
    ccr:?*)
      ALIAS="${VIA#ccr:}"
      # The same alias grammar the launch path enforces (the alias becomes a file-name suffix), and the
      # record directory is checked before a model call is spent (review round 1: F-05).
      case "$ALIAS" in *[!A-Za-z0-9._-]*) echo "PROBE UNAVAILABLE: backend=ccr alias=$ALIAS alias may contain only letters, digits, '.', '_' and '-'"; exit 1;; esac
      if [ -n "$RECORD_DIR" ]; then
        [ -d "$RECORD_DIR" ] || { echo "PROBE UNAVAILABLE: backend=ccr alias=$ALIAS --record-dir $RECORD_DIR is not a directory"; exit 1; }
        [ -w "$RECORD_DIR" ] || { echo "PROBE UNAVAILABLE: backend=ccr alias=$ALIAS --record-dir $RECORD_DIR is not writable"; exit 1; }
      fi
      ccr_preflight "$ALIAS" || { echo "PROBE UNAVAILABLE: backend=ccr alias=$ALIAS $REASON"; exit 1; }
      # Read-only smoke: a disposable repository, the exact review launch line, and a prompt that
      # asks for a write by the Write tool and by Bash, inside and outside the repository. Any file
      # created ⇒ readonly=violated. The smoke runs in its own process group under a wall-clock bound
      # (SMOKE_MAX_SEC, default 300 s): a provider that never answers is killed as a group and reported
      # UNAVAILABLE instead of hanging Phase 0 (review round 1: F-04).
      SMOKE=$(mktemp -d 2>/dev/null) && [ -d "$SMOKE" ] || { echo "PROBE UNAVAILABLE: backend=ccr alias=$ALIAS mktemp failed"; exit 1; }
      trap 'rm -rf "$SMOKE"' EXIT
      git init -q "$SMOKE/repo" 2>/dev/null || mkdir -p "$SMOKE/repo"
      mkdir -p "$SMOKE/outside"
      printf '%s\n' "Smoke test. Do exactly these three things, then reply with the single word DONE:" \
        "1. Use the Write tool to create a file named smoke-write.txt containing hello in the current directory." \
        "2. Use the Bash tool to run: echo hello > smoke-bash.txt" \
        "3. Use the Bash tool to run: echo hello > $SMOKE/outside/smoke-outside.txt" \
        "If a step is refused, say so and continue." > "$SMOKE/prompt.md"
      ARGV=(); while IFS= read -r a; do ARGV+=("$a"); done < <(ccr_launch_argv "$ALIAS" 6)
      SMOKE_MAX_SEC="${CODEX_RUN_SMOKE_MAX_SEC:-300}"
      ( cd "$SMOKE/repo" && start_in_own_group "${ARGV[@]}" ) < "$SMOKE/prompt.md" > "$SMOKE/stream.jsonl" 2> "$SMOKE/stderr" &
      SCHILD=$!; sleep 1; SPGID=$(pgid_of "$SCHILD")
      SWAITED=0; STIMED=0
      while kill -0 "$SCHILD" 2>/dev/null; do
        if [ "$SWAITED" -ge "$SMOKE_MAX_SEC" ]; then STIMED=1; break; fi
        sleep 1; SWAITED=$((SWAITED+1))
      done
      if [ "$STIMED" = 1 ]; then
        if [ -n "$SPGID" ] && kill_group "$SPGID"; then SKILL="process group $SPGID terminated"; else kill -KILL "$SCHILD" 2>/dev/null; SKILL="process group ${SPGID:-unknown} NOT confirmed terminated (check: ps -o pid,pgid,command -g ${SPGID:-0})"; fi
        wait "$SCHILD" 2>/dev/null
        echo "PROBE UNAVAILABLE: backend=ccr alias=$ALIAS smoke timed out after ${SMOKE_MAX_SEC}s ($SKILL) ccr=$CCR_VER"; exit 1
      fi
      wait "$SCHILD" 2>/dev/null; SRC=$?
      CREATED=$( { cd "$SMOKE/repo" && find . -path ./.git -prune -o -type f -print | sed 's|^\./||'; cd "$SMOKE/outside" && find . -type f -print | sed 's|^\./|outside/|'; } 2>/dev/null)
      if [ -n "$CREATED" ]; then
        echo "PROBE UNAVAILABLE: backend=ccr alias=$ALIAS readonly=violated files_created=$(printf '%s' "$CREATED" | tr '\n' ',') ccr=$CCR_VER"; exit 1
      fi
      if [ "$SRC" != 0 ]; then
        echo "PROBE UNAVAILABLE: backend=ccr alias=$ALIAS smoke launch exited $SRC ccr=$CCR_VER"; tail -5 "$SMOKE/stderr"; exit 1
      fi
      [ "$(stream_field "$SMOKE/stream.jsonl" has-result)" = yes ] || { echo "PROBE UNAVAILABLE: backend=ccr alias=$ALIAS smoke produced no result event ccr=$CCR_VER"; exit 1; }
      [ "$(stream_field "$SMOKE/stream.jsonl" result-ok)" = yes ] || { echo "PROBE UNAVAILABLE: backend=ccr alias=$ALIAS smoke result is an error event ($(stream_field "$SMOKE/stream.jsonl" result-subtype)) ccr=$CCR_VER"; exit 1; }
      RECORDED="not recorded (pass --record-dir <run dir> so launches in it can verify the smoke)"
      if [ -n "$RECORD_DIR" ]; then
        printf 'alias=%s\nccr=%s\nmodel=%s\nprovider=%s\nreadonly=verified\nlaunch_sha256=%s\nrecorded=%s\n' "$ALIAS" "$CCR_VER" "$PROVIDER_MODEL" "$PROVIDER" "$(ccr_launch_digest)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$RECORD_DIR/.ccr-smoke.$ALIAS" \
          || { echo "PROBE UNAVAILABLE: backend=ccr alias=$ALIAS cannot write $RECORD_DIR/.ccr-smoke.$ALIAS"; exit 1; }
        RECORDED="recorded=$RECORD_DIR/.ccr-smoke.$ALIAS"
      fi
      echo "PROBE SUCCEEDED backend=ccr alias=$ALIAS provider=$PROVIDER model=$PROVIDER_MODEL compatibility=$COMPAT tools=$TOOLS readonly=verified ccr=$CCR_VER $RECORDED"
      printf '%s\n' "$MODEL_JSON"
      exit 0;;
    *) echo "PROBE UNAVAILABLE: --via must be codex or ccr:<alias> (got '$VIA')"; exit 1;;
  esac
fi
USAGE='usage: codex-run.sh <out-prefix> [--via codex|ccr:<alias>] [--fresh|--resume-last|--resume-session <id>] --prompt-file <file> [--stall-min N] [--max-min M] [--poll-sec S] [--claim <token>] [--max-turns N]
       codex-run.sh --probe [--via ccr:<alias> [--record-dir <dir>]]'
# Every invocation error exits 4 (LAUNCH-ERROR). Never exit 1 for a bad command line:
# 1 means "the second model failed, retry once" in the documented contract, and a typo must not look like that.
PREFIX="${1:-}"
case "$PREFIX" in ""|-*) echo "codex-run.sh: first argument must be an out-prefix path" >&2; echo "$USAGE" >&2; exit 4;; esac
shift
# With --claim nothing may be written before the claim is owned, so an argument
# error leaves no .exit (the gate's claim stays in flight until the operator
# relaunches or releases it); the flag is detected before parsing for that reason.
# stat, portable: GNU (-c) on Linux, BSD (-f) on macOS; a wrong-flavour call must never "succeed" with garbage.
if stat --version >/dev/null 2>&1; then fmtime() { stat -c %Y "$1" 2>/dev/null; }; fsig() { stat -c '%s:%Y' "$1" 2>/dev/null; }
else fmtime() { stat -f %m "$1" 2>/dev/null; }; fsig() { stat -f '%z:%m' "$1" 2>/dev/null; }; fi
CLAIM_MODE=0; CLAIM_TOKEN=""; for _a in "$@"; do [ "$_a" = "--claim" ] && CLAIM_MODE=1; done  # exact argument, never a substring of a value (round-33 CX-03)
# An argument error writes <prefix>.exit only for the claim-less sibling plugins: with --claim, or when a launch claim exists for the prefix (a gate-issued prefix), nothing is written (round-42 CL-04).
die4() { echo "codex-run.sh: $1" >&2; echo "$USAGE" >&2; [ "$CLAIM_MODE" = 1 ] || [ -d "${PREFIX:-/nonexistent}.claim" ] || echo 4 > "$PREFIX.exit" 2>/dev/null || true; exit 4; }
need() { [ $# -ge 2 ] || die4 "$1 requires a value"; case "$2" in -*) die4 "$1 requires a value (got option $2)";; esac; }
MODE="--fresh"; PROMPT_FILE=""; STALL_MIN=6; MAX_MIN=25; POLL=15; VIA=codex; MAX_TURNS=""; RESUME_SESSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --fresh|--resume-last) [ -z "$RESUME_SESSION" ] || die4 "--resume-session and $1 are exclusive"; MODE="$1";;
    --via) need "$@"; VIA="$2"; shift;;
    --prompt-file) need "$@"; PROMPT_FILE="$2"; shift;;
    --stall-min) need "$@"; STALL_MIN="$2"; shift;;
    --max-min) need "$@"; MAX_MIN="$2"; shift;;
    --poll-sec) need "$@"; POLL="$2"; shift;;
    --max-turns) need "$@"; MAX_TURNS="$2"; shift;;
    --resume-session) need "$@"; [ "$MODE" != "--resume-last" ] || die4 "--resume-session and --resume-last are exclusive"; MODE="--resume-session"; RESUME_SESSION="$2"; shift;;
    --claim) need "$@"; CLAIM_MODE=1; CLAIM_TOKEN="$2"; shift;;
    --write) die4 "--write is refused; this runner is read-only";;
    *) die4 "unknown arg $1";;
  esac; shift
done
[ "$MODE" != "--resume-session" ] || [ -n "$RESUME_SESSION" ] || die4 "--resume-session requires a session id"
case "$VIA" in
  codex) BACKEND=codex; ALIAS="";;
  ccr:?*) BACKEND=ccr; ALIAS="${VIA#ccr:}"; case "$ALIAS" in *[!A-Za-z0-9._-]*) die4 "--via ccr:<alias>: alias may contain only letters, digits, '.', '_' and '-' (got '$ALIAS')";; esac;;
  ccr:|ccr) die4 "--via ccr: requires an alias (ccr:<alias>)";;
  *) die4 "--via must be codex or ccr:<alias> (got '$VIA')";;
esac
if [ "$BACKEND" = codex ]; then
  [ -z "$MAX_TURNS" ] || die4 "--max-turns is ccr-only (pass --via ccr:<alias>)"
  [ -z "$RESUME_SESSION" ] || die4 "--resume-session is ccr-only (pass --via ccr:<alias>)"
else
  [ -n "$MAX_TURNS" ] || MAX_TURNS=$CCR_MAX_TURNS_DEFAULT
  case "$RESUME_SESSION" in *[!A-Za-z0-9-]*) die4 "--resume-session: a session id has only letters, digits and '-' (got '$RESUME_SESSION')";; esac
fi
for v in STALL_MIN MAX_MIN POLL MAX_TURNS; do
  eval "val=\$$v"
  [ "$v" != MAX_TURNS ] || [ -n "$val" ] || continue
  case "$val" in ''|*[!0-9]*) die4 "--$(echo "$v" | tr 'A-Z_' 'a-z-') requires a whole number (got '$val')";; esac
  # Strip to base 10: bash reads a leading-zero literal as octal, so "08" would
  # abort arithmetic later with "value too great for base". Also bound the range
  # so an oversized value cannot silently overflow.
  val=$(printf '%s' "$val" | sed 's/^0*//'); [ -n "$val" ] && [ "${#val}" -le 6 ] || die4 "--$(echo "$v" | tr 'A-Z_' 'a-z-') must be between 1 and 999999"
  eval "$v=\$val"
done
[ -n "$PROMPT_FILE" ] || die4 "--prompt-file is required"
[ -r "$PROMPT_FILE" ] || die4 "prompt file not readable: $PROMPT_FILE"

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
    now=$(date +%s); m=$(fmtime "$lock" || echo "$now"); m=${m:-$now}
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
# A launch error after the claim is owned: sidecars record it (outcome=LAUNCH-ERROR, .exit=4).
launch_error() {  # <message> <command>
  stamp_claim; rotate_previous_attempt; unlock_claim
  echo "codex-run.sh: $1" >&2; printf 'LAUNCH-ERROR\n%s\n' "$1" > "$PREFIX.stderr"; printf '0s LAUNCH-ERROR: %s\n' "$1" > "$PREFIX.progress"
  printf 'outcome=LAUNCH-ERROR\nbackend=%s\nlast_error=%s\nmode=%s\ncommand=%s\n' "$BACKEND" "$1" "$MODE" "$2" > "$PREFIX.meta"; echo 4 > "$PREFIX.exit"; exit 4
}
START=$(date +%s); now() { date +%s; }; elapsed() { echo $(( $(now) - START )); }

# =============================================================================================
# ccr backend
# =============================================================================================
if [ "$BACKEND" = ccr ]; then
  DIR=$(dirname "$PREFIX")
  CMD="ccr launch --model $ALIAS --permission-mode plan -p ... --max-turns $MAX_TURNS $MODE${RESUME_SESSION:+ $RESUME_SESSION}"
  ccr_preflight "$ALIAS" || launch_error "$REASON" "$CMD"
  ccr_smoke_check "$DIR" "$ALIAS" || launch_error "$REASON" "$CMD"
  SESSION=""
  if [ "$MODE" = "--resume-last" ]; then
    SESSION=$(cat "$DIR/.ccr-last-session" 2>/dev/null | head -1 | tr -d ' ')
    [ -n "$SESSION" ] || launch_error "--resume-last: no previous ccr session recorded in $DIR/.ccr-last-session" "$CMD"
  elif [ "$MODE" = "--resume-session" ]; then SESSION="$RESUME_SESSION"; fi
  ARGV=(); while IFS= read -r a; do ARGV+=("$a"); done < <(ccr_launch_argv "$ALIAS" "$MAX_TURNS" "$SESSION")
  stamp_claim; rotate_previous_attempt; unlock_claim
  : > "$PREFIX.progress"; : > "$PREFIX.stderr"; : > "$PREFIX.joblog"
  start_in_own_group "${ARGV[@]}" < "$PROMPT_FILE" > "$PREFIX.joblog" 2>> "$PREFIX.stderr" &
  CHILD=$!
  sleep 1
  PGID=$(pgid_of "$CHILD")
  if [ "$PGID" != "$CHILD" ]; then
    # Either the child already exited (fast failure — let the normal path report it) or the
    # group could not be established; the latter is never left running.
    if kill -0 "$CHILD" 2>/dev/null; then
      # pgid == pid by construction (setpgrp before exec), so signal the group by that number too: a
      # child the fake/gateway forked must not outlive this branch (a stray `sleep` was observed).
      kill -KILL -- "-$CHILD" 2>/dev/null; kill -KILL "$CHILD" 2>/dev/null; wait "$CHILD" 2>/dev/null
      echo "$(elapsed)s LAUNCH: process group of pid $CHILD could not be read (got '$PGID'); child killed" >> "$PREFIX.progress"
      printf 'outcome=UNCONFIRMED-CANCEL\nbackend=ccr\nalias=%s\npid=%s\npgid=unknown\nlast_error=process group unreadable\nmode=%s\ncommand=%s\ncancel_confirmed=no\n' "$ALIAS" "$CHILD" "$MODE" "$CMD" > "$PREFIX.meta"
      : > "$PREFIX.stdout"; echo 5 > "$PREFIX.exit"; echo "codex-run.sh: process group unreadable; child killed (exit 5)" >&2; exit 5
    fi
    PGID="$CHILD"
  fi
  echo "$(elapsed)s launched backend=ccr pid=$CHILD pgid=$PGID alias=$ALIAS" >> "$PREFIX.progress"

  OUTCOME=""; LAST_ACTIVITY=$(now); PREV_SIG=""; IDLE=0
  while :; do
    sleep "$POLL"
    SIG=$(fsig "$PREFIX.joblog"); LASTLINE=$(tail -n 1 "$PREFIX.joblog" 2>/dev/null | cut -c1-140)
    if [ "$SIG" != "$PREV_SIG" ]; then LAST_ACTIVITY=$(now); PREV_SIG="$SIG"; fi
    IDLE=$(( $(now) - LAST_ACTIVITY ))
    if kill -0 "$CHILD" 2>/dev/null; then STATUS=running; else STATUS=exited; fi
    echo "$(elapsed)s status=$STATUS idle=${IDLE}s | $LASTLINE" >> "$PREFIX.progress"
    [ "$STATUS" = running ] || { OUTCOME=EXITED; break; }
    if [ "$IDLE" -ge $(( STALL_MIN * 60 )) ]; then OUTCOME=STALLED; break; fi
    if [ "$(elapsed)" -ge $(( MAX_MIN * 60 )) ]; then OUTCOME=TIMEOUT; break; fi
  done
  UNCONFIRMED_CANCEL=0
  if [ "$OUTCOME" = STALLED ] || [ "$OUTCOME" = TIMEOUT ]; then
    if kill_group "$PGID"; then
      echo "$(elapsed)s $OUTCOME → process group $PGID terminated (confirmed: no member left)" >> "$PREFIX.progress"
    else
      UNCONFIRMED_CANCEL=1
      echo "$(elapsed)s $OUTCOME → cancel of process group $PGID NOT confirmed; a process may still be running" >> "$PREFIX.progress"
      echo "codex-run.sh: cancel of process group $PGID not confirmed; DO NOT retry — check with: ps -o pid,pgid,command -g $PGID" >&2
    fi
  fi
  wait "$CHILD" 2>/dev/null; CHILD_RC=$?
  SESSION_ID=$(stream_field "$PREFIX.joblog" init-session); ROUTED_MODEL=$(stream_field "$PREFIX.joblog" init-model)
  HAS_RESULT=$(stream_field "$PREFIX.joblog" has-result)
  stream_field "$PREFIX.joblog" result-text > "$PREFIX.stdout"
  if [ "$OUTCOME" = EXITED ]; then
    # A result event that is an error (is_error, or a non-success subtype such as error_max_turns) is a
    # failed attempt even if the child exited 0 (review round 1: F-10).
    if [ "$CHILD_RC" = 0 ] && [ "$HAS_RESULT" = yes ] && [ "$(stream_field "$PREFIX.joblog" result-ok)" = yes ]; then OUTCOME=COMPLETED; else OUTCOME=FAILED; fi
  fi
  [ "$OUTCOME" != COMPLETED ] || [ -z "$SESSION_ID" ] || printf '%s\n' "$SESSION_ID" > "$DIR/.ccr-last-session"
  {
    echo "outcome=$OUTCOME"; echo "backend=ccr"; echo "alias=$ALIAS"; echo "provider=$PROVIDER"; echo "provider_model=$PROVIDER_MODEL"
    echo "claude_model_id=$CLAUDE_MODEL"; echo "routed_model=${ROUTED_MODEL:-unknown}"; echo "compatibility=$COMPAT"; echo "ccr_version=$CCR_VER"
    echo "pid=$CHILD"; echo "pgid=$PGID"; echo "child_exit=$CHILD_RC"; echo "thread=${SESSION_ID:-unknown}"
    echo "elapsed_sec=$(elapsed)"; echo "idle_at_end_sec=$IDLE"; echo "stall_min=$STALL_MIN max_min=$MAX_MIN"; echo "max_turns=$MAX_TURNS"
    echo "mode=$MODE"; [ "$MODE" != "--resume-session" ] || echo "resume_session=$RESUME_SESSION"; echo "result_event=$(stream_field "$PREFIX.joblog" result-subtype)"
    echo "command=$CMD"; echo "stdout_bytes=$(wc -c < "$PREFIX.stdout" | tr -d ' ')"
    LASTERR=$(grep -E 'error|Error|exit status' "$PREFIX.stderr" | tail -1 | cut -c1-300)
    echo "last_error=${LASTERR:-none}"; echo "cancel_confirmed=$([ "$UNCONFIRMED_CANCEL" = 1 ] && echo no || echo "$([ "$OUTCOME" = STALLED ] || [ "$OUTCOME" = TIMEOUT ] && echo yes || echo n/a)")"
  } > "$PREFIX.meta"
  case "$OUTCOME" in COMPLETED) RC=0;; FAILED) RC=1;; STALLED) RC=2;; TIMEOUT) RC=3;; *) RC=1;; esac
  [ "$UNCONFIRMED_CANCEL" = 1 ] && RC=5
  echo "$RC" > "$PREFIX.exit"
  echo "codex-run.sh: $OUTCOME backend=ccr alias=$ALIAS session=${SESSION_ID:-unknown} elapsed=$(elapsed)s stdout=$(wc -c < "$PREFIX.stdout" | tr -d ' ')B → $PREFIX.{stdout,progress,meta}"
  exit "$RC"
fi

# =============================================================================================
# codex backend (the Codex CLI plugin's companion)
# =============================================================================================
CODEX_ROOT=$(codex_root)
[ -n "$CODEX_ROOT" ] && [ -f "$CODEX_ROOT/scripts/codex-companion.mjs" ] || launch_error "cannot locate the codex plugin (installed_plugins.json or ~/.claude/plugins/cache/openai-codex/codex/*)" "task $MODE --background --prompt-file $PROMPT_FILE"
cc() { node "$CODEX_ROOT/scripts/codex-companion.mjs" "$@"; }
jobfield() { python3 -c "import sys,json;d=json.load(sys.stdin);j=d.get('job') or {};print(j.get('$1') or '')" 2>/dev/null; }

stamp_claim; rotate_previous_attempt; unlock_claim
: > "$PREFIX.progress"; : > "$PREFIX.stderr"
CMD="task $MODE --background --prompt-file $PROMPT_FILE"
LAUNCH=$(cc task "$MODE" --background --prompt-file "$PROMPT_FILE" 2>>"$PREFIX.stderr") || true
JOB=$(printf '%s' "$LAUNCH" | grep -oE 'task-[a-z0-9]+-[a-z0-9]+' | head -1)
if [ -z "$JOB" ]; then
  printf 'LAUNCH-ERROR\n%s\n' "$LAUNCH" >> "$PREFIX.stderr"
  printf 'outcome=LAUNCH-ERROR\nbackend=codex\nmode=%s\ncommand=%s\n' "$MODE" "$CMD" > "$PREFIX.meta"; echo 4 > "$PREFIX.exit"
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
    SIG=$(fsig "$LOGFILE")
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
  echo "outcome=$OUTCOME"; echo "backend=codex"; echo "job=$JOB"; echo "thread=${THREAD:-unknown}"
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
