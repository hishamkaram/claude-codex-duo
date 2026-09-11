#!/bin/bash
# implement-run.sh — the WRITE-CAPABLE implementer: run an approved plan through the ccr gateway
# on a new branch in a git worktree, monitor it, return its result.
#
# This is deliberately a different script from codex-run.sh. The review runner is read-only and
# refuses --write; this launcher is the one place in the plugin that hands a model
# `--permission-mode acceptEdits`, and it does so only inside a worktree it created for the
# purpose. Nothing here is sourced from the runner: the shared helpers are copied, so each
# script stays self-contained and scripts/validate.sh can check that no runner copy carries a
# write mode (check 13).
#
# Usage:
#   implement-run.sh <out-prefix> --via ccr:<alias> --repo <path> --base <sha> --branch <name> --plan <PLAN.md>
#                    [--test-cmd "<command>"]... [--stall-min 15] [--max-min 90] [--poll-sec 15] [--max-turns 200]
#
#   Write mode is ccr-only: any other --via exits 4. The worktree is <out-dir>/worktree (out-dir =
#   the directory of <out-prefix>), created with `git worktree add -b <branch> <base>`; the user's
#   checkout, index and refs are untouched — the branch is the deliverable. The worktree is never
#   removed by this script (the user decides: `git -C <repo> worktree remove <path>`).
#
# Writes (same names and meaning as the runner, plus three):
#   <out-prefix>.progress .stdout .stderr .joblog .meta .exit   (exit 0-5 as the runner)
#   <out-prefix>.brief.md      the brief the model executed (fixed header + the plan verbatim)
#   <out-prefix>.plan.sha256   sha256 of that brief (what was implemented, exactly)
#   <out-prefix>.worktree      absolute worktree path
#   <out-prefix>.diff          working tree against the base (committed and uncommitted; intent-to-add makes untracked files visible)
#
# Exit 4 for every argument error and every launch precondition (ccr missing, version, alias,
# branch or worktree already present); 1 child failed; 2 stalled; 3 timeout; 5 cancel unconfirmed.

set -u
CCR_MIN_VERSION="0.4.11"
USAGE='usage: implement-run.sh <out-prefix> --via ccr:<alias> --repo <path> --base <sha> --branch <name> --plan <PLAN.md> [--test-cmd "<cmd>"]... [--stall-min N] [--max-min M] [--poll-sec S] [--max-turns N]'
PREFIX="${1:-}"
case "$PREFIX" in ""|-*) echo "implement-run.sh: first argument must be an out-prefix path" >&2; echo "$USAGE" >&2; exit 4;; esac
shift
die4() { echo "implement-run.sh: $1" >&2; echo "$USAGE" >&2; echo 4 > "$PREFIX.exit" 2>/dev/null || true; exit 4; }
need() { [ $# -ge 2 ] || die4 "$1 requires a value"; case "$2" in -*) die4 "$1 requires a value (got option $2)";; esac; }
VIA=""; REPO=""; BASE=""; BRANCH=""; PLAN=""; TEST_CMDS=(); STALL_MIN=15; MAX_MIN=90; POLL=15; MAX_TURNS=200
while [ $# -gt 0 ]; do
  case "$1" in
    --via) need "$@"; VIA="$2"; shift;;
    --repo) need "$@"; REPO="$2"; shift;;
    --base) need "$@"; BASE="$2"; shift;;
    --branch) need "$@"; BRANCH="$2"; shift;;
    --plan) need "$@"; PLAN="$2"; shift;;
    --test-cmd) need "$@"; TEST_CMDS+=("$2"); shift;;
    --stall-min) need "$@"; STALL_MIN="$2"; shift;;
    --max-min) need "$@"; MAX_MIN="$2"; shift;;
    --poll-sec) need "$@"; POLL="$2"; shift;;
    --max-turns) need "$@"; MAX_TURNS="$2"; shift;;
    *) die4 "unknown arg $1";;
  esac; shift
