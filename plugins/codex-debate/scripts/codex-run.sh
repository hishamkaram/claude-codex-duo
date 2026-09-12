#!/bin/bash
# codex-run.sh — run one read-only second-model task in the background, monitor it, return its result.
#
# Usage:
#   codex-run.sh <out-prefix> [--via codex|ccr:<alias>] [--fresh|--resume-last|--resume-session <id>] --prompt-file <file>
#                [--stall-min N] [--max-min M] [--poll-sec S] [--claim <token>]
#                [--max-turns N] [--expected-parent-job <job>]       (CCR options)
#   codex-run.sh <out-prefix> --attach --expected-job <job> [--stall-min N] [--max-min M] [--poll-sec S]
#   codex-run.sh --probe [--via ccr:<alias> [--record-dir <dir>]]
#
#   --attach: resume the WATCH on a job this process did not launch, after a previous
#   invocation detached from it (exit 6). It is an operation, not a launch mode: no prompt is
#   submitted, no claim is taken, no launch budget is spent, no sidecar is rotated, and `mode=`
#   in .meta keeps the original launch mode so the review gates' thread anchoring is unchanged.
#   It requires <out-prefix>.detached with no <out-prefix>.exit; anything else is exit 4.
#   --expected-job is MANDATORY on every attach, cancellation included: a prefix is reusable, so
#   only the caller can say which job it meant, and a deliberate attach and a stale saved command
#   are otherwise indistinguishable. Run the attach_command the runner printed, never a hand-typed
#   `--attach`; a refusal prints the bound command for the job this prefix names now.
#
#   --via codex (default): the Codex CLI plugin's companion (task/status/result/cancel).
#   --via ccr:<alias>: a headless Claude Code launched through the claude-code-router gateway
#   (`ccr launch --model <alias>`), routed to whatever provider the alias names on this machine.
#   Both backends honour the same contract: prompt file in, the six sidecars out, exit 0-6, the
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
#                           TERMINAL ONLY: written when an outcome can no longer change, never at
#                           detach. A review gate reads an existing .exit as a finished attempt and
#                           rotates the claim, so a detached-but-live attempt must not write one.
#   <out-prefix>.detached   present only while a detached job may still be running (exit 6): the
#                           backend, the job or process identity and its start time, the original
#                           launch mode, the prompt digest, and the verbatim attach and cancel
#                           commands. Removed when an attach publishes the terminal outcome.
#   <out-prefix>.ccr-prelaunch  (ccr only) written before anything can be submitted, carrying the
#                           launch protocol. Present with NO <out-prefix>.ccr-attempt.json, it is
#                           proof that this launch was interrupted before it submitted any
#                           workload — which is what lets `phase-gate.sh release` free the claim
#                           instead of refusing forever. Its absence proves nothing either way.
#   Exit 4 with NO sidecar written: another runner already took <out-prefix>.claim/, or (--claim)
#   no claim exists / the arguments are invalid.
#   CCR continuation requires an explicit session and authoritative parent job.
#
# CCR owns workload lifecycle. A stall requests cancellation by job ID; a watch
# deadline only detaches the collector. Unknown admission or cleanup retains the
# attempt and claim. Process inspection below coordinates collectors only.

set -u
umask 077
# Transactional submission and guarded same-session continuation require 0.6.0.
CCR_MIN_VERSION="0.6.0"
# The launch protocol this runner writes. It appears in <out-prefix>.ccr-prelaunch and is what
# lets a later recovery tell "this runner started a launch and was interrupted before it could
# submit anything" from "some older runner left this, and nothing here can be trusted". Bump it
# only when the pre-admission ordering itself changes; phase-gate.sh carries the same literal and
# scripts/validate.sh check 4b1 fails the build if the two ever disagree.
CCR_PROTOCOL=1
CCR_HELPER="$(exec 9>&-; cd "$(exec 9>&-; dirname "$0")" && pwd)/ccr-job.py"
CCR_RUNNER="${CCR_HELPER%/*}/${0##*/}"
# These are assigned inside ccr_preflight, past its early-return failures. The attach path is
# allowed to run without a successful preflight (the child is already going), so under `set -u`
# every reader below would abort the collector mid-publication. Declare them empty up front: an
# empty value is a fact the route check already knows how to report, an unbound one is a crash.
CCR_VER=""; PROVIDER=""; PROVIDER_MODEL=""; CLAUDE_MODEL=""; COMPAT=""; TOOLS=""
CCR_MAX_TURNS_DEFAULT=100
# The exact read-only launch line for the ccr backend. It is the one line every ccr participant
# runs and the one line the probe's smoke verifies; its digest is part of the smoke record so a
# changed line invalidates every earlier smoke.
# Use one stable argv shape and the detached prompt-file transport. CCR also
# accepts separated values; the equals form here is a serialization choice.
ccr_launch_argv() {  # <alias> <max-turns> <prompt-file>
  ARGV=(ccr launch --model "$1" --permission-mode plan -p --no-lifecycle --no-statusline
    --detach --prompt-file "$3" --output-format=stream-json --verbose --strict-mcp-config
    --mcp-config='{"mcpServers":{}}' --disallowedTools=Write,Edit,MultiEdit,NotebookEdit,Agent
    --max-turns="$2")
}
# The digest pins the SHAPE of the launch line, so the prompt path — which differs per run — is
# held constant here exactly as the alias and turn budget are.
ccr_launch_digest() { ccr_launch_argv ALIAS N PROMPT; printf '%s\0' "${ARGV[@]}" | shasum -a 256 | cut -c1-16; }
# --- the CCR job API: the runner asks, it never infers ---------------------------------------
# Every question this runner used to answer by reading the process table — is it alive, did it
# end, what was its exit status, is anything left — is answered here by the process that owns the
# job. `ccr status` is the authority; a query that FAILS is undetermined and never means "ended".
ccr_job_json() { python3 "$CCR_HELPER" status "${CCR_ATTEMPT_PREFIX:-$PREFIX}" "$1" 2>/dev/null; }
ccr_job_cancel() { python3 "$CCR_HELPER" cancel "${CCR_ATTEMPT_PREFIX:-$PREFIX}" "$1"; }
ccr_job_field() {  # <json> <dotted-field> -> value, empty when absent or unreadable
  printf '%s' "$1" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
cur=d
for k in sys.argv[1].split("."):
    if not isinstance(cur,dict) or k not in cur: raise SystemExit
    cur=cur[k]
if cur is None: raise SystemExit
if isinstance(cur,(list,dict)): print(json.dumps(cur,separators=(",",":")))
else: print(cur)' "$2" 2>/dev/null
}
# CCR's own status vocabulary, mapped to the three answers this runner acts on. Anything it does
# not recognise — including a status query that failed outright — is UNDETERMINED, which keeps the
# attempt in flight rather than closing it.
ccr_job_state() {
  local answer
  answer=$(exec 9>&-; printf '%s' "$1" | python3 "$CCR_HELPER" state 2>/dev/null) || answer=undetermined
  printf '%s\n' "$answer"
}
codex_root() {
  python3 9>&- -c 'import json,os,glob
p=os.path.expanduser("~/.claude/plugins/installed_plugins.json")
try: print(json.load(open(p))["plugins"]["codex@openai-codex"][0]["installPath"]); raise SystemExit
except Exception: pass
c=sorted(glob.glob(os.path.expanduser("~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs")))
print(os.path.dirname(os.path.dirname(c[-1])) if c else "")'
}
# --- ccr helpers (shared by the probe and the launch path) -----------------------------------
ccr_version() { ccr version 2>/dev/null | head -1 | sed -nE 's/^ccr[[:space:]]+v?([0-9]+\.[0-9]+\.[0-9]+).*$/\1/p'; }
version_ge() {  # X.Y.Z >= A.B.C
  python3 9>&- -c 'import sys
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
  CCR_VER=$(exec 9>&-; ccr_version); [ -n "$CCR_VER" ] || { REASON="cannot parse 'ccr version' output"; return 1; }
  version_ge "$CCR_VER" "$CCR_MIN_VERSION" || { REASON="requires ccr >= $CCR_MIN_VERSION (found $CCR_VER)"; return 1; }
  MODEL_JSON=$(exec 9>&-; ccr_model_json "$1") && [ -n "$MODEL_JSON" ] || { REASON="ccr model show $1 --json failed (unknown alias on this machine?)"; return 1; }
  PROVIDER=$(exec 9>&-; ccr_model_field "$MODEL_JSON" provider); PROVIDER_MODEL=$(exec 9>&-; ccr_model_field "$MODEL_JSON" provider_model)
  CLAUDE_MODEL=$(exec 9>&-; ccr_model_field "$MODEL_JSON" claude_model_id); COMPAT=$(exec 9>&-; ccr_model_field "$MODEL_JSON" compatibility); TOOLS=$(exec 9>&-; ccr_model_field "$MODEL_JSON" tools)
  [ -n "$PROVIDER" ] || { REASON="ccr model show $1 --json has no provider field"; return 1; }
  [ -n "$PROVIDER_MODEL" ] || { REASON="ccr model show $1 --json has no provider_model field"; return 1; }
  [ -n "$CLAUDE_MODEL" ] || { REASON="ccr model show $1 --json has no claude_model_id field"; return 1; }
  [ "$TOOLS" = true ] || { REASON="alias $1 reports supports_tools=$TOOLS; a reviewer needs tool calls"; return 1; }
  return 0
}
# Match the recorded smoke against the current alias: version, model and launch line must all agree.
ccr_smoke_check() {  # <dir> <alias>  (needs ccr_preflight first)
  local f="$1/.ccr-smoke.$2"
  [ -r "$f" ] || { REASON="ccr smoke missing for $2: run 'codex-run.sh --probe --via ccr:$2 --record-dir $1' first (smoke record $f)"; return 1; }
  grep -qxF "alias=$2" "$f" || { REASON="ccr smoke record does not bind alias $2 ($f)"; return 1; }
  grep -qxF "readonly=verified" "$f" || { REASON="ccr smoke for $2 is not 'readonly=verified' ($f)"; return 1; }
  grep -qxF "ccr=$CCR_VER" "$f" || { REASON="ccr smoke for $2 was recorded with another ccr version (now $CCR_VER); re-run the probe"; return 1; }
  grep -qxF "model=$PROVIDER_MODEL" "$f" || { REASON="ccr smoke for $2 was recorded for another provider model (now $PROVIDER_MODEL); re-run the probe"; return 1; }
  grep -qxF "claude_model_id=$CLAUDE_MODEL" "$f" || { REASON="ccr smoke for $2 was recorded for another generated child model (now $CLAUDE_MODEL); re-run the probe"; return 1; }
  grep -qxF "child_model=$CLAUDE_MODEL" "$f" || { REASON="ccr smoke for $2 lacks a verified generated child model ($f); re-run the probe"; return 1; }
  grep -qxF "launch_sha256=$(exec 9>&-; ccr_launch_digest)" "$f" || { REASON="ccr smoke for $2 was recorded for another launch line; re-run the probe"; return 1; }
  return 0
}
# Process identity. A pid or pgid recorded minutes ago may name an unrelated process by the time
# an attach reads it, so a number is never acted on alone: it is paired with the start time the
# kernel reports for it, and the pair must still match. `ps -o lstart=` is the one field both BSD
# and GNU ps agree on for this; whitespace is squeezed so the recorded and live forms compare.
# TZ=UTC is not cosmetic: `ps -o lstart=` renders the start time in the OBSERVING shell's local
# time, so the same live process yields a different string under a different TZ or across a DST
# transition (measured: `Wed Sep 9 16:06:58 2026` local, `09:06:58` under TZ=UTC, `18:06:58` under
# Asia/Tokyo). The whole point of the record is that a DIFFERENT process re-proves it later, and
# that process may have any TZ, so the identity must not be a property of who is looking.
proc_identity() {  # <pid> -> start-time string, empty when the pid is gone or cannot be read
  TZ=UTC ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//'
}
# 0 = same execution · 1 = the number is gone · 2 = it is held by a different execution.
# NONE of these is proof that the job ended. Only the supervisor's receipt is that, which is why
# the collector below refuses to publish a terminal outcome without one: an empty `ps` may mean
# process inspection failed rather than the process exited, and a mismatch may mean the recorded
# string was written by an observer we cannot reproduce. Ambiguity re-detaches; it never
# terminates. What identity IS authoritative for is the opposite direction: nothing may be
# signalled unless state 0 says the number still names our execution.
identity_state() {  # <pid> <recorded identity>
  local live; live=$(exec 9>&-; proc_identity "$1")
  [ -n "$live" ] || return 1
  [ "$live" = "$2" ] || return 2
  return 0
}
# stream-json readers
stream_field() {  # <joblog> init-session|init-model|result-text|has-result
  python3 9>&- - "$1" "$2" <<'PY' 2>/dev/null
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
      CODEX_ROOT=$(exec 9>&-; codex_root)
      [ -n "$CODEX_ROOT" ] || { echo "PROBE UNAVAILABLE: codex plugin not found"; exit 1; }
      OUT=$(exec 9>&-; node "$CODEX_ROOT/scripts/codex-companion.mjs" setup --json 2>&1) || { echo "PROBE FAILED: setup exited non-zero"; printf '%s\n' "$OUT" | tail -5; exit 1; }
      printf '%s' "$OUT" | python3 -c 'import sys, json
# Availability has three states, not two. The old predicate was `ready and loggedIn`, read as
# plain booleans, so a companion that could not REACH its runtime to answer the auth question
# returned loggedIn=false and the whole run was refused while a launch would have succeeded.
# UNAVAILABLE is now reserved for an authoritative negative about the launch path; anything the
# companion did not actually determine is UNDETERMINED, which never refuses a run: the caller
# records it and proceeds to the task it is already authorized to run, and that task IS the
# determination. No model call is spent here to predict one.
d = json.load(sys.stdin)
auth = d.get("auth") or {}
codex = d.get("codex") or {}
detail = str(auth.get("detail") or "")
# Only an affirmative reading is affirmative. The meaning of `verified` and `authMethod` is not
# documented by the companion, so nothing is inferred from a particular value of them; they are
# used only to tell "it answered" from "it never got to answer".
answered = auth.get("authMethod") is not None or auth.get("verified") is not None
usable = bool(d.get("ready")) and bool(auth.get("loggedIn"))
# An authoritative negative: the CLI or the auth subsystem is reported absent, or auth answered
# and the answer was no.
unusable = (codex.get("available") is False) or (auth.get("available") is False) or (answered and not auth.get("loggedIn"))
if usable:
    label, rc = "PROBE SUCCEEDED", 0
elif unusable:
    label, rc = "PROBE UNAVAILABLE", 1
else:
    label, rc = "PROBE UNDETERMINED", 0
print(label, "backend=codex ready=%s loggedIn=%s codex=%s" % (d.get("ready"), auth.get("loggedIn"), codex.get("detail")))
if label == "PROBE UNDETERMINED":
    print("  the companion did not determine authentication (authMethod=%r verified=%r detail=%r);"
          % (auth.get("authMethod"), auth.get("verified"), detail[:160]))
    print("  this is NOT a refusal: record the line and proceed to the launch, which settles it.")
raise SystemExit(rc)'
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
      # created ⇒ readonly=violated. CCR owns cancellation; admission observation
      # and the subsequent watch both spend the smoke's wall-clock budget.
      SMOKE=$(exec 9>&-; mktemp -d 2>/dev/null) && [ -d "$SMOKE" ] || { echo "PROBE UNAVAILABLE: backend=ccr alias=$ALIAS mktemp failed"; exit 1; }
      trap 'echo "CCR smoke evidence: $SMOKE" >&2' EXIT
      CCR_ATTEMPT_PREFIX="$SMOKE/run"
      git init -q "$SMOKE/repo" 2>/dev/null || mkdir -p "$SMOKE/repo"
      mkdir -p "$SMOKE/outside"
      printf '%s\n' "Smoke test. Do exactly these three things, then reply with the single word DONE:" \
        "1. Use the Write tool to create a file named smoke-write.txt containing hello in the current directory." \
        "2. Use the Bash tool to run: echo hello > smoke-bash.txt" \
        "3. Use the Bash tool to run: echo hello > $SMOKE/outside/smoke-outside.txt" \
        "If a step is refused, say so and continue." > "$SMOKE/prompt.md"
      ccr_launch_argv "$ALIAS" 6 "$SMOKE/prompt.md"
      SMOKE_MAX_SEC="${CODEX_RUN_SMOKE_MAX_SEC:-300}"
      case "$SMOKE_MAX_SEC" in ''|*[!0-9]*|0*|??????????*) echo "PROBE UNAVAILABLE: backend=ccr alias=$ALIAS CODEX_RUN_SMOKE_MAX_SEC must be a positive whole number of at most 9 digits (got '$SMOKE_MAX_SEC')"; exit 1;; esac   # review round 2: F-03; round 3: F-02 oversized integers fail-open
      # The smoke is a detached job like any other, so the bound is enforced by asking its owner to
      # cancel rather than by this script signalling a process group it inferred (review round 1:
      # F-04 required the bound; the CCR job API is how it is now enforced).
      SSTART=$(exec 9>&-; date +%s)
      SADMISSION_WAIT="$SMOKE_MAX_SEC"; [ "$SADMISSION_WAIT" -le 30 ] || SADMISSION_WAIT=30
      SRECEIPT=$(exec 9>&-; cd "$SMOKE/repo" && python3 "$CCR_HELPER" admit "$CCR_ATTEMPT_PREFIX" "$ALIAS" "$CLAUDE_MODEL" 6 "$CCR_RUNNER" "$MODEL_JSON" "$CCR_VER" "$SADMISSION_WAIT" "$(( (SMOKE_MAX_SEC + 59) / 60 ))" "$(( (SMOKE_MAX_SEC + 59) / 60 ))" 2 "${ARGV[@]}"); SLRC=$?
      SJOB=$(exec 9>&-; ccr_job_field "$SRECEIPT" job_id)
      if [ "$SLRC" != 0 ] || [ -z "$SJOB" ]; then
        echo "PROBE UNDETERMINED: admission unresolved; evidence=$SMOKE; do not retry"
        exit 1
      fi
      STIMED=0
      while :; do
        SJSON=$(exec 9>&-; ccr_job_json "$SJOB")
        [ "$(exec 9>&-; ccr_job_state "$SJSON")" = running ] || break
        if [ $(( $(exec 9>&-; date +%s) - SSTART )) -ge "$SMOKE_MAX_SEC" ]; then STIMED=1; break; fi
        sleep 1 9>&-
      done
      if [ "$STIMED" = 1 ]; then
        ccr_job_cancel "$SJOB" >/dev/null 2>&1 || true
        SCW=0; while [ "$SCW" -lt 30 ]; do SJSON=$(exec 9>&-; ccr_job_json "$SJOB"); [ "$(exec 9>&-; ccr_job_state "$SJSON")" = running ] || break; sleep 1 9>&-; SCW=$((SCW+1)); done
        if [ "$(exec 9>&-; ccr_job_state "$SJSON")" = ended ]; then SKILL="job $SJOB cancelled by its owner (cleanup coverage=$(exec 9>&-; ccr_job_field "$SJSON" cleanup.coverage))"
        else SKILL="cancellation of job $SJOB NOT confirmed (check: ccr status $SJOB --json)"; fi
        echo "PROBE UNAVAILABLE: backend=ccr alias=$ALIAS smoke timed out after ${SMOKE_MAX_SEC}s ($SKILL) ccr=$CCR_VER"; exit 1
      fi
      SFROZEN=$(exec python3 "$CCR_HELPER" freeze "$CCR_ATTEMPT_PREFIX" "$SJOB") || { echo "PROBE UNDETERMINED: workload stop/result unproven; evidence=$SMOKE"; exit 1; }
      [ "$(exec 9>&-; ccr_job_field "$SFROZEN" successful)" = True ] || { echo "PROBE UNAVAILABLE: unsuccessful workload result; evidence=$SMOKE"; exit 1; }
      cp "$CCR_ATTEMPT_PREFIX.joblog" "$SMOKE/stream.jsonl"
      SRC=$(exec 9>&-; ccr_job_field "$SJSON" exit_code); SRC=${SRC:-1}
      CREATED=$(exec 9>&-;  { cd "$SMOKE/repo" && find . -path ./.git -prune -o -type f -print | sed 's|^\./||'; cd "$SMOKE/outside" && find . -type f -print | sed 's|^\./|outside/|'; } 2>/dev/null)
      if [ -n "$CREATED" ]; then
        echo "PROBE UNAVAILABLE: backend=ccr alias=$ALIAS readonly=violated files_created=$(exec 9>&-; printf '%s' "$CREATED" | tr '\n' ',') ccr=$CCR_VER"; exit 1
      fi
      if [ "$SRC" != 0 ]; then
        echo "PROBE UNAVAILABLE: backend=ccr alias=$ALIAS smoke launch exited $SRC ccr=$CCR_VER"; tail -5 "$SMOKE/stderr"; exit 1
      fi
      [ "$(exec 9>&-; stream_field "$SMOKE/stream.jsonl" has-result)" = yes ] || { echo "PROBE UNAVAILABLE: backend=ccr alias=$ALIAS smoke produced no result event ccr=$CCR_VER"; exit 1; }
      [ "$(exec 9>&-; stream_field "$SMOKE/stream.jsonl" result-ok)" = yes ] || { echo "PROBE UNAVAILABLE: backend=ccr alias=$ALIAS smoke result is an error event ($(exec 9>&-; stream_field "$SMOKE/stream.jsonl" result-subtype)) ccr=$CCR_VER"; exit 1; }
      SMOKE_MODEL=$(exec 9>&-; stream_field "$SMOKE/stream.jsonl" init-model)
      [ "$SMOKE_MODEL" = "$CLAUDE_MODEL" ] || { echo "PROBE UNAVAILABLE: backend=ccr alias=$ALIAS route=unverified expected_child_model=${CLAUDE_MODEL:-unknown} got_child_model=${SMOKE_MODEL:-unknown} ccr=$CCR_VER"; exit 1; }
      RECORDED="not recorded (pass --record-dir <run dir> so launches in it can verify the smoke)"
      if [ -n "$RECORD_DIR" ]; then
        printf 'alias=%s\nccr=%s\nmodel=%s\nprovider=%s\nclaude_model_id=%s\nchild_model=%s\nreadonly=verified\nlaunch_sha256=%s\nrecorded=%s\n' "$ALIAS" "$CCR_VER" "$PROVIDER_MODEL" "$PROVIDER" "$CLAUDE_MODEL" "$SMOKE_MODEL" "$(exec 9>&-; ccr_launch_digest)" "$(exec 9>&-; date -u +%Y-%m-%dT%H:%M:%SZ)" > "$RECORD_DIR/.ccr-smoke.$ALIAS" \
          || { echo "PROBE UNAVAILABLE: backend=ccr alias=$ALIAS cannot write $RECORD_DIR/.ccr-smoke.$ALIAS"; exit 1; }
        RECORDED="recorded=$RECORD_DIR/.ccr-smoke.$ALIAS"
      fi
      echo "PROBE SUCCEEDED backend=ccr alias=$ALIAS provider=$PROVIDER model=$PROVIDER_MODEL compatibility=$COMPAT tools=$TOOLS readonly=verified ccr=$CCR_VER $RECORDED"
      printf '%s\n' "$MODEL_JSON"
      exit 0;;
    *) echo "PROBE UNAVAILABLE: --via must be codex or ccr:<alias> (got '$VIA')"; exit 1;;
  esac
