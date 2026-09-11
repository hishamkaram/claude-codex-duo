#!/bin/bash
# codex-run.sh — run one read-only second-model task in the background, monitor it, return its result.
#
# Usage:
#   codex-run.sh <out-prefix> [--via codex|ccr:<alias>] [--fresh|--resume-last|--resume-session <id>] --prompt-file <file>
#                [--stall-min N] [--max-min M] [--poll-sec S] [--claim <token>]
#                [--max-turns N]                                  (--max-turns and --resume-session: ccr backend only)
#   codex-run.sh <out-prefix> --attach [--stall-min N] [--max-min M] [--poll-sec S]
#   codex-run.sh --probe [--via ccr:<alias> [--record-dir <dir>]]
#
#   --attach: resume the WATCH on a job this process did not launch, after a previous
#   invocation detached from it (exit 6). It is an operation, not a launch mode: no prompt is
#   submitted, no claim is taken, no launch budget is spent, no sidecar is rotated, and `mode=`
#   in .meta keeps the original launch mode so the review gates' thread anchoring is unchanged.
#   It requires <out-prefix>.detached with no <out-prefix>.exit; anything else is exit 4.
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
#   <out-prefix>.childexit  ccr only: the supervisor's receipt, `child_exit=<rc>`, published
#                           atomically when the child is reaped. An attaching process is not the
#                           child's parent and cannot wait() for it, so the success predicate
#                           (child exit 0 AND a successful result event) reads the receipt.
#   Exit 4 with NO sidecar written: another runner already took <out-prefix>.claim/, or (--claim)
#   no claim exists / the arguments are invalid.
#   ccr backend also writes <dir>/.ccr-last-session (the session id --resume-last resumes).
#
# Safety: refuses --write. Cancels the job on STALLED — no log activity for --stall-min is a
# determination that the job is wedged — but NOT when --max-min elapses: that bound is the
# watcher's own, and says nothing about the job. The watch then detaches (exit 6) and leaves the
# job running to be re-attached. A ccr child runs in its own process group, under a supervisor
# that owns it and publishes its exit status, so the whole tree is still signalled on a stall and
# its pgid and start time are recorded. A recorded pid or pgid is never signalled on the strength
# of the record alone: identity is proved against the live process's start time first, because a
# number recorded minutes ago may name something else entirely.
# Run it with the caller's background execution (Claude Code: run_in_background) so a foreground
# shell limit can never kill the worker mid-turn.