done
case "$VIA" in
  ccr:?*) ALIAS="${VIA#ccr:}"; case "$ALIAS" in *[!A-Za-z0-9._-]*) die4 "--via ccr:<alias>: alias may contain only letters, digits, '.', '_' and '-' (got '$ALIAS')";; esac;;
  "") die4 "--via ccr:<alias> is required (write mode is ccr-only)";;
  *) die4 "write mode is ccr-only: --via must be ccr:<alias> (got '$VIA')";;
esac
[ -n "$REPO" ] || die4 "--repo is required"; [ -n "$BASE" ] || die4 "--base is required"
[ -n "$BRANCH" ] || die4 "--branch is required"; [ -n "$PLAN" ] || die4 "--plan is required"
[ -r "$PLAN" ] || die4 "plan file not readable: $PLAN"
case "$BRANCH" in *[!A-Za-z0-9._/-]*|-*|*/|*..*) die4 "--branch: not a safe branch name (got '$BRANCH')";; esac
for v in STALL_MIN MAX_MIN POLL MAX_TURNS; do
  eval "val=\$$v"
  case "$val" in ''|*[!0-9]*) die4 "--$(echo "$v" | tr 'A-Z_' 'a-z-') requires a whole number (got '$val')";; esac
  val=$(printf '%s' "$val" | sed 's/^0*//'); [ -n "$val" ] && [ "${#val}" -le 6 ] || die4 "--$(echo "$v" | tr 'A-Z_' 'a-z-') must be between 1 and 999999"
  eval "$v=\$val"
done
git -C "$REPO" rev-parse --show-toplevel >/dev/null 2>&1 || die4 "--repo is not a git repository: $REPO"
BASE_SHA=$(git -C "$REPO" rev-parse --verify --quiet "$BASE^{commit}") || die4 "--base does not name a commit in $REPO: $BASE"
DIR=$(dirname "$PREFIX"); mkdir -p "$DIR" 2>/dev/null || die4 "cannot create $DIR"
WT="$DIR/worktree"
[ ! -e "$WT" ] || die4 "worktree path already exists: $WT (finish or remove that implementation first)"
! git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH" || die4 "branch already exists: $BRANCH"

# --- copied helpers (kept identical in spirit to codex-run.sh; not sourced on purpose) ----------
if stat --version >/dev/null 2>&1; then fsig() { stat -c '%s:%Y' "$1" 2>/dev/null; }; else fsig() { stat -f '%z:%m' "$1" 2>/dev/null; }; fi
ccr_version() { ccr version 2>/dev/null | head -1 | sed -nE 's/^ccr[[:space:]]+v?([0-9]+\.[0-9]+\.[0-9]+).*$/\1/p'; }
version_ge() { python3 -c 'import sys
a=[int(x) for x in sys.argv[1].split(".")]; b=[int(x) for x in sys.argv[2].split(".")]
raise SystemExit(0 if a>=b else 1)' "$1" "$2"; }
ccr_model_field() { printf '%s' "$1" | python3 -c 'import sys,json
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
    v=d.get(f); print("" if v is None else v)' "$2" 2>/dev/null; }
start_in_own_group() { exec python3 -c 'import os,sys; os.setpgrp(); os.execvp(sys.argv[1], sys.argv[1:])' "$@"; }
pgid_of() { ps -o pgid= -p "$1" 2>/dev/null | tr -d ' '; }
# THE ONLY GATE THROUGH WHICH THIS SCRIPT MAY SIGNAL A PROCESS GROUP. `kill -- "-N"` gives two
# values of N a session-wide meaning: 1 is EVERY process the user may signal (on macOS the whole
# login session, loginwindow included), and 0 is the SENDER's own process group (the invoking
# shell and its sibling jobs). A group number is therefore a legal target only when it is a
# plausible group id AND still the process group of the pid this script recorded. Anything else
# refuses and signals nothing. Kept identical in wording and behaviour to codex-run.sh.
pgid_is_signalable() {  # <pgid> [owner-pid]
  local pg="$1" owner="${2:-}" self
  case "$pg" in ''|*[!0-9]*) return 1;; esac
  [ "$pg" -ge 2 ] 2>/dev/null || return 1
  [ "$pg" != "$$" ] || return 1
  self=$(pgid_of "$$"); [ -z "$self" ] || [ "$pg" != "$self" ] || return 1
  if [ -n "$owner" ]; then
    case "$owner" in ''|*[!0-9]*) return 1;; esac
    [ "$(pgid_of "$owner")" = "$pg" ] || return 1
  fi
  return 0
}
group_alive() {  # <pgid> [owner-pid]
  pgid_is_signalable "$1" "${2:-}" || return 1
  kill -0 -- "-$1" 2>/dev/null
}
# Fails closed: an unverified target returns 1 (cancel not confirmed) having signalled nothing.
kill_group() { local i owner="${2:-}"
  pgid_is_signalable "$1" "$owner" || { echo "implement-run.sh: REFUSING to signal process group '${1:-<empty>}' — it is not a verified job group. Nothing was signalled." >&2; return 1; }
  kill -TERM -- "-$1" 2>/dev/null || true
  for i in 1 2 3 4 5; do group_alive "$1" || return 0; sleep 1; done
  kill -KILL -- "-$1" 2>/dev/null || true
  for i in 1 2 3 4 5; do group_alive "$1" || return 0; sleep 1; done; return 1; }