fi
USAGE='usage: codex-run.sh <out-prefix> [--via codex|ccr:<alias>] [--fresh|--resume-last|--resume-session <id>] --prompt-file <file> [--stall-min N] [--max-min M] [--poll-sec S] [--claim <token>] [--max-turns N] [--expected-parent-job <job>]
       codex-run.sh <out-prefix> --attach --expected-job <job> [--stall-min N] [--max-min M] [--poll-sec S]
       codex-run.sh <out-prefix> --attach --expected-job <job> --cancel
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
CLAIM_MODE=0; CLAIM_TOKEN=""; ATTACH_MODE=0
for _a in "$@"; do  # exact arguments, never a substring of a value (round-33 CX-03)
  [ "$_a" = "--claim" ] && CLAIM_MODE=1
  [ "$_a" = "--attach" ] && ATTACH_MODE=1
done
# An argument error writes <prefix>.exit only for the claim-less sibling plugins: with --claim, or when a launch claim exists for the prefix (a gate-issued prefix), nothing is written (round-42 CL-04).
# .exit is terminal in BOTH directions: an attempt that has published one must not have it
# rewritten (a refused --attach would otherwise overwrite a COMPLETED 0 with a 4 and destroy the
# result this runner exists to preserve), and an attempt that is still in flight must not have one
# invented (a detached attempt's missing .exit is deliberate — it is what keeps the review gate
# closed, and writing 4 there frees the claim and makes every later --attach refuse a job that is
# still running). The claim-less plugins are the exposed case: they pass neither --claim nor a
# claim directory, so those two disjuncts never save them.
# Never turn somebody else's live attempt into a terminal failure. .claim, .exit and .detached
# each say "an attempt owns this prefix"; so does .progress, and it is the ONLY one of the four
# present in the window between a launch starting and its first outcome — the window an --attach
# that arrives too early lands in (cycle 2: CL-05). An argument error is a fact about THIS
# invocation, so when any of them is present it is reported and nothing is published.
# --attach NEVER publishes, marker or no marker (cycle 11: F-03). An attach does not own the
# attempt a .exit would describe: it is a second watcher of a job some other invocation launched,
# so "this attach was malformed" is never the same statement as "that attempt ended 4". The bare
# prefix is the case that exposed it — the binding refusal below runs before any sidecar exists,
# so every marker disjunct is false and the refusal that promises "nothing was written" wrote the
# one file every gate reads as a finished attempt.
# .ccr-prelaunch and its staging name .ccr-prelaunch.part are markers here for the same reason
# rotation already treats them as attempt markers: the prelaunch record is written before anything
# can be submitted, so its presence means a launch on this prefix has begun and may be in flight.
publishing_marker() {  # a sidecar that says "an attempt owns this prefix" exists
  local ext
  for ext in claim exit detached progress ccr-prelaunch ccr-prelaunch.part ccr-attempt.json ccr-receipt.json claim.lock; do
    [ ! -e "${PREFIX:-/nonexistent}.$ext" ] || return 0
  done
  return 1
}
die4() {
  echo "codex-run.sh: $1" >&2; echo "$USAGE" >&2
  [ "$CLAIM_MODE" = 1 ] || [ "$ATTACH_MODE" = 1 ] || publishing_marker \
    || echo 4 > "$PREFIX.exit" 2>/dev/null || true
  exit 4
}
need() { [ $# -ge 2 ] || die4 "$1 requires a value"; case "$2" in -*) die4 "$1 requires a value (got option $2)";; esac; }
MODE="--fresh"; MODE_SET=0; PROMPT_FILE=""; STALL_MIN=6; MAX_MIN=25; POLL=15; VIA=codex; MAX_TURNS=""; RESUME_SESSION=""; ATTACH=0; VIA_SET=0; CANCEL_ONLY=0; EXPECTED_JOB=""; EXPECTED_PARENT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --attach) ATTACH=1;;
    --cancel) CANCEL_ONLY=1;;
    --expected-job) need "$@"; EXPECTED_JOB="$2"; shift;;
    --expected-parent-job) need "$@"; EXPECTED_PARENT="$2"; shift;;
    --fresh|--resume-last) [ "$MODE_SET" != 1 ] || [ "$MODE" = "$1" ] || die4 "$MODE and $1 are exclusive"; MODE="$1"; MODE_SET=1;;
    --via) need "$@"; VIA="$2"; VIA_SET=1; shift;;
    --prompt-file) need "$@"; PROMPT_FILE="$2"; shift;;
    --stall-min) need "$@"; STALL_MIN="$2"; shift;;
    --max-min) need "$@"; MAX_MIN="$2"; shift;;
    --poll-sec) need "$@"; POLL="$2"; shift;;
    --max-turns) need "$@"; MAX_TURNS="$2"; shift;;
    --resume-session) need "$@"; [ "$MODE_SET" != 1 ] || [ "$MODE" = "--resume-session" ] || die4 "$MODE and --resume-session are exclusive"; MODE="--resume-session"; MODE_SET=1; RESUME_SESSION="$2"; shift;;
    --claim) need "$@"; CLAIM_MODE=1; CLAIM_TOKEN="$2"; shift;;
    --write) die4 "--write is refused; this runner is read-only";;
    *) die4 "unknown arg $1";;
  esac; shift
done
# --attach is an operation, not a launch mode: it submits no prompt and chooses no backend. The
# backend, the launch mode and every identifier come from the detached record the launch left.
[ -z "$EXPECTED_PARENT" ] || { [ "$ATTACH" != 1 ] && [ "$MODE" != --fresh ]; } || die4 "--expected-parent-job requires a resume launch"
[ -z "$EXPECTED_JOB" ] || [ "$ATTACH" = 1 ] || die4 "--expected-job requires --attach"
# Either durable record names the job this attach was written for: the CCR attempt for a gateway
# job, the detached record for a companion one. Requiring the CCR attempt alone made the guard
# unavailable to exactly the backend that had no other job binding at all.
[ -z "$EXPECTED_JOB" ] || [ -f "$PREFIX.ccr-attempt.json" ] || [ -f "$PREFIX.detached" ] || die4 "--expected-job requires a durable CCR attempt or a detached record naming the job"
[ "$CANCEL_ONLY" != 1 ] || [ "$ATTACH" = 1 ] || die4 "--cancel is only valid with --attach"
if [ "$ATTACH" = 1 ]; then
  [ "$MODE_SET" != 1 ] || die4 "--attach and $MODE are exclusive: an attach resumes the watch on the job the launch already started"
  [ -z "$PROMPT_FILE" ] || die4 "--attach takes no --prompt-file: the prompt was submitted by the launch it re-attaches to"
  [ -z "$MAX_TURNS" ] || die4 "--attach takes no --max-turns: the child's turn budget was fixed at launch"
  [ "$VIA_SET" != 1 ] || die4 "--attach takes no --via: the backend is read from $PREFIX.detached"