set -u
CCR_MIN_VERSION="0.4.11"
# These are assigned inside ccr_preflight, past its early-return failures. The attach path is
# allowed to run without a successful preflight (the child is already going), so under `set -u`
# every reader below would abort the collector mid-publication. Declare them empty up front: an
# empty value is a fact the route check already knows how to report, an unbound one is a crash.
CCR_VER=""; PROVIDER=""; PROVIDER_MODEL=""; CLAUDE_MODEL=""; COMPAT=""; TOOLS=""
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
  grep -qxF "launch_sha256=$(ccr_launch_digest)" "$f" || { REASON="ccr smoke for $2 was recorded for another launch line; re-run the probe"; return 1; }
  return 0
}
# Start a command in its own process group; echoes nothing, sets CHILD (pid) — pgid == pid.
# exec, so that when it is called as `start_in_own_group … &` the background pid IS the child (and its pgid).
start_in_own_group() { exec python3 -c 'import os,sys; os.setpgrp(); os.execvp(sys.argv[1], sys.argv[1:])' "$@"; }
# The ccr backend's durable owner. The supervisor leads the job's process group, forks the child
# that execs the gateway (inheriting the redirections the caller set up), waits for it, and
# publishes `child_exit=<rc>` atomically. It exists because an attaching process is NOT the
# child's parent and can never wait() for it: without this receipt the success predicate below
# would have to drop its exit-status condition, silently weakening a contract an earlier review
# tightened on purpose. The supervisor never signals the child; only kill_group does, on a stall.
start_supervised_group() {  # <receipt> <argv...>
  exec python3 -c '
import os, signal, subprocess, sys
os.setpgrp()                       # pgid == this pid, so the runner is auditing one number
receipt, argv = sys.argv[1], sys.argv[2:]

def publish(rc):
    tmp = receipt + ".tmp"
    try:
        with open(tmp, "w") as f:
            f.write("child_exit=%d\n" % rc); f.flush(); os.fsync(f.fileno())
        os.replace(tmp, receipt)   # atomic: an attach never reads a half-written receipt
    except OSError as e:
        sys.stderr.write("supervisor: cannot publish receipt: %s\n" % e)

try:
    child = subprocess.Popen(argv) # stdin/stdout/stderr inherited from the shell redirections
except OSError as e:
    sys.stderr.write("supervisor: cannot start child: %s\n" % e); publish(127); sys.exit(127)

# A group cancel signals every member, the supervisor included. Dying here without a receipt
# would leave the attempt permanently uncollectable: .detached would stay, the claim would stay
# closed, and every later attach would find no receipt and re-detach forever (cycle 2: CL-03,
# CX-03). So the terminating signal is caught, the child is given a bounded chance to land
# (shorter than kill_groups escalation to KILL), and a receipt is published either way.
# The supervisor OUTLIVES these signals, because its single obligation is to reap this child and
# publish what it actually returned. Two earlier attempts at this were both wrong. Dying on the
# signal published nothing, and the attempt then wedged forever: .detached kept, the claim closed,
# every attach re-detaching (cycle 2: CL-03). Catching it and writing a status after a bounded
# wait published a LIE — `Popen.wait()` called from the handler cannot acquire the reaping lock the
# main thread already holds, so it always timed out, and `child_exit=-15` was written for a child
# that was still running (cycle 3: CX-03, reproduced). Ignoring them is what is actually wanted:
# a group TERM reaches the child directly, the main wait() below returns its real status, and the
# receipt is true. SIGKILL remains uncatchable — the collector proves that case from an empty
# process group instead. This is set AFTER Popen on purpose: an ignored disposition is inherited
# across exec, and the child must stay killable by the TERM that kill_group sends.
for _s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(_s, signal.SIG_IGN)

rc = child.wait()
publish(rc)
sys.exit(rc if rc >= 0 else 128 - rc)
' "$@"
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
  local live; live=$(proc_identity "$1")
  [ -n "$live" ] || return 1
  [ "$live" = "$2" ] || return 2
  return 0
}
# The comment above says an empty `ps` may mean inspection FAILED rather than the process exited —
# and then every caller collapsed that into state 1 and acted on it. For the collector that is
# safe (it refuses either way), but the lock reclaimer read state 1 as "the holder is dead" and
# took a live collector's lock, admitting a second one (cycle 5: CX-05). This separates the two:
# process inspection is proved to WORK, by asking it about a process that certainly exists — this
# one — before an absent answer about someone else is allowed to mean absence.
identity_is_readable() {  # 0 when `ps` can identify a process we know is alive
  [ -n "$(proc_identity "$$")" ]
}
holder_is_provably_gone() {  # <pid> <recorded identity> -> 0 only on a PROVEN absence or reuse
  identity_state "$1" "$2" && return 1     # state 0: alive and ours — definitely not gone
  case $? in
    2) return 0;;                          # the number now names a different execution: ours ended
    *) identity_is_readable;;              # state 1: absence counts only if `ps` is working at all
  esac
}
pgid_of() { ps -o pgid= -p "$1" 2>/dev/null | tr -d ' '; }
# ============================================================================================
# THE ONLY GATE THROUGH WHICH THIS SCRIPT MAY SIGNAL A PROCESS GROUP
# ============================================================================================
# `kill -- "-N"` does not mean "the group N" for every N. POSIX gives two values a session-wide
# meaning, and both are catastrophic here:
#
#   N = 1  -> EVERY process the user is permitted to signal. On macOS that is the whole login
#             session: the terminal, the editor, the browser, the password manager, and
#             loginwindow itself, which then relaunches the GUI.
#   N = 0  -> the SENDER's own process group: the invoking shell and every sibling job in it.
#
# So a process-group number is not a safe signal target merely because it is a number. It is safe
# only when it is a plausible group id AND it is still the group of a process this runner recorded
# and identity-proved. Everything else refuses: an unverifiable target is never signalled.
#
# This existed because the --attach path reads `pgid=` straight out of <prefix>.detached and every
# other PGID assignment in this file is checked while that one was not, and because the identity
# check that authorises a cancel proves `pid=` and then signals `pgid=` — a different field. A
# record carrying `pgid=1` (a truncated write, a stale file, a hand edit, or a test fixture — one
# was found on disk) therefore reached `kill -TERM -- -1`.
pgid_is_signalable() {  # <pgid> [owner-pid] -> 0 only when signalling this group is provably safe
  local pg="$1" owner="${2:-}" self
  case "$pg" in ''|*[!0-9]*) return 1;; esac        # empty, negative or non-numeric
  [ "$pg" -ge 2 ] 2>/dev/null || return 1           # 0 = our own group, 1 = every process we own
  [ "$pg" != "$$" ] || return 1                     # never this process
  self=$(pgid_of "$$"); [ -z "$self" ] || [ "$pg" != "$self" ] || return 1   # never our own group
  # Ownership: the group must STILL be the process group of the pid this runner recorded and
  # proved. This is what makes a stale or corrupt `pgid=` inert rather than lethal.
  if [ -n "$owner" ]; then
    case "$owner" in ''|*[!0-9]*) return 1;; esac
    [ "$(pgid_of "$owner")" = "$pg" ] || return 1
  fi
  return 0
}
refuse_signal() {  # <pgid> <context>
  echo "codex-run.sh: REFUSING to signal process group '${1:-<empty>}' from $2 — it is not a verified job group. Nothing was signalled. (0 would signal this shell's own process group; 1 would signal every process this user owns, which on macOS ends the login session.)" >&2
  [ -z "${PREFIX:-}" ] || echo "$(elapsed)s REFUSED-SIGNAL pgid='${1:-<empty>}' ($2): not a verified job group; nothing signalled" >> "$PREFIX.progress" 2>/dev/null || true
}
# Liveness is asked the same way, and about the same verified target: `kill -0 -- "-1"` is a
# permission probe against every process on the machine and would answer "alive" for a group that
# does not exist, which would in turn keep a finished attempt open forever.
group_alive() {  # <pgid> [owner-pid] -> 0 only when the group is BOTH signalable and alive
  pgid_is_signalable "$1" "${2:-}" || return 1
  kill -0 -- "-$1" 2>/dev/null
}
# group_alive answers "may I signal this, and is it there" — a refusal and an empty group are the
# same answer (1), so `! group_alive` is NOT a proof of emptiness. Every caller that closes an
# attempt needs that proof, and reaches it on paths where the owner pid is already gone and the
# gate therefore refuses unconditionally: `! group_alive` would be vacuously true and would close
# a live job (cycle 4: F-01/CL-01/CX-02). So emptiness is asked separately, by READING the process
# table and never by signalling. Soundness runs one way only: a pgid can be reused, which can make
# a dead group look alive but never a live one look dead. Undetermined answers — a non-numeric or
# sentinel pgid, or a ps that told us nothing — return 1 (not provably empty), so callers stay in
# flight rather than closing on an unproven termination.
# Two ways this predicate could have said "empty" about a live group, both fixed here
# (cycle 5: CX-04). (1) `ps … | tr …` reports TR's status, so a ps that failed — or that died
# part-way through printing, leaving a partial table that happens to omit this group — was read as
# a complete answer; the raw ps output is now captured on its own and its status checked, and a
# truncated-looking table is treated as undetermined. (2) The pgid was compared as TEXT, so a
# zero-padded `012345` passed the numeric guard and then matched nothing in a table that says
# `12345`. Both are normalized to base-10 integers before the comparison. Every uncertain answer
# is 1 (NOT provably empty), which keeps callers in flight rather than closing a running job.
group_is_empty() {  # <pgid> -> 0 only when the process table proves no member is left
  local pg="$1" raw rc norm self
  case "$pg" in ''|*[!0-9]*) return 1;; esac
  pg=$((10#$pg))                      # 012345 and 12345 are the same group; the table prints one form
  [ "$pg" -ge 2 ] 2>/dev/null || return 1
  raw=$(ps -Ao pgid= 2>/dev/null); rc=$?
  [ "$rc" = 0 ] || return 1           # ps failed: undetermined, never "empty"
  # Both sides are normalized to base-10 before anything is compared, so the answer is about the
  # group and not about how its number happens to be spelled.
  norm=$(printf '%s\n' "$raw" | tr -d ' ' | grep -E '^[0-9]+$' | sed 's/^0*\([0-9]\)/\1/')
  [ -n "$norm" ] || return 1
  # A working `ps -A` always lists at least this shell, and our own group is the cheapest thing to
  # look for: a table that does not contain it is truncated or filtered, not a description of the
  # machine, and nothing may be concluded from it.
  self=$(pgid_of "$$")
  case "$self" in ''|*[!0-9]*) return 1;; esac
  printf '%s\n' "$norm" | grep -qx -- "$((10#$self))" || return 1
  printf '%s\n' "$norm" | grep -qx -- "$pg" && return 1
  return 0
}
# TERM then KILL the whole group; return 0 when nothing in it is left, 1 when something survives.
# Fails closed: an unverified target returns 1 (not confirmed) WITHOUT signalling anything, so
# every caller treats it as "the cancel could not be confirmed" rather than as a completed kill.
kill_group() {  # <pgid> [owner-pid]
  local i owner="${2:-}"
  pgid_is_signalable "$1" "$owner" || { refuse_signal "$1" "kill_group"; return 1; }
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
      case "$SMOKE_MAX_SEC" in ''|*[!0-9]*|0*|??????????*) echo "PROBE UNAVAILABLE: backend=ccr alias=$ALIAS CODEX_RUN_SMOKE_MAX_SEC must be a positive whole number of at most 9 digits (got '$SMOKE_MAX_SEC')"; exit 1;; esac   # review round 2: F-03; round 3: F-02 oversized integers fail-open
      ( cd "$SMOKE/repo" && start_in_own_group "${ARGV[@]}" ) < "$SMOKE/prompt.md" > "$SMOKE/stream.jsonl" 2> "$SMOKE/stderr" &
      SCHILD=$!; sleep 1; SPGID=$(pgid_of "$SCHILD")
      # Same guard as the launch path: signal only a group the child created (pgid == pid); a group id
      # that is not the child's is the runner's own inherited group (review round 2: F-07).
      [ "$SPGID" = "$SCHILD" ] || SPGID=""
      SWAITED=0; STIMED=0
      while kill -0 "$SCHILD" 2>/dev/null; do
        if [ "$SWAITED" -ge "$SMOKE_MAX_SEC" ]; then STIMED=1; break; fi
        sleep 1; SWAITED=$((SWAITED+1))
      done
      if [ "$STIMED" = 1 ]; then
        if [ -n "$SPGID" ] && kill_group "$SPGID" "$SCHILD"; then SKILL="process group $SPGID terminated"
        else
          # No verified group: signal the CHILD BY PID only. A bare negative here would be a
          # group target derived from an unverified number.
          pgid_is_signalable "$SCHILD" "$SCHILD" && kill -KILL -- "-$SCHILD" 2>/dev/null
          kill -KILL "$SCHILD" 2>/dev/null
          SKILL="process group ${SPGID:-$SCHILD} NOT confirmed terminated (check: ps -o pid,pgid,command -g ${SPGID:-$SCHILD})"; fi
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
      SMOKE_MODEL=$(stream_field "$SMOKE/stream.jsonl" init-model)
      [ "$SMOKE_MODEL" = "$CLAUDE_MODEL" ] || { echo "PROBE UNAVAILABLE: backend=ccr alias=$ALIAS route=unverified expected_child_model=${CLAUDE_MODEL:-unknown} got_child_model=${SMOKE_MODEL:-unknown} ccr=$CCR_VER"; exit 1; }
      RECORDED="not recorded (pass --record-dir <run dir> so launches in it can verify the smoke)"
      if [ -n "$RECORD_DIR" ]; then
        printf 'alias=%s\nccr=%s\nmodel=%s\nprovider=%s\nclaude_model_id=%s\nchild_model=%s\nreadonly=verified\nlaunch_sha256=%s\nrecorded=%s\n' "$ALIAS" "$CCR_VER" "$PROVIDER_MODEL" "$PROVIDER" "$CLAUDE_MODEL" "$SMOKE_MODEL" "$(ccr_launch_digest)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$RECORD_DIR/.ccr-smoke.$ALIAS" \
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
       codex-run.sh <out-prefix> --attach [--stall-min N] [--max-min M] [--poll-sec S]
       codex-run.sh <out-prefix> --attach --cancel
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
die4() { echo "codex-run.sh: $1" >&2; echo "$USAGE" >&2; [ "$CLAIM_MODE" = 1 ] || [ -d "${PREFIX:-/nonexistent}.claim" ] || [ -e "${PREFIX:-/nonexistent}.exit" ] || [ -e "${PREFIX:-/nonexistent}.detached" ] || [ -e "${PREFIX:-/nonexistent}.progress" ] || echo 4 > "$PREFIX.exit" 2>/dev/null || true; exit 4; }
need() { [ $# -ge 2 ] || die4 "$1 requires a value"; case "$2" in -*) die4 "$1 requires a value (got option $2)";; esac; }
MODE="--fresh"; MODE_SET=0; PROMPT_FILE=""; STALL_MIN=6; MAX_MIN=25; POLL=15; VIA=codex; MAX_TURNS=""; RESUME_SESSION=""; ATTACH=0; VIA_SET=0; CANCEL_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --attach) ATTACH=1;;
    --cancel) CANCEL_ONLY=1;;
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
prompt_digest() { { shasum -a 256 "$1" 2>/dev/null || sha256sum "$1" 2>/dev/null; } | awk '{print $1; exit}'; }
# Publication of a terminal outcome is serialized against a concurrent attach and against the
# review gate's release, which take the same lock while they rotate a claim. Held across the whole
# step — receipt, .stdout, .meta, removing .detached, writing .exit — so no reader ever sees a
# half-published attempt. A lock older than a minute belongs to a dead process, exactly as
# stamp_claim treats it.
# Released on every exit path, including a die4 or a `set -e`-style abort inside the publish
# window: a lock leaked by a crashed collector would otherwise block every later attach and the
# review gate's own release for a full minute (F-04's abort was exactly this shape).
# A bash trap handler that RETURNS does not terminate the script. Releasing the lock on INT/TERM
# and carrying on would hand the publication lock to a second collector while this one keeps
# watching and still publishes at the end — two collectors of one job, the exact failure this lock
# exists to prevent (cycle 3: CL-02/CX-01, reproduced). The signal handlers therefore exit.
trap 'publish_unlock' EXIT
trap 'publish_unlock; exit 130' INT
trap 'publish_unlock; exit 143' TERM
# Staleness here is a property of the HOLDER, never of the clock. An --attach holds this lock for
# its whole watch — up to --max-min, twenty-five minutes by default — so an age-based reclaim
# would time out against a perfectly healthy holder and admit a second collector into the same
# job, which is exactly the mutual exclusion this lock exists to provide (cycle 2: CL-02). The
# holder records its pid and start-time identity inside the lock; the lock is reclaimed only when
# that execution is provably no longer running. The clock is used for one case only: a lock
# directory with no holder record, which is either a pre-change lock or the millisecond window
# between mkdir and the record being written — a grace far longer than that window settles it.
# Reclaiming a lock is a race against a contender who may legitimately own it by now. Testing the
# holder and then deleting it are two steps, so a second reclaimer can delete the REPLACEMENT
# holder and both end up believing they hold the lock (cycle 3: CL-04/CX-04). The rename is the
# serializing step: only one contender can move the holder file away, and the loser's `mv` fails
# because the source is gone. The mover then checks that what it moved is the very record it
# judged stale — a live contender's holder carries a different, live pid — and puts it back if it
# is not. A holder file that cannot be read at all (empty, truncated by an interrupted write) is
# NOT treated as a dead holder; it falls to the clock, which must remove the file too, because
# `rmdir` cannot remove a directory that still contains it — that combination wedged the lock
# permanently (cycle 3: CX-05, reproduced: rc=4 forever with the lock still present).
reclaim_lock() {  # <lock> <the exact holder record judged stale> -> 0 when the lock is now free
  local lock="$1" want="$2" tmp="$1/holder.dead.$$"
  mv "$lock/holder" "$tmp" 2>/dev/null || return 1
  if [ "$(cat "$tmp" 2>/dev/null)" = "$want" ]; then
    rm -f "$tmp"; rmdir "$lock" 2>/dev/null && return 0
    return 1
  fi
  mv "$tmp" "$lock/holder" 2>/dev/null || rm -f "$tmp"   # a live holder replaced it: leave it alone
  return 1
}
# `--must` is for the publication path, which is reached only AFTER the job has finished and its
# answer has been written to .stdout. Abandoning there because another process held the lock for
# five seconds threw away a completed second-model review and reported it as a LAUNCH-ERROR
# (cycle 3: CL-05) — `phase-gate.sh release` alone holds this lock across a companion call that
# can exceed that. With `--must` a PROVABLY LIVE holder is waited out instead: the wait is bounded
# by the longest legitimate hold (an attach's own watch bound) and says so in .progress, and a
# holder that stops being provable is reclaimed by the branch above as usual.
PUBLISH_WAIT_MAX=$(( 30 * 60 * 10 ))   # 0.1 s ticks
publish_lock() {  # [--must]
  local must=0; [ "${1:-}" != --must ] || must=1
  local lock="$PREFIX.claim.lock" i=0 waited=0 now m hpid hident hrec d dp
  while ! mkdir "$lock" 2>/dev/null; do
    hrec=$(cat "$lock/holder" 2>/dev/null)
    hpid=$(printf '%s\n' "$hrec" | awk -F= '$1=="pid"{print $2; exit}')
    hident=$(printf '%s\n' "$hrec" | awk -F= '$1=="identity"{sub(/^[^=]*=/, ""); print; exit}')
    if [ -n "$hpid" ]; then
      # Reclaim only on a PROVEN absence. `identity_state` returns 1 both when the holder is gone
      # and when `ps` could not answer, and reading the second as the first let a contender take a
      # live collector's lock during a transient inspection failure (cycle 5: CX-05).
      if holder_is_provably_gone "$hpid" "$hident"; then
        reclaim_lock "$lock" "$hrec" && continue
      elif [ "$must" = 1 ]; then
        waited=$((waited+1))
        [ "$waited" -lt "$PUBLISH_WAIT_MAX" ] || { echo "codex-run.sh: $lock has been held by a live process (pid $hpid) for 30 minutes; the job's answer is in $PREFIX.stdout but no terminal sidecar was published" >&2; exit 4; }
        [ $(( waited % 600 )) -ne 0 ] || echo "$(elapsed)s waiting to publish: $lock held by live pid $hpid ($(( waited / 600 )) min)" >> "$PREFIX.progress"
        i=0   # a provably live holder is not a reason to discard a finished attempt
      fi
    else
      now=$(date +%s); m=$(fmtime "$lock" || echo "$now"); m=${m:-$now}
      # rmdir cannot remove a directory that still contains anything, so the clock must clear
      # EVERY file a lock can hold — including a `holder.dead.<pid>` left by a reclaim_lock that
      # was killed between its rename and its rm. Clearing only `holder` wedged the lock forever
      # in exactly the shape cycle 3 fixed for `holder` itself (cycle 4: CX-05).
      # But `holder.dead.<pid>` is only abandoned once <pid> is gone: while that reclaimer is still
      # running, the file is a LIVE holder record it has moved aside and may still put back, and
      # deleting it let a third contender take a lock a second one legitimately owned (cycle 5:
      # CX-06). The name carries the reclaimer's pid, so the question is answerable — and it is
      # asked, rather than assumed from the directory's age.
      if [ $(( now - m )) -ge 60 ]; then
        for d in "$lock"/holder.dead.*; do
          [ -e "$d" ] || continue
          dp=${d##*.}
          case "$dp" in ''|*[!0-9]*) rm -f "$d" 2>/dev/null; continue;; esac
          kill -0 "$dp" 2>/dev/null || rm -f "$d" 2>/dev/null   # its reclaimer is gone: abandoned
        done
        rm -f "$lock/holder" 2>/dev/null; rmdir "$lock" 2>/dev/null && continue
      fi
    fi
    # One bound for both shapes of failure: a lock a live holder legitimately owns, and a stale one
    # that cannot be removed (a directory with something else inside it). Neither may spin forever.
    i=$((i+1)); [ "$i" -lt 50 ] || { echo "codex-run.sh: $lock is held by another attach, a launch gate or a release, or is stale and cannot be removed; retry in a moment (nothing was published)" >&2; exit 4; }
    sleep 0.1
  done
  printf 'pid=%s\nidentity=%s\n' "$$" "$(proc_identity "$$")" > "$lock/holder" 2>/dev/null || true
  HELD_LOCK="$lock"
}
publish_unlock() { [ -z "${HELD_LOCK:-}" ] || { rm -f "$HELD_LOCK/holder" 2>/dev/null; rmdir "$HELD_LOCK" 2>/dev/null; }; HELD_LOCK=""; }

