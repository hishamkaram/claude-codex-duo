#!/bin/bash
# agent-watch.sh — supervise ONE asynchronous review unit.
#
#   agent-watch.sh <out-prefix> --expect <file> (--after <minutes> | --after-sec <seconds>) \
#                  [--label <name>] [--poll-sec <n>]
#
# Why this exists. The join turn launches units in the background and then waits. Before this
# script the only supervised unit was the Codex job, which has codex-run.sh's progress sidecar,
# stall window and deadline; a reviewer agent had none, so a reviewer blocked on an unanswered
# tool-approval prompt waited indefinitely — observed at 2 h 16 m, ended only by a human.
#
# ONE PROCESS, ONE VERDICT. A background job notifies its caller exactly once, when it exits. A
# watcher that exited to raise an advisory would therefore be dead before its own deadline, and
# could never raise it. So this script has a single deadline and a single terminal verdict, and
# the caller launches TWO of them per unit: an advisory watcher with a short --after and a
# deadline watcher with a long one. Do not add a second threshold here.
#
# --expect is REQUIRED, so every watcher has a success condition and can never outlive the work
# it watches. For a stage that produces no watchable file — a Workflow fan-out, whose agents
# return structured objects rather than writing files — the caller writes a sentinel
# (ART/.stage-<name>.done) the moment the stage returns, and the stage's watchers expect that.
#
# Writes: <out-prefix>.progress (one line per poll), <out-prefix>.exit (the exit code).
# Exit 0 the expected artifact appeared, non-empty, before the deadline (WATCH-OK)
#      3 the deadline passed and it had not (WATCH-OVERDUE) — the caller decides what that means
#      2 usage error
# This script never cancels, kills or writes anything outside its own two sidecars. Acting on a
# verdict is the caller's job: an advisory verdict is advisory, and a deadline verdict requires an
# acknowledged stop before any fallback writes the artifact this watcher was waiting for.
set -u
USAGE='usage: agent-watch.sh <out-prefix> --expect <file> (--after <minutes> | --after-sec <seconds>) [--label <name>] [--poll-sec <n>]'
die2() { echo "agent-watch.sh: $1" >&2; echo "$USAGE" >&2; exit 2; }
need() { [ $# -ge 2 ] || die2 "$1 requires a value"; case "$2" in -*) die2 "$1 requires a value (got option $2)";; esac; }

case "${1:-}" in
  "" ) die2 "an out-prefix is required";;
  -* ) die2 "the first argument must be an out-prefix, not an option";;
esac
PREFIX="$1"; shift
EXPECT=""; AFTER_SEC=""; LABEL=""; POLL=15
while [ $# -gt 0 ]; do
  case "$1" in
    --expect)    need "$@"; EXPECT="$2";;
    --after)     need "$@"; AFTER_MIN="$2";;
    --after-sec) need "$@"; AFTER_SEC="$2";;
    --label)     need "$@"; LABEL="$2";;
    --poll-sec)  need "$@"; POLL="$2";;
    *) die2 "unknown arg $1";;
  esac
  shift 2
done

# Whole numbers only, and normalised before any arithmetic: "08" passes a digit test but aborts
# bash arithmetic as invalid octal (the defect the 1.0.2 debate found in the runner).
num() {
  local name="$1" val="$2"
  case "$val" in *[!0-9]*|"") die2 "$name requires a whole number (got '$val')";; esac
  val=$(printf '%s' "$val" | sed 's/^0*//'); [ -n "$val" ] || val=0
  [ "${#val}" -le 6 ] || die2 "$name is too large"
  printf '%s' "$val"
}
[ -n "$EXPECT" ] || die2 "--expect is required: a watcher without a success condition can outlive the work it watches"
if [ -n "${AFTER_MIN:-}" ]; then
  [ -z "$AFTER_SEC" ] || die2 "--after and --after-sec are alternatives; give one"
  AFTER_SEC=$(( $(num --after "$AFTER_MIN") * 60 ))
elif [ -n "$AFTER_SEC" ]; then
  AFTER_SEC=$(num --after-sec "$AFTER_SEC")
else
  die2 "a deadline is required: give --after <minutes> or --after-sec <seconds>"
fi
[ "$AFTER_SEC" -gt 0 ] || die2 "the deadline must be greater than zero"
POLL=$(num --poll-sec "$POLL"); [ "$POLL" -gt 0 ] || POLL=1

mkdir -p "$(dirname "$PREFIX")" 2>/dev/null
: > "$PREFIX.progress" || die2 "cannot write $PREFIX.progress"
START=$(date +%s)
elapsed() { echo $(( $(date +%s) - START )); }
say() { echo "$1" >> "$PREFIX.progress"; }
finish() { echo "$1" > "$PREFIX.exit"; exit "$1"; }

# Non-empty, because an artifact that exists but is empty is not yet an artifact: the lead writes
# its file in one write, and the join gate refuses an empty one.
arrived() { [ -s "$EXPECT" ]; }

say "0s launched label=${LABEL:-unnamed} expect=$EXPECT deadline=${AFTER_SEC}s poll=${POLL}s"
while :; do
  if arrived; then
    say "$(elapsed)s status=arrived expect=$EXPECT"
    echo "WATCH-OK label=${LABEL:-unnamed} elapsed=$(elapsed)s expect=$EXPECT"
    finish 0
  fi
  if [ "$(elapsed)" -ge "$AFTER_SEC" ]; then
    say "$(elapsed)s status=overdue expect=$EXPECT"
    echo "WATCH-OVERDUE label=${LABEL:-unnamed} elapsed=$(elapsed)s deadline=${AFTER_SEC}s expect=$EXPECT"
    finish 3
  fi
  sleep "$POLL"
  say "$(elapsed)s status=waiting expect=$EXPECT"
done