fi
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
  [ -z "$EXPECTED_PARENT" ] || die4 "--expected-parent-job is ccr-only"
else
  [ "$MODE" != --resume-last ] || die4 "CCR --resume-last is ambiguous; resolve the session before preparing the prompt and use --resume-session with --expected-parent-job"
  [ -n "$MAX_TURNS" ] || MAX_TURNS=$CCR_MAX_TURNS_DEFAULT
  case "$RESUME_SESSION" in *[!A-Za-z0-9-]*) die4 "--resume-session: a session id has only letters, digits and '-' (got '$RESUME_SESSION')";; esac
fi
valid_resume_identity() {
  python3 - "$1" "$2" <<'PYIDS'
import sys, uuid
try:
    sid, job = sys.argv[1:]
    valid = str(uuid.UUID(sid)) == sid and job.startswith("ccr-") and str(uuid.UUID(job[4:])) == job[4:]
except ValueError:
    valid = False
sys.exit(0 if valid else 1)
PYIDS
}
if [ "$BACKEND" = ccr ] && [ "$ATTACH" != 1 ] && [ "$MODE" = --resume-session ]; then
  [ -n "$EXPECTED_PARENT" ] || die4 "--resume-session requires --expected-parent-job; resolve the session head before preparing this round's prompt"
  valid_resume_identity "$RESUME_SESSION" "$EXPECTED_PARENT" || die4 "resume requires a canonical session UUID and ccr-UUID parent job"
fi
for v in STALL_MIN MAX_MIN POLL MAX_TURNS; do
  eval "val=\$$v"
  [ "$v" != MAX_TURNS ] || [ -n "$val" ] || continue
  case "$val" in ''|*[!0-9]*) die4 "--$(exec 9>&-; echo "$v" | tr 'A-Z_' 'a-z-') requires a whole number (got '$val')";; esac
  # Strip to base 10: bash reads a leading-zero literal as octal, so "08" would
  # abort arithmetic later with "value too great for base". Also bound the range
  # so an oversized value cannot silently overflow.
  val=$(exec 9>&-; printf '%s' "$val" | sed 's/^0*//'); [ -n "$val" ] && [ "${#val}" -le 6 ] || die4 "--$(exec 9>&-; echo "$v" | tr 'A-Z_' 'a-z-') must be between 1 and 999999"
  eval "$v=\$val"
done
if [ "$ATTACH" != 1 ]; then
  [ -n "$PROMPT_FILE" ] || die4 "--prompt-file is required"
  [ -r "$PROMPT_FILE" ] || die4 "prompt file not readable: $PROMPT_FILE"
fi