# The in-flight refusals, split out of rotate_previous_attempt so they can run BEFORE the claim is
# taken. They used to run after: stamp_claim did `mkdir <prefix>.claim/runner` and wrote its pid,
# and only then did rotation ask whether the prefix already held an unfinished attempt. A refusal
# therefore left a taken claim behind — which `phase-gate.sh` counts against the four-launch budget
# and reports as a runner in flight for a process that has exited — so four refusals could exhaust
# a review's budget without a single job being launched (cycle 5: CL-05). This function only ever
# reads and refuses; it never rotates or writes.
refuse_if_in_flight() {
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
    lline=$(grep -E '^[0-9]+s launched backend=ccr ' "$PREFIX.progress" 2>/dev/null | tail -1)
    if [ -n "$lline" ]; then
      lpgid=$(printf '%s' "$lline" | sed -n 's/.* pgid=\([0-9]*\).*/\1/p')
      # The pid on that line is the SUPERVISOR and its child outlives it, so the group — not the
      # pid — is what says whether work is still happening. Only a provably empty group clears it.
      if [ -n "$lpgid" ] && ! group_is_empty "$lpgid"; then
        mlive="process group $lpgid still has members"
      fi
    else
      ljob=$(grep -oE 'launched job=task-[a-z0-9-]+' "$PREFIX.progress" 2>/dev/null | head -1 | cut -d= -f2)
      if [ -n "$ljob" ]; then
        lroot=$(codex_root)
        if [ -n "$lroot" ] && [ -f "$lroot/scripts/codex-companion.mjs" ]; then
          lstat=$(node "$lroot/scripts/codex-companion.mjs" status "$ljob" --json 2>/dev/null \
                  | python3 -c "import sys,json;d=json.load(sys.stdin);print((d.get('job') or {}).get('status') or '')" 2>/dev/null)
          case "$lstat" in
            completed|failed|cancelled|canceled) ;;                      # over: rotate
            "") mlive="the companion did not answer for job $ljob";;      # fail closed
            *)  mlive="job $ljob is $lstat";;
          esac
        else
          mlive="the codex companion could not be consulted for job $ljob"
        fi
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
  # recorded identity is provably still running; an unprovable one is allowed to rotate so a dead
  # record can never deadlock the prefix.
  if [ -e "$PREFIX.detached" ] && [ ! -e "$PREFIX.exit" ]; then
    local dbackend dpid dident djob dstatus droot dlive=no
    dbackend=$(detached_field backend)
    case "$dbackend" in
      ccr)
        # The recorded pid is the SUPERVISOR, not the work. A supervisor that is gone or whose
        # number has been reused proves nothing about the child: the child is reparented and keeps
        # running in the same process group. Treating an unresolved identity as "not live" rotated
        # the record of a job still executing and authorized a second one beside it — the same
        # defect the codex branch below already fails closed on (cycle 4: CX-04). So identity is
        # only ever promoted to a POSITIVE answer here; the negative comes from the group.
        local dpgid dreceipt
        dpid=$(detached_field pid); dident=$(detached_field identity)
        dpgid=$(detached_field pgid); dreceipt=$(detached_field receipt)
        if [ -n "$dpid" ] && identity_state "$dpid" "$dident"; then
          dlive="yes (pid $dpid, start time matches)"
        elif [ -n "$dreceipt" ] && [ -s "$dreceipt" ]; then
          dlive=no                                  # the supervisor reaped the child: over
        elif [ -s "$PREFIX.childexit" ]; then
          dlive=no
        elif [ -n "$dpgid" ] && group_is_empty "$dpgid"; then
          dlive=no                                  # nothing of the job is left: over
        elif [ -z "$dpid" ] && [ -z "$dpgid" ]; then
          dlive="undetermined ($PREFIX.detached records no pid or pgid for the ccr attempt)"
        else
          dlive="undetermined (pid ${dpid:-<none>} is gone or reused and process group ${dpgid:-<none>} is not provably empty)"
        fi
        ;;
      codex)
        # The codex record carries no process WE own — the companion owns the job — so liveness is
        # asked of the companion, exactly as phase-gate.sh asks it. Until this was added the guard
        # was dead code on the default backend (no pid= was ever recorded), so a relaunch rotated a
        # live job's record away and started a SECOND job beside it — and codex-debate and
        # codex-deep-plan, which pass no --claim, had no other protection (cycle 3: CL-03/CX-02).
        djob=$(detached_field job); droot=$(codex_root)
        if [ -n "$djob" ] && [ -n "$droot" ] && [ -f "$droot/scripts/codex-companion.mjs" ]; then
          dstatus=$(node "$droot/scripts/codex-companion.mjs" status "$djob" --json 2>/dev/null \
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
        dpid=$(detached_field worker_pid); dident=$(detached_field worker_identity)
        [ -z "$dpid" ] || ! identity_state "$dpid" "$dident" || dlive="yes (worker pid $dpid is still running)"
        ;;
    esac
    if [ "$dlive" != no ]; then
      echo "codex-run.sh: $PREFIX.detached names an attempt that has not ended — $dlive. Launching here would strand it and start a second job beside it. Attach to it or cancel it first:" >&2
      echo "  $(detached_field attach_command)" >&2
      echo "  $(detached_field cancel_command)" >&2
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
  if [ -e "$PREFIX.meta" ] || [ -e "$PREFIX.exit" ] || [ -e "$PREFIX.progress" ]; then
    N=1; while ls "$PREFIX.attempt$N."* >/dev/null 2>&1; do N=$((N+1)); done
    # .detached and .childexit belong to the attempt too: a record left behind would make a bogus
    # --attach admissible against the NEXT, live attempt, and a stale receipt would let it publish
    # a terminal outcome from the previous run's exit status.
    for ext in stdout stderr progress joblog meta exit detached childexit; do [ -e "$PREFIX.$ext" ] && mv "$PREFIX.$ext" "$PREFIX.attempt$N.$ext"; done
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
  # The lock is taken FIRST and unconditionally, because what it serializes is not only the claim:
  # every caller runs `stamp_claim; rotate_previous_attempt; unlock_claim`, so returning early from
  # here left the in-flight check and the sidecar rotation completely unserialized. On the default
  # path of codex-debate and codex-deep-plan — no claim directory and no --claim — that early
  # return was ALWAYS taken, so two launches racing on one prefix could both read "not in flight"
  # and both rotate, each hiding the other's attempt (cycle 4: CL-04/CX-03). The claim-specific
  # work below stays conditional; the lock does not.
  # Taking the claim (token check, mkdir runner, pid) is serialized against the
  # gate rotating or replacing it by <prefix>.claim.lock, the same atomic-mkdir
  # lock the gate holds while it rotates (round-38 CX-03). The lock stays held
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
    echo "codex-run.sh: $PREFIX.claim is already taken by runner $(cat "$PREFIX.claim/runner/pid" 2>/dev/null || echo unknown); re-run the launch gate before launching again (no sidecar was written)" >&2
    exit 4
  fi
  printf '%s\n' "$$" > "$PREFIX.claim/runner/pid"
  printf 'runner_pid=%s\nstarted=%s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$PREFIX.claim/owner" 2>/dev/null
  HELD_LOCK="$lock"
  return 0
}
HELD_LOCK=""
unlock_claim() { publish_unlock; }   # one release for one acquisition: the holder record goes too
# A launch error after the claim is owned: sidecars record it (outcome=LAUNCH-ERROR, .exit=4).
launch_error() {  # <message> <command>
  stamp_claim; rotate_previous_attempt; unlock_claim
  echo "codex-run.sh: $1" >&2; printf 'LAUNCH-ERROR\n%s\n' "$1" > "$PREFIX.stderr"; printf '0s LAUNCH-ERROR: %s\n' "$1" > "$PREFIX.progress"
  printf 'outcome=LAUNCH-ERROR\nbackend=%s\nlast_error=%s\nmode=%s\nprompt_file=%s\ncommand=%s\n' "$BACKEND" "$1" "$MODE" "$PROMPT_FILE" "$2" > "$PREFIX.meta"; echo 4 > "$PREFIX.exit"; exit 4
}
START=$(date +%s); now() { date +%s; }; elapsed() { echo $(( $(now) - START )); }


