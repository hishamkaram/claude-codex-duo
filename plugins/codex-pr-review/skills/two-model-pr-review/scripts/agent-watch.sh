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
# ARRIVAL IS NOT COMPLETION. A file that exists and is non-empty is not necessarily a finished
# one: a producer that creates its output early — a placeholder, a heading, an incremental draft —
# satisfies a bare existence test the moment it starts, so both watchers exit 0 within seconds and
# supervise nothing. That is worse than no watcher, because the operator learns to ignore a signal
# that is always green. Hence --expect-mode: the lead's terminal act is `chmod 000`, which is also
# how the join gate defines a finished lead review, so `--expect-mode 000` tests COMPLETION rather
# than arrival. It is the only predicate available once the file is sealed — stat still works on a
# mode-000 file while reading its bytes does not. The producer must also publish atomically
# (write .part, seal, rename), so the path never resolves to a half-written file at all.
#
# Writes: <out-prefix>.progress (one line per poll), <out-prefix>.exit (the exit code).
# Exit 0 the expected artifact appeared, non-empty, before the deadline (WATCH-OK)
#      3 the deadline passed and it had not (WATCH-OVERDUE) — the caller decides what that means
#      2 usage error
# This script never cancels, kills or writes anything outside its own two sidecars. Acting on a
# verdict is the caller's job: an advisory verdict is advisory, and a deadline verdict requires an
# acknowledged stop before anything else touches the artifact this watcher was waiting for. A
# deadline is not proof of death — only of silence — so the caller stops the unit, confirms the
# stop, and records the run as INCOMPLETE, preserving whatever partial result exists. It does not
# start a replacement worker: at the measured p95 a lead review that merely ran long would cost a
# second full review, and an unconfirmed stop plus a fallback would race two writers onto one file.
set -u
USAGE='usage: agent-watch.sh <out-prefix> --expect <file> (--after <minutes> | --after-sec <seconds>) [--expect-mode <octal>] [--label <name>] [--poll-sec <n>]'
die2() { echo "agent-watch.sh: $1" >&2; echo "$USAGE" >&2; exit 2; }
need() { [ $# -ge 2 ] || die2 "$1 requires a value"; case "$2" in -*) die2 "$1 requires a value (got option $2)";; esac; }

case "${1:-}" in
  "" ) die2 "an out-prefix is required";;
  -* ) die2 "the first argument must be an out-prefix, not an option";;
esac
PREFIX="$1"; shift
EXPECT=""; AFTER_SEC=""; LABEL=""; POLL=15; EXPECT_MODE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --expect)      need "$@"; EXPECT="$2";;
    --after)       need "$@"; AFTER_MIN="$2";;
    --after-sec)   need "$@"; AFTER_SEC="$2";;
    --expect-mode) need "$@"; EXPECT_MODE="$2";;
    --label)       need "$@"; LABEL="$2";;
    --poll-sec)    need "$@"; POLL="$2";;
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
# A permission mode is three octal digits and is NOT a number: num() strips leading zeros, which
# would turn the mode 000 we actually wait for into "0" and 040 into "40". Validate it as a
# literal instead, and compare it the same way stat renders it (see mode() below).
if [ -n "$EXPECT_MODE" ]; then
  case "$EXPECT_MODE" in
    [0-7][0-7][0-7]) ;;
    *) die2 "--expect-mode requires three octal digits (got '$EXPECT_MODE')";;
  esac
fi
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

# stat, portable: GNU (-c) on Linux, BSD (-f) on macOS. Both print a mode-000 file as "0", so
# compare on the leading-zero-stripped form rather than the literal the caller passed.
if stat --version >/dev/null 2>&1; then mode() { stat -c '%a' "$1" 2>/dev/null; }
else mode() { stat -f '%Lp' "$1" 2>/dev/null; }; fi
# "000" strips to the empty string, which would never equal stat's "0" — restore the zero, as num() does.
WANT_MODE=$(printf '%s' "${EXPECT_MODE:-}" | sed 's/^0*//'); [ -n "$EXPECT_MODE" ] && [ -z "$WANT_MODE" ] && WANT_MODE=0

# Non-empty, because an artifact that exists but is empty is not yet an artifact: the join gate
# refuses an empty one. With --expect-mode the artifact must ALSO carry that mode, which is what
# makes this a completion test rather than an arrival test — see the header. A mode mismatch is
# "not finished yet", never a distinct verdict: the watcher keeps waiting and the deadline decides,
# so the documented 0/2/3 exit contract is unchanged.
arrived() {
  [ -s "$EXPECT" ] || return 1
  [ -z "$EXPECT_MODE" ] && return 0
  [ "$(mode "$EXPECT")" = "$WANT_MODE" ]
}

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