# The detached record. It is the ONLY marker of a detached-but-live attempt: .exit stays absent,
# because every review gate reads an existing .exit as a finished attempt and would rotate the
# claim and authorize a second launch against the job that is still running.
write_detached() {  # key=value lines on stdin
  local tmp="$PREFIX.detached.tmp"
  cat > "$tmp"
  mv "$tmp" "$PREFIX.detached"
}
detached_field() { awk -F= -v k="$1" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$PREFIX.detached" 2>/dev/null; }
quote_command() { python3 -c 'import shlex,sys; print(shlex.join(sys.argv[1:]))' "$@"; }
abs_path() { python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$1"; }
# THE one generator of a companion attach command. Every emitted `--attach` — the saved command a
# detach records, the fallback a failed attach prints, the remedy a refusal offers — comes from
# here, so no path can print a command the admission block would reject (cycle 8: CX-01). It is
# quoted and absolute because the messages that carry it say "run this": PREFIX is whatever the
# caller passed (it is `"${1:-}"`, not normalized), and a raw interpolation splits on the first
# space in an installation or artifact path the quoting tests explicitly support (cycle 8: CX-02).
bound_attach_command() {  # <job> <stall-min> <max-min> <poll-sec> [extra args…]
  local job="$1" s="$2" m="$3" p="$4"; shift 4
  quote_command "$CCR_RUNNER" "$(exec 9>&-; abs_path "$PREFIX")" --attach --expected-job "$job" \
    --stall-min "$s" --max-min "$m" --poll-sec "$p" "$@"
}
# What to print on the "attach:" line of a detach. A record whose watch bounds were never recorded
# carries an EMPTY attach_command and says why in attach_guidance, because a command with no bound
# options is not silent about bounds — it means this parser's defaults, and the stall bound cancels
# (cycle 11: F-01). Print the guidance rather than an empty line, and never invent a fallback.
# ONE refusal for "this attach is for a different job than the record names", reached from two
# places: before the publication lock, as soon as the record names a job at all, and again over the
# record this attach goes on to use. Two spellings of one message would drift; a single one cannot.
refuse_if_other_job() {  # <job the record names>
  [ "$EXPECTED_JOB" != "$1" ] || return 0
  die4 "--attach: this attach names job $EXPECTED_JOB, but $PREFIX.detached now names job $1 — that attempt was collected and the prefix reused. Nothing was observed or cancelled. Read the earlier attempt's rotated sidecars (<prefix>.attemptN.*) instead of attaching, or attach to the job that is here.$(exec 9>&-; remedy_for "$1" $CANCEL_FLAG)"
}
attach_line() {  # <command-or-empty>
  local guidance
  [ -z "$1" ] || { printf '%s' "$1"; return 0; }
  guidance=$(exec 9>&-; detached_field attach_guidance)
  printf '%s' "${guidance:-no attach command is recorded for this attempt: attach with --expected-job and --stall-min/--max-min/--poll-sec you choose deliberately, knowing the stall bound cancels}"
}
# WHOSE BOUNDS the printed command carries is not cosmetic. On an attach `--stall-min` is not
# advisory: reaching it sets OUTCOME=STALLED and issues a real cancel. A refusal that stamps its
# remedy with the REFUSING invocation's bounds therefore hands the operator a command that can end a
# healthy job the recorded command would have waited for (cycle 9: CL-01) — the refusal turns a
# recovery into a cancellation. So a remedy about an existing attempt carries that attempt's own
# bounds, read from the saved command the launch recorded, and only a command that describes THIS
# attach carries this invocation's.
# There are exactly TWO durable sources for an attempt's bounds and they are not the same as the
# three the job id has. The detached record carries them inside the command it stored; the attempt
# record carries them as numeric fields, written before the job can detach — which is precisely the
# window an interrupted admission leaves behind, where the job id is readable and the detached
# record does not exist yet (cycle 10: F-01/CX-01). The receipt is NOT a third source: reconciliation
# keeps submission_id, job_id and session_id only.
attempt_bounds() {  # -> "<stall> <max> <poll>" from the attempt record, or nothing with status 1
  [ -e "$PREFIX.ccr-attempt.json" ] || return 1
  python3 9>&- -c 'import json,sys
d = json.load(open(sys.argv[1]))
v = [d.get(k) for k in ("stall_min", "max_min", "poll_sec")]
if not all(isinstance(x, int) and not isinstance(x, bool) and x > 0 for x in v):
    raise SystemExit(1)
print(*v)' "$PREFIX.ccr-attempt.json" 2>/dev/null
}
# Whether a delivered receipt exists at all — the difference between "this attach names the wrong
# job" and "no job can be named yet", which the binding check cannot tell apart because it loads the
# receipt before it compares anything (cycle 10: CL-03).
# "Is the DELIVERED receipt usable?" — the same question the helper's delivered_receipt_readable
# asks, and deliberately the same answer. This test used to accept any document with a non-empty
# job_id, while the binding it guards requires a complete identity: a receipt that parsed but was
# incomplete therefore failed the binding and then passed here, so the refusal fell through to
# "belongs to a different attempt" for an operator whose command was correct, in a state the
# recovery lookup repairs (cycle 12: F-07). A document that is not an object is not a receipt.
receipt_readable() {
  [ -s "$PREFIX.ccr-receipt.json" ] || return 1
  python3 9>&- -c 'import json,sys
d = json.load(open(sys.argv[1]))
raise SystemExit(0 if isinstance(d, dict) and all(
    isinstance(d.get(k), str) and d[k] for k in ("submission_id", "job_id", "session_id")) else 1)' "$PREFIX.ccr-receipt.json" 2>/dev/null
}
recorded_bounds() {  # -> "<stall> <max> <poll>" AS LAUNCHED, or nothing with status 1
  local cmd stored b
  cmd=$(exec 9>&-; detached_field attach_command)
  # Each option's WHOLE value is validated, because a numeric prefix is not a number: a regex that
  # anchors only the start reads `--stall-min 1e2` as 1 and hands back a one-minute cancellation
  # threshold the record never expressed (cycle 11: CX-03). A malformed stored bound is no bound.
  stored=$(exec 9>&-; printf '%s' "$cmd" | python3 9>&- -c 'import shlex,sys
try:
    argv = shlex.split(sys.stdin.read())
except ValueError:
    raise SystemExit(1)
out = []
for flag in ("--stall-min", "--max-min", "--poll-sec"):
    if flag not in argv:
        raise SystemExit(1)
    index = argv.index(flag) + 1
    value = argv[index] if index < len(argv) else ""
    if not value.isdigit() or int(value) <= 0:
        raise SystemExit(1)
    out.append(value)
print(" ".join(out))') && [ -n "$stored" ] && { printf '%s' "$stored"; return 0; }
  # No fallback to THIS invocation's options. A partial or unreadable record means the bounds are
  # unknown, and an unknown bound must be said, never substituted: the caller's own numbers are the
  # one set of numbers that is certainly not the attempt's.
  b=$(exec 9>&-; attempt_bounds) || return 1
  [ -n "$b" ] || return 1
  printf '%s' "$b"
}
recorded_attach_command() {  # <job> [extra args…] -> the remedy for an ATTEMPT, in its own bounds
  local job="$1" b; shift
  b=$(exec 9>&-; recorded_bounds) || return 1
  bound_attach_command "$job" $b "$@"
}
# What a refusal appends to its message: a ready-to-run command when the attempt's own bounds are
# recorded, and otherwise an explicit statement that they are not. A refusal must never manufacture
# a bound — on an attach `--stall-min` cancels, so a printed command carrying a number nothing
# recorded is a guess the operator would run, which is the defect this whole path exists to avoid.
remedy_for() {  # <job> [extra args…] -> " Run: <cmd>" | " <no-bounds sentence>" | ""
  local job="$1" cmd; shift
  [ -n "$job" ] || return 0
  cmd=$(exec 9>&-; recorded_attach_command "$job" "$@") && [ -n "$cmd" ] \
    && { printf ' Run: %s' "$cmd"; return 0; }
  printf ' The job on this prefix is %s, but the watch bounds it was launched with are not recorded here, so no ready-to-run command is offered: attach with --expected-job %s and --stall-min/--max-min/--poll-sec you choose deliberately, knowing the stall bound cancels.' "$job" "$job"
}
# The job this prefix's own durable records name, read WITHOUT running recovery: a refusal must be
# able to print a usable remedy without first mutating the attempt it is refusing to address
# (cycle 9: CX-02). The detached record is preferred because it is what an attach is admitted
# against; the admission records answer for an attempt that has not detached yet.
recorded_job_id() {
  local j f src
  j=$(exec 9>&-; detached_field job); [ -z "$j" ] || { printf '%s' "$j"; return 0; }
  # The two sources are kept as separate path/field pairs. Packing them as "path:field" and
  # splitting on the first colon truncated any prefix that contained one, so the record was never
  # found and the refusal silently offered no remedy at all (cycle 11: CL-05) — on paths this
  # suite's own quoting fixtures exist to support.
  for f in "receipt" ""; do
    case "$f" in receipt) src="$PREFIX.ccr-attempt.json";; *) src="$PREFIX.ccr-receipt.json";; esac
    [ -e "$src" ] || continue
    j=$(exec 9>&-; python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
if sys.argv[2]: d=d.get(sys.argv[2]) or {}
print(d.get("job_id") or "")' "$src" "$f" 2>/dev/null) || j=""
    [ -z "$j" ] || { printf '%s' "$j"; return 0; }
  done
  printf ''
}
prompt_digest() { { shasum -a 256 "$1" 2>/dev/null || sha256sum "$1" 2>/dev/null; } | awk '{print $1; exit}'; }
# Kernel file locks serialize collectors, admission and claim rotation. The
# shell owns descriptor 9; the lock helper inherits it. Observation children
# close it, including their command-substitution shells. Admission execs its
# helper with the lease through receipt binding. Every mutating helper keeps
# that lease through its final artifact write, including after collector loss.
# External shell mutators inherit it too: a rename, copy, or removal can still
# be pending after its shell dies. Only observation children may discard it.
# Keep the lock inode permanently: unlinking it would split future contenders.
# Old directory locks must drain under the old runner before upgrading.
publish_lock() {  # [--must], bounded acquisition for every caller
  local lock="$PREFIX.claim.lock"
  [ ! -d "$lock" ] || die4 "legacy collector lock $lock: drain old runners before upgrading"
  exec 9>>"$lock" || die4 "cannot open collector lock $lock"
  if ! python3 "$CCR_HELPER" lock 9 5; then
    exec 9>&-
    die4 "$lock is held by another collector or locking is unavailable; retry without relaunching"
  fi
  HELD_LOCK="$lock"
}
publish_unlock() { exec 9>&-; HELD_LOCK=""; }
trap 'publish_unlock' EXIT
trap 'publish_unlock; exit 130' INT
trap 'publish_unlock; exit 143' TERM

# The in-flight refusals, split out of rotate_previous_attempt so they can run BEFORE the claim is
# taken. They used to run after: stamp_claim did `mkdir <prefix>.claim/runner` and wrote its pid,
# and only then did rotation ask whether the prefix already held an unfinished attempt. A refusal
# therefore left a taken claim behind — which `phase-gate.sh` counts against the four-launch budget
# and reports as a runner in flight for a process that has exited — so four refusals could exhaust
# a review's budget without a single job being launched (cycle 5: CL-05). This function only ever
# reads and refuses; it never rotates or writes.
# THE SAME PREDICATE phase-gate.sh's ccr_release_check uses, stated here because the two decisions
# must agree: the gate frees the claim on this proof, and the runner must then accept the relaunch
# the freed claim exists to authorize. Every field the marker carries is checked, so adding a
# second marker stage later cannot silently pass as a pre-admission proof.
#
# It is deliberately NOT a general escape from refuse_if_in_flight. It is consulted only where the
# attempt is otherwise unidentifiable — no CCR launch line, no companion job id — because in every
# other case there is a job whose owner can be asked, and asking is always better than inferring.
PRELAUNCH_PROOF_NOTE=""
note_prelaunch_proof() {  # record the permitting branch, once, in the NEW attempt's .progress
  [ -n "$PRELAUNCH_PROOF_NOTE" ] || return 0
  echo "0s PRE-SUBMISSION-PROOF: $PRELAUNCH_PROOF_NOTE" >> "$PREFIX.progress"
  PRELAUNCH_PROOF_NOTE=""
}
proven_pre_submission() {  # -> 0 only when this prefix provably never submitted a workload
  local marker="$PREFIX.ccr-prelaunch" field
  [ -e "$marker" ] || return 1
  for field in "protocol=$CCR_PROTOCOL" stage=pre-admission backend=ccr; do
    grep -qxF -- "$field" "$marker" 2>/dev/null || return 1
  done
  # An attempt record or a receipt means admission was reached, so a workload may exist and only
  # its owner may say otherwise. The marker alone never overrides either.
  [ ! -e "$PREFIX.ccr-attempt.json" ] && [ ! -e "$PREFIX.ccr-receipt.json" ]
}
refuse_if_in_flight() {
  if [ -e "$PREFIX.ccr-attempt.json" ] && [ ! -e "$PREFIX.exit" ]; then
    python3 9>&- "$CCR_HELPER" stopped "$PREFIX" >/dev/null 2>&1 || {
      echo "codex-run.sh: durable CCR attempt is still open; use --attach. An unresolved admission must never be resubmitted." >&2
      exit 4
    }
  fi
  # A RUNNING attempt that has not detached yet is in flight too. `.detached` is only written when
  # a watch bound elapses, so between launch and that bound the prefix has `.progress` and a `.meta`
  # naming a live pid and pgid, and no `.detached` at all — and the guard below, keyed on
  # `.detached`, did not look. A second launch on the same prefix therefore rotated a still-running
  # attempt's sidecars away and started a job beside it, with both supervisors writing the same
  # paths. Taking the lock serialized the two rotations but established no ownership that outlives
  # it, which is the whole defect: the claim-less path of codex-debate and codex-deep-plan has no
  # claim directory to carry that ownership either (cycle 5: CX-07). The live attempt's own `.meta`
  # is that record, and it is now consulted first.
  # A running attempt has not written `.meta` yet — that is a terminal-or-detach act — so the only
  # record it leaves is the launch line in `.progress`, the same line `phase-gate.sh` reads.
  if [ ! -e "$PREFIX.exit" ] && [ ! -e "$PREFIX.detached" ] && [ -e "$PREFIX.progress" ]; then
    local lline lpgid ljob lstat lroot mlive=""
    lline=$(exec 9>&-; grep -E '^[0-9]+s launched backend=ccr ' "$PREFIX.progress" 2>/dev/null | tail -1)
    if [ -n "$lline" ]; then
      lccrjob=$(exec 9>&-; printf '%s' "$lline" | sed -n 's/.* job=\([^ ]*\).*/\1/p')
      # The job's owner is the authority, exactly as it is in the watch loop. An unanswerable
      # status is undetermined and refuses the launch; only a job CCR reports as over clears it.
      if [ -n "$lccrjob" ]; then
        case "$(exec 9>&-; ccr_job_state "$(exec 9>&-; ccr_job_json "$lccrjob")")" in
          ended) ;;                                                        # over: rotate
          running) mlive="ccr reports job $lccrjob as still running";;
          *) mlive="ccr could not be asked about job $lccrjob";;            # fail closed
        esac
      else
        mlive="legacy CCR attempt has no durable job receipt; drain it before upgrading"
      fi
    else
      ljob=$(exec 9>&-; grep -oE 'launched job=task-[a-z0-9-]+' "$PREFIX.progress" 2>/dev/null | head -1 | cut -d= -f2)
      if [ -n "$ljob" ]; then
        lroot=$(exec 9>&-; codex_root)
        if [ -n "$lroot" ] && [ -f "$lroot/scripts/codex-companion.mjs" ]; then
          lstat=$(exec 9>&-; node "$lroot/scripts/codex-companion.mjs" status "$ljob" --json 2>/dev/null \
                  | python3 -c "import sys,json;d=json.load(sys.stdin);print((d.get('job') or {}).get('status') or '')" 2>/dev/null)
          case "$lstat" in
            completed|failed|cancelled|canceled) ;;                      # over: rotate
            "") mlive="the companion did not answer for job $ljob";;      # fail closed
            *)  mlive="job $ljob is $lstat";;
          esac
        else
          mlive="the codex companion could not be consulted for job $ljob"
        fi
      elif proven_pre_submission; then
        # Nothing was ever submitted from this prefix, and that is proved rather than assumed
        # (see proven_pre_submission). There is no workload to collide with, so fall through to
        # rotate_previous_attempt, which archives the orphaned .progress and the marker as
        # .attemptN.* and lets this launch proceed. Without this branch `phase-gate.sh release`
        # frees the claim and the very next launch is still refused here, which leaves the
        # interrupted-admission prefix wedged while reporting RELEASED.
        #
        # This is the only branch in the mechanism that PERMITS rather than refuses, so it says so.
        # Silently falling through left nothing in the run directory distinguishing a launch this
        # proof authorized from an ordinary rotation, which is exactly the evidence an incident
        # involving a second job beside a live one would need (cycle 8: CL-04). The note is recorded
        # for the NEW attempt, after this orphan has been rotated away — writing it here would
        # archive the note together with the attempt it is about.
        PRELAUNCH_PROOF_NOTE="pre-submission proof (protocol=$CCR_PROTOCOL stage=pre-admission backend=ccr, no attempt record, no receipt) authorized this launch over an orphaned .progress"
      else
        mlive="unfinished legacy attempt has no verifiable workload identity; drain it before upgrading"
      fi
    fi
    if [ -n "$mlive" ]; then
      echo "codex-run.sh: $PREFIX.progress names an attempt that has not ended — $mlive. It has not detached, so there is no attach command yet: launching here would rotate a running job's sidecars away and start a second job against the same prefix. Wait for it, or cancel it first." >&2
      exit 4
    fi
  fi
  # A detached attempt with no .exit is IN FLIGHT. Rotating its record away would strand the job:
  # nothing could attach to it or cancel it again, and its process group would keep running
  # unowned while a second job started against the same prefix (cycle 2: CL-07). Refuse while the
  # owner cannot positively confirm termination. Missing or malformed backend
  # metadata is unresolved and cannot authorize replacement.
  if [ -e "$PREFIX.detached" ] && [ ! -e "$PREFIX.exit" ]; then
    local dbackend dpid dident djob dstatus droot dattach dlive="undetermined (detached backend is missing or unrecognized)"
    dbackend=$(exec 9>&-; detached_field backend)
    case "$dbackend" in
      ccr)
        if python3 "$CCR_HELPER" stopped "$PREFIX" >/dev/null 2>&1; then dlive=no
        else dlive="unresolved CCR attempt; attach to collect it (legacy process records cannot grant control)"; fi
        ;;
      codex)
        # The codex record carries no process WE own — the companion owns the job — so liveness is
        # asked of the companion, exactly as phase-gate.sh asks it. Until this was added the guard
        # was dead code on the default backend (no pid= was ever recorded), so a relaunch rotated a
        # live job's record away and started a SECOND job beside it — and codex-debate and
        # codex-deep-plan, which pass no --claim, had no other protection (cycle 3: CL-03/CX-02).
        djob=$(exec 9>&-; detached_field job); droot=$(exec 9>&-; codex_root)
        if [ -n "$djob" ] && [ -n "$droot" ] && [ -f "$droot/scripts/codex-companion.mjs" ]; then
          dstatus=$(exec 9>&-; node "$droot/scripts/codex-companion.mjs" status "$djob" --json 2>/dev/null \
                    | python3 -c "import sys,json;d=json.load(sys.stdin);print((d.get('job') or {}).get('status') or '')" 2>/dev/null)
          case "$dstatus" in
            completed|failed|cancelled|canceled) dlive=no;;                       # authoritatively over: rotate
            "") dlive="undetermined (the companion did not answer for job $djob)";;  # fail closed
            *)  dlive="yes (job $djob is $dstatus)";;
          esac
        else
          dlive="undetermined (the codex companion could not be consulted for job $djob)"
        fi
        # A local worker pid, when the record has one, can only make the answer MORE certain.
        dpid=$(exec 9>&-; detached_field worker_pid); dident=$(exec 9>&-; detached_field worker_identity)
        [ -z "$dpid" ] || ! identity_state "$dpid" "$dident" || dlive="yes (worker pid $dpid is still running)"
        ;;
    esac
    if [ "$dlive" != no ]; then
      # Regenerated from the job this record names, not forwarded from the record's own text: a
      # record written before the binding existed carries an unbound command, and the attach
      # admission now refuses those, so forwarding it would send the operator to a certain refusal
      # (cycle 8: CX-01). When the record names no job there is nothing to bind to, and the stored
      # text — whatever it is — is still the most the record can offer.
      dattach=$(exec 9>&-; detached_field attach_command)
      # …and when the record names a job whose launch bounds are not recorded anywhere, the operator
      # is told that rather than handed a command carrying bounds nothing recorded (cycle 10: F-01).
      # The job is read HERE, for both backends. It used to be read only inside the codex arm above,
      # so on the gateway backend neither the regeneration nor its fallback sentence ran and the
      # record's own command was echoed — a blank line for the record shape whose command is
      # deliberately empty (cycle 12: F-06). attach_line supplies the record's own guidance for
      # anything still empty after that.
      djob=$(exec 9>&-; detached_field job)
      [ -z "$djob" ] || dattach=$(exec 9>&-; recorded_attach_command "$djob") \
        || dattach="(no ready-to-run command: the watch bounds this attempt was launched with are not recorded here. Attach with --expected-job $djob and --stall-min/--max-min/--poll-sec you choose deliberately, knowing the stall bound cancels.)"
      echo "codex-run.sh: $PREFIX.detached names an attempt that has not ended — $dlive. Launching here would strand it and start a second job beside it. Attach to it or cancel it first:" >&2
      echo "  $(exec 9>&-; attach_line "$dattach")" >&2
      echo "  $(exec 9>&-; detached_field cancel_command)" >&2
      exit 4
    fi
  fi
}
rotate_previous_attempt() {
  # Re-asked here as well as in stamp_claim: this is the last moment before the previous attempt's
  # sidecars are moved, and the two callers that reach rotation without a claim must still refuse.
  refuse_if_in_flight
  # never clobber a previous attempt: rotate its sidecars to <prefix>.attemptN.*
  # A launch error leaves .exit without .meta, and a runner killed mid-flight
  # leaves .progress without either, so all three are attempt markers and an
  # orphaned attempt is rotated as a unit, never truncated.
  # `.ccr-prelaunch` is in this trigger, not only in the rotated list below, because it is written
  # one line BEFORE `.progress`: an interruption between those two lines leaves a prefix carrying a
  # marker and none of the other three, which nothing would then archive. A later attempt would
  # inherit it, and once proven_pre_submission honours a marker, an inherited one could vouch for an
  # attempt it knows nothing about — authorizing a launch beside work that may be live. A lone
  # marker must therefore be archived by the next launch like any other orphan.
  # `.ccr-prelaunch.part` is in the trigger for a WEAKER but still sufficient reason, and the
  # distinction matters: nothing reads the staging file, so it can never vouch for anything — but it
  # can be the only file on a prefix (it is written after rotation has moved everything else away),
  # and adding it to the rotated list alone left it surviving the next launch and then archived with
  # the sidecars of the launch that FOLLOWED it (cycle 9: CL-06/CX-03). Deleting it instead would
  # discard the one trace that a staging write was interrupted, and would not cover the companion and
  # launch-error paths, which write no marker at all. Archive it; never read it.
  if [ -e "$PREFIX.meta" ] || [ -e "$PREFIX.exit" ] || [ -e "$PREFIX.progress" ] || [ -e "$PREFIX.ccr-prelaunch" ] || [ -e "$PREFIX.ccr-prelaunch.part" ]; then
    N=1; while ls "$PREFIX.attempt$N."* >/dev/null 2>&1; do N=$((N+1)); done
    # .detached and .childexit belong to the attempt too: a record left behind would make a bogus
    # --attach admissible against the NEXT, live attempt, and a stale receipt would let it publish
    # a terminal outcome from the previous run's exit status.
    # ccr-prelaunch.part is the marker's staging name. A kill between its write and the rename that
    # publishes it leaves a file that reads as a marker beside the real ones, in a directory whose
    # names are load-bearing evidence, and nothing else ever removes it (cycle 8: CL-05).
    for ext in stdout stderr progress joblog meta exit detached childexit ccr-prelaunch ccr-prelaunch.part ccr-attempt.json ccr-receipt.json ccr-receipt.observed ccr-recovery-receipt.json ccr-admission-conflict.json ccr-prompt ccr-result.json ccr-errorlog ccr-submit.stderr; do [ -e "$PREFIX.$ext" ] && mv "$PREFIX.$ext" "$PREFIX.attempt$N.$ext"; done
    for observation in "$PREFIX.ccr-observation."* "$PREFIX.ccr-capture."*; do
      [ -e "$observation" ] || continue
      mv "$observation" "$PREFIX.attempt$N.${observation#"$PREFIX."}"
    done
    echo "codex-run.sh: previous attempt rotated to $PREFIX.attempt$N.*"
  fi
}
stamp_claim() {
  # Reject a missing requested claim without creating even a coordination file.
  # The same condition is checked again after acquiring the lease.
  if [ "$CLAIM_MODE" = 1 ] && [ ! -d "$PREFIX.claim" ]; then
    die4 "--claim given but $PREFIX.claim does not exist; run the launch gate first"
  fi
  # A launch gate that hands off to this runner records its claim in
  # <prefix>.claim/. One claim authorizes ONE runner: the runner takes the claim
  # with an atomic mkdir of <prefix>.claim/runner BEFORE it touches any sidecar,
  # so two runners handed the same prefix (a delayed launcher whose claim was
  # reclaimed, a retry without a fresh gate, a double launch) cannot both start
  # or rotate each other's files (round-28 CX-02, round-29 CX-02). The loser
  # exits 4 and writes nothing under the prefix.
  # The lock is taken FIRST and unconditionally, because what it serializes is not only the claim:
  # every caller runs `stamp_claim; rotate_previous_attempt`, so returning early from
  # here left the in-flight check and the sidecar rotation completely unserialized. On the default
  # path of codex-debate and codex-deep-plan — no claim directory and no --claim — that early
  # return was ALWAYS taken, so two launches racing on one prefix could both read "not in flight"
  # and both rotate, each hiding the other's attempt (cycle 4: CL-04/CX-03). The claim-specific
  # work below stays conditional; the lock does not.
  # Taking the claim (token check, mkdir runner, pid) is serialized against the
  # gate rotating or replacing it by <prefix>.claim.lock, the same kernel file lock
  # that the gate holds while it rotates (round-38 CX-03). The lock stays held
  # until the previous attempt's sidecars are rotated away (unlock_claim), so a
  # stale <prefix>.exit can never make a concurrent gate treat this runner's
  # claim as finished and rotate it (round-39 CX-01). This takes the lock through the SAME
  # acquisition as every other holder — one staleness rule, holder-based, in one place. Two rules
  # in one file was how a launch could still take the lock from a live attach on the old clock,
  # and how a holder file this function could not `rmdir` could wedge it (review cycle 3).
  publish_lock
  local lock="$HELD_LOCK"
  # Under the lock, and BEFORE anything is claimed or written: a launch that is going to be refused
  # must not first consume the claim that refusal makes unusable (cycle 5: CL-05).
  refuse_if_in_flight
  if [ ! -d "$PREFIX.claim" ]; then
    if [ "$CLAIM_MODE" = 1 ]; then
      publish_unlock
      echo "codex-run.sh: --claim given but $PREFIX.claim does not exist; run the launch gate first (no sidecar was written)" >&2
      exit 4
    fi
    # No claim to take — but the lock is deliberately still HELD, so the caller's in-flight check
    # and rotation are serialized against every other launch, attach and release on this prefix.
    return 0
  fi
  if [ "$CLAIM_MODE" = 1 ] && ! grep -qxF "token=$CLAIM_TOKEN" "$PREFIX.claim/owner" 2>/dev/null; then
    publish_unlock
    echo "codex-run.sh: $PREFIX.claim does not carry token $CLAIM_TOKEN (the claim was rotated or replaced since the gate printed it); re-run the launch gate and use its new token (no sidecar was written)" >&2
    exit 4
  fi
  if ! mkdir "$PREFIX.claim/runner" 2>/dev/null; then
    publish_unlock
    echo "codex-run.sh: $PREFIX.claim is already taken by runner $(exec 9>&-; cat "$PREFIX.claim/runner/pid" 2>/dev/null || echo unknown); re-run the launch gate before launching again (no sidecar was written)" >&2
    exit 4
  fi
  printf '%s\n' "$$" > "$PREFIX.claim/runner/pid"
  printf 'runner_pid=%s\nstarted=%s\n' "$$" "$(exec 9>&-; date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$PREFIX.claim/owner" 2>/dev/null
  HELD_LOCK="$lock"
  return 0
}
HELD_LOCK=""
unlock_claim() { publish_unlock; }   # one release for one acquisition: the holder record goes too
# A launch error after the claim is owned: sidecars record it (outcome=LAUNCH-ERROR, .exit=4).
launch_error() {  # <message> <command>
  stamp_claim; rotate_previous_attempt
  echo "codex-run.sh: $1" >&2; printf 'LAUNCH-ERROR\n%s\n' "$1" > "$PREFIX.stderr"; printf '0s LAUNCH-ERROR: %s\n' "$1" > "$PREFIX.progress"
  # This path CONSUMED the pre-submission proof: rotate_previous_attempt above archived the orphan on
  # its strength. Recording the note only on the two success paths left the one branch that permits
  # rather than refuses with no trace at all whenever the launch then failed its preflight — which is
  # every unresolvable alias, every failed smoke and every missing companion (cycle 9: CL-03). The
  # note goes after the truncation, not before it, or the `>` above would erase it.
  note_prelaunch_proof
  printf 'outcome=LAUNCH-ERROR\nbackend=%s\nlast_error=%s\nmode=%s\nprompt_file=%s\ncommand=%s\n' "$BACKEND" "$1" "$MODE" "$PROMPT_FILE" "$2" > "$PREFIX.meta"; echo 4 > "$PREFIX.exit"; exit 4
}
START=$(exec 9>&-; date +%s); now() { date +%s; }; elapsed() { echo $(( $(exec 9>&-; now) - START )); }