# =============================================================================================
# --attach — resume the watch on a job this process did not launch
# =============================================================================================
# Not a launch: no claim is taken (stamp_claim would refuse a claim already held), no sidecar is
# rotated (rotate_previous_attempt would hide the very .meta this needs), no launch budget is
# spent, and `mode=` keeps the original launch mode so the review gates' thread anchoring is
# untouched. Attachment is recorded separately, in `attached=`.
if [ "$ATTACH" = 1 ]; then
  # Admission is decided under the publication lock and HELD for the whole attach, so a second
  # attach cannot pass the same guard and end up as a concurrent collector of one job. Testing
  # `.exit` outside the lock only proved it was absent at some moment in the past; by the time
  # this process published, another collector could already have finished.
  publish_lock
  [ -e "$PREFIX.detached" ] || die4 "--attach: no $PREFIX.detached — nothing detached from this prefix (a launch that finished wrote .exit; a launch that never ran wrote nothing)"
  [ ! -e "$PREFIX.exit" ] || die4 "--attach: $PREFIX.exit exists, so that attempt already finished; re-read its sidecars instead of attaching"
  BACKEND=$(detached_field backend); JOB=$(detached_field job); MODE=$(detached_field mode)
  ALIAS=$(detached_field alias); LOGFILE=$(detached_field joblog); RECEIPT=$(detached_field receipt)
  DPID=$(detached_field pid); PGID=$(detached_field pgid); IDENT=$(detached_field identity)
  ATTEMPTS=$(awk -F= '$1=="attached"{print $2; exit}' "$PREFIX.meta" 2>/dev/null); ATTEMPTS=$(( ${ATTEMPTS:-0} + 1 ))
  case "$BACKEND" in codex|ccr) ;; *) die4 "--attach: $PREFIX.detached names no usable backend (backend='$BACKEND')";; esac
  ATTACH_CMD=$(detached_field attach_command); CANCEL_CMD=$(detached_field cancel_command)
  echo "$(elapsed)s ATTACH #$ATTEMPTS backend=$BACKEND ${JOB:+job=$JOB}${DPID:+pid=$DPID pgid=$PGID}" >> "$PREFIX.progress"

  # ---- identity, before anything is observed or signalled -------------------
  # 0 = the recorded number still names our execution · 1 = it is gone · 2 = it now names
  # something else. 1 and 2 both mean our execution ended — a live pid is never reused — so both
  # collect; what neither may do is signal, which is why the state is resolved before the loop.
  # ALIVE gates SIGNALLING only. Whether the job ENDED is a separate question, and identity cannot
  # answer it: an empty `ps` may be a failed inspection rather than an exit, and an unequal string
  # may be an identity we cannot reproduce rather than a reused pid. Only the supervisor receipt
  # settles that, so an ambiguous state with no receipt re-detaches instead of publishing.
  ALIVE=1; IDENT_NOTE=""; IDENT_STATE=0
  if [ "$BACKEND" = ccr ]; then
    identity_state "$DPID" "$IDENT"; IDENT_STATE=$?
    case "$IDENT_STATE" in
      0) ALIVE=1;;
      1) ALIVE=0; IDENT_NOTE="the recorded process id is not readable; only the supervisor receipt can say whether the job ended";;
      2) ALIVE=0; IDENT_NOTE="pid $DPID does not match the recorded start time; nothing will be signalled, and only the receipt can end this attempt";;
    esac
    [ -z "$IDENT_NOTE" ] || echo "$(elapsed)s IDENTITY: $IDENT_NOTE" >> "$PREFIX.progress"
  fi

  if [ "$CANCEL_ONLY" = 1 ]; then
    if [ "$BACKEND" = codex ]; then
      CODEX_ROOT=$(codex_root); [ -n "$CODEX_ROOT" ] || die4 "--attach --cancel: cannot locate the codex plugin"
      node "$CODEX_ROOT/scripts/codex-companion.mjs" cancel "$JOB" >>"$PREFIX.stderr" 2>&1 || true
      echo "codex-run.sh: cancel requested for job $JOB"
    elif [ "$ALIVE" = 1 ]; then
      # `ALIVE` proved DPID. It says nothing about PGID, which is a different field read from the
      # same file — so the group is passed with its owner and signalled only if it is still that
      # process's group.
      kill_group "$PGID" "$DPID" && echo "codex-run.sh: cancelled process group $PGID (identity verified)" || echo "codex-run.sh: cancel of process group $PGID not confirmed" >&2
    else
      echo "codex-run.sh: nothing to cancel — $IDENT_NOTE"
    fi
    # A cancel ENDS the job; it does not CLOSE the attempt. .detached is still here and .exit is
    # still absent, so every gate still reports this phase in flight and `release` still refuses.
    # Exit 0 alone reads as "recovery finished", which it is not (cycle 3: CL-09).
    echo "codex-run.sh: the attempt is still open — .detached remains and no .exit was written. Attach once more to publish the outcome and free the claim:"
    echo "  ${ATTACH_CMD:-$0 $PREFIX --attach}"
    exit 0
  fi