stream_field() { python3 - "$1" "$2" <<'PY' 2>/dev/null
import sys,json
path,what=sys.argv[1],sys.argv[2]; sid=""; res=None
for line in open(path,encoding="utf-8",errors="replace"):
    line=line.strip()
    if not line.startswith("{"): continue
    try: e=json.loads(line)
    except Exception: continue
    if e.get("type")=="system" and e.get("subtype")=="init": sid=sid or e.get("session_id","") or ""
    if e.get("type")=="result": res=e
if what=="init-session": print(sid)
elif what=="has-result": print("yes" if res is not None else "no")
elif what=="result-ok": print("yes" if res is not None and not res.get("is_error") and res.get("subtype","success")=="success" else "no")
elif what=="result-subtype": print("" if res is None else "%s is_error=%s" % (res.get("subtype","success"), bool(res.get("is_error"))))
elif what=="result-text":
    if res is not None:
        r=res.get("result"); r="" if r is None else r
        sys.stdout.write(r if isinstance(r,str) else json.dumps(r))
PY
}
launch_error() { echo "implement-run.sh: $1" >&2; printf 'LAUNCH-ERROR\n%s\n' "$1" > "$PREFIX.stderr"; printf '0s LAUNCH-ERROR: %s\n' "$1" > "$PREFIX.progress"
  printf 'outcome=LAUNCH-ERROR\nbackend=ccr\nmode=implement\nlast_error=%s\n' "$1" > "$PREFIX.meta"; echo 4 > "$PREFIX.exit"; exit 4; }

# --- preconditions --------------------------------------------------------------------------
command -v ccr >/dev/null 2>&1 || launch_error "ccr not found on PATH (install claude-code-router >= $CCR_MIN_VERSION)"
CCR_VER=$(ccr_version); [ -n "$CCR_VER" ] || launch_error "cannot parse 'ccr version' output"
version_ge "$CCR_VER" "$CCR_MIN_VERSION" || launch_error "requires ccr >= $CCR_MIN_VERSION (found $CCR_VER)"
MODEL_JSON=$(ccr model show "$ALIAS" --json 2>/dev/null) && [ -n "$MODEL_JSON" ] || launch_error "ccr model show $ALIAS --json failed (unknown alias on this machine?)"
PROVIDER=$(ccr_model_field "$MODEL_JSON" provider); PROVIDER_MODEL=$(ccr_model_field "$MODEL_JSON" provider_model); TOOLS=$(ccr_model_field "$MODEL_JSON" tools)
[ "$TOOLS" = true ] || launch_error "alias $ALIAS reports supports_tools=$TOOLS; an implementer needs tool calls"
START=$(date +%s); now() { date +%s; }; elapsed() { echo $(( $(now) - START )); }