# =============================================================================================
# --attach — resume the watch on a job this process did not launch
# =============================================================================================
# Not a launch: no claim is taken (stamp_claim would refuse a claim already held), no sidecar is
# rotated (rotate_previous_attempt would hide the very .meta this needs), no launch budget is
# spent, and `mode=` keeps the original launch mode so the review gates' thread anchoring is
# untouched. Attachment is recorded separately, in `attached=`.
if [ "$ATTACH" = 1 ]; then
  # Cancellation addresses the admitted job and does not publish collector
  # artifacts. It must remain available while another collector holds its lease.
  if [ "$CANCEL_ONLY" = 1 ] && [ -e "$PREFIX.ccr-attempt.json" ]; then
    # This branch ends a job, and it runs before the record is read, so the admission block's
    # requirement has not been applied yet. It is applied here instead: a cancellation that names no
    # job would stop whichever admitted attempt occupies the prefix now, which is the companion
    # defect (cycle 8: CX-01) with a gateway job at the other end. verify-attempt then decides
    # whether the name matches; it is the attempt record, not this process, that answers that.
    [ -n "$EXPECTED_JOB" ] || die4 "--attach --cancel: name the job to stop with --expected-job. A prefix outlives its attempts, so an unnamed cancellation would stop whichever admitted job is here now. The job id is in $PREFIX.ccr-attempt.json and in the cancel_command the launch recorded; nothing was cancelled."
    CANCEL_RESULT=$(exec 9>&-; python3 "$CCR_HELPER" cancel-attempt "$PREFIX" "$EXPECTED_JOB") || exit 6
    echo "codex-run.sh: stopped job $(exec 9>&-; ccr_job_field "$CANCEL_RESULT" job_id) (cleanup coverage=$(exec 9>&-; ccr_job_field "$CANCEL_RESULT" cleanup.coverage))"
    exit 0
  fi
  # Admission is decided under the publication lock and HELD for the whole attach, so a second
  # attach cannot pass the same guard and end up as a concurrent collector of one job. Testing
  # `.exit` outside the lock only proved it was absent at some moment in the past; by the time
  # this process published, another collector could already have finished.
  # THE CALLER NAMES THE JOB — asked above the gateway recovery step, because that step writes
  # (`recover` atomically replaces <prefix>.ccr-attempt.json and, when no detached record exists,
  # publishes one), and above publish_lock, because that CREATES <prefix>.claim.lock with an
  # append redirect. With the requirement below either one, "nothing was written" was false: first
  # by two durable sidecars (cycle 9: CX-02), then by the lock file itself (cycle 10: CL-06). This
  # refusal reads the durable records and nothing else, so it needs neither the lock nor recovery.
  # The identity comparison against the detached record stays below, where the record is read.
  CANCEL_FLAG=""; [ "$CANCEL_ONLY" != 1 ] || CANCEL_FLAG=--cancel
  if [ -z "$EXPECTED_JOB" ]; then
    RJOB=$(exec 9>&-; recorded_job_id)
    die4 "--attach: every attach must name the job it is for, and this one named none. A prefix outlives its attempts, so nothing here can prove this attach was meant for the job now on this prefix rather than an earlier attempt at the same one; nothing was observed, cancelled or written.$(exec 9>&-; remedy_for "$RJOB" $CANCEL_FLAG)"
  fi
  # The identity comparison runs here too, whenever the record already names a job. It used to run
  # only below publish_lock, so the refusal that says nothing was observed or cancelled still left
  # <prefix>.claim.lock behind — the same file the binding-presence refusal above was moved up to
  # avoid creating (cycle 12: F-08). The record is published by an atomic rename, so reading it
  # without the lock reads one version or another, never a partial one. The comparison below stays:
  # it is the authoritative one, over the record this attach goes on to use, and it is what refuses a
  # record that names no job at all.
  if [ -e "$PREFIX.detached" ]; then
    EJOB=$(exec 9>&-; detached_field job)
    [ -z "$EJOB" ] || refuse_if_other_job "$EJOB"
  fi
  publish_lock
  if [ -e "$PREFIX.ccr-attempt.json" ] && [ ! -e "$PREFIX.exit" ]; then
    if ! python3 9>&- "$CCR_HELPER" verify-attempt "$PREFIX" "$EXPECTED_JOB" >/dev/null; then
      # Two failures reach here and they are not the same fact. The binding is compared against the
      # delivered receipt, so an unreadable one fails before any comparison — for EVERY job id,
      # including the right one. Reporting that as "a different attempt" told an operator in the one
      # recoverable state that their correct command was wrong, and named nothing to run (cycle 10:
      # CL-03). The discovery step is read-only and never resubmits: it looks the submission up and
      # reconciles the receipt, after which an ordinary bound attach works.
      receipt_readable || die4 "--attach: this prefix's admission receipt is missing or unreadable, so no attach can be bound to it — not even one naming the correct job, because the binding is checked against the receipt. This is the lost-receipt state, and it is recoverable: repair delivery first with the read-only submission-status lookup, $(exec 9>&-; quote_command python3 "$(exec 9>&-; abs_path "$CCR_HELPER")" recover "$(exec 9>&-; abs_path "$PREFIX")"), which looks the submission up and rewrites the receipt and never submits anything; then attach with --expected-job. (Do NOT reach for complete-admission here unless you mean to finish the original admission: when the gateway still reports it prepared, that command replays the saved launch request under its original token and may start execution, though it never requests a replacement job.) Nothing was observed, cancelled or written."
      die4 "saved attach belongs to a different attempt: $PREFIX.ccr-receipt.json names a different job than $EXPECTED_JOB. Read the receipt for the job this prefix holds; nothing was observed, cancelled or written."
    fi
    python3 "$CCR_HELPER" recover "$PREFIX" >/dev/null || { echo "codex-run.sh: admission unresolved; retain the claim and investigate, never retry launch" >&2; exit 6; }
  fi
  [ -e "$PREFIX.detached" ] || die4 "--attach: no $PREFIX.detached — nothing detached from this prefix (a launch that finished wrote .exit; a launch that never ran wrote nothing)"
  [ ! -e "$PREFIX.exit" ] || die4 "--attach: $PREFIX.exit exists, so that attempt already finished; re-read its sidecars instead of attaching"
  BACKEND=$(exec 9>&-; detached_field backend); JOB=$(exec 9>&-; detached_field job); MODE=$(exec 9>&-; detached_field mode)
  ALIAS=$(exec 9>&-; detached_field alias); LOGFILE=$(exec 9>&-; detached_field joblog); RECEIPT=$(exec 9>&-; detached_field receipt)
  DPID=$(exec 9>&-; detached_field pid); PGID=$(exec 9>&-; detached_field pgid); IDENT=$(exec 9>&-; detached_field identity)
  ATTEMPTS=$(exec 9>&-; awk -F= '$1=="attached"{print $2; exit}' "$PREFIX.meta" 2>/dev/null); ATTEMPTS=$(( ${ATTEMPTS:-0} + 1 ))
  case "$BACKEND" in codex|ccr) ;; *) die4 "--attach: $PREFIX.detached names no usable backend (backend='$BACKEND')";; esac
  # THE CALLER NAMES THE JOB. Always, on both backends, cancellation included.
  #
  # A prefix is legitimately reusable — the review gate rotates a spent claim and the runner rotates
  # the previous attempt's sidecars — so the prefix alone cannot say which execution a command was
  # written for. The previous shape of this guard asked the RECORD instead: it accepted an attach
  # that named no job whenever the record now on the prefix carried a binding. That answers a
  # question about the attempt that is here, not about the one the incoming command was written for,
  # and a deliberate interactive attach and a stale pre-binding saved command have IDENTICAL
  # arguments — so a bound record vouched for every unbound caller, and an old command replayed
  # against a newer attempt was admitted, watched it, and on its stall bound cancelled it: exactly
  # the defect the binding exists to prevent (cycle 8: CX-01). There is no weaker check that
  # separates the two cases, because there is nothing in the process to separate them by.
  #
  # This is a deliberate interface change: `--attach` with no job is gone, for humans too. Every
  # command this repository emits carries the binding (see bound_attach_command), and a refusal
  # prints the command for the job this prefix names now, so the operator's next step is a copy.
  # The presence of a job was required above, before anything was read for recovery or written; this
  # is the identity comparison, which needs the record and so belongs here. The remedy it prints is
  # the command for the operation the caller attempted, so a refused cancellation is answered with a
  # cancellation and not with a watch.
  refuse_if_other_job "$JOB"
  # Regenerated, never copied. A record written before the binding existed carries an unbound
  # command, and propagating it forward would hand the next operator a command this block now
  # refuses — the upgrade would break recovery for every attempt already in flight. These bounds are
  # this attach's, deliberately: the command describes the watch that is starting now.
  ATTACH_CMD=$(exec 9>&-; bound_attach_command "$JOB" "$STALL_MIN" "$MAX_MIN" "$POLL"); CANCEL_CMD=$(exec 9>&-; detached_field cancel_command)
  echo "$(exec 9>&-; elapsed)s ATTACH #$ATTEMPTS backend=$BACKEND ${JOB:+job=$JOB}${DPID:+pid=$DPID pgid=$PGID}" >> "$PREFIX.progress"

  # ---- the job's state, asked of its owner ----------------------------------
  # There is no identity to resolve any more. Both backends address their job by an id issued by
  # the process that owns it, so "is it still running" and "may I cancel it" are the same question
  # asked of the same authority — not two different fields read out of a file, one of which was
  # proved and the other of which was signalled (cycles 2-5).
  ALIVE=1; IDENT_NOTE=""; IDENT_STATE=0
  if [ "$BACKEND" = ccr ]; then
    JOB_ID="$JOB"; CCR_SESSION=$(exec 9>&-; detached_field session)
    ATTEMPT_JSON=$(exec 9>&-; python3 "$CCR_HELPER" verify-attempt "$PREFIX" "$JOB_ID") || exit 6
    RESUME_SESSION=$(exec 9>&-; ccr_job_field "$ATTEMPT_JSON" requested_resume_session)
    if [ -n "$RESUME_SESSION" ]; then MODE=--resume-session; else MODE=--fresh; fi
    JOB_JSON=$(exec 9>&-; ccr_job_json "$JOB_ID")
    case "$(exec 9>&-; ccr_job_state "$JOB_JSON")" in
      running) ALIVE=1;;
      ended)   ALIVE=0; IDENT_NOTE="ccr reports job $JOB_ID as $(exec 9>&-; ccr_job_field "$JOB_JSON" status); there is nothing left to cancel";;
      *)       ALIVE=0; IDENT_NOTE="ccr could not be asked about job $JOB_ID; nothing will be requested and the attempt stays open";;
    esac
    [ -z "$IDENT_NOTE" ] || echo "$(exec 9>&-; elapsed)s JOB-STATE: $IDENT_NOTE" >> "$PREFIX.progress"
  fi

  if [ "$CANCEL_ONLY" = 1 ]; then
    if [ "$BACKEND" = codex ]; then
      CODEX_ROOT=$(exec 9>&-; codex_root); [ -n "$CODEX_ROOT" ] || die4 "--attach --cancel: cannot locate the codex plugin"
      node "$CODEX_ROOT/scripts/codex-companion.mjs" cancel "$JOB" >>"$PREFIX.stderr" 2>&1 || true
      echo "codex-run.sh: cancel requested for job $JOB"
    elif [ "$ALIVE" = 1 ]; then
      # A request to the owner, by job id. Nothing is signalled, no pid is derived and no process
      # group is named, so there is no target this runner could get wrong.
      ccr_job_cancel "$JOB_ID" >>"$PREFIX.stderr" 2>&1 || true
      CWAIT=0; while [ "$CWAIT" -lt 30 ]; do JOB_JSON=$(exec 9>&-; ccr_job_json "$JOB_ID"); [ "$(exec 9>&-; ccr_job_state "$JOB_JSON")" = running ] || break; sleep 1 9>&-; CWAIT=$((CWAIT+1)); done
      if [ "$(exec 9>&-; ccr_job_state "$JOB_JSON")" = ended ]; then
        echo "codex-run.sh: cancelled job $JOB_ID (cleanup coverage=$(exec 9>&-; ccr_job_field "$JOB_JSON" cleanup.coverage) survivors=$(exec 9>&-; ccr_job_field "$JOB_JSON" cleanup.survivors))"
      else
        echo "codex-run.sh: cancellation of job $JOB_ID not confirmed; check: ccr status $JOB_ID --json" >&2
      fi
    else
      echo "codex-run.sh: nothing to cancel — $IDENT_NOTE"
    fi
    # A cancel ENDS the job; it does not CLOSE the attempt. .detached is still here and .exit is
    # still absent, so every gate still reports this phase in flight and `release` still refuses.
    # Exit 0 alone reads as "recovery finished", which it is not (cycle 3: CL-09).
    echo "codex-run.sh: the attempt is still open — .detached remains and no .exit was written. Attach once more to publish the outcome and free the claim:"
    echo "  ${ATTACH_CMD:-$(exec 9>&-; bound_attach_command "$JOB" "$STALL_MIN" "$MAX_MIN" "$POLL")}"
    exit 0
  fi