fi

# =============================================================================================
# ccr backend
# =============================================================================================
if [ "$BACKEND" = ccr ]; then
  DIR=$(dirname "$PREFIX")
 if [ "$ATTACH" = 1 ]; then
  # Attaching: the launch already happened. Take the identifiers from the detached record, keep
  # the launch's own command line for .meta, and go straight to the watch loop.
  CMD=$(awk -F= '$1=="command"{sub(/^[^=]*=/,""); print; exit}' "$PREFIX.meta" 2>/dev/null)
  CHILD="$DPID"; SESSION=""; PROMPT_FILE=$(awk -F= '$1=="prompt_file"{sub(/^[^=]*=/,""); print; exit}' "$PREFIX.meta" 2>/dev/null)
  # The launch's turn budget, not this collector's default: `error_max_turns` in a result event is
  # only interpretable against the budget the run actually used (cycle 3: CL-11).
  MAX_TURNS=$(detached_field max_turns); MAX_TURNS=${MAX_TURNS:-$CCR_MAX_TURNS_DEFAULT}
  ccr_preflight "$ALIAS" >/dev/null 2>&1 || true   # descriptive only; the child is already running
 else
  CMD="ccr launch --model $ALIAS --permission-mode plan -p ... --max-turns $MAX_TURNS $MODE${RESUME_SESSION:+ $RESUME_SESSION} --prompt-file $PROMPT_FILE"
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
  rm -f "$PREFIX.childexit" "$PREFIX.childexit.tmp"
  # The launcher needs the receipt path by the same name the attach path reads it under: its
  # monitor now uses the identical "receipt or provably empty group" termination predicate, and
  # under `set -u` an undefined RECEIPT would abort the run instead (cycle 5: CX-03).
  RECEIPT="$PREFIX.childexit"
  start_supervised_group "$PREFIX.childexit" "${ARGV[@]}" < "$PROMPT_FILE" > "$PREFIX.joblog" 2>> "$PREFIX.stderr" &
  CHILD=$!
  sleep 1
  PGID=$(pgid_of "$CHILD")
  if [ "$PGID" != "$CHILD" ]; then
    # Either the child already exited (fast failure — let the normal path report it) or the
    # group could not be established; the latter is never left running.
    if kill -0 "$CHILD" 2>/dev/null; then
      # pgid == pid by construction (setpgrp before exec), so signal the group by that number too: a
      # child the fake/gateway forked must not outlive this branch (a stray `sleep` was observed).
      pgid_is_signalable "$CHILD" "$CHILD" && kill -KILL -- "-$CHILD" 2>/dev/null
      kill -KILL "$CHILD" 2>/dev/null; wait "$CHILD" 2>/dev/null
      echo "$(elapsed)s LAUNCH: process group of pid $CHILD could not be read (got '$PGID'); child killed" >> "$PREFIX.progress"
      printf 'outcome=UNCONFIRMED-CANCEL\nbackend=ccr\nalias=%s\npid=%s\npgid=unknown\nlast_error=process group unreadable\nmode=%s\nprompt_file=%s\ncommand=%s\ncancel_confirmed=no\n' "$ALIAS" "$CHILD" "$MODE" "$PROMPT_FILE" "$CMD" > "$PREFIX.meta"
      : > "$PREFIX.stdout"; echo 5 > "$PREFIX.exit"; echo "codex-run.sh: process group unreadable; child killed (exit 5)" >&2; exit 5
    fi
    PGID="$CHILD"
  fi
  echo "$(elapsed)s launched backend=ccr pid=$CHILD pgid=$PGID alias=$ALIAS" >> "$PREFIX.progress"
 fi

  OUTCOME=""; LAST_ACTIVITY=$(now); PREV_SIG=""; IDLE=0
  while :; do
    sleep "$POLL"
    SIG=$(fsig "$PREFIX.joblog"); LASTLINE=$(tail -n 1 "$PREFIX.joblog" 2>/dev/null | cut -c1-140)
    if [ "$SIG" != "$PREV_SIG" ]; then LAST_ACTIVITY=$(now); PREV_SIG="$SIG"; fi
    IDLE=$(( $(now) - LAST_ACTIVITY ))
    if [ "$ATTACH" = 1 ]; then
      # Not our child: `kill -0` would answer for whatever holds the number now, so the pid is
      # paired with its start time. A number that is gone, or that has been reused, both mean our
      # execution ended — and neither may be signalled.
      identity_state "$CHILD" "$IDENT"; IDENT_STATE=$?
      case "$IDENT_STATE" in
        0) STATUS=running;;
        # The number is gone or contested. That is not proof the job finished — only the receipt
        # is. With a receipt the execution is genuinely over and we collect; without one the
        # attempt stays in flight and this watch re-detaches at the bound (see below).
        1|2) ALIVE=0
             if [ -s "$RECEIPT" ]; then STATUS=exited
             elif [ -n "$PGID" ] && group_is_empty "$PGID"; then
               # The identity is gone AND the whole process group is empty. Group emptiness is
               # sound in this direction — pgid reuse can only make a dead group look alive — so
               # the execution really is over, and the collector below closes the attempt with the
               # status recorded as unknown rather than watching a dead job to the bound.
               STATUS=exited; IDENT_NOTE="identity unresolved (state $IDENT_STATE) and process group $PGID is empty; the execution ended without a receipt"
             else STATUS=running; IDENT_NOTE="identity unresolved (state $IDENT_STATE) and no supervisor receipt yet; not concluding the job ended"; fi;;
      esac
    elif kill -0 "$CHILD" 2>/dev/null; then STATUS=running
    else
      # $CHILD is the SUPERVISOR, not the work. Its death is not the job's: the gateway child is
      # reparented and keeps running in the same process group. Reading "supervisor gone" as
      # "attempt over" published a terminal .exit for a live job and freed the prefix for a second
      # one — the same defect the attach branch above was fixed for in cycle 4, left standing on
      # the ORIGINAL launcher's path (cycle 5: CX-03). The launcher now uses the identical
      # predicate: a receipt, or a provably empty group, and nothing else ends the attempt.
      if [ -s "$RECEIPT" ]; then STATUS=exited
      elif [ -n "$PGID" ] && group_is_empty "$PGID"; then
        STATUS=exited; IDENT_NOTE="the supervisor is gone and process group $PGID is empty; the execution ended without a receipt"
      else
        STATUS=running
        IDENT_NOTE="the supervisor (pid $CHILD) is gone but process group ${PGID:-<unrecorded>} is not provably empty and there is no receipt; not concluding the job ended"
      fi
    fi
    echo "$(elapsed)s status=$STATUS idle=${IDLE}s | $LASTLINE" >> "$PREFIX.progress"
    [ "$STATUS" = running ] || { OUTCOME=EXITED; break; }
    if [ "$IDLE" -ge $(( STALL_MIN * 60 )) ]; then OUTCOME=STALLED; break; fi
    # The watch bound is the watcher's own and says nothing about the job, so it detaches
    # instead of killing: the supervisor keeps the child, and an --attach resumes the watch.
    if [ "$(elapsed)" -ge $(( MAX_MIN * 60 )) ]; then OUTCOME=DETACHED; break; fi
  done
  if [ "$OUTCOME" = DETACHED ]; then
    # Every field of this record is owned by the LAUNCH, and a re-detaching attach is not it.
    # Re-deriving identity= would write down whatever holds the number NOW — laundering an
    # identity this very run refused to act on into one a later attach would signal on — and
    # re-deriving claude_model_id= or prompt_sha256= would erase what the launch pinned with
    # values this process cannot know (cycle 2: CL-04). So an attach copies them forward
    # verbatim; only a launch writes them.
    if [ "$ATTACH" = 1 ]; then
      D_IDENT="$IDENT"; D_MODEL=$(detached_field claude_model_id); D_SHA=$(detached_field prompt_sha256); D_TURNS=$(detached_field max_turns)
      D_AT=$(detached_field detached_at); D_JOBLOG="${LOGFILE:-$PREFIX.joblog}"; D_RECEIPT="${RECEIPT:-$PREFIX.childexit}"
      ATTACH_CMD=$(detached_field attach_command); CANCEL_CMD=$(detached_field cancel_command)
    else
      D_IDENT=$(proc_identity "$CHILD"); D_MODEL="$CLAUDE_MODEL"; D_SHA=$(prompt_digest "$PROMPT_FILE"); D_TURNS="$MAX_TURNS"
      D_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ); D_JOBLOG="$PREFIX.joblog"; D_RECEIPT="$PREFIX.childexit"
      ATTACH_CMD="$0 $PREFIX --attach --stall-min $STALL_MIN --max-min $MAX_MIN --poll-sec $POLL"
      CANCEL_CMD="$0 $PREFIX --attach --cancel   # identity-checked; never kill -$PGID directly, that number may name something else by now"
    fi
    echo "$(elapsed)s DETACHED → watch bound reached with the job still running; nothing signalled (pgid $PGID left alive)" >> "$PREFIX.progress"
    # ORDER MATTERS: .detached is what admits an --attach, so it is written LAST, after every other
    # sidecar this attempt owns. Publishing it first opened a window in which an attach could be
    # admitted, collect the job and write .exit, and then have this block's .meta land on top of
    # the terminal record with outcome=DETACHED (cycle 3: CX-07).
    {
      echo "outcome=DETACHED"; echo "backend=ccr"; echo "alias=$ALIAS"; echo "detached=yes"; echo "attached=${ATTEMPTS:-0}"
      echo "pid=$CHILD"; echo "pgid=$PGID"; echo "thread=$(stream_field "$PREFIX.joblog" init-session)"
      echo "elapsed_sec=$(elapsed)"; echo "idle_at_end_sec=$IDLE"; echo "stall_min=$STALL_MIN max_min=$MAX_MIN"; echo "max_turns=$MAX_TURNS"
      echo "mode=$MODE"; echo "prompt_file=$PROMPT_FILE"; echo "command=$CMD"
      echo "attach_command=$ATTACH_CMD"; echo "cancel_command=$CANCEL_CMD"
    } > "$PREFIX.meta"
    write_detached <<EOD