# --- worktree + brief ------------------------------------------------------------------------
git -C "$REPO" worktree add "$WT" -b "$BRANCH" "$BASE_SHA" > "$PREFIX.stderr" 2>&1 || { echo "implement-run.sh: git worktree add failed:" >&2; cat "$PREFIX.stderr" >&2; printf 'outcome=LAUNCH-ERROR\nbackend=ccr\nmode=implement\nlast_error=git worktree add failed\n' > "$PREFIX.meta"; echo 4 > "$PREFIX.exit"; exit 4; }
WT=$(cd "$WT" && pwd -P); printf '%s\n' "$WT" > "$PREFIX.worktree"
{
  echo "# Implementation brief"
  echo
  echo "You are implementing an approved plan. Work ONLY inside the repository at $WT, which is a git"
  echo "worktree checked out on branch \`$BRANCH\` at commit $BASE_SHA. Do not touch any other path,"
  echo "do not change branches, do not push. Make the changes the plan describes, run the tests it names,"
  echo "and commit on this branch in small commits with clear messages (one commit per plan group is fine)."
  echo "When every test passes, reply with a short summary: the commits you made (\`git log --oneline\`), what"
  echo "you could not do and why, and any deviation from the plan. If a step is impossible, say so instead of"
  echo "working around it silently."
  if [ ${#TEST_CMDS[@]} -gt 0 ]; then echo; echo "Test commands to run from $WT before finishing:"; for c in "${TEST_CMDS[@]}"; do echo "- \`$c\`"; done; fi
  echo; echo "----- PLAN (verbatim) -----"; echo
  cat "$PLAN"
} > "$PREFIX.brief.md"
shasum -a 256 "$PREFIX.brief.md" | cut -d' ' -f1 > "$PREFIX.plan.sha256"

# --- launch ----------------------------------------------------------------------------------
# acceptEdits auto-approves file edits inside the worktree only; every Bash command still needs a
# permission the headless session cannot ask for (verified live: git commit and test commands are
# denied). The launcher therefore pre-allows the git subcommands the brief asks for and each
# --test-cmd as a WHOLE command (leading NAME=value words dropped), and commits whatever the child
# leaves uncommitted (review round 1: F-17). Never the interpreter alone: a rule such as
# Bash(python3:*) is unrestricted shell — a python3 -c write outside the worktree was observed live
# (review round 2: F-02). A test command still runs repository code, which no rule path-bounds.
ALLOWED=("Bash(git add:*)" "Bash(git commit:*)" "Bash(git status:*)" "Bash(git diff:*)" "Bash(git log:*)" "Bash(git show:*)" "Bash(git rev-parse:*)")
test_rule() {  # test_rule "<cmd>": the command with leading environment assignments removed, or nothing
  local cmd; cmd=$(printf '%s' "$1" | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//; s/[[:space:]]+$//')
  case "$cmd" in ""|*[!A-Za-z0-9_./=@:+,\ -]*) return 1;; esac   # a rule needs a plain command line: words of letters, digits, _ . / = @ : + , - (no shell metacharacters, no quotes)
  printf '%s\n' "$cmd"
}
for c in ${TEST_CMDS[@]+"${TEST_CMDS[@]}"}; do
  rule=$(test_rule "$c") || { echo "implement-run.sh: --test-cmd '$c' cannot be pre-allowed (empty after environment assignments, or contains shell metacharacters); the child will have to ask, which it cannot — pick a plain command" >&2; continue; }
  ALLOWED+=("Bash($rule)" "Bash($rule:*)")
done
ARGV=(ccr launch --model "$ALIAS" --permission-mode acceptEdits -p --no-lifecycle --no-statusline -- \
      --output-format stream-json --verbose --strict-mcp-config --mcp-config '{"mcpServers":{}}' --max-turns "$MAX_TURNS" --allowedTools "${ALLOWED[@]}")
CMD="ccr launch --model $ALIAS --permission-mode acceptEdits -p ... --max-turns $MAX_TURNS (cwd=$WT)"
: > "$PREFIX.progress"; : > "$PREFIX.joblog"
( cd "$WT" && start_in_own_group "${ARGV[@]}" ) < "$PREFIX.brief.md" > "$PREFIX.joblog" 2>> "$PREFIX.stderr" &
CHILD=$!
sleep 1
PGID=$(pgid_of "$CHILD")
if [ "$PGID" != "$CHILD" ]; then
  if kill -0 "$CHILD" 2>/dev/null; then
    pgid_is_signalable "$CHILD" "$CHILD" && kill -KILL -- "-$CHILD" 2>/dev/null   # pgid == pid by construction, verified
    kill -KILL "$CHILD" 2>/dev/null; wait "$CHILD" 2>/dev/null
    echo "$(elapsed)s LAUNCH: process group of pid $CHILD could not be read (got '$PGID'); child killed" >> "$PREFIX.progress"
    printf 'outcome=UNCONFIRMED-CANCEL\nbackend=ccr\nmode=implement\nalias=%s\npid=%s\npgid=unknown\nbranch=%s\nworktree=%s\nlast_error=process group unreadable\ncancel_confirmed=no\n' "$ALIAS" "$CHILD" "$BRANCH" "$WT" > "$PREFIX.meta"
    : > "$PREFIX.stdout"; echo 5 > "$PREFIX.exit"; echo "implement-run.sh: process group unreadable; child killed (exit 5)" >&2; exit 5
  fi
  PGID="$CHILD"
fi
echo "$(elapsed)s launched backend=ccr pid=$CHILD pgid=$PGID alias=$ALIAS mode=implement branch=$BRANCH" >> "$PREFIX.progress"

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
  if kill_group "$PGID" "$CHILD"; then echo "$(elapsed)s $OUTCOME → process group $PGID terminated (confirmed: no member left)" >> "$PREFIX.progress"
  else UNCONFIRMED_CANCEL=1; echo "$(elapsed)s $OUTCOME → cancel of process group $PGID NOT confirmed; a process may still be running" >> "$PREFIX.progress"
    echo "implement-run.sh: cancel of process group $PGID not confirmed; DO NOT retry — check with: ps -o pid,pgid,command -g $PGID" >&2; fi
fi
if [ "$UNCONFIRMED_CANCEL" = 1 ]; then
  # The child may still edit the worktree. Do not wait indefinitely, parse a
  # changing result, or stage/commit its files while cancellation is unresolved.
  printf 'outcome=UNCONFIRMED-CANCEL\nbackend=ccr\nmode=implement\nalias=%s\npid=%s\npgid=%s\nbranch=%s\nworktree=%s\nchild_exit=unknown\nlauncher_commit=not_attempted\ncancel_confirmed=no\n' "$ALIAS" "$CHILD" "$PGID" "$BRANCH" "$WT" > "$PREFIX.meta"
  : > "$PREFIX.stdout"
  echo 5 > "$PREFIX.exit"
  exit 5
fi
wait "$CHILD" 2>/dev/null; CHILD_RC=$?
SESSION_ID=$(stream_field "$PREFIX.joblog" init-session); HAS_RESULT=$(stream_field "$PREFIX.joblog" has-result)
stream_field "$PREFIX.joblog" result-text > "$PREFIX.stdout"
if [ "$OUTCOME" = EXITED ]; then if [ "$CHILD_RC" = 0 ] && [ "$HAS_RESULT" = yes ] && [ "$(stream_field "$PREFIX.joblog" result-ok)" = yes ]; then OUTCOME=COMPLETED; else OUTCOME=FAILED; fi; fi
# Whatever the child left uncommitted is committed by the launcher, so the branch is the deliverable
# even when the child could not run git; the sidecar records how many paths that was.
LEFT=$(git -C "$WT" --no-optional-locks status --porcelain=v1 --untracked-files=all 2>/dev/null | wc -l | tr -d ' ')
LAUNCHER_COMMIT=none; LAUNCHER_COMMITTED=0
if [ "$LEFT" != 0 ]; then
  if git -C "$WT" add -A >>"$PREFIX.stderr" 2>&1 && git -C "$WT" -c user.name="implement-run.sh" -c user.email="implement-run@localhost" commit -q -m "implement: uncommitted work left by the implementer ($LEFT paths; plan $(cat "$PREFIX.plan.sha256" | cut -c1-12))" >>"$PREFIX.stderr" 2>&1; then
    LAUNCHER_COMMIT=ok; LAUNCHER_COMMITTED=$LEFT; echo "$(elapsed)s launcher committed $LEFT uncommitted path(s)" >> "$PREFIX.progress"
  else
    # The branch is the deliverable: a recovery commit that fails (hook, signing, lock) means the
    # branch lacks the child's work, so the run fails even if the child completed (review round 2: F-01).
    LAUNCHER_COMMIT=failed; echo "$(elapsed)s launcher could not commit $LEFT uncommitted path(s); the run is FAILED" >> "$PREFIX.progress"
    [ "$OUTCOME" != COMPLETED ] || OUTCOME=FAILED
  fi
fi
# .diff shows the branch against the base INCLUDING anything still uncommitted (intent-to-add makes
# untracked files visible), so the work is inspectable whether or not the commit succeeded.
# If intent-to-add fails (index lock), untracked files would be omitted — fail the run (review round 3: F-03).
if git -C "$WT" add -N -A >>"$PREFIX.stderr" 2>&1; then
  git -C "$WT" diff "$BASE_SHA" > "$PREFIX.diff" 2>>"$PREFIX.stderr" || true
  git -C "$WT" reset -q >>"$PREFIX.stderr" 2>&1 || true
else
  echo "$(elapsed)s intent-to-add for .diff failed; untracked work would be omitted — the run is FAILED" >> "$PREFIX.progress"
  git -C "$WT" --no-optional-locks status --porcelain=v1 --untracked-files=all > "$PREFIX.diff" 2>>"$PREFIX.stderr" || true
  [ "$OUTCOME" != COMPLETED ] || OUTCOME=FAILED
fi
COMMITS=$(git -C "$WT" rev-list --count "$BASE_SHA"..HEAD 2>/dev/null || echo 0)
DIRTY=$(git -C "$WT" --no-optional-locks status --porcelain=v1 --untracked-files=all 2>/dev/null | wc -l | tr -d ' ')
{
  echo "outcome=$OUTCOME"; echo "backend=ccr"; echo "mode=implement"; echo "alias=$ALIAS"; echo "provider=$PROVIDER"; echo "provider_model=$PROVIDER_MODEL"; echo "ccr_version=$CCR_VER"
  echo "pid=$CHILD"; echo "pgid=$PGID"; echo "child_exit=$CHILD_RC"; echo "thread=${SESSION_ID:-unknown}"
  echo "repo=$REPO"; echo "base=$BASE_SHA"; echo "branch=$BRANCH"; echo "worktree=$WT"; echo "commits=$COMMITS"; echo "launcher_commit=$LAUNCHER_COMMIT"; echo "launcher_committed_paths=$LAUNCHER_COMMITTED"; echo "uncommitted_paths=$DIRTY"; echo "result_event=$(stream_field "$PREFIX.joblog" result-subtype)"
  echo "plan_sha256=$(cat "$PREFIX.plan.sha256")"; echo "elapsed_sec=$(elapsed)"; echo "idle_at_end_sec=$IDLE"; echo "stall_min=$STALL_MIN max_min=$MAX_MIN"; echo "max_turns=$MAX_TURNS"
  echo "command=$CMD"; echo "stdout_bytes=$(wc -c < "$PREFIX.stdout" | tr -d ' ')"
  LASTERR=$(grep -E 'error|Error|exit status' "$PREFIX.stderr" | tail -1 | cut -c1-300); echo "last_error=${LASTERR:-none}"
  echo "cancel_confirmed=$([ "$UNCONFIRMED_CANCEL" = 1 ] && echo no || echo "$([ "$OUTCOME" = STALLED ] || [ "$OUTCOME" = TIMEOUT ] && echo yes || echo n/a)")"
} > "$PREFIX.meta"
case "$OUTCOME" in COMPLETED) RC=0;; FAILED) RC=1;; STALLED) RC=2;; TIMEOUT) RC=3;; *) RC=1;; esac
[ "$UNCONFIRMED_CANCEL" = 1 ] && RC=5
echo "$RC" > "$PREFIX.exit"
echo "implement-run.sh: $OUTCOME alias=$ALIAS branch=$BRANCH commits=$COMMITS uncommitted=$DIRTY worktree=$WT elapsed=$(elapsed)s → $PREFIX.{stdout,diff,progress,meta}"
exit "$RC"