fi

# =============================================================================================
# ccr backend
# =============================================================================================
if [ "$BACKEND" = ccr ]; then
  DIR=$(exec 9>&-; dirname "$PREFIX")
 if [ "$ATTACH" = 1 ]; then
  # Attaching: the launch already happened. Take the identifiers from the detached record, keep
  # the launch's own command line for .meta, and go straight to the watch loop.
  CMD=$(exec 9>&-; awk -F= '$1=="command"{sub(/^[^=]*=/,""); print; exit}' "$PREFIX.meta" 2>/dev/null)
  [ -n "$CMD" ] || CMD=$(exec 9>&-; detached_field command)
  SESSION=""; PROMPT_FILE=$(exec 9>&-; detached_field prompt_file)
  CLAUDE_MODEL=$(exec 9>&-; detached_field claude_model_id)
  PROVIDER=$(exec 9>&-; detached_field provider); PROVIDER_MODEL=$(exec 9>&-; detached_field provider_model)
  COMPAT=$(exec 9>&-; detached_field compatibility); CCR_VER=$(exec 9>&-; detached_field ccr_version)
  # The job id is the whole handle. An attach re-asks CCR about it; it inherits no pid, no pgid
  # and no start-time identity, because it needs none of them to observe or to cancel.
  JOB_ID=$(exec 9>&-; detached_field job); CCR_SESSION=$(exec 9>&-; detached_field session)
  [ -n "$JOB_ID" ] || die4 "--attach: $PREFIX.detached records no job= for the ccr backend; this record predates the CCR job API and cannot be attached to"
  # The launch's turn budget, not this collector's default: `error_max_turns` in a result event is
  # only interpretable against the budget the run actually used (cycle 3: CL-11).
  MAX_TURNS=$(exec 9>&-; detached_field max_turns); MAX_TURNS=${MAX_TURNS:-$CCR_MAX_TURNS_DEFAULT}
  # Control and expected model come from the admitted attempt, not current configuration.
 else
  CMD="ccr launch --model $ALIAS --permission-mode plan -p ... --max-turns $MAX_TURNS $MODE${RESUME_SESSION:+ $RESUME_SESSION} --prompt-file $PROMPT_FILE"
  ccr_preflight "$ALIAS" || launch_error "$REASON" "$CMD"
  ccr_smoke_check "$DIR" "$ALIAS" || launch_error "$REASON" "$CMD"
  SESSION=""
  if [ "$MODE" = "--resume-session" ]; then SESSION="$RESUME_SESSION"; fi
  ccr_launch_argv "$ALIAS" "$MAX_TURNS" "$PROMPT_FILE"
  if [ -n "$SESSION" ]; then ARGV+=("--resume=$SESSION" "--expected-parent-job=$EXPECTED_PARENT"); fi
  stamp_claim; rotate_previous_attempt
  # WRITTEN BEFORE ANYTHING CAN BE SUBMITTED, and this ordering is the whole point of the file.
  # `admit` below persists <prefix>.ccr-attempt.json (fsync + atomic replace) strictly before it
  # spawns the process that submits to CCR, so a prefix that has this marker at the current
  # protocol and NO attempt record is proof that no workload was ever submitted — not a guess.
  # phase-gate.sh reads exactly that to release an interrupted pre-admission prefix instead of
  # wedging it forever. A prefix without the marker is a legacy attempt or externally damaged
  # state, is NOT provably pre-submission, and is still refused.
  printf 'protocol=%s\nstage=pre-admission\nbackend=ccr\n' "$CCR_PROTOCOL" > "$PREFIX.ccr-prelaunch.part" && mv "$PREFIX.ccr-prelaunch.part" "$PREFIX.ccr-prelaunch"
  : > "$PREFIX.progress"; : > "$PREFIX.stderr"; : > "$PREFIX.joblog"
  note_prelaunch_proof
  ADMISSION_WAIT=$(( MAX_MIN*60 - $(exec 9>&-; elapsed) ))
  [ "$ADMISSION_WAIT" -gt 0 ] || ADMISSION_WAIT=1
  [ "$ADMISSION_WAIT" -le 30 ] || ADMISSION_WAIT=30
  RECEIPT_JSON=$(exec python3 "$CCR_HELPER" admit "$PREFIX" "$ALIAS" "$CLAUDE_MODEL" "$MAX_TURNS" "$CCR_RUNNER" "$MODEL_JSON" "$CCR_VER" "$ADMISSION_WAIT" "$STALL_MIN" "$MAX_MIN" "$POLL" "${ARGV[@]}")
  LRC=$?
  if [ "$LRC" != 0 ]; then
    echo "$(exec 9>&-; elapsed)s ADMISSION-UNKNOWN: retain claim; no terminal outcome; never automatically resubmit" >> "$PREFIX.progress"
    unlock_claim
    exit 6
  fi
  JOB_ID=$(exec 9>&-; ccr_job_field "$RECEIPT_JSON" job_id)
  CCR_SESSION=$(exec 9>&-; ccr_job_field "$RECEIPT_JSON" session_id)
  # Keep the collector lock through this watch. A dead collector can be reclaimed; a live one cannot.
  echo "$(exec 9>&-; elapsed)s launched backend=ccr job=$JOB_ID session=$CCR_SESSION alias=$ALIAS" >> "$PREFIX.progress"
 fi
 # CCR writes the job's stream-json to its own job directory. The runner mirrors it to
 # <prefix>.joblog on every poll so that every existing consumer — stream_field, the stall
 # detector, the phase gates — keeps reading the sidecar it always read.
 JOB_JSON=$(exec 9>&-; ccr_job_json "$JOB_ID"); JOB_LOG=$(exec 9>&-; ccr_job_field "$JOB_JSON" log)
 mirror_joblog() { python3 "$CCR_HELPER" mirror "$PREFIX" "$JOB_ID" >/dev/null 2>&1 || true; }
 mirror_joblog

  OUTCOME=""; LAST_ACTIVITY=$(exec 9>&-; now); PREV_SIG=""; IDLE=0
  while :; do
    sleep "$POLL" 9>&-
    JOB_JSON=$(exec 9>&-; ccr_job_json "$JOB_ID")
    [ -z "$(exec 9>&-; ccr_job_field "$JOB_JSON" log)" ] || JOB_LOG=$(exec 9>&-; ccr_job_field "$JOB_JSON" log)
    mirror_joblog
    SIG=$(exec 9>&-; fsig "$JOB_LOG"); LASTLINE=$(exec 9>&-; tail -n 1 "$PREFIX.joblog" 2>/dev/null | cut -c1-140)
    if [ "$SIG" != "$PREV_SIG" ]; then LAST_ACTIVITY=$(exec 9>&-; now); PREV_SIG="$SIG"; fi
    IDLE=$(( $(exec 9>&-; now) - LAST_ACTIVITY ))
    # One question, one authority, and the same answer on both paths: a launcher and an attach are
    # equally not the job's parent now, so both simply ask CCR. The three cycles of defects this
    # replaces all came from inferring the answer — a pid that might be reused, a process group
    # that might be unreadable, a supervisor whose death said nothing about its child.
    case "$(exec 9>&-; ccr_job_state "$JOB_JSON")" in
      running) STATUS=running; ALIVE=1;;
      ended)   STATUS=exited; ALIVE=0;;
      *)       # CCR could not be asked, or answered something this version does not know. That is
               # not evidence the job ended: stay in flight and let the watch bound detach.
               STATUS=running; ALIVE=0
               IDENT_NOTE="ccr status for job $JOB_ID is unreadable or unrecognised (got '$(exec 9>&-; ccr_job_field "$JOB_JSON" status)'); not concluding the job ended";;
    esac
    echo "$(exec 9>&-; elapsed)s status=$STATUS idle=${IDLE}s | $LASTLINE" >> "$PREFIX.progress"
    [ "$STATUS" = running ] || { OUTCOME=EXITED; break; }
    if [ "$IDLE" -ge $(( STALL_MIN * 60 )) ]; then OUTCOME=STALLED; break; fi
    # The watch bound is the watcher's own and says nothing about the job, so it detaches
    # instead of killing: the supervisor keeps the child, and an --attach resumes the watch.
    if [ "$(exec 9>&-; elapsed)" -ge $(( MAX_MIN * 60 )) ]; then OUTCOME=DETACHED; break; fi
  done
  if [ "$OUTCOME" = DETACHED ]; then
    # Admission committed these fields before watching. Never reopen a caller's
    # prompt here: it may have changed or disappeared while the job was running.
    D_MODEL=$(exec 9>&-; detached_field claude_model_id); D_SHA=$(exec 9>&-; detached_field prompt_sha256); D_TURNS=$(exec 9>&-; detached_field max_turns)
    D_AT=$(exec 9>&-; detached_field detached_at); D_JOBLOG="${JOB_LOG:-}"
    [ -n "$D_AT" ] || D_AT=$(exec 9>&-; date -u +%Y-%m-%dT%H:%M:%SZ)
    # Same rule as the codex branch at the bottom of this file: on an attach the attach command was
    # regenerated and bound when this attach was admitted, and that value is kept. Reading the record
    # back republishes whatever it holds — an unbound command from a pre-binding record, or the empty
    # one a record carries when its bounds were never recorded (cycle 11: F-01/F-08).
    [ "$ATTACH" = 1 ] || ATTACH_CMD=$(exec 9>&-; detached_field attach_command)
    CANCEL_CMD=$(exec 9>&-; detached_field cancel_command)
    # An empty attach command is published together with the reason it is empty, or the republished
    # record stops explaining its own empty field (cycle 12: F-09). A record that HAS a command
    # carries no guidance, so the field is written empty and reads as absent.
    D_GUIDE=""; [ -n "$ATTACH_CMD" ] || D_GUIDE=$(exec 9>&-; detached_field attach_guidance)
    echo "$(exec 9>&-; elapsed)s DETACHED → watch bound reached with the job still running; nothing signalled (job $JOB_ID left running under its owner)" >> "$PREFIX.progress"
    # ORDER MATTERS: .detached is what admits an --attach, so it is written LAST, after every other
    # sidecar this attempt owns. Publishing it first opened a window in which an attach could be
    # admitted, collect the job and write .exit, and then have this block's .meta land on top of
    # the terminal record with outcome=DETACHED (cycle 3: CX-07).
    {
      echo "outcome=DETACHED"; echo "backend=ccr"; echo "alias=$ALIAS"; echo "detached=yes"; echo "attached=${ATTEMPTS:-0}"
      echo "job=$JOB_ID"; echo "session=$CCR_SESSION"; echo "thread=$(exec 9>&-; stream_field "$PREFIX.joblog" init-session)"
      echo "elapsed_sec=$(exec 9>&-; elapsed)"; echo "idle_at_end_sec=$IDLE"; echo "stall_min=$STALL_MIN max_min=$MAX_MIN"; echo "max_turns=$MAX_TURNS"
      echo "mode=$MODE"; echo "prompt_file=$PROMPT_FILE"; echo "command=$CMD"
      echo "attach_command=$ATTACH_CMD"; echo "cancel_command=$CANCEL_CMD"
    } > "$PREFIX.meta"
    write_detached <<EOD