backend=ccr
alias=$ALIAS
claude_model_id=$D_MODEL
pid=$CHILD
pgid=$PGID
identity=$D_IDENT
joblog=$D_JOBLOG
receipt=$D_RECEIPT
mode=$MODE
max_turns=$D_TURNS
prompt_sha256=$D_SHA
detached_at=$D_AT
attach_command=$ATTACH_CMD
cancel_command=$CANCEL_CMD
EOD
    # NO .exit: an existing .exit tells every review gate the attempt finished, and it would then
    # rotate the claim and authorize a second launch against this still-running job.
    echo "codex-run.sh: DETACHED backend=ccr alias=$ALIAS pgid=$PGID elapsed=$(elapsed)s — the job is still running."
    echo "  attach: $ATTACH_CMD"
    echo "  cancel: $CANCEL_CMD"
    exit 6
  fi
  UNCONFIRMED_CANCEL=0
  if [ "$OUTCOME" = STALLED ] && [ "$ATTACH" = 1 ] && [ "${ALIVE:-1}" != 1 ]; then
    # The stall bound elapsed on an attach that has already logged that the recorded identity is
    # unresolved — the pid is unreadable, or it now names a different execution. The one rule
    # identity IS authoritative for is that nothing may be signalled unless the number still names
    # our execution, and TERM/KILLing the recorded group here would break it against a process we
    # have no reason to believe is ours (cycle 2: CL-01, CX-01). Nothing is signalled and nothing
    # terminal is published: the attempt stays in flight and the recovery is another attach.
    OUTCOME=DETACHED
    REDETACH_REASON="stall bound reached but the recorded identity is unresolved (state ${IDENT_STATE:-?}); nothing was signalled"
    echo "$(elapsed)s STALLED → identity unresolved (state ${IDENT_STATE:-?}); refusing to signal pgid $PGID — re-detaching instead" >> "$PREFIX.progress"
  elif [ "$OUTCOME" = STALLED ]; then
    if kill_group "$PGID" "$CHILD"; then
      echo "$(elapsed)s $OUTCOME → process group $PGID terminated (confirmed: no member left)" >> "$PREFIX.progress"
    else
      UNCONFIRMED_CANCEL=1
      echo "$(elapsed)s $OUTCOME → cancel of process group $PGID NOT confirmed; a process may still be running" >> "$PREFIX.progress"
      echo "codex-run.sh: cancel of process group $PGID not confirmed; DO NOT retry — check with: ps -o pid,pgid,command -g $PGID" >&2
    fi
  fi
  if [ "$ATTACH" = 1 ]; then
    # An attaching process cannot wait() for a child it did not fork. The supervisor's receipt is
    # exactly why it exists: the success predicate below keeps its exit-status condition.
    CHILD_RC=$(awk -F= '$1=="child_exit"{print $2; exit}' "$RECEIPT" 2>/dev/null)
    if [ -z "$CHILD_RC" ] && [ -n "$PGID" ] && group_is_empty "$PGID"; then
      # No receipt, and the recorded process group is EMPTY. That is a proof of termination in the
      # one direction that is sound: a pgid can be reused, which can only make a dead group look
      # alive, never a live one look dead. So the execution is over and its exit status is
      # unknowable — the supervisor was killed (SIGKILL, OOM, a host crash) before it could reap.
      # Without this branch the prefix wedged permanently: the attach re-detached forever, the
      # cancel refused to signal an unprovable identity, `release` refused a detached prefix and
      # the taken claim refused a relaunch (cycle 3: CL-01/CX-06, executed). The attempt is closed
      # as a FAILURE with the status recorded as unknown — never manufactured as success.
      CHILD_RC=unknown
      echo "$(elapsed)s no supervisor receipt at $RECEIPT and process group $PGID is empty; the execution ended without publishing a status — closing the attempt as FAILED with child_exit=unknown" >> "$PREFIX.progress"
      LAST_ERROR_OVERRIDE="supervisor left no receipt and process group $PGID is provably empty; the exit status of this attempt is unknown"
    fi
    if [ -z "$CHILD_RC" ]; then
      # No receipt means the owner has not reaped the child, so this attempt has NOT ended —
      # whatever the pid looks like. Publishing a terminal failure here would delete .detached,
      # free the claim and let a second job be launched against the one still running: the exact
      # failure this change exists to prevent, reintroduced one level up.
      OUTCOME=DETACHED
      echo "$(elapsed)s no supervisor receipt at $RECEIPT; the attempt has not ended — re-detaching rather than publishing a terminal outcome" >> "$PREFIX.progress"
      # A more specific reason already set upstream (a refused stall signal) is the one to keep.
      REDETACH_REASON="${REDETACH_REASON:-no supervisor receipt; identity state ${IDENT_STATE:-0}}"
    fi
  else
    wait "$CHILD" 2>/dev/null; CHILD_RC=$?
  fi
  # A collector that cannot prove the attempt ended publishes nothing terminal. It refreshes the
  # detached record and leaves with exit 6, so .exit stays absent, the claim stays closed, and the
  # documented recovery is still an attach.
  if [ "$OUTCOME" = DETACHED ]; then
    ATTEMPTS=${ATTEMPTS:-0}
    ATTACH_CMD=$(detached_field attach_command); CANCEL_CMD=$(detached_field cancel_command)
    echo "$(elapsed)s DETACHED (re-detached): $REDETACH_REASON" >> "$PREFIX.progress"
    {
      echo "outcome=DETACHED"; echo "backend=ccr"; echo "alias=$ALIAS"; echo "detached=yes"; echo "attached=$ATTEMPTS"
      echo "pid=$DPID"; echo "pgid=$PGID"; echo "elapsed_sec=$(elapsed)"
      echo "stall_min=$STALL_MIN max_min=$MAX_MIN"; echo "mode=$MODE"; echo "prompt_file=$PROMPT_FILE"
      echo "command=$CMD"; echo "redetach_reason=$REDETACH_REASON"
      echo "attach_command=$ATTACH_CMD"; echo "cancel_command=$CANCEL_CMD"
    } > "$PREFIX.meta"
    publish_unlock
    echo "codex-run.sh: DETACHED backend=ccr alias=$ALIAS elapsed=$(elapsed)s — $REDETACH_REASON; the attempt is still open."
    echo "  attach: $ATTACH_CMD"
    exit 6
  fi
  SESSION_ID=$(stream_field "$PREFIX.joblog" init-session); ROUTED_MODEL=$(stream_field "$PREFIX.joblog" init-model)
  HAS_RESULT=$(stream_field "$PREFIX.joblog" has-result)
  stream_field "$PREFIX.joblog" result-text > "$PREFIX.stdout"
  if [ "$UNCONFIRMED_CANCEL" = 1 ]; then : > "$PREFIX.stdout"; fi
  if [ "$OUTCOME" = EXITED ]; then
    # A result event that is an error (is_error, or a non-success subtype such as error_max_turns) is a
    # failed attempt even if the child exited 0 (review round 1: F-10).
    # `child_exit=unknown` (a supervisor that died before reaping, above) is not zero, so this
    # predicate closes such an attempt as FAILED without ever manufacturing a success.
    if [ "$CHILD_RC" = 0 ] && [ "$HAS_RESULT" = yes ] && [ "$(stream_field "$PREFIX.joblog" result-ok)" = yes ]; then OUTCOME=COMPLETED; else OUTCOME=FAILED; fi
  fi
  # The configured alias is CCR input. `CLAUDE_MODEL` is the generated model ID
  # CCR promised for it; the child independently reports `ROUTED_MODEL` at init.
  # A mismatch is a route/configuration failure, never a reason to try Claude or
  # another alias. This comparison is local metadata only — no extra ccr call.
  ROUTE_OK=unknown
  if [ "$OUTCOME" = COMPLETED ]; then
    # On an attach, the expected model is the one recorded at launch. Judging a finished execution
    # by whatever the alias resolves to NOW would turn an ordinary config change into UNAVAILABLE
    # for an answer that was already produced correctly.
    if [ "$ATTACH" = 1 ]; then
      WANT_MODEL=$(detached_field claude_model_id); [ -n "$WANT_MODEL" ] || WANT_MODEL="$CLAUDE_MODEL"
      CLAUDE_MODEL="$WANT_MODEL"
    fi
    if [ -z "$CLAUDE_MODEL" ] || [ -z "$ROUTED_MODEL" ] || [ "$ROUTED_MODEL" != "$CLAUDE_MODEL" ]; then
      OUTCOME=UNAVAILABLE; ROUTE_OK=no
      echo "$(elapsed)s ROUTE-UNAVAILABLE alias=$ALIAS expected_child_model=${CLAUDE_MODEL:-unknown} got_child_model=${ROUTED_MODEL:-unknown}" >> "$PREFIX.progress"
      printf 'codex-run.sh: CCR route identity mismatch for alias %s (expected generated child model %s, got %s); do not retry with another alias or Claude\n' "$ALIAS" "${CLAUDE_MODEL:-unknown}" "${ROUTED_MODEL:-unknown}" >> "$PREFIX.stderr"
    else
      ROUTE_OK=yes
    fi
  fi
  # The attach path already holds this lock from admission; a launch takes it here.
  [ "$ATTACH" = 1 ] || publish_lock --must
  [ "$OUTCOME" != COMPLETED ] || [ -z "$SESSION_ID" ] || printf '%s\n' "$SESSION_ID" > "$DIR/.ccr-last-session"
  {
    echo "outcome=$OUTCOME"; echo "backend=ccr"; echo "alias=$ALIAS"; echo "detached=no"; echo "attached=${ATTEMPTS:-0}"
    [ -z "${IDENT_NOTE:-}" ] || echo "identity_note=$IDENT_NOTE"; echo "provider=$PROVIDER"; echo "provider_model=$PROVIDER_MODEL"
    echo "claude_model_id=$CLAUDE_MODEL"; echo "routed_model=${ROUTED_MODEL:-unknown}"; echo "route_identity=$ROUTE_OK"; echo "compatibility=$COMPAT"; echo "ccr_version=$CCR_VER"
    echo "pid=$CHILD"; echo "pgid=$PGID"; echo "child_exit=$CHILD_RC"; echo "thread=${SESSION_ID:-unknown}"
    echo "elapsed_sec=$(elapsed)"; echo "idle_at_end_sec=$IDLE"; echo "stall_min=$STALL_MIN max_min=$MAX_MIN"; echo "max_turns=$MAX_TURNS"
    echo "mode=$MODE"; [ "$MODE" != "--resume-session" ] || echo "resume_session=$RESUME_SESSION"; echo "prompt_file=$PROMPT_FILE"; echo "result_event=$(stream_field "$PREFIX.joblog" result-subtype)"
    echo "command=$CMD"; echo "stdout_bytes=$(wc -c < "$PREFIX.stdout" | tr -d ' ')"
    LASTERR=$(grep -E 'error|Error|exit status' "$PREFIX.stderr" | tail -1 | cut -c1-300)
    echo "last_error=${LAST_ERROR_OVERRIDE:-${LASTERR:-none}}"; echo "cancel_confirmed=$([ "$UNCONFIRMED_CANCEL" = 1 ] && echo no || echo "$([ "$OUTCOME" = STALLED ] && echo yes || echo n/a)")"
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
  echo "codex-run.sh: $OUTCOME backend=ccr alias=$ALIAS session=${SESSION_ID:-unknown} elapsed=$(elapsed)s stdout=$(wc -c < "$PREFIX.stdout" | tr -d ' ')B → $PREFIX.{stdout,progress,meta}"
  exit "$RC"
fi

# =============================================================================================
# codex backend (the Codex CLI plugin's companion)
# =============================================================================================
CODEX_ROOT=$(codex_root)
if [ -z "$CODEX_ROOT" ] || [ ! -f "$CODEX_ROOT/scripts/codex-companion.mjs" ]; then
  if [ "$ATTACH" = 1 ]; then
    # Not finding the companion says something about THIS process, not about the job it owns.
    # Publishing a terminal launch error would delete .detached and free the claim for a second
    # launch against a job that is still running (cycle 2: CX-06). Leave the attempt as found.
    echo "$(elapsed)s ATTACH: cannot locate the codex plugin; nothing was observed and the attempt stays open" >> "$PREFIX.progress"
    echo "codex-run.sh: --attach: cannot locate the codex plugin (installed_plugins.json or ~/.claude/plugins/cache/openai-codex/codex/*); job $JOB is untouched and still detached." >&2
    echo "  attach: ${ATTACH_CMD:-$0 $PREFIX --attach}"
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
  CMD=$(awk -F= '$1=="command"{sub(/^[^=]*=/,""); print; exit}' "$PREFIX.meta" 2>/dev/null)
  PROMPT_FILE=$(awk -F= '$1=="prompt_file"{sub(/^[^=]*=/,""); print; exit}' "$PREFIX.meta" 2>/dev/null)
  echo "$(elapsed)s attached job=$JOB" >> "$PREFIX.progress"
else
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
fi

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
      # As on the ccr backend: the bound is the watcher's, not the job's. The companion keeps
      # the job — it is already the durable owner — so detaching costs nothing and loses nothing.
      if [ "$(elapsed)" -ge $(( MAX_MIN * 60 )) ]; then OUTCOME=DETACHED; break; fi;;
    *) echo "$(elapsed)s unknown status '$STATUS'" >> "$PREFIX.progress";;
  esac