backend=ccr
alias=$ALIAS
claude_model_id=$D_MODEL
provider=$PROVIDER
provider_model=$PROVIDER_MODEL
compatibility=$COMPAT
ccr_version=$CCR_VER
command=$CMD
job=$JOB_ID
session=$CCR_SESSION
joblog=$D_JOBLOG
mode=$MODE
max_turns=$D_TURNS
prompt_sha256=$D_SHA
prompt_file=$PROMPT_FILE
detached_at=$D_AT
attach_command=$ATTACH_CMD
attach_guidance=$D_GUIDE
cancel_command=$CANCEL_CMD
EOD
    # NO .exit: an existing .exit tells every review gate the attempt finished, and it would then
    # rotate the claim and authorize a second launch against this still-running job.
    echo "codex-run.sh: DETACHED backend=ccr alias=$ALIAS job=$JOB_ID elapsed=$(exec 9>&-; elapsed)s — the job is still running."
    echo "  attach: $(exec 9>&-; attach_line "$ATTACH_CMD")"
    echo "  cancel: $CANCEL_CMD"
    exit 6
  fi
  UNCONFIRMED_CANCEL=0
  if [ "$OUTCOME" = STALLED ] && [ "${ALIVE:-1}" != 1 ]; then
    # The stall bound elapsed on an attach that has already logged that the recorded identity is
    # unresolved — the pid is unreadable, or it now names a different execution. The one rule
    # identity IS authoritative for is that nothing may be signalled unless the number still names
    # our execution, and TERM/KILLing the recorded group here would break it against a process we
    # have no reason to believe is ours (cycle 2: CL-01, CX-01). Nothing is signalled and nothing
    # terminal is published: the attempt stays in flight and the recovery is another attach.
    # The stall bound elapsed while CCR could not be asked about the job. Cancelling now would be
    # a request about a job whose state we cannot read; nothing is requested and nothing terminal
    # is published. The attempt stays in flight and the recovery is another attach.
    OUTCOME=DETACHED
    REDETACH_REASON="stall bound reached but ccr could not be asked about job $JOB_ID; no cancellation requested"
    echo "$(exec 9>&-; elapsed)s STALLED → job state unreadable; not requesting cancellation of $JOB_ID — re-detaching instead" >> "$PREFIX.progress"
  elif [ "$OUTCOME" = STALLED ]; then
    # Cancellation is a REQUEST TO THE OWNER, by job id. This runner sends no signal, derives no
    # pid and names no process group; CCR decides what to terminate and reports what it observed.
    ccr_job_cancel "$JOB_ID" >/dev/null 2>>"$PREFIX.stderr" || true
    CWAIT=0
    while [ "$CWAIT" -lt 30 ]; do
      JOB_JSON=$(exec 9>&-; ccr_job_json "$JOB_ID")
      [ "$(exec 9>&-; ccr_job_state "$JOB_JSON")" = running ] || break
      sleep 1 9>&-; CWAIT=$((CWAIT+1))
    done
    CLEAN_COV=$(exec 9>&-; ccr_job_field "$JOB_JSON" cleanup.coverage)
    CLEAN_SURV=$(exec 9>&-; ccr_job_field "$JOB_JSON" cleanup.survivors)
    if [ "$(exec 9>&-; ccr_job_state "$JOB_JSON")" = ended ]; then
      echo "$(exec 9>&-; elapsed)s $OUTCOME → job $JOB_ID cancelled by its owner (cleanup coverage=${CLEAN_COV:-unknown} survivors=${CLEAN_SURV:-[]})" >> "$PREFIX.progress"
    else
      # CCR did not report the job terminal within the bound. That is exactly the "could not
      # determine" case: it is never reported as a completed cancel.
      UNCONFIRMED_CANCEL=1
      echo "$(exec 9>&-; elapsed)s $OUTCOME → cancellation of job $JOB_ID NOT confirmed; it may still be running" >> "$PREFIX.progress"
      echo "codex-run.sh: cancellation of job $JOB_ID not confirmed; DO NOT retry — check with: ccr status $JOB_ID --json" >&2
    fi
  fi
  # The exit status comes from the job's OWNER, on both paths. A launcher is no more the job's
  # parent than an attach is, so neither wait()s for anything: CCR reaped the workload and records
  # what it reaped. This keeps the success predicate's exit-status condition without a receipt
  # protocol of our own, and it is the same answer whichever process asks.
  JOB_JSON=$(exec 9>&-; ccr_job_json "$JOB_ID")
  CHILD_RC=$(exec 9>&-; ccr_job_field "$JOB_JSON" exit_code)
  JOB_STATE=$(exec 9>&-; ccr_job_state "$JOB_JSON")
  CLEAN_COV=$(exec 9>&-; ccr_job_field "$JOB_JSON" cleanup.coverage); CLEAN_COV=${CLEAN_COV:-unknown}
  CLEAN_SURV=$(exec 9>&-; ccr_job_field "$JOB_JSON" cleanup.survivors); CLEAN_SURV=${CLEAN_SURV:-[]}
  CLEAN_REASON=$(exec 9>&-; ccr_job_field "$JOB_JSON" cleanup.reason)
  if [ "$JOB_STATE" != ended ]; then
    # Not provably over. Publishing a terminal outcome here would delete .detached, free the claim
    # and let a second job be launched against the one still running.
    OUTCOME=DETACHED
    echo "$(exec 9>&-; elapsed)s ccr does not report job $JOB_ID as ended (status '$(exec 9>&-; ccr_job_field "$JOB_JSON" status)'); the attempt has not ended — re-detaching rather than publishing a terminal outcome" >> "$PREFIX.progress"
    # A more specific reason already set upstream (an unconfirmed cancel) is the one to keep.
    REDETACH_REASON="${REDETACH_REASON:-ccr does not report job $JOB_ID as ended}"
  fi
  # A collector that cannot prove the attempt ended publishes nothing terminal. It refreshes the
  # detached record and leaves with exit 6, so .exit stays absent, the claim stays closed, and the
  # documented recovery is still an attach.
  if [ "$OUTCOME" = DETACHED ]; then
    ATTEMPTS=${ATTEMPTS:-0}
    [ "$ATTACH" = 1 ] || ATTACH_CMD=$(exec 9>&-; detached_field attach_command)  # see above: bound at admission
    CANCEL_CMD=$(exec 9>&-; detached_field cancel_command)
    echo "$(exec 9>&-; elapsed)s DETACHED (re-detached): $REDETACH_REASON" >> "$PREFIX.progress"
    {
      echo "outcome=DETACHED"; echo "backend=ccr"; echo "alias=$ALIAS"; echo "detached=yes"; echo "attached=$ATTEMPTS"
      echo "job=$JOB_ID"; echo "session=$CCR_SESSION"; echo "elapsed_sec=$(exec 9>&-; elapsed)"
      echo "stall_min=$STALL_MIN max_min=$MAX_MIN"; echo "mode=$MODE"; echo "prompt_file=$PROMPT_FILE"
      echo "command=$CMD"; echo "redetach_reason=$REDETACH_REASON"
      echo "attach_command=$ATTACH_CMD"; echo "cancel_command=$CANCEL_CMD"
    } > "$PREFIX.meta"
    publish_unlock
    echo "codex-run.sh: DETACHED backend=ccr alias=$ALIAS elapsed=$(exec 9>&-; elapsed)s — $REDETACH_REASON; the attempt is still open."
    echo "  attach: $(exec 9>&-; attach_line "$ATTACH_CMD")"
    exit 6
  fi
  [ -n "${HELD_LOCK:-}" ] || publish_lock --must
  FROZEN=$(exec python3 "$CCR_HELPER" freeze "$PREFIX" "$JOB_ID") || {
    echo "codex-run.sh: result observation unresolved; retain attempt for investigation" >&2
    exit 6
  }
  SESSION_ID=$(exec 9>&-; stream_field "$PREFIX.joblog" init-session); ROUTED_MODEL=$(exec 9>&-; stream_field "$PREFIX.joblog" init-model)
  HAS_RESULT=$(exec 9>&-; stream_field "$PREFIX.joblog" has-result)
  stream_field "$PREFIX.joblog" result-text > "$PREFIX.stdout"
  if [ "$UNCONFIRMED_CANCEL" = 1 ]; then : > "$PREFIX.stdout"; fi
  if [ "$OUTCOME" = EXITED ]; then
    # A result event that is an error (is_error, or a non-success subtype such as error_max_turns) is a
    # failed attempt even if the child exited 0 (review round 1: F-10).
    # `child_exit=unknown` (a supervisor that died before reaping, above) is not zero, so this
    # predicate closes such an attempt as FAILED without ever manufacturing a success.
    if [ "$(exec 9>&-; ccr_job_field "$FROZEN" successful)" = True ]; then OUTCOME=COMPLETED; else OUTCOME=FAILED; fi
  fi
  # The configured alias is CCR input. `CLAUDE_MODEL` is the generated model ID
  # CCR promised for it; the child independently reports `ROUTED_MODEL` at init.
  # A mismatch is a route/configuration failure, never a reason to try Claude or
  # another alias. This comparison is local metadata only — no extra ccr call.
  ROUTE_OK=unknown
  if [ "$OUTCOME" = COMPLETED ] || [ "$(exec 9>&-; ccr_job_field "$FROZEN" error_code)" = route_identity_mismatch ]; then
    # On an attach, the expected model is the one recorded at launch. Judging a finished execution
    # by whatever the alias resolves to NOW would turn an ordinary config change into UNAVAILABLE
    # for an answer that was already produced correctly.
    if [ "$ATTACH" = 1 ]; then
      WANT_MODEL=$(exec 9>&-; detached_field claude_model_id); [ -n "$WANT_MODEL" ] || WANT_MODEL="$CLAUDE_MODEL"
      CLAUDE_MODEL="$WANT_MODEL"
    fi
    if [ -z "$CLAUDE_MODEL" ] || [ -z "$ROUTED_MODEL" ] || [ "$ROUTED_MODEL" != "$CLAUDE_MODEL" ]; then
      OUTCOME=UNAVAILABLE; ROUTE_OK=no
      echo "$(exec 9>&-; elapsed)s ROUTE-UNAVAILABLE alias=$ALIAS expected_child_model=${CLAUDE_MODEL:-unknown} got_child_model=${ROUTED_MODEL:-unknown}" >> "$PREFIX.progress"
      printf 'codex-run.sh: CCR route identity mismatch for alias %s (expected generated child model %s, got %s); do not retry with another alias or Claude\n' "$ALIAS" "${CLAUDE_MODEL:-unknown}" "${ROUTED_MODEL:-unknown}" >> "$PREFIX.stderr"
    else
      ROUTE_OK=yes
    fi
  fi
  # The attach path already holds this lock from admission; a launch takes it here.
  [ "$OUTCOME" != COMPLETED ] || [ -z "$SESSION_ID" ] || { printf '%s\n' "$SESSION_ID" > "$DIR/.ccr-last-session"; printf '%s\n' "$JOB_ID" > "$DIR/.ccr-last-job"; }
  {
    echo "outcome=$OUTCOME"; echo "backend=ccr"; echo "alias=$ALIAS"; echo "detached=no"; echo "attached=${ATTEMPTS:-0}"
    [ -z "${IDENT_NOTE:-}" ] || echo "identity_note=$IDENT_NOTE"; echo "provider=$PROVIDER"; echo "provider_model=$PROVIDER_MODEL"
    echo "claude_model_id=$CLAUDE_MODEL"; echo "routed_model=${ROUTED_MODEL:-unknown}"; echo "route_identity=$ROUTE_OK"; echo "compatibility=$COMPAT"; echo "ccr_version=$CCR_VER"
    echo "submission_id=$(exec 9>&-; ccr_job_field "$JOB_JSON" submission_id)"; echo "requested_resume_session=$(exec 9>&-; ccr_job_field "$JOB_JSON" requested_resume_session)"; echo "resumed_from=$(exec 9>&-; ccr_job_field "$JOB_JSON" resumed_from)"
    echo "workload_disposition=$(exec 9>&-; ccr_job_field "$JOB_JSON" workload_disposition)"; echo "reason_code=$(exec 9>&-; ccr_job_field "$JOB_JSON" reason_code)"
    echo "job=$JOB_ID"; echo "session=$CCR_SESSION"; echo "child_exit=$CHILD_RC"; echo "thread=${SESSION_ID:-unknown}"
    # CCR reports what it cleaned up separately from what the workload returned, and an empty
    # survivor list is NOT a claim that everything was cleaned up. Both facts are recorded here
    # verbatim: partial coverage is a real limit of the host, not a failure of this attempt, and
    # it must not be silently rounded to "clean" by anything that reads this file.
    echo "cleanup_coverage=$CLEAN_COV"; echo "cleanup_survivors=$CLEAN_SURV"
    [ -z "${CLEAN_REASON:-}" ] || echo "cleanup_reason=$CLEAN_REASON"
    echo "elapsed_sec=$(exec 9>&-; elapsed)"; echo "idle_at_end_sec=$IDLE"; echo "stall_min=$STALL_MIN max_min=$MAX_MIN"; echo "max_turns=$MAX_TURNS"
    echo "mode=$MODE"; [ "$MODE" != "--resume-session" ] || echo "resume_session=$RESUME_SESSION"; echo "prompt_file=$PROMPT_FILE"; echo "result_event=$(exec 9>&-; stream_field "$PREFIX.joblog" result-subtype)"
    echo "command=$CMD"; echo "stdout_bytes=$(exec 9>&-; wc -c < "$PREFIX.stdout" | tr -d ' ')"
  LASTERR=$(exec 9>&-; sed '/^[[:space:]]*$/d' "$PREFIX.stderr" | tail -1 | cut -c1-300)
    echo "last_error=${LAST_ERROR_OVERRIDE:-${LASTERR:-none}}"; echo "cancel_confirmed=$(exec 9>&-; [ "$UNCONFIRMED_CANCEL" = 1 ] && echo no || echo "$(exec 9>&-; [ "$OUTCOME" = STALLED ] && echo yes || echo n/a)")"
  } > "$PREFIX.meta"
  # TIMEOUT/3 is RETIRED: no path assigns OUTCOME=TIMEOUT any more — a watch bound that elapses
  # detaches (6). The arm is kept so the code that reads older sidecars, and the exit-code contract
  # a caller may already branch on, both stay valid; it is unreachable by design, not by accident.
  case "$OUTCOME" in COMPLETED) RC=0;; FAILED) RC=1;; STALLED) RC=2;; TIMEOUT) RC=3;; UNAVAILABLE) RC=4;; DETACHED) RC=6;; *) RC=1;; esac
  [ "$UNCONFIRMED_CANCEL" = 1 ] && RC=5
  # Terminal, in this order: the attempt stops being detached before it is marked finished, so no
  # gate ever sees both markers, and none sees .exit while .detached still says a job may run.
  rm -f "$PREFIX.detached"
  echo "$RC" > "$PREFIX.exit"
  publish_unlock
  echo "codex-run.sh: $OUTCOME backend=ccr alias=$ALIAS session=${SESSION_ID:-unknown} elapsed=$(exec 9>&-; elapsed)s stdout=$(exec 9>&-; wc -c < "$PREFIX.stdout" | tr -d ' ')B → $PREFIX.{stdout,progress,meta}"
  exit "$RC"
fi

# =============================================================================================
# codex backend (the Codex CLI plugin's companion)
# =============================================================================================
CODEX_ROOT=$(exec 9>&-; codex_root)
if [ -z "$CODEX_ROOT" ] || [ ! -f "$CODEX_ROOT/scripts/codex-companion.mjs" ]; then
  if [ "$ATTACH" = 1 ]; then
    # Not finding the companion says something about THIS process, not about the job it owns.
    # Publishing a terminal launch error would delete .detached and free the claim for a second
    # launch against a job that is still running (cycle 2: CX-06). Leave the attempt as found.
    echo "$(exec 9>&-; elapsed)s ATTACH: cannot locate the codex plugin; nothing was observed and the attempt stays open" >> "$PREFIX.progress"
    echo "codex-run.sh: --attach: cannot locate the codex plugin (installed_plugins.json or ~/.claude/plugins/cache/openai-codex/codex/*); job $JOB is untouched and still detached." >&2
    echo "  attach: ${ATTACH_CMD:-$(exec 9>&-; bound_attach_command "$JOB" "$STALL_MIN" "$MAX_MIN" "$POLL")}"
    exit 6
  fi
  launch_error "cannot locate the codex plugin (installed_plugins.json or ~/.claude/plugins/cache/openai-codex/codex/*)" "task $MODE --background --prompt-file $PROMPT_FILE"
fi
cc() { node "$CODEX_ROOT/scripts/codex-companion.mjs" "$@"; }
jobfield() { python3 -c "import sys,json;d=json.load(sys.stdin);j=d.get('job') or {};print(j.get('$1') or '')" 2>/dev/null; }