done

if [ "$OUTCOME" = "DETACHED" ]; then
  # The same rule as the ccr branch: on an attach every field below belongs to the LAUNCH and is
  # copied forward, never re-derived. PROMPT_FILE on an attach comes from .meta and may since have
  # been deleted, in which case re-deriving would replace the launch's prompt pin with an empty
  # one — the record would stop being the launch's own testimony (cycle 3: CL-07).
  if [ "$ATTACH" = 1 ]; then
    D_THREAD=$(detached_field thread); D_SHA=$(detached_field prompt_sha256); D_AT=$(detached_field detached_at)
    D_JOBLOG=$(detached_field joblog); D_WPID=$(detached_field worker_pid); D_WIDENT=$(detached_field worker_identity)
    ATTACH_CMD=$(detached_field attach_command); CANCEL_CMD=$(detached_field cancel_command)
  else
    D_THREAD=$(grep -oE 'Codex session ID: [0-9a-f-]+' "${LOGFILE:-/dev/null}" 2>/dev/null | head -1 | awk '{print $4}')
    D_SHA=$(prompt_digest "$PROMPT_FILE"); D_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ); D_JOBLOG="${LOGFILE:-}"
    # The worker pid the companion reports, with its identity, so a later launch can PROVE this
    # job is still running rather than assume it (cycle 3: CL-03/CX-02). The companion remains the
    # authority; this is the cheap local check, and `job=` is what a relaunch consults.
    D_WPID="${PID:-}"; D_WIDENT=$(proc_identity "${PID:-0}")
    ATTACH_CMD="$0 $PREFIX --attach --stall-min $STALL_MIN --max-min $MAX_MIN --poll-sec $POLL"
    CANCEL_CMD="node $CODEX_ROOT/scripts/codex-companion.mjs cancel $JOB"
  fi
  echo "$(elapsed)s DETACHED → watch bound reached with job $JOB still running; not cancelled" >> "$PREFIX.progress"
  {
    echo "outcome=DETACHED"; echo "backend=codex"; echo "job=$JOB"; echo "detached=yes"; echo "attached=${ATTEMPTS:-0}"
    echo "elapsed_sec=$(elapsed)"; echo "idle_at_end_sec=$IDLE"; echo "stall_min=$STALL_MIN max_min=$MAX_MIN"
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
detached_at=$D_AT
attach_command=$ATTACH_CMD
cancel_command=$CANCEL_CMD
EOD
  # NO .exit — see the ccr branch: a terminal sidecar would free the claim for a second launch.
  echo "codex-run.sh: DETACHED backend=codex job=$JOB elapsed=$(elapsed)s — the job is still running."
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
# An unconfirmed cancel has no final result eligible for a downstream gate. The
# raw job log is still preserved; do not let a late `result` look completed.
if [ "${UNCONFIRMED_CANCEL:-0}" = "1" ]; then : > "$PREFIX.stdout"
else cc result "$JOB" > "$PREFIX.stdout" 2>>"$PREFIX.stderr" || true
fi
[ -n "$LOGFILE" ] && [ -r "$LOGFILE" ] && cp "$LOGFILE" "$PREFIX.joblog" 2>/dev/null
THREAD=$(grep -oE 'Codex session ID: [0-9a-f-]+' "$PREFIX.stdout" | head -1 | awk '{print $4}')
# A resumed run must land in the thread it named. The companion offers no way to ask for a thread
# by id — --resume-last takes the newest eligible one — so the binding can only be checked after
# the fact, and a mismatch is reported rather than accepted: continuing someone else's thread is
# worse than starting a fresh, self-contained round.
THREAD_NOTE=""
if [ "$MODE" = "--resume-last" ] && [ "$OUTCOME" = COMPLETED ] && [ -n "$THREAD" ]; then
  WANT=$(awk -F= '$1=="thread"{print $2; exit}' "$PREFIX.detached" 2>/dev/null)
  [ -n "$WANT" ] || WANT=$(detached_field thread)
  if [ -n "$WANT" ] && [ "$WANT" != unknown ] && [ "$WANT" != "$THREAD" ]; then
    OUTCOME=FAILED
    THREAD_NOTE="resumed thread $THREAD is not the expected $WANT; the continuation is not this attempt's, so it is refused"
    echo "codex-run.sh: $THREAD_NOTE" >> "$PREFIX.stderr"
  fi
fi
[ "$ATTACH" = 1 ] || publish_lock --must
{
  echo "outcome=$OUTCOME"; echo "backend=codex"; echo "job=$JOB"; echo "thread=${THREAD:-unknown}"
  echo "detached=no"; echo "attached=${ATTEMPTS:-0}"; [ -z "$THREAD_NOTE" ] || echo "thread_note=$THREAD_NOTE"
  echo "elapsed_sec=$(elapsed)"; echo "idle_at_end_sec=$IDLE"; echo "stall_min=$STALL_MIN max_min=$MAX_MIN"
  echo "mode=$MODE"; echo "prompt_file=$PROMPT_FILE"; echo "command=$CMD"; echo "stdout_bytes=$(wc -c < "$PREFIX.stdout" | tr -d ' ')"
  LASTERR=""; [ -n "$LOGFILE" ] && [ -r "$LOGFILE" ] && LASTERR=$(grep -E "Codex error:|Turn failed" "$LOGFILE" | tail -1 | cut -c1-300)
  echo "last_error=${LASTERR:-none}"; echo "cancel_confirmed=$([ "${UNCONFIRMED_CANCEL:-0}" = "1" ] && echo no || echo "$([ "$OUTCOME" = "STALLED" ] && echo yes || echo n/a)")"
} > "$PREFIX.meta"
# TIMEOUT/3 is RETIRED here too — see the ccr branch.
case "$OUTCOME" in COMPLETED) RC=0;; FAILED) RC=1;; STALLED) RC=2;; TIMEOUT) RC=3;; DETACHED) RC=6;; *) RC=1;; esac
# An unconfirmed cancel outranks the outcome: 1, 2 and 3 all invite a retry or
# treat the job as finished, and neither is safe while a worker may be alive.
[ "${UNCONFIRMED_CANCEL:-0}" = "1" ] && RC=5
rm -f "$PREFIX.detached"
echo "$RC" > "$PREFIX.exit"
publish_unlock
echo "codex-run.sh: $OUTCOME job=$JOB elapsed=$(elapsed)s stdout=$(wc -c < "$PREFIX.stdout" | tr -d ' ')B → $PREFIX.{stdout,progress,meta}"
exit "$RC"