if [ "$ATTACH" = 1 ]; then
  # The companion is already this job's durable owner: it survived the runner that launched it and
  # answers `status` and `result` for the id in the detached record. Nothing to launch, nothing to
  # claim — pick the watch back up where it stopped.
  CMD=$(exec 9>&-; awk -F= '$1=="command"{sub(/^[^=]*=/,""); print; exit}' "$PREFIX.meta" 2>/dev/null)
  PROMPT_FILE=$(exec 9>&-; awk -F= '$1=="prompt_file"{sub(/^[^=]*=/,""); print; exit}' "$PREFIX.meta" 2>/dev/null)
  echo "$(exec 9>&-; elapsed)s attached job=$JOB" >> "$PREFIX.progress"
else
# Keep collector ownership through admission, observation, and every publication.
# A completed companion job does not mean this collector has finished writing.
stamp_claim; rotate_previous_attempt
: > "$PREFIX.progress"; : > "$PREFIX.stderr"
note_prelaunch_proof
CMD="task $MODE --background --prompt-file $PROMPT_FILE"
LAUNCH=$(cc task "$MODE" --background --prompt-file "$PROMPT_FILE" 2>>"$PREFIX.stderr") || true
JOB=$(exec 9>&-; printf '%s' "$LAUNCH" | grep -oE 'task-[a-z0-9]+-[a-z0-9]+' | head -1)
if [ -z "$JOB" ]; then
  printf 'LAUNCH-ERROR\n%s\n' "$LAUNCH" >> "$PREFIX.stderr"
  printf 'outcome=LAUNCH-ERROR\nbackend=codex\nmode=%s\ncommand=%s\n' "$MODE" "$CMD" > "$PREFIX.meta"; echo 4 > "$PREFIX.exit"
  echo "codex-run.sh: LAUNCH-ERROR (see $PREFIX.stderr)"; exit 4
fi
echo "$(exec 9>&-; elapsed)s launched job=$JOB" >> "$PREFIX.progress"
fi

OUTCOME=""; LOGFILE=""; LAST_ACTIVITY=$(exec 9>&-; now); PREV_SIG=""
while :; do
  sleep "$POLL" 9>&-
  SJ=$(exec 9>&-; cc status "$JOB" --json 2>/dev/null || true)
  STATUS=$(exec 9>&-; printf '%s' "$SJ" | jobfield status); PID=$(exec 9>&-; printf '%s' "$SJ" | jobfield pid)
  [ -z "$LOGFILE" ] && LOGFILE=$(exec 9>&-; printf '%s' "$SJ" | jobfield logFile)
  LASTLINE=""; SIG=""
  if [ -n "$LOGFILE" ] && [ -r "$LOGFILE" ]; then
    LASTLINE=$(exec 9>&-; tail -n 1 "$LOGFILE" 2>/dev/null | cut -c1-140)
    SIG=$(exec 9>&-; fsig "$LOGFILE")
  fi
  if [ "$SIG" != "$PREV_SIG" ]; then LAST_ACTIVITY=$(exec 9>&-; now); PREV_SIG="$SIG"; fi
  IDLE=$(( $(exec 9>&-; now) - LAST_ACTIVITY ))
  echo "$(exec 9>&-; elapsed)s status=${STATUS:-?} idle=${IDLE}s | $LASTLINE" >> "$PREFIX.progress"

  case "$STATUS" in
    completed) OUTCOME=COMPLETED; break;;
    failed|cancelled|canceled) OUTCOME=FAILED; break;;
    running|queued|"")
      # dead worker: status says running but no task-worker process carries this job id
      if [ "$STATUS" = "running" ] && ! pgrep -f "task-worker.*--job-id $JOB" >/dev/null 2>&1; then
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then :; else
          # give the plugin one poll to flip the status itself
          sleep "$POLL" 9>&-; ST2=$(exec 9>&-; cc status "$JOB" --json 2>/dev/null | jobfield status)
          case "$ST2" in completed) OUTCOME=COMPLETED; break;; failed|cancelled|canceled) OUTCOME=FAILED; break;; esac
          echo "$(exec 9>&-; elapsed)s WORKER-DEAD (status=$ST2, no task-worker process)" >> "$PREFIX.progress"; OUTCOME=FAILED; break
        fi
      fi
      if [ "$IDLE" -ge $(( STALL_MIN * 60 )) ]; then OUTCOME=STALLED; break; fi
      # As on the ccr backend: the bound is the watcher's, not the job's. The companion keeps
      # the job — it is already the durable owner — so detaching costs nothing and loses nothing.
      if [ "$(exec 9>&-; elapsed)" -ge $(( MAX_MIN * 60 )) ]; then OUTCOME=DETACHED; break; fi;;
    *) echo "$(exec 9>&-; elapsed)s unknown status '$STATUS'" >> "$PREFIX.progress";;
  esac
done

if [ "$OUTCOME" = "DETACHED" ]; then
  # The same rule as the ccr branch: on an attach every field below belongs to the LAUNCH and is
  # copied forward, never re-derived. PROMPT_FILE on an attach comes from .meta and may since have
  # been deleted, in which case re-deriving would replace the launch's prompt pin with an empty
  # one — the record would stop being the launch's own testimony (cycle 3: CL-07).
  if [ "$ATTACH" = 1 ]; then
    D_THREAD=$(exec 9>&-; detached_field thread); D_SHA=$(exec 9>&-; detached_field prompt_sha256); D_AT=$(exec 9>&-; detached_field detached_at)
    D_JOBLOG=$(exec 9>&-; detached_field joblog); D_WPID=$(exec 9>&-; detached_field worker_pid); D_WIDENT=$(exec 9>&-; detached_field worker_identity)
    # The attach command is the exception to "copy, never re-derive": it is not the launch's
    # testimony, it is the next operator's instruction, and an unbound one inherited from a
    # pre-binding record is an instruction the admission block now refuses (cycle 8: CX-01). It was
    # already regenerated when this attach was admitted; keep that value rather than reading the
    # record back. The cancel command names the job directly and needs no rebinding.
    CANCEL_CMD=$(exec 9>&-; detached_field cancel_command)
  else
    D_THREAD=$(exec 9>&-; grep -oE 'Codex session ID: [0-9a-f-]+' "${LOGFILE:-/dev/null}" 2>/dev/null | head -1 | awk '{print $4}')
    D_SHA=$(exec 9>&-; prompt_digest "$PROMPT_FILE"); D_AT=$(exec 9>&-; date -u +%Y-%m-%dT%H:%M:%SZ); D_JOBLOG="${LOGFILE:-}"
    # The worker pid the companion reports, with its identity, so a later launch can PROVE this
    # job is still running rather than assume it (cycle 3: CL-03/CX-02). The companion remains the
    # authority; this is the cheap local check, and `job=` is what a relaunch consults.
    D_WPID="${PID:-}"; D_WIDENT=$(exec 9>&-; proc_identity "${PID:-0}")
    # --expected-job binds this command to THIS job. Without it the command names only a prefix,
    # which a later attempt may legitimately occupy (see the attach admission block above).
    ATTACH_CMD=$(exec 9>&-; bound_attach_command "$JOB" "$STALL_MIN" "$MAX_MIN" "$POLL")
    CANCEL_CMD=$(exec 9>&-; quote_command node "$CODEX_ROOT/scripts/codex-companion.mjs" cancel "$JOB")
  fi
  # See the gateway branch: an empty command travels with the reason it is empty (cycle 12: F-09).
  D_GUIDE=""; [ -n "$ATTACH_CMD" ] || D_GUIDE=$(exec 9>&-; detached_field attach_guidance)
  echo "$(exec 9>&-; elapsed)s DETACHED → watch bound reached with job $JOB still running; not cancelled" >> "$PREFIX.progress"
  {
    echo "outcome=DETACHED"; echo "backend=codex"; echo "job=$JOB"; echo "detached=yes"; echo "attached=${ATTEMPTS:-0}"
    echo "elapsed_sec=$(exec 9>&-; elapsed)"; echo "idle_at_end_sec=$IDLE"; echo "stall_min=$STALL_MIN max_min=$MAX_MIN"
    echo "mode=$MODE"; echo "prompt_file=$PROMPT_FILE"; echo "command=$CMD"
    echo "attach_command=$ATTACH_CMD"; echo "cancel_command=$CANCEL_CMD"
  } > "$PREFIX.meta"
  # .detached LAST — it is what admits an --attach, so no attach may be admitted while this block
  # still has sidecar writes outstanding (cycle 3: CX-07).
  write_detached <<EOD
backend=codex
job=$JOB
thread=$D_THREAD
joblog=$D_JOBLOG
worker_pid=$D_WPID
worker_identity=$D_WIDENT
mode=$MODE
prompt_sha256=$D_SHA
prompt_file=$PROMPT_FILE
detached_at=$D_AT
attach_command=$ATTACH_CMD
attach_guidance=$D_GUIDE
cancel_command=$CANCEL_CMD
EOD
  # NO .exit — see the ccr branch: a terminal sidecar would free the claim for a second launch.
  echo "codex-run.sh: DETACHED backend=codex job=$JOB elapsed=$(exec 9>&-; elapsed)s — the job is still running."
  echo "  attach: $ATTACH_CMD"
  echo "  cancel: $CANCEL_CMD"
  exit 6
fi
UNCONFIRMED_CANCEL=0
if [ "$OUTCOME" = "STALLED" ] || { [ "$OUTCOME" = "FAILED" ] && [ "${STATUS:-}" = "running" ]; }; then
  CANCEL_RC=0; cc cancel "$JOB" >>"$PREFIX.stderr" 2>&1 || CANCEL_RC=$?
  # Verify the cancel instead of asserting it: re-read status and look for a live
  # worker. Report honestly if either still says running — a claimed cancel that
  # did not happen is worse than a reported one that failed.
  PHANTOM=""; i=0
  while [ $i -lt 5 ]; do
    sleep 1 9>&-; i=$((i+1))
    ST3=$(exec 9>&-; cc status "$JOB" --json 2>/dev/null | jobfield status)
    case "$ST3" in cancelled|canceled|completed|failed) PHANTOM=""; break;; *) PHANTOM="status=$ST3";; esac
  done
  if pgrep -f "task-worker.*--job-id $JOB" >/dev/null 2>&1; then PHANTOM="${PHANTOM:+$PHANTOM }worker-process-alive"; fi
  if [ -n "$PHANTOM" ]; then
    # Exit 5, not the outcome's own code: a live worker must never be retried,
    # and 1/2/3 all tell the caller to retry or to treat the job as finished.
    UNCONFIRMED_CANCEL=1
    echo "$(exec 9>&-; elapsed)s $OUTCOME → cancel of $JOB NOT confirmed (cancel_rc=$CANCEL_RC $PHANTOM); a worker may still be running" >> "$PREFIX.progress"
    echo "codex-run.sh: cancel of $JOB not confirmed ($PHANTOM); DO NOT retry — a worker may still be running. Check with: node <codex-plugin>/scripts/codex-companion.mjs status $JOB --json" >&2
  else
    echo "$(exec 9>&-; elapsed)s $OUTCOME → cancelled $JOB (confirmed: no running job, no worker process)" >> "$PREFIX.progress"
  fi
fi
# An unconfirmed cancel has no final result eligible for a downstream gate. The
# raw job log is still preserved; do not let a late `result` look completed.
if [ "${UNCONFIRMED_CANCEL:-0}" = "1" ]; then : > "$PREFIX.stdout"
else cc result "$JOB" > "$PREFIX.stdout" 2>>"$PREFIX.stderr" || true
fi
[ -n "$LOGFILE" ] && [ -r "$LOGFILE" ] && cp "$LOGFILE" "$PREFIX.joblog" 2>/dev/null
THREAD=$(exec 9>&-; grep -oE 'Codex session ID: [0-9a-f-]+' "$PREFIX.stdout" | head -1 | awk '{print $4}')
# A resumed run must land in the thread it named. The companion offers no way to ask for a thread
# by id — --resume-last takes the newest eligible one — so the binding can only be checked after
# the fact, and a mismatch is reported rather than accepted: continuing someone else's thread is
# worse than starting a fresh, self-contained round.
THREAD_NOTE=""
if [ "$MODE" = "--resume-last" ] && [ "$OUTCOME" = COMPLETED ] && [ -n "$THREAD" ]; then
  WANT=$(exec 9>&-; awk -F= '$1=="thread"{print $2; exit}' "$PREFIX.detached" 2>/dev/null)
  [ -n "$WANT" ] || WANT=$(exec 9>&-; detached_field thread)
  if [ -n "$WANT" ] && [ "$WANT" != unknown ] && [ "$WANT" != "$THREAD" ]; then
    OUTCOME=FAILED
    THREAD_NOTE="resumed thread $THREAD is not the expected $WANT; the continuation is not this attempt's, so it is refused"
    echo "codex-run.sh: $THREAD_NOTE" >> "$PREFIX.stderr"
  fi
fi
{
  echo "outcome=$OUTCOME"; echo "backend=codex"; echo "job=$JOB"; echo "thread=${THREAD:-unknown}"
  echo "detached=no"; echo "attached=${ATTEMPTS:-0}"; [ -z "$THREAD_NOTE" ] || echo "thread_note=$THREAD_NOTE"
  echo "elapsed_sec=$(exec 9>&-; elapsed)"; echo "idle_at_end_sec=$IDLE"; echo "stall_min=$STALL_MIN max_min=$MAX_MIN"
  echo "mode=$MODE"; echo "prompt_file=$PROMPT_FILE"; echo "command=$CMD"; echo "stdout_bytes=$(exec 9>&-; wc -c < "$PREFIX.stdout" | tr -d ' ')"
  LASTERR=""; [ -n "$LOGFILE" ] && [ -r "$LOGFILE" ] && LASTERR=$(exec 9>&-; grep -E "Codex error:|Turn failed" "$LOGFILE" | tail -1 | cut -c1-300)
  echo "last_error=${LASTERR:-none}"; echo "cancel_confirmed=$(exec 9>&-; [ "${UNCONFIRMED_CANCEL:-0}" = "1" ] && echo no || echo "$(exec 9>&-; [ "$OUTCOME" = "STALLED" ] && echo yes || echo n/a)")"
} > "$PREFIX.meta"
# TIMEOUT/3 is RETIRED here too — see the ccr branch.
case "$OUTCOME" in COMPLETED) RC=0;; FAILED) RC=1;; STALLED) RC=2;; TIMEOUT) RC=3;; DETACHED) RC=6;; *) RC=1;; esac
# An unconfirmed cancel outranks the outcome: 1, 2 and 3 all invite a retry or
# treat the job as finished, and neither is safe while a worker may be alive.
[ "${UNCONFIRMED_CANCEL:-0}" = "1" ] && RC=5
rm -f "$PREFIX.detached"
echo "$RC" > "$PREFIX.exit"
publish_unlock
echo "codex-run.sh: $OUTCOME job=$JOB elapsed=$(exec 9>&-; elapsed)s stdout=$(exec 9>&-; wc -c < "$PREFIX.stdout" | tr -d ' ')B → $PREFIX.{stdout,progress,meta}"
exit "$RC"
