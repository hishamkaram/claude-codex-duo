#!/bin/bash
# test-args.sh — executed regression test for command-line handling.
# Guards the defect found in the 1.0.2 debate: value-taking options dereferenced
# "$2" under `set -u`, so a missing operand produced a raw "unbound variable"
# abort with exit 1 — the code the protocol reserves for "Codex failed, retry".
# Contract: runner invocation errors exit 4 (LAUNCH-ERROR); builder usage errors
# exit 2. Runs on macOS and Linux; needs no Codex, no network.
set -uo pipefail
cd "$(dirname "$0")/.."
B=plugins/codex-pr-review/skills/two-model-pr-review/scripts/build-brief.sh
R=plugins/codex-pr-review/scripts/codex-run.sh
D=plugins/codex-debate/scripts/codex-run.sh
P=plugins/codex-deep-plan/scripts/codex-run.sh
DS=plugins/codex-deep-plan/skills/deep-plan-duo/scripts
FAIL=0
# The gate counts launches by runner-taken claims and refuses sidecars without
# one (round-32 debate). Fixtures below write attempt sidecars directly, so a
# gate call through pgw first tops up runner-taken spent claims to the number of
# sidecar slots — exactly what a real launch through the runner leaves behind.
# Tests of the invariant itself call "$PG" directly.
top_up_claims() {
  local dir="$1" prefix f slots taken n d
  for prefix in 02-codex 04-consultation 06-resolution; do
    slots=0; taken=0
    for f in "$dir/$prefix".meta "$dir/$prefix".exit "$dir/$prefix".progress "$dir/$prefix".attempt*.meta "$dir/$prefix".attempt*.exit "$dir/$prefix".attempt*.progress; do [ -e "$f" ] && printf '%s\n' "${f%.*}"; done > "$TMP/.slots"
    slots=$(sort -u "$TMP/.slots" | grep -c . || true)
    for d in "$dir/$prefix.claim" "$dir/$prefix".claim.spent*; do [ -d "$d/runner" ] && taken=$((taken+1)); done
    while [ "$taken" -lt "$slots" ]; do
      n=1; while [ -e "$dir/$prefix.claim.spent$n" ]; do n=$((n+1)); done
      mkdir -p "$dir/$prefix.claim.spent$n/runner"; taken=$((taken+1))
    done
  done
}
fixture_revs() {  # what build-brief.sh (.base/.head) and pre-codex (00-repo.txt) record in a real run
  [ -e "$1/00-brief.md.repo" ] || (cd "$G2" && pwd -P) > "$1/00-brief.md.repo"
  [ -e "$1/00-brief.md.base" ] || printf '%s\n' "$SHA2" > "$1/00-brief.md.base"
  [ -e "$1/00-brief.md.head" ] || printf '%s\n' "$SHA2" > "$1/00-brief.md.head"
  [ -e "$1/00-repo.txt" ] || printf 'repo=%s\nbase=%s\nhead=%s\n' "$(cd "$G2" && pwd -P)" "$SHA2" "$SHA2" > "$1/00-repo.txt"
}
mkbrief() {  # a brief whose Target section restates fixture_revs: the gate pins 00-repo.txt to it (round-38 CX-02)
  printf -- '- Repository: %s\n- Head: `HEAD` (%s)\n- Base: `HEAD` (%s)\nbrief\n' "$(cd "$G2" && pwd -P)" "$SHA2" "$SHA2" > "$1/00-brief.md"
}
# File mode, portable: GNU stat (-c) on Linux, BSD stat (-f) on macOS — the same detection phase-gate.sh uses.
if stat --version >/dev/null 2>&1; then fmode() { stat -c %a "$1" 2>/dev/null; }; else fmode() { stat -f %Lp "$1" 2>/dev/null; }; fi
pgw() { [ -d "${2:-}" ] && { top_up_claims "$2"; fixture_revs "$2"; }; bash "$PG" "$@"; }
pgwg() { local g="$1"; shift; [ -d "${2:-}" ] && { top_up_claims "$2"; fixture_revs "$2"; }; PHASE_GATE_CLAIM_GRACE_SEC="$g" bash "$PG" "$@"; }
chk() {
  local n="$1" e="$2" sub="$3"; shift 3
  local out code; out=$("$@" 2>&1); code=$?
  if [ "$code" = "$e" ] && printf '%s' "$out" | grep -q -- "$sub"; then
    printf '  ok    %-42s exit=%s\n' "$n" "$code"
  else
    printf '  FAIL  %-42s exit=%s (want %s) out=%s\n' "$n" "$code" "$e" "$(printf '%s' "$out" | head -1)"; FAIL=1
  fi
}
TMP="$(mktemp -d)" && [ -n "$TMP" ] && [ -d "$TMP" ] || { echo "test-args.sh: mktemp -d failed; refusing to run with an empty TMP" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
PROMPT="$TMP/p.md"; echo hi > "$PROMPT"; PFX="$TMP/x"

echo "runner: every invocation error exits 4 (never 1)"
for o in --prompt-file --stall-min --max-min --poll-sec; do chk "$o with no value" 4 "requires a value" bash "$R" "$PFX" $o; done
for o in --stall-min --max-min --poll-sec; do chk "$o followed by an option" 4 "requires a value" bash "$R" "$PFX" $o --fresh --prompt-file "$PROMPT"; done
chk "non-numeric --stall-min"          4 "whole number"            bash "$R" "$PFX" --prompt-file "$PROMPT" --stall-min abc
chk "missing --prompt-file entirely"   4 "--prompt-file is required" bash "$R" "$PFX" --fresh
chk "unreadable prompt file"           4 "not readable"            bash "$R" "$PFX" --prompt-file "$TMP/absent"
chk "unknown arg"                      4 "unknown arg"             bash "$R" "$PFX" --bogus
chk "--write is refused"               4 "read-only"               bash "$R" "$PFX" --write --prompt-file "$PROMPT"
chk "no arguments"                     4 "out-prefix"              bash "$R"
chk "option as first argument"         4 "out-prefix"              bash "$R" --prompt-file "$PROMPT"
chk "debate copy behaves identically"  4 "requires a value"        bash "$D" "$PFX" --max-min
chk "deep-plan copy behaves identically" 4 "requires a value"      bash "$P" "$PFX" --max-min
rm -f "$PFX.exit"; bash "$R" "$PFX" --bogus >/dev/null 2>&1
[ "$(cat "$PFX.exit" 2>/dev/null)" = "4" ] && printf '  ok    %-42s\n' ".exit sidecar records 4" || { printf '  FAIL  %-42s\n' ".exit sidecar"; FAIL=1; }

# CX-04r15: a launch error that cannot even locate the Codex plugin must still
# leave a .meta (outcome=LAUNCH-ERROR) beside .exit=4, and a re-run must rotate
# that attempt instead of clobbering it.
mkdir -p "$TMP/nohome"; PFX4="$TMP/cx04r15"
HOME="$TMP/nohome" bash "$R" "$PFX4" --prompt-file "$PROMPT" >/dev/null 2>&1; rc=$?
[ "$rc" = 4 ] && grep -q '^outcome=LAUNCH-ERROR' "$PFX4.meta" 2>/dev/null && [ "$(cat "$PFX4.exit")" = 4 ] && printf '  ok    %-42s\n' "CX-04r15: missing plugin writes .meta + .exit=4" || { printf '  FAIL  CX-04r15: rc=%s meta=%s\n' "$rc" "$(cat "$PFX4.meta" 2>/dev/null)"; FAIL=1; }
HOME="$TMP/nohome" bash "$R" "$PFX4" --prompt-file "$PROMPT" >/dev/null 2>&1
# CX-01r26: a runner killed after launching leaves only .progress/.stderr; the next
# launch rotates that orphan as a unit instead of truncating it, and the runner
# records its own pid in the gate's claim so the gate can tell it is alive.
PFX5="$TMP/runner-orphan"; printf '10s launched job=orphan\n' > "$PFX5.progress"; mkdir -p "$PFX5.claim"; printf 'pid=1\nat=now\ngate=pre-codex\n' > "$PFX5.claim/owner"
HOME="$TMP/nohome" bash "$R" "$PFX5" --prompt-file "$PROMPT" >/dev/null 2>&1
grep -q 'job=orphan' "$PFX5.attempt1.progress" 2>/dev/null && [ -s "$PFX5.exit" ] && printf '  ok    %-42s\n' "CX-01r26: orphaned .progress rotated, not truncated" || { printf '  FAIL  CX-01r26: orphaned .progress was not rotated\n'; FAIL=1; }
grep -q '^runner_pid=[0-9]' "$PFX5.claim/owner" && grep -q '^started=' "$PFX5.claim/owner" && printf '  ok    %-42s\n' "CX-01r26: runner stamps its pid into the claim" || { printf '  FAIL  CX-01r26: claim not stamped by runner\n'; FAIL=1; }
# CX-02r28: one claim authorizes one runner; a second runner on a stamped claim refuses (exit 4).
cp "$PFX5.exit" "$TMP/pfx5-exit.bak"
HOME="$TMP/nohome" bash "$R" "$PFX5" --prompt-file "$PROMPT" >/dev/null 2> "$TMP/pfx5-dup.err"; rc=$?
[ "$rc" = 4 ] && grep -q 'already taken by runner' "$TMP/pfx5-dup.err" && [ -d "$PFX5.claim/runner" ] && [ "$(grep -c '^runner_pid=' "$PFX5.claim/owner")" = 1 ] && cmp -s "$PFX5.exit" "$TMP/pfx5-exit.bak" && [ ! -e "$PFX5.attempt2.exit" ] && printf '  ok    %-42s\n' "CX-02r28/r29: second runner on a taken claim refuses, touches nothing" || { printf '  FAIL  CX-02r28/r29: duplicate runner not refused cleanly (rc=%s)\n' "$rc"; FAIL=1; }
# CX-02r29: the runner lock is an atomic mkdir taken before any sidecar is touched —
# a live attempt's .progress survives a concurrent duplicate launch.
PFX6="$TMP/runner-race"; mkdir -p "$PFX6.claim"; printf 'pid=1\nat=now\ngate=pre-codex\n' > "$PFX6.claim/owner"
HOME="$TMP/nohome" bash "$R" "$PFX6" --prompt-file "$PROMPT" >/dev/null 2>&1 & HOME="$TMP/nohome" bash "$R" "$PFX6" --prompt-file "$PROMPT" >/dev/null 2>&1 & wait
# Round-32 debate: with --claim the runner writes nothing before it owns the claim.
PFX7="$TMP/claimmode/02-codex"; mkdir -p "$TMP/claimmode"
chk "claim mode: missing claim refused" 4 "does not exist" bash "$R" "$PFX7" --claim t1 --prompt-file "$PROMPT"
[ -z "$(ls "$TMP/claimmode")" ] && printf '  ok    %-42s\n' "claim mode: nothing written without a claim" || { printf '  FAIL  claim mode: wrote %s\n' "$(ls "$TMP/claimmode")"; FAIL=1; }
mkdir -p "$PFX7.claim"; printf 'pid=1\ntoken=t1\n' > "$PFX7.claim/owner"
chk "claim mode: argument error exits 4" 4 "unknown arg" bash "$R" "$PFX7" --bogus --claim t1 --prompt-file "$PROMPT"
# CL-04r42: a claim-less argument error on a prefix that has a claim writes no .exit either.
chk "CL-04r42: claim-less argument error on a claimed prefix" 4 "unknown arg" bash "$R" "$PFX7" --bogus --prompt-file "$PROMPT"
[ ! -e "$PFX7.exit" ] && printf '  ok    %-42s\n' "CL-04r42: no .exit written for a claimed prefix" || { printf '  FAIL  CL-04r42: .exit written\n'; FAIL=1; }
chk "claim mode: unreadable prompt exits 4" 4 "not readable" bash "$R" "$PFX7" --claim t1 --prompt-file "$TMP/absent"
chk "claim mode: --claim needs a token" 4 "requires a value" bash "$R" "$PFX7" --claim --prompt-file "$PROMPT"
# CX-03r36: a runner takes only the claim whose token it was handed; a rotated/replacement claim is refused.
chk "CX-03r36: token mismatch refused" 4 "does not carry token t2" bash "$R" "$PFX7" --claim t2 --prompt-file "$PROMPT"
# CL-03r39: the token is matched as a fixed string, so regex metacharacters cannot widen it.
printf 'pid=1\ntoken=tX1\n' > "$PFX7.claim/owner"
chk "CL-03r39: token compared as a fixed string" 4 "does not carry token t.1" bash "$R" "$PFX7" --claim 't.1' --prompt-file "$PROMPT"
printf 'pid=1\ntoken=t1\n' > "$PFX7.claim/owner"
# L-02r37: a runner launched without --claim against a token-bearing claim still takes it (legacy path).
PFX7L="$TMP/claimlegacy/02-codex"; mkdir -p "$PFX7L.claim"; printf 'pid=1\ntoken=t9\n' > "$PFX7L.claim/owner"
HOME="$TMP/nohome" bash "$R" "$PFX7L" --prompt-file "$PROMPT" >/dev/null 2>&1
[ -d "$PFX7L.claim/runner" ] && grep -q '^runner_pid=' "$PFX7L.claim/owner" && printf '  ok    %-42s\n' "L-02r37: legacy runner takes a token-bearing claim" || { printf '  FAIL  L-02r37: legacy runner did not take the claim\n'; FAIL=1; }
# CX-03r38: the runner takes the claim under <prefix>.claim.lock; a stale lock is reclaimed, a held one refused.
mkdir "$PFX7.claim.lock"; touch -t 202001010000 "$PFX7.claim.lock"
chk "CX-03r38: runner reclaims a stale claim lock" 4 "does not carry token t2" bash "$R" "$PFX7" --claim t2 --prompt-file "$PROMPT"
[ ! -e "$PFX7.claim.lock" ] && printf '  ok    %-42s\n' "CX-03r38: runner releases the claim lock" || { printf '  FAIL  CX-03r38: runner left the claim lock\n'; FAIL=1; }
mkdir "$PFX7.claim.lock"
chk "CX-03r38: runner refuses a held claim lock" 4 "claim.lock is held" bash "$R" "$PFX7" --claim t1 --prompt-file "$PROMPT"
rmdir "$PFX7.claim.lock"
# CL-01r42: a stale lock that cannot be removed (non-empty) is bounded like a held one, never a busy loop.
mkdir -p "$PFX7.claim.lock/stray"; touch -t 202001010000 "$PFX7.claim.lock"
chk "CL-01r42: unremovable stale lock exits 4, no hang" 4 "cannot be removed" bash "$R" "$PFX7" --claim t1 --prompt-file "$PROMPT"
rm -rf "$PFX7.claim.lock"
# CX-01r39: the runner keeps the claim lock until the previous attempt's sidecars are rotated,
# so a stale <prefix>.exit cannot let a concurrent gate rotate the live claim.
PFX8="$TMP/claimrot/02-codex"; mkdir -p "$TMP/claimrot/bin" "$PFX8.claim"; printf 'pid=1\ntoken=t8\n' > "$PFX8.claim/owner"; printf '1\n' > "$PFX8.exit"; printf 'old\n' > "$PFX8.stdout"
printf '#!/bin/sh\ncase "$1" in *.exit) [ -d "%s.claim.lock" ] && : > "%s/lock-held";; esac\nexec /bin/mv "$@"\n' "$PFX8" "$TMP/claimrot" > "$TMP/claimrot/bin/mv"; chmod +x "$TMP/claimrot/bin/mv"
PATH="$TMP/claimrot/bin:$PATH" HOME="$TMP/nohome" bash "$R" "$PFX8" --claim t8 --prompt-file "$PROMPT" >/dev/null 2>&1
[ -e "$TMP/claimrot/lock-held" ] && [ -e "$PFX8.attempt1.exit" ] && [ ! -e "$PFX8.claim.lock" ] && printf '  ok    %-42s\n' "CX-01r39: lock held through sidecar rotation, then released" || { printf '  FAIL  CX-01r39: lock-held=%s rotated=%s lock-left=%s\n' "$([ -e "$TMP/claimrot/lock-held" ] && echo y || echo n)" "$([ -e "$PFX8.attempt1.exit" ] && echo y || echo n)" "$([ -e "$PFX8.claim.lock" ] && echo y || echo n)"; FAIL=1; }
[ ! -e "$PFX7.exit" ] && [ ! -d "$PFX7.claim/runner" ] && printf '  ok    %-42s\n' "claim mode: argument errors leave no .exit and do not take the claim" || { printf '  FAIL  claim mode: side effect on argument error\n'; FAIL=1; }
chk "no claim mode: argument error still records .exit" 4 "unknown arg" bash "$R" "$TMP/claimmode/legacy" --bogus --prompt-file "$PROMPT"
# CX-03r33: "--claim" inside a value is not the flag.
cp "$PROMPT" "$TMP/claimmode/a --claim b.md"
chk "CX-03r33: prompt path containing --claim is not claim mode" 4 "unknown arg" bash "$R" "$TMP/claimmode/legacy2" --bogus --prompt-file "$TMP/claimmode/a --claim b.md"
[ "$(cat "$TMP/claimmode/legacy2.exit" 2>/dev/null)" = 4 ] && printf '  ok    %-42s\n' "CX-03r33: legacy behaviour kept (.exit written)" || { printf '  FAIL  CX-03r33: value misread as --claim\n'; FAIL=1; }
[ "$(cat "$TMP/claimmode/legacy.exit" 2>/dev/null)" = 4 ] && printf '  ok    %-42s\n' "no claim mode: sibling-plugin behaviour unchanged" || { printf '  FAIL  legacy .exit missing\n'; FAIL=1; }
HOME="$TMP/nohome" bash "$R" "$PFX7" --claim t1 --prompt-file "$PROMPT" >/dev/null 2>&1
[ -d "$PFX7.claim/runner" ] && [ -s "$PFX7.exit" ] && printf '  ok    %-42s\n' "claim mode: launch takes the claim then writes sidecars" || { printf '  FAIL  claim mode: launch did not stamp\n'; FAIL=1; }
[ "$(grep -c '^runner_pid=' "$PFX6.claim/owner")" = 1 ] && [ ! -e "$PFX6.attempt1.exit" ] && [ -s "$PFX6.exit" ] && printf '  ok    %-42s\n' "CX-02r29: two concurrent runners → exactly one takes the claim" || { printf '  FAIL  CX-02r29: concurrent runners both ran (stamps=%s)\n' "$(grep -c '^runner_pid=' "$PFX6.claim/owner")"; FAIL=1; }
[ -s "$PFX4.attempt1.exit" ] && [ -s "$PFX4.attempt1.meta" ] && [ -s "$PFX4.exit" ] && printf '  ok    %-42s\n' "CX-04r15: launch-error attempt rotated on re-run" || { printf '  FAIL  CX-04r15: launch-error attempt not rotated\n'; FAIL=1; }
grep -q 'cannot locate the codex plugin' "$PFX4.stderr" 2>/dev/null && [ -s "$PFX4.progress" ] && printf '  ok    %-42s\n' "CX-04r16: missing plugin writes .stderr + .progress" || { printf '  FAIL  CX-04r16: .stderr/.progress missing on launch error\n'; FAIL=1; }

echo "builder: every usage error exits 2"
for o in --repo --base-ref --base --head --head-ref --intent-file --conventions-file --out; do chk "$o with no value" 2 "requires a value" bash "$B" $o; done
chk "missing required option"  2 "is required"     bash "$B" --repo .
chk "unknown arg"              2 "unknown arg"     bash "$B" --nope x
chk "--repo not a directory"   2 "not a directory" bash "$B" --repo "$TMP/absent" --base-ref H --base H --head WORKTREE --intent-file "$PROMPT" --conventions-file "$PROMPT" --out "$TMP/o.md"
# CL-03r40: --base/--head are normalised to full ids; an unresolvable one is refused by the builder, not blamed on it by the gate.
BBR="$TMP/bb-repo"; mkdir -p "$BBR"; ( cd "$BBR" && git init -q && git config user.email t@t && git config user.name t && echo a > a && git add a && git commit -qm a && echo b > a && git commit -qam b ) 
BBS=$(git -C "$BBR" rev-parse HEAD); BBP=$(git -C "$BBR" rev-parse HEAD~1)
chk "CL-03r40: unresolvable --base refused" 2 "does not resolve" bash "$B" --repo "$BBR" --base-ref x --base 0123456 --head-ref y --head "$BBS" --intent-file "$PROMPT" --conventions-file "$PROMPT" --out "$TMP/bb.md"
bash "$B" --repo "$BBR" --base-ref x --base "$(printf '%s' "$BBP" | cut -c1-8)" --head-ref y --head "$(printf '%s' "$BBS" | cut -c1-8)" --intent-file "$PROMPT" --conventions-file "$PROMPT" --out "$TMP/bb.md" >/dev/null 2>&1
[ "$(cat "$TMP/bb.md.base")" = "$BBP" ] && [ "$(cat "$TMP/bb.md.head")" = "$BBS" ] && grep -q "($BBP)" "$TMP/bb.md" && printf '  ok    %-42s\n' "CL-03r40: abbreviated --base/--head expanded to full ids" || { printf '  FAIL  CL-03r40: short ids not expanded (%s / %s)\n' "$(cat "$TMP/bb.md.base" 2>/dev/null)" "$(cat "$TMP/bb.md.head" 2>/dev/null)"; FAIL=1; }
chk "--intent-file unreadable" 2 "not readable"    bash "$B" --repo . --base-ref H --base H --head WORKTREE --intent-file "$TMP/absent" --conventions-file "$PROMPT" --out "$TMP/o.md"
chk "--out inside the repo"    2 "outside the repository" bash "$B" --repo . --base-ref HEAD --base HEAD --head WORKTREE --intent-file "$PROMPT" --conventions-file "$PROMPT" --out ./brief.md
# X-07: range mode without --head-ref must be a usage error, not a raw ${HREF:?} abort
chk "range mode missing --head-ref" 2 "--head-ref is required" bash "$B" --repo . --base-ref HEAD --base HEAD --head HEAD --intent-file "$PROMPT" --conventions-file "$PROMPT" --out "$TMP/o.md"

echo "runner: leading-zero timings are base 10, not octal"
# X-08: "08"/"09" pass the digit test but abort bash arithmetic as invalid octal.
# Validation happens before the prompt-file check, so reaching "not readable"
# proves the value was normalised and no arithmetic abort occurred.
for v in 08 09 007; do
  chk "--stall-min $v accepted as base 10" 4 "not readable" bash "$R" "$PFX" --stall-min "$v" --prompt-file "$TMP/absent"
  chk "--max-min $v accepted as base 10"   4 "not readable" bash "$R" "$PFX" --max-min "$v" --prompt-file "$TMP/absent"
done
chk "--poll-sec 0 rejected"        4 "between 1 and"  bash "$R" "$PFX" --poll-sec 0 --prompt-file "$PROMPT"
chk "oversized --max-min rejected" 4 "between 1 and"  bash "$R" "$PFX" --max-min 12345678 --prompt-file "$PROMPT"

echo "builder: the file-list parser survives awkward filenames"
# X-09 / X-10: a git path is bytes and may contain a newline; one changed file
# must stay one line of the brief, and a non-UTF-8 byte must not crash the run.
PARSER=plugins/codex-pr-review/skills/two-model-pr-review/scripts/quote-name-status.py
out=$(printf 'M\0bad\xffname.txt\0' | python3 "$PARSER" 2>&1); code=$?
[ $code -eq 0 ] && printf '  ok    %-42s\n' "non-UTF-8 filename does not crash" || { printf '  FAIL  non-UTF-8 filename: %s\n' "$out"; FAIL=1; }
out=$(printf 'M\0dir/first\nsecond.md\0' | python3 "$PARSER" 2>&1); code=$?
n=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
[ $code -eq 0 ] && [ "$n" = "1" ] && printf '  ok    %-42s\n' "newline in filename stays one line" || { printf '  FAIL  newline filename produced %s lines: %s\n' "$n" "$out"; FAIL=1; }
out=$(printf 'M\0a file with spaces.md\0R100\0old n.md\0new n.md\0' | python3 "$PARSER" 2>&1)
printf '%s' "$out" | grep -q 'a file with spaces.md  (M)' && printf '%s' "$out" | grep -q 'new n.md  (R from old n.md, similarity 100)' \
  && printf '  ok    %-42s\n' "spaces and renames parse correctly" || { printf '  FAIL  parser: %s\n' "$out"; FAIL=1; }
# X-16 / X-17: the quoting must be reversible — a raw byte or a real newline must
# not render identically to a path whose own characters are a backslash and x/n.
a=$(printf 'M\0bad\xffname.txt\0'      | python3 "$PARSER")
b=$(printf 'M\0bad\\xffname.txt\0'    | python3 "$PARSER")
c=$(printf 'M\0dir/f\nsecond.md\0'     | python3 "$PARSER")
d=$(printf 'M\0dir/f\\nsecond.md\0'   | python3 "$PARSER")
[ "$a" != "$b" ] && [ "$c" != "$d" ] && printf '  ok    %-42s\n' "quoting distinguishes raw bytes from text" || { printf '  FAIL  quoting is ambiguous: [%s] vs [%s]; [%s] vs [%s]\n' "$a" "$b" "$c" "$d"; FAIL=1; }
printf '%s' "$a$c" | grep -q '^  - "' && printf '  ok    %-42s\n' "unusual paths are git-quoted" || { printf '  FAIL  unusual path not quoted: %s\n' "$a"; FAIL=1; }
out=$(printf 'M\0normal.md\0' | python3 "$PARSER")
[ "$out" = "  - normal.md  (M)" ] && printf '  ok    %-42s\n' "ordinary paths stay unquoted" || { printf '  FAIL  ordinary path altered: %s\n' "$out"; FAIL=1; }

echo "builder: happy path on a throwaway repo"
G="$TMP/repo"; mkdir -p "$G"; ( cd "$G" && git init -q && git config user.email t@t && git config user.name t && echo a > a.txt && git add a.txt && git commit -qm init ) || { echo "  FAIL  fixture"; FAIL=1; }
BASE=$(git -C "$G" rev-parse HEAD)
bash "$B" --repo "$G" --base-ref HEAD --base "$BASE" --head WORKTREE --intent-file "$PROMPT" --conventions-file "$PROMPT" --out "$TMP/clean.md" >/dev/null 2>&1
[ $? -eq 3 ] && printf '  ok    %-42s exit=3\n' "clean tree reports nothing to review" || { printf '  FAIL  clean tree\n'; FAIL=1; }
echo b > "$G/b.txt"; echo a2 >> "$G/a.txt"
IDX_BEFORE=$(cksum "$G/.git/index" | cut -d' ' -f1)
bash "$B" --repo "$G" --base-ref HEAD --base "$BASE" --head WORKTREE --intent-file "$PROMPT" --conventions-file "$PROMPT" --out "$TMP/dirty.md" >/dev/null 2>&1
code=$?; T1=$(cat "$TMP/dirty.md.tree" 2>/dev/null || true)
[ $code -eq 0 ] && [ -n "$T1" ] && printf '  ok    %-42s tree=%s\n' "dirty tree captured" "${T1:0:12}" || { printf '  FAIL  dirty tree exit=%s\n' "$code"; FAIL=1; }
bash "$B" --repo "$G" --base-ref HEAD --base "$BASE" --head WORKTREE --intent-file "$PROMPT" --conventions-file "$PROMPT" --out "$TMP/dirty2.md" >/dev/null 2>&1
[ "$(cat "$TMP/dirty2.md.tree" 2>/dev/null)" = "$T1" ] && printf '  ok    %-42s\n' "recapture is deterministic" || { printf '  FAIL  recapture differs\n'; FAIL=1; }
[ "$(cksum "$G/.git/index" | cut -d' ' -f1)" = "$IDX_BEFORE" ] && printf '  ok    %-42s\n' "repository index untouched" || { printf '  FAIL  index mutated\n'; FAIL=1; }
grep -q '^  - b.txt  (A)$' "$TMP/dirty.md" && printf '  ok    %-42s\n' "untracked file listed as added" || { printf '  FAIL  untracked file missing from brief\n'; FAIL=1; }
[ -e "$TMP/tmp-index" ] || ls "$TMP"/tmp-index.* >/dev/null 2>&1 && { printf '  FAIL  scratch index left behind\n'; FAIL=1; } || printf '  ok    %-42s\n' "scratch index cleaned up"

echo "deep-plan: init-plan.sh usage errors exit 2, inputs are pinned verbatim, gh failures exit 3"
I="$DS/init-plan.sh"
for o in --repo --out --slug --rounds --issue --pr --comment --request --request-file; do chk "init $o with no value" 2 "requires a value" bash "$I" $o; done
chk "init: no input at all"            2 "at least one input"   bash "$I" --repo . --out "$TMP/a"
chk "init: unknown arg"                2 "unknown arg"          bash "$I" --repo . --out "$TMP/a" --nope --request x
chk "init: --rounds 0 rejected"        2 "between 1 and 3"      bash "$I" --repo . --out "$TMP/a" --rounds 0 --request x
chk "init: --rounds 08 is base 10"     2 "between 1 and 3"      bash "$I" --repo . --out "$TMP/a" --rounds 08 --request x
chk "init: --out inside the repo"      2 "outside the repository" bash "$I" --repo . --out ./plan-out --request x
chk "init: --request-file unreadable"  2 "not readable"         bash "$I" --repo . --out "$TMP/a" --request-file "$TMP/absent"
chk "init: bad issue ref"              2 "must be a number"     bash "$I" --parse-only --issue "not-a-ref"
chk "init: comment URL without fragment" 2 "fragment"           bash "$I" --parse-only --comment "https://github.com/o/r/pull/4"
out=$(bash "$I" --parse-only --comment "https://github.com/own/rep/pull/45#discussion_r123456" 2>&1)
printf '%s' "$out" | grep -q '"api": "repos/own/rep/pulls/comments/123456"' && printf '  ok    %-42s\n' "review-comment URL parsed to its API path" || { printf '  FAIL  comment parse: %s\n' "$out"; FAIL=1; }
out=$(bash "$I" --parse-only --issue "https://github.com/own/rep/issues/7" 2>&1)
printf '%s' "$out" | grep -q '"number": 7' && printf '%s' "$out" | grep -q '"owner": "own"' && printf '  ok    %-42s\n' "issue URL parsed" || { printf '  FAIL  issue parse: %s\n' "$out"; FAIL=1; }
out=$(bash "$I" --parse-only --pr "#12" 2>&1)
printf '%s' "$out" | grep -q '"number": 12' && printf '  ok    %-42s\n' "#N parsed as a number" || { printf '  FAIL  pr parse: %s\n' "$out"; FAIL=1; }
G2="$TMP/repo2"; mkdir -p "$G2"; ( cd "$G2" && git init -q && git config user.email t@t && git config user.name t && printf 'line one\nline two\nline three\n' > f.txt && printf 'FROM python\n' > Dockerfile && git add f.txt Dockerfile && git commit -qm init ) || { echo "  FAIL  fixture2"; FAIL=1; }
SHA2=$(git -C "$G2" rev-parse HEAD)
printf 'The export endpoint should be rate limited.\n' > "$TMP/req.txt"
A="$TMP/art1"
out=$(bash "$I" --repo "$G2" --out "$A" --request "make it fast" --request-file "$TMP/req.txt" 2>&1); code=$?
[ $code -eq 0 ] && grep -q '^make it fast$' "$A/inputs/request-1.md" && grep -q 'should be rate limited' "$A/inputs/request-2.md" \
  && printf '  ok    %-42s\n' "text and file inputs pinned verbatim" || { printf '  FAIL  init text inputs exit=%s: %s\n' "$code" "$out"; FAIL=1; }
python3 -c "import json,sys; m=json.load(open('$A/meta.json')); assert m['base_sha']=='$SHA2', m; assert [i['kind'] for i in m['inputs']]==['request','request'], m; assert m['slug']=='make-it-fast', m; assert m['dirty_tree'] is False" \
  && printf '  ok    %-42s\n' "meta.json pins sha, inputs and slug" || { printf '  FAIL  meta.json contents\n'; FAIL=1; }
[ -f "$A/00-scope.md.baseline" ] && [ -d "$A/debate" ] && printf '  ok    %-42s\n' "baseline and debate dir created" || { printf '  FAIL  baseline/debate missing\n'; FAIL=1; }
chk "init: refuses to reuse a run dir"  2 "already holds a run"  bash "$I" --repo "$G2" --out "$A" --request x
FAKE="$TMP/fakebin"; mkdir -p "$FAKE"; printf '#!/bin/sh\necho "gh: not logged in" >&2; exit 1\n' > "$FAKE/gh"; chmod +x "$FAKE/gh"
out=$(PATH="$FAKE:$PATH" bash "$I" --repo "$G2" --out "$TMP/art2" --issue 1 --request kept 2>&1); code=$?
[ $code -eq 3 ] && printf '%s' "$out" | grep -q -- '--issue 1' && [ -f "$TMP/art2/inputs/request-1.md" ] \
  && printf '  ok    %-42s exit=3\n' "gh failure exits 3, names input, keeps others" || { printf '  FAIL  gh failure exit=%s: %s\n' "$code" "$out"; FAIL=1; }

echo "deep-plan: review findings F-01, F-08, F-09, F-10, F-16 (init-plan.sh)"
# F-01: a refused in-repo --out must not create the directory
rm -rf "$G2/plan-out"; bash "$I" --repo "$G2" --out "$G2/plan-out" --request x >/dev/null 2>&1
[ ! -e "$G2/plan-out" ] && printf '  ok    %-42s\n' "refused --out leaves no directory behind" || { printf '  FAIL  refused --out created %s\n' "$G2/plan-out"; FAIL=1; }
# F-09: an untracked file makes the tree dirty
echo new > "$G2/untracked.txt"
bash "$I" --repo "$G2" --out "$TMP/art9" --request x 2>&1 | grep -q 'WARNING: dirty' && python3 -c "import json,sys; sys.exit(0 if json.load(open('$TMP/art9/meta.json'))['dirty_tree'] else 1)" \
  && printf '  ok    %-42s\n' "untracked-only tree is reported dirty" || { printf '  FAIL  untracked file not reported dirty\n'; FAIL=1; }
rm -f "$G2/untracked.txt"
# F-10: a malformed comment fragment is a usage error, not a traceback
chk "init: non-numeric comment fragment" 2 "must be #issuecomment"  bash "$I" --parse-only --comment "https://github.com/o/r/pull/4#discussion_rabc"
# F-16: free text may begin with a dash
bash "$I" --repo "$G2" --out "$TMP/art16" --request "-v is ignored" >/dev/null 2>&1 && grep -q '^-v is ignored$' "$TMP/art16/inputs/request-1.md" \
  && printf '  ok    %-42s\n' "request text may start with a dash" || { printf '  FAIL  dash-leading request rejected\n'; FAIL=1; }
# proportionality (debate 2026-09-03): --deep is recorded; the resolved mode is left to the skill
bash "$I" --repo "$G2" --out "$TMP/artdeep" --deep --request x >/dev/null 2>&1
python3 -c "import json; m=json.load(open('$TMP/artdeep/meta.json')); assert m['mode_requested']=='deep' and m['mode'] is None, m" \
  && printf '  ok    %-42s\n' "--deep recorded as mode_requested" || { printf '  FAIL  --deep not recorded\n'; FAIL=1; }
python3 -c "import json; m=json.load(open('$TMP/art16/meta.json')); assert m['mode_requested'] is None, m" \
  && printf '  ok    %-42s\n' "mode_requested null without --deep" || { printf '  FAIL  mode_requested default\n'; FAIL=1; }
# review F-05: --deep defaults to three rounds; an explicit --rounds wins; the default stays 2
python3 -c "import json; assert json.load(open('$TMP/artdeep/meta.json'))['rounds']==3" && printf '  ok    %-42s\n' "--deep defaults rounds to 3" || { printf '  FAIL  --deep rounds default\n'; FAIL=1; }
bash "$I" --repo "$G2" --out "$TMP/artdeep1" --deep --rounds 1 --request x >/dev/null 2>&1
python3 -c "import json; assert json.load(open('$TMP/artdeep1/meta.json'))['rounds']==1" && printf '  ok    %-42s\n' "--deep keeps explicit --rounds" || { printf '  FAIL  --deep overrides --rounds\n'; FAIL=1; }
python3 -c "import json; assert json.load(open('$TMP/art16/meta.json'))['rounds']==2" && printf '  ok    %-42s\n' "rounds default 2 without --deep" || { printf '  FAIL  rounds default\n'; FAIL=1; }
# F-08: gh output of one JSON array per page (older gh) is merged
FAKE2="$TMP/fakegh2"; mkdir -p "$FAKE2"; cat > "$FAKE2/gh" <<'GH'
#!/bin/sh
case "$1 $2" in
  "repo view") echo '{"nameWithOwner":"own/rep"}';;
  "pr view") echo '{"number":7,"title":"T","body":"B","state":"OPEN","url":"u","baseRefName":"main","headRefName":"f","reviews":[],"comments":[]}';;
  "api --paginate") printf '[{"path":"a.py","line":1,"body":"first","user":{"login":"x"}}]\n[{"path":"b.py","line":2,"body":"second","user":{"login":"y"}}]\n';;
  *) exit 1;;
esac
GH
chmod +x "$FAKE2/gh"
PATH="$FAKE2:$PATH" bash "$I" --repo "$G2" --out "$TMP/art8b" --pr 7 >/dev/null 2>&1; code=$?
[ $code -eq 0 ] && grep -q 'first' "$TMP/art8b/inputs/pr-7.md" && grep -q 'second' "$TMP/art8b/inputs/pr-7.md" \
  && printf '  ok    %-42s\n' "paginated arrays are merged" || { printf '  FAIL  paginated arrays exit=%s\n' "$code"; FAIL=1; }

echo "deep-plan: check-citations.py string-matches quotes against git show"
C="$DS/check-citations.py"; L="$DS/lint-claims.py"
chk "citations: no file"               2 "usage"                python3 "$C"
chk "citations: --repo with no value"  2 "requires a value"     python3 "$C" --repo
printf '| F-1 | [FACT] | second line exists | `f.txt:2-2@%s` "line two" |\n' "$SHA2" > "$TMP/ev-ok.md"
chk "citations: correct quote passes"  0 "OK"                   python3 "$C" --repo "$G2" "$TMP/ev-ok.md"
# two citations in one cell: each quote is checked against its own citation (live-run friction 2026-09-03)
printf '| F-1 | [FACT] | both | `f.txt:1-1@%s` "line one" ; `f.txt:2-2@%s` "line two" |\n' "$SHA2" "$SHA2" > "$TMP/ev-two.md"
chk "citations: two citations per cell pass" 0 "checked 2 citation" python3 "$C" --repo "$G2" "$TMP/ev-two.md"
printf '| F-1 | [FACT] | both | `f.txt:1-1@%s` "line one" ; `f.txt:2-2@%s` "line nine" |\n' "$SHA2" "$SHA2" > "$TMP/ev-two-bad.md"
chk "citations: second of two citations fails" 1 "quote not found" python3 "$C" --repo "$G2" "$TMP/ev-two-bad.md"
# review F-02: a citation never borrows a neighbour's quote
printf '| F-1 | [FACT] | x | `f.txt:1-1@%s` ; `f.txt:2-2@%s` "line two" |\n' "$SHA2" "$SHA2" > "$TMP/ev-noq1.md"
chk "citations: first citation without quote fails" 1 "no verbatim" python3 "$C" --repo "$G2" "$TMP/ev-noq1.md"
printf '| F-1 | [FACT] | x | `f.txt:1-1@%s` "line one" ; `f.txt:1-1@%s` |\n' "$SHA2" "$SHA2" > "$TMP/ev-noq2.md"
chk "citations: second citation without quote fails" 1 "no verbatim" python3 "$C" --repo "$G2" "$TMP/ev-noq2.md"
printf '| F-1 | [FACT] | wrong | `f.txt:2-2@%s` "line nine" |\n' "$SHA2" > "$TMP/ev-bad.md"
chk "citations: wrong quote fails"     1 "quote not found"      python3 "$C" --repo "$G2" "$TMP/ev-bad.md"
printf '| F-1 | [FACT] | oob | `f.txt:9-12@%s` "line two" |\n' "$SHA2" > "$TMP/ev-oob.md"
chk "citations: out-of-range fails"    1 "out of range"         python3 "$C" --repo "$G2" "$TMP/ev-oob.md"
printf '| F-1 | [FACT] | nosha | `f.txt:2-2@0123456789abcdef` "line two" |\n' > "$TMP/ev-nosha.md"
chk "citations: unknown sha fails"     1 "is not a commit"      python3 "$C" --repo "$G2" "$TMP/ev-nosha.md"
printf '| F-1 | [FACT] | noquote | `f.txt:2-2@%s` |\n' "$SHA2" > "$TMP/ev-noq.md"
chk "citations: missing quote fails"   1 "no verbatim"          python3 "$C" --repo "$G2" "$TMP/ev-noq.md"
printf 'no citations here\n' > "$TMP/ev-empty.md"
chk "citations: zero citations fails"  1 "zero citations"       python3 "$C" --repo "$G2" "$TMP/ev-empty.md"
chk "citations: --allow-empty"         0 "OK"                   python3 "$C" --repo "$G2" --allow-empty "$TMP/ev-empty.md"
cp "$TMP/ev-ok.md" "$A/01-evidence.md"
chk "citations: repo taken from meta.json" 0 "OK"               python3 "$C" "$A/01-evidence.md"
# F-02: a citation must pin the run's base commit, not just any commit
( cd "$G2" && echo extra >> f.txt && git commit -qam later )
SHA_LATER=$(git -C "$G2" rev-parse HEAD)
printf '| F-1 | [FACT] | later | `f.txt:2-2@%s` "line two" |\n' "$SHA_LATER" > "$TMP/ev-later.md"
chk "citations: non-base sha rejected"  1 "base SHA"             python3 "$C" --repo "$G2" --base-sha "$SHA2" "$TMP/ev-later.md"
chk "citations: base sha accepted"      0 "OK"                   python3 "$C" --repo "$G2" --base-sha "$SHA2" "$TMP/ev-ok.md"
cp "$TMP/ev-later.md" "$A/01-evidence-later.md"
chk "citations: base sha from meta.json" 1 "base SHA"            python3 "$C" "$A/01-evidence-later.md"
rm -f "$A/01-evidence-later.md"
# Live-run friction 2026-09-02: `.github/workflows/x.yml` could not be cited because the path
# regex demanded a letter first. Dot-paths are ordinary repository paths.
( cd "$G2" && mkdir -p .github && printf 'name: ci\n' > .github/ci.yml && git add .github && git commit -qm dotpath )
SHA3=$(git -C "$G2" rev-parse HEAD)
printf '| F-1 | [FACT] | dotpath | `.github/ci.yml:1-1@%s` "name: ci" |\n' "$SHA3" > "$TMP/ev-dot.md"
chk "citations: dot-path cited"        0 "OK"                   python3 "$C" --repo "$G2" "$TMP/ev-dot.md"
# Live-run friction 2026-09-02: a quoted line that itself contains double quotes was rejected
# because the shortest "..." match ended at the inner quote.
( cd "$G2" && printf 'else note ok "no paths"; fi\n' > q.sh && git add q.sh && git commit -qm quotes )
SHA4=$(git -C "$G2" rev-parse HEAD)
printf '| F-1 | [FACT] | inner quotes | `q.sh:1-1@%s` "note ok "no paths"; fi" |\n' "$SHA4" > "$TMP/ev-inner.md"
chk "citations: quote containing quotes" 0 "OK"                 python3 "$C" --repo "$G2" "$TMP/ev-inner.md"
printf '| F-1 | [FACT] | inner quotes wrong | `q.sh:1-1@%s` "note ok "yes paths"; fi" |\n' "$SHA4" > "$TMP/ev-inner-bad.md"
chk "citations: wrong inner-quote text fails" 1 "quote not found" python3 "$C" --repo "$G2" "$TMP/ev-inner-bad.md"
chk "lint: dot-path counts as citation" 0 "OK"                  python3 "$L" "$TMP/ev-dot.md"

echo "deep-plan: lint-claims.py enforces tags, hedges and evidence ids"
chk "lint: no args"                    2 "usage"                python3 "$L"
chk "lint: clean file passes"          0 "OK"                   python3 "$L" "$TMP/ev-ok.md"
printf 'This probably works.\n' > "$TMP/l-hedge.md"
chk "lint: hedge outside INFERENCE"    1 "hedge without"        python3 "$L" "$TMP/l-hedge.md"
printf '| I-1 | [INFERENCE] | probably works | from: F-1 |\n| F-1 | [FACT] | x | `a.py:1-1@0123456789ab` "x" |\n' > "$TMP/l-inf.md"
chk "lint: hedge inside INFERENCE ok"  0 "OK"                   python3 "$L" "$TMP/l-inf.md"
printf '| F-1 | [FACT] | no citation here |\n' > "$TMP/l-fact.md"
chk "lint: FACT without citation"      1 "without path:lines@sha" python3 "$L" "$TMP/l-fact.md"
printf '| V-1 | [VERIFIED] | ran it |\n' > "$TMP/l-ver.md"
chk "lint: VERIFIED without cmd"       1 "without \`cmd:\`"     python3 "$L" "$TMP/l-ver.md"
printf 'Decision: use the cache\n' > "$TMP/l-dec.md"
chk "lint: decision without id"        1 "cites no F-/V-"       python3 "$L" "$TMP/l-dec.md"
# F-03: an evidence row without its tag, or with the wrong tag, fails
printf '| F-1 | | handler drops jobs | `f.txt:1-1@%s` "line one" |\n' "$SHA2" > "$TMP/l-untagged.md"
chk "lint: untagged evidence row"      1 "must carry exactly"   python3 "$L" "$TMP/l-untagged.md"
printf '| V-1 | [FACT] | mislabelled | `f.txt:1-1@%s` "line one" |\n' "$SHA2" > "$TMP/l-mistag.md"
chk "lint: mis-tagged evidence row"    1 "must carry exactly"   python3 "$L" "$TMP/l-mistag.md"
# F-04: a decision resting only on an inference fails
printf '| I-1 | [INFERENCE] | x | from: F-1 |\n| F-1 | [FACT] | y | `f.txt:1-1@%s` "line one" |\nDecision: use the cache (I-1)\n' "$SHA2" > "$TMP/l-infdec.md"
chk "lint: decision on inference only" 1 "cites no F-/V-"       python3 "$L" "$TMP/l-infdec.md"
printf '| F-1 | [FACT] | y | `f.txt:1-1@%s` "line one" |\nDecision: use the cache (F-1)\n' "$SHA2" > "$TMP/l-factdec.md"
chk "lint: decision on a fact passes"  0 "OK"                   python3 "$L" "$TMP/l-factdec.md"
# F-15: a table header cell is not a decision line
printf '| Decision | Because |\n|---|---|\n| x | y |\n' > "$TMP/l-hdr.md"
chk "lint: table header is not a decision" 0 "OK"               python3 "$L" "$TMP/l-hdr.md"
printf 'Decision: use the cache (F-9)\n' > "$TMP/l-dang.md"
chk "lint: dangling id"                1 "never defined"        python3 "$L" "$TMP/l-dang.md"
printf '```\nthis should be ignored inside a fence\n```\n' > "$TMP/l-fence.md"
chk "lint: fenced code skipped"        0 "OK"                   python3 "$L" "$TMP/l-fence.md"
mkdir -p "$A/inputs2"; cp "$TMP/l-hedge.md" "$A/inputs/issue-1.md"
chk "lint: inputs/ dir skipped"        0 "OK"                   python3 "$L" "$A"
# live-run friction 2026-09-03: a sealed (mode 000) file is reported, not a traceback
printf '| F-1 | [FACT] | sealed | `f.txt:1-1@%s` "line one" |\n' "$SHA2" > "$A/sealed.md"; chmod 000 "$A/sealed.md"
chk "lint: sealed file named, no traceback" 1 "unreadable"       python3 "$L" "$A"
chmod 600 "$A/sealed.md"; rm -f "$A/sealed.md"

echo "deep-plan: the summary-first plan templates lint clean once filled"
PT=plugins/codex-deep-plan/skills/deep-plan-duo/templates
mkdir -p "$TMP/plan"; cp "$A/meta.json" "$TMP/plan/"
python3 - "$PT" "$TMP/plan" "$SHA2" <<'PY2'
import re,sys,os
pt,out,sha=sys.argv[1:]
fill={"PLAN.md":{"{{slug}}":"s","{{REVIEWED by Codex, N rounds, termination Tn | SOLO — unreviewed by second model: <reason>}}":"REVIEWED by Codex, 1 round, termination T0 (light)",
  "{{light | standard | deep}}":"light","{{, escalated from light at Phase n: <trigger>}}":"","{{7-char sha}}":sha[:7],"{{branch}}":"main","{{date}}":"2026-09-03","{{date + 14 days}}":"2026-09-17","{{artifact dir}}":out},
 "PLAN-EVIDENCE.md":{"{{slug}}":"s","{{7-char sha}}":sha[:7],"{{light | standard | deep}}":"light","{{DS-n}}":"DS-1","{{F-/V- ids}}":"F-1"},
 "ANSWER.md":{"{{slug}}":"s","{{the input, quoted}}":"q","{{7-char sha}}":sha[:7],"{{branch}}":"main","{{date}}":"2026-09-03","{{CHECKED by Codex, blind round 0 | SOLO: <reason>}}":"SOLO: test","{{artifact dir}}":out}}
for f,rep in fill.items():
    t=open(os.path.join(pt,f)).read()
    for k,v in rep.items(): t=t.replace(k,v)
    t=re.sub(r"\{\{[^}]*\}\}","x",t)
    t=t.replace("| F-1 | [FACT] | x | `x` \"x\" |", "| F-1 | [FACT] | x | `f.txt:1-1@%s` \"line one\" |" % sha)
    t=t.replace("{{RC-1: one sentence (violated_invariant)}}","x")
    open(os.path.join(out,f),"w").write(t)
PY2
chk "templates: filled PLAN/EVIDENCE/ANSWER lint" 0 "OK"        python3 "$L" "$TMP/plan"
[ "$(wc -l < "$PT/PLAN.md")" -lt 45 ] && printf '  ok    %-42s\n' "PLAN.md template stays short" || { printf '  FAIL  PLAN.md template too long\n'; FAIL=1; }

echo "deep-plan: validate-verdict.py enforces the objection contract"
V="$DS/validate-verdict.py"
chk "verdict: missing args"            2 "usage"                python3 "$V" --extract "$TMP/absent"
mkobj() { cat > "$1" <<JSON
{"role":"codex","round":$2,"verdict":"$3","summary":"s",
 "root_causes":[{"id":"RC-1","explains":["request-1"],"cause_class":"absent_constraint","statement":"no limiter","evidence":["f.txt:2-2@$SHA2 \\"line two\\""]}],
 "designs":[{"id":"DS-1","one_sentence":"a","addresses":["RC-1"],"files":["f.txt"],"blast_radius":"1","reversibility":"yes","risks":"none","preferred":true},
            {"id":"DS-2","one_sentence":"b","addresses":["RC-1"],"files":["f.txt"],"blast_radius":"2","reversibility":"yes","risks":"none","preferred":false}],
 "single_pr_recommendation":{"verdict":"ONE_PR","because":"one cause (RC-1)"},
 "objections":$4,"changed_positions":[],"evidence_requests":[],
 "attestations":{"files_read":["f.txt"],"checks_performed":["git show -> ok","git grep -> 0","git log -> 1"],"adversarial_attempt":"$5"}}
JSON
}
mkobj "$TMP/v-ok.json" 0 APPROVE '[]' "tried to break it"
{ echo 'Some prose before.'; echo '```json'; cat "$TMP/v-ok.json"; echo '```'; } > "$TMP/v-ok.stdout"
chk "verdict: valid round 0 accepted"  0 "OK verdict=APPROVE"   python3 "$V" --extract "$TMP/v-ok.stdout" --out "$TMP/v-ok.out.json" --round 0 --role codex --repo "$G2"
python3 -c "import json; json.load(open('$TMP/v-ok.out.json'))" && printf '  ok    %-42s\n' "verdict json written" || { printf '  FAIL  verdict json not written\n'; FAIL=1; }
chk "verdict: wrong round rejected"    1 "round must be 1"      python3 "$V" --extract "$TMP/v-ok.stdout" --round 1
mkobj "$TMP/v-bare.json" 0 APPROVE '[]' ""
chk "verdict: bare APPROVE needs adversarial_attempt" 1 "adversarial_attempt" python3 "$V" --extract "$TMP/v-bare.json" --round 0
mkobj "$TMP/v-nofals.json" 0 REJECT '[{"id":"X-1","class":"TEST_GAP","severity":"MAJOR","claim":"c","evidence":["f.txt:1-1 \"line one\""],"proposed_change":"p"}]' "x"
chk "verdict: objection without falsifier" 1 "missing falsifier" python3 "$V" --extract "$TMP/v-nofals.json" --round 0
mkobj "$TMP/v-hyp.json" 0 REJECT '[{"id":"X-1","class":"RISK_UNMANAGED","severity":"BLOCKER","claim":"c","evidence":["hypothesis: the db may be slow"],"proposed_change":"p","falsifier":"f"}]' "x"
chk "verdict: hypothesis-only BLOCKER"  1 "hypothesis-only"     python3 "$V" --extract "$TMP/v-hyp.json" --round 0
mkobj "$TMP/v-praise.json" 0 APPROVE '[]' "great plan, I agree"
chk "verdict: praise language rejected" 1 "praise"              python3 "$V" --extract "$TMP/v-praise.json" --round 0
mkobj "$TMP/v-badcite.json" 0 REJECT '[{"id":"X-1","class":"FACT_ERROR","severity":"MAJOR","claim":"c","evidence":["f.txt:2-2@'"$SHA2"' \"line nine\""],"proposed_change":"p","falsifier":"f"}]' "x"
chk "verdict: fabricated citation caught" 1 "quote not found"   python3 "$V" --extract "$TMP/v-badcite.json" --round 0 --repo "$G2"
# F-02: an unpinned path citation is not evidence
mkobj "$TMP/v-unpinned.json" 0 REJECT '[{"id":"X-1","class":"FACT_ERROR","severity":"BLOCKER","claim":"c","evidence":["src/x.py:9999"],"proposed_change":"p","falsifier":"f"}]' "x"
chk "verdict: unpinned citation rejected" 1 "no sha-pinned"     python3 "$V" --extract "$TMP/v-unpinned.json" --round 0
# F-02: a citation to a commit other than the base is rejected
mkobj "$TMP/v-later.json" 0 REJECT '[{"id":"X-1","class":"FACT_ERROR","severity":"MAJOR","claim":"c","evidence":["f.txt:2-2@'"$SHA_LATER"' \"line two\""],"proposed_change":"p","falsifier":"f"}]' "x"
chk "verdict: non-base sha rejected"   1 "base SHA"             python3 "$V" --extract "$TMP/v-later.json" --round 0 --repo "$G2" --base-sha "$SHA2"
# F-11: extensionless paths are ordinary paths
mkobj "$TMP/v-noext.json" 0 REJECT '[{"id":"X-1","class":"FACT_ERROR","severity":"MAJOR","claim":"c","evidence":["Dockerfile:1-1@'"$SHA2"' \"FROM python\""],"proposed_change":"p","falsifier":"f"}]' "x"
chk "verdict: extensionless path accepted" 0 "OK"               python3 "$V" --extract "$TMP/v-noext.json" --round 0 --repo "$G2" --base-sha "$SHA2"
# F-13: praise words inside a quoted evidence line are not Codex's praise
mkobj "$TMP/v-quote.json" 0 REJECT '[{"id":"X-1","class":"FACT_ERROR","severity":"MAJOR","claim":"c","evidence":["cmd: grep great -> a great line"],"proposed_change":"p","falsifier":"f"}]' "x"
chk "verdict: praise inside evidence ignored" 0 "OK"            python3 "$V" --extract "$TMP/v-quote.json" --round 0
# F-05: empty design objects, two preferred designs, unknown root-cause references
python3 - "$TMP/v-ok.json" "$TMP/v-empty.json" "$TMP/v-twopref.json" "$TMP/v-badref.json" <<'PY2'
import json,sys
v=json.load(open(sys.argv[1])); v["objections"]=[]; v["verdict"]="REJECT"
e=dict(v); e["designs"]=[{},{}]; json.dump(e,open(sys.argv[2],"w"))
t=json.loads(json.dumps(v)); t["designs"][1]["preferred"]=True; json.dump(t,open(sys.argv[3],"w"))
b=json.loads(json.dumps(v)); b["designs"][0]["addresses"]=["RC-9"]; json.dump(b,open(sys.argv[4],"w"))
PY2
chk "verdict: empty designs rejected"  1 "design without an id" python3 "$V" --extract "$TMP/v-empty.json" --round 0
chk "verdict: two preferred designs"   1 "exactly one design"   python3 "$V" --extract "$TMP/v-twopref.json" --round 0
chk "verdict: unknown root cause ref"  1 "unknown root cause"   python3 "$V" --extract "$TMP/v-badref.json" --round 0
# F-06: round 1 must resolve round-0 objections
mkobj "$TMP/v-r1-none.json" 1 APPROVE '[]' "x"
chk "verdict: round 1 must resolve r0" 1 "must resolve every prior" python3 "$V" --extract "$TMP/v-r1-none.json" --round 1 --prior "$TMP/v-hyp.json"
# proportionality: the content cause class is accepted, an unknown class still rejected
python3 - "$TMP/v-ok.json" "$TMP/v-content.json" "$TMP/v-badclass.json" <<'PY2'
import json,sys
v=json.load(open(sys.argv[1])); v["objections"]=[]; v["verdict"]="REJECT"
c=json.loads(json.dumps(v)); c["root_causes"][0]["cause_class"]="incorrect_authoritative_content"; json.dump(c,open(sys.argv[2],"w"))
b=json.loads(json.dumps(v)); b["root_causes"][0]["cause_class"]="docs_drift"; json.dump(b,open(sys.argv[3],"w"))
PY2
chk "verdict: content cause class accepted" 0 "OK"              python3 "$V" --extract "$TMP/v-content.json" --round 0
chk "verdict: unknown cause class rejected" 1 "cause_class"     python3 "$V" --extract "$TMP/v-badclass.json" --round 0
# review F-03: a question with no defect is a valid round 0 only in question mode, and only with a cited answer
python3 - "$TMP/v-ok.json" "$TMP/v-q.json" "$TMP/v-q-nocite.json" "$SHA2" <<'PY2'
import json,sys
v=json.load(open(sys.argv[1])); v["objections"]=[]; v["verdict"]="APPROVE"; v["root_causes"]=[]; v["designs"]=[]
v["single_pr_recommendation"]={"verdict":"INSUFFICIENT_EVIDENCE","because":"no defect found"}
q=json.loads(json.dumps(v)); q["summary"]='Yes: f.txt:2-2@%s "line two" shows it.' % sys.argv[4]; json.dump(q,open(sys.argv[2],"w"))
n=json.loads(json.dumps(v)); n["summary"]="Yes, it is fine."; json.dump(n,open(sys.argv[3],"w"))
PY2
chk "verdict: question mode accepts no-defect answer" 0 "OK"   python3 "$V" --extract "$TMP/v-q.json" --round 0 --mode question --repo "$G2" --base-sha "$SHA2"
chk "verdict: question answer needs a citation" 1 "citation"    python3 "$V" --extract "$TMP/v-q-nocite.json" --round 0 --mode question --repo "$G2" --base-sha "$SHA2"
chk "verdict: no-defect shape rejected outside question mode" 1 "root_causes" python3 "$V" --extract "$TMP/v-q.json" --round 0 --repo "$G2" --base-sha "$SHA2"
printf 'no json here\n' > "$TMP/v-none.txt"
chk "verdict: no JSON block"           1 "no parseable JSON"    python3 "$V" --extract "$TMP/v-none.txt" --round 0
mkobj "$TMP/v-r1.json" 1 REJECT '[{"id":"X-1","class":"SCOPE","severity":"MINOR","claim":"c","evidence":["cmd: git grep x -> 0 hits"],"proposed_change":"p","falsifier":"f"}]' "x"
chk "verdict: round 1 accepted"        0 "OK verdict=REJECT"    python3 "$V" --extract "$TMP/v-r1.json" --out "$TMP/r1.json" --round 1
python3 - "$TMP/r1.json" "$TMP/v-r2.json" <<'PY2'
import json,sys
v=json.load(open(sys.argv[1])); v["round"]=2; v["objections"]=[]
v["objection_resolutions"]=[{"id":"X-1","status":"WITHDRAWN","because":"you make a good point"}]
json.dump(v,open(sys.argv[2],"w"))
PY2
chk "verdict: evidence-free withdrawal" 1 "praise"              python3 "$V" --extract "$TMP/v-r2.json" --round 2 --prior "$TMP/r1.json"
python3 - "$TMP/r1.json" "$TMP/v-r2b.json" <<'PY2'
import json,sys
v=json.load(open(sys.argv[1])); v["round"]=2; v["objections"]=[]; v["objection_resolutions"]=[]
json.dump(v,open(sys.argv[2],"w"))
PY2
chk "verdict: unresolved prior objection" 1 "must resolve every prior" python3 "$V" --extract "$TMP/v-r2b.json" --round 2 --prior "$TMP/r1.json"

echo "deep-plan: build-prompt.sh fills the blind brief and refuses leaks"
BP="$DS/build-prompt.sh"
chk "prompt: --art with no value"      2 "requires a value"     bash "$BP" --art
chk "prompt: missing --round"          2 "--round is required"  bash "$BP" --art "$A"
chk "prompt: non-numeric round"        2 "whole number"         bash "$BP" --art "$A" --round x
chk "prompt: unknown arg"              2 "unknown arg"          bash "$BP" --art "$A" --round 0 --bogus 1
chk "prompt: no meta.json"             2 "no meta.json"         bash "$BP" --art "$TMP" --round 0
printf '# Scope\n\n## In-scope paths\n- f.txt\n\nSTATUS: PHASE 0 COMPLETE\n' > "$A/00-scope.md"
chk "prompt: round 0 built"            0 "prompt written"       bash "$BP" --art "$A" --round 0
grep -q 'make it fast' "$A/debate/r0-prompt.md" && grep -q "$SHA2" "$A/debate/r0-prompt.md" && grep -q '^- f.txt$' "$A/debate/r0-prompt.md" && ! grep -q '{{' "$A/debate/r0-prompt.md" \
  && printf '  ok    %-42s\n' "brief carries inputs, sha, paths, no {{}}" || { printf '  FAIL  brief content\n'; FAIL=1; }
printf '# Scope\n\n## In-scope paths\n- f.txt (compare with the second analysis in the debate dir)\n' > "$A/00-scope.md"
chk "prompt: leak in scope paths exits 3" 3 "LEAK"              bash "$BP" --art "$A" --round 0
# a real repository path may contain a leak word (this repo has plugins/codex-debate and .claude-plugin)
( cd "$G2" && mkdir -p debate && echo n > debate/notes.md && mkdir -p .claude-plugin && echo '{}' > .claude-plugin/plugin.json && git add -A && git commit -qm leakpaths )
printf '# Scope\n\n## In-scope paths\n- debate/notes.md\n- .claude-plugin/plugin.json (manifest)\n- f.txt\n' > "$A/00-scope.md"
chk "prompt: repository paths with leak words pass" 0 "prompt written" bash "$BP" --art "$A" --round 0
grep -q '^- debate/notes.md$' "$A/debate/r0-prompt.md" && grep -q '^- .claude-plugin/plugin.json (manifest)$' "$A/debate/r0-prompt.md" && printf '  ok    %-42s\n' "exempt paths restored in the brief" || { printf '  FAIL  exempt paths not restored\n'; FAIL=1; }
# review F-01: only normalized relative repository paths are exempt — never absolute or `..` paths, whatever exists there
LEAKDIR="$TMP/debate-artifacts"; mkdir -p "$LEAKDIR"
printf '# Scope\n\n## In-scope paths\n- %s\n- f.txt\n' "$LEAKDIR" > "$A/00-scope.md"
chk "prompt: absolute existing path is not exempt" 3 "LEAK"    bash "$BP" --art "$A" --round 0
printf '# Scope\n\n## In-scope paths\n- ../%s/debate/notes.md\n' "$(basename "$G2")" > "$A/00-scope.md"
chk "prompt: parent-relative path is not exempt" 3 "LEAK"      bash "$BP" --art "$A" --round 0
# a path present at the pinned base SHA but deleted from the worktree is still exempt (git branch)
A5="$TMP/art5"; bash "$I" --repo "$G2" --out "$A5" --request x >/dev/null 2>&1; rm -f "$G2/debate/notes.md"
printf '# Scope\n\n## In-scope paths\n- debate/notes.md\n' > "$A5/00-scope.md"
chk "prompt: path at base SHA only is exempt" 0 "prompt written" bash "$BP" --art "$A5" --round 0
( cd "$G2" && git checkout -q -- debate/notes.md )
printf '# Scope\n\n## In-scope paths\n- f.txt\n' > "$A/00-scope.md"
printf 'Please compare this with Claude'"'"'s debate.\n' > "$TMP/req-claude.txt"
A3="$TMP/art3"; bash "$I" --repo "$G2" --out "$A3" --request-file "$TMP/req-claude.txt" >/dev/null 2>&1
chk "prompt: inputs are exempt from the leak check" 0 "prompt written" bash "$BP" --art "$A3" --round 0
chk "prompt: round 1 needs the r0 reply" 2 "required file missing" bash "$BP" --art "$A" --round 1
echo 'reply' > "$A/debate/r0-codex.stdout"; for f in 02-root-cause 03-designs; do echo "# $f" > "$A/$f.md"; done; echo '# div' > "$A/debate/divergence.md"
chk "prompt: round 1 built"            0 "prompt written"       bash "$BP" --art "$A" --round 1
grep -q '<file name="debate/divergence.md">' "$A/debate/r1-prompt.md" && grep -q 'Round 1 of 2' "$A/debate/r1-prompt.md" && printf '  ok    %-42s\n' "round 1 carries materials and cap" || { printf '  FAIL  round 1 content\n'; FAIL=1; }

echo "deep-plan: debate-status.py reports termination"
DSY="$DS/debate-status.py"
chk "status: usage"                    2 "usage"                python3 "$DSY"
chk "status: no rounds"                1 "NO_ROUNDS"            python3 "$DSY" --art "$A3"
cp "$TMP/v-ok.out.json" "$A/debate/r0-codex.json"
chk "status: approve with nothing open is T1" 0 "termination=T1" python3 "$DSY" --art "$A"
cp "$TMP/r1.json" "$A/debate/r1-codex.json"
printf '| id | Source | Claim | Class | Severity | Your verdict | Status | Evidence | Round |\n|---|---|---|---|---|---|---|---|---|\n| D-1 | X-1 | c | SCOPE | MINOR | REJECT | OPEN | F-1 | 1 |\n' > "$A/05-disagreements.md"
out=$(python3 "$DSY" --art "$A" 2>&1)
printf '%s' "$out" | grep -q 'LEDGER_OPEN: D-1' && printf '%s' "$out" | grep -q 'VERDICT: REJECT' && printf '%s' "$out" | grep -q 'termination=none' \
  && printf '  ok    %-42s\n' "open ledger row blocks T1" || { printf '  FAIL  status: %s\n' "$out"; FAIL=1; }
python3 - "$A/debate/r1-codex.json" "$A/debate/r2-codex.json" <<'PY2'
import json,sys
v=json.load(open(sys.argv[1])); v["round"]=2; json.dump(v,open(sys.argv[2],"w"))
PY2
out=$(python3 "$DSY" --art "$A" 2>&1)
printf '%s' "$out" | grep -q 'termination=T2' && printf '  ok    %-42s\n' "round cap reached is T2" || { printf '  FAIL  T2: %s\n' "$out"; FAIL=1; }
# Live-run friction 2026-09-02: Codex reused objection id X-1 in a later round for a new claim;
# the status block must show the latest claim and treat the re-raised id as open.
python3 - "$A/debate/r2-codex.json" <<'PY2'
import json,sys
v=json.load(open(sys.argv[1]))
v["objection_resolutions"]=[{"id":"X-1","status":"WITHDRAWN","because":"cmd: git grep x -> 0"}]
v["objections"]=[{"id":"X-1","class":"SCOPE","severity":"MAJOR","claim":"brand new claim under an old id","evidence":["cmd: git grep y -> 1"],"proposed_change":"p","falsifier":"f"}]
json.dump(v,open(sys.argv[1],"w"))
PY2
out=$(python3 "$DSY" --art "$A" 2>&1)
printf '%s' "$out" | grep -q 'OPEN_MAJORS: X-1: brand new claim' && printf '  ok    %-42s\n' "re-used objection id shows latest claim" || { printf '  FAIL  id reuse: %s\n' "$out"; FAIL=1; }
# F-07: a withdrawn objection stays withdrawn when a later round does not repeat it
A7="$TMP/art7"; mkdir -p "$A7/debate"; echo '{"rounds":3}' > "$A7/meta.json"
mkobj "$A7/debate/r0-codex.json" 0 REJECT '[{"id":"X-1","class":"SCOPE","severity":"MAJOR","claim":"old","evidence":["cmd: a -> b"],"proposed_change":"p","falsifier":"f"},{"id":"X-2","class":"TEST_GAP","severity":"MAJOR","claim":"c2","evidence":["cmd: a -> b"],"proposed_change":"p","falsifier":"f"}]' "x"
python3 - "$A7/debate/r0-codex.json" "$A7/debate/r1-codex.json" "$A7/debate/r2-codex.json" <<'PY2'
import json,sys
v=json.load(open(sys.argv[1])); v["objections"]=[]; v["round"]=1; v["verdict"]="REJECT"
v["objection_resolutions"]=[{"id":"X-1","status":"WITHDRAWN","because":"F-1"},{"id":"X-2","status":"SUSTAINED","because":"F-2"}]; json.dump(v,open(sys.argv[2],"w"))
v["round"]=2; v["verdict"]="APPROVE"; v["objection_resolutions"]=[{"id":"X-2","status":"WITHDRAWN","because":"F-3"}]; json.dump(v,open(sys.argv[3],"w"))
PY2
out=$(python3 "$DSY" --art "$A7" 2>&1)
printf '%s' "$out" | grep -q 'OPEN_MAJORS: none' && printf '%s' "$out" | grep -q 'termination=T1' && printf '  ok    %-42s\n' "withdrawn objection stays withdrawn (T1)" || { printf '  FAIL  withdrawn state: %s\n' "$out"; FAIL=1; }
# F-Q1: build-prompt refuses a round beyond the run's cap
chk "prompt: round beyond cap refused" 2 "exceeds the run"      bash "$BP" --art "$A" --round 3

echo "review: phase-gate.sh join gates (pre-codex / pre-phase3 / post-join)"
PG=plugins/codex-pr-review/skills/two-model-pr-review/scripts/phase-gate.sh
PB=plugins/codex-pr-review/skills/two-model-pr-review/scripts/build-verifier-packets.py
# Fixtures re-run launch gates back to back with no runner in between; the
# gate->runner handoff grace (round-26 CX-01) is exercised explicitly below.
export PHASE_GATE_CLAIM_GRACE_SEC=0
# One normalized base packet per matrix ID (03-findings.ndjson, round-26 CX-03).
base_packets() {
  python3 - "$1" <<'PYB'
import json, os, sys
d = sys.argv[1]; out = []
for line in open(os.path.join(d, "03-matrix.tsv")):
    line = line.strip()
    if not line or line.startswith("#"): continue
    fid, origin, sev = line.split("\t")
    out.append(json.dumps({"id": fid, "severity": sev, "claim": "x", "locations": ["a:1"], "trigger": "t", "impact": "i", "observations": ["a:1 \"x\""], "falsifier": "f", "proposed_checks": ["c"], "open_factual_questions": ["q"]}))
open(os.path.join(d, "03-findings.ndjson"), "w").write("".join(l + "\n" for l in out))
PYB
}
# Under the accept ledger 05-verdicts.tsv is a draft accepted by pre-resolution and
# frozen once Phase 6 has an artifact: to change verdicts a fixture goes back
# through pre-resolution with the Phase-6 status file cleared.
reverdict() {  # reverdict <dir> <verdicts> <06-resolution.md content> [<ids>]
  rm -f "$1/06-resolution.md"; printf "$2" > "$1/05-verdicts.tsv"
  [ -n "${4:-}" ] && printf "$4" > "$1/06-resolution-selection.ids"
  pgw pre-resolution "$1" >/dev/null 2>&1 || true
  printf "$3" > "$1/06-resolution.md"
}
# Generate 05-verifier-packets.ndjson the way pre-verification does (no consultation).
gen_packets() { python3 "$PB" --matrix "$1/03-matrix.tsv" --base "$1/03-findings.ndjson" --out "$1/05-verifier-packets.ndjson" >/dev/null || { printf '  FAIL  gen_packets %s\n' "$1"; FAIL=1; }; }
GA="$TMP/gate"; mkdir -p "$GA"
chk "gate: no arguments"               2 "usage"                pgw
chk "gate: unknown subcommand"         2 "usage"                pgw bogus "$GA"
chk "gate: pre-codex without repo"     2 "usage"                pgw pre-codex "$GA"
chk "gate: pre-codex, no brief"        1 "00-brief.md"          pgw pre-codex "$GA" "$G2"
printf 'scope\n' > "$GA/00-scope.md"; mkbrief "$GA"
chk "gate: pre-codex, lead absent"     0 "PREFLIGHT-OK"         pgw pre-codex "$GA" "$G2"
[ -s "$GA/00-brief.md.sha256" ] && [ -s "$GA/00-scope.md.sha256" ] && [ "$(wc -c < "$GA/00-brief.md.sha256" | tr -d ' ')" = "65" ] && printf '  ok    %-42s\n' "gate: 64-hex hashes recorded on first call" || { printf '  FAIL  gate: hashes not recorded\n'; FAIL=1; }
H1=$(cat "$GA/00-brief.md.sha256")
chk "gate: pre-codex repeat, unchanged" 0 "PREFLIGHT-OK"        pgw pre-codex "$GA" "$G2"
# compare-never-rewrite: a tampered record must make the gate fail, not be replaced by a fresh hash
printf '%s\n' "0000000000000000000000000000000000000000000000000000000000000000" > "$GA/00-brief.md.sha256"
chk "gate: pre-codex vs tampered record" 1 "changed since"        pgw pre-codex "$GA" "$G2"
[ "$(cat "$GA/00-brief.md.sha256")" = "0000000000000000000000000000000000000000000000000000000000000000" ] && printf '  ok    %-42s\n' "gate: record never rewritten" || { printf '  FAIL  gate: record rewritten\n'; FAIL=1; }
printf '%s\n' "$H1" > "$GA/00-brief.md.sha256"
rm -f "$GA/00-scope.md"
chk "gate: pre-codex, no scope"        1 "00-scope.md"          pgw pre-codex "$GA" "$G2"
printf 'scope\n' > "$GA/00-scope.md"
printf '%s\n' "0123456789abcdef0123456789abcdef01234567" > "$GA/00-brief.md.tree"
chk "gate: pre-codex, snapshot tree gone" 1 "no longer resolves" pgw pre-codex "$GA" "$G2"
rm -f "$GA/00-brief.md.tree"
# L-02r35: the recorded head/base revisions must resolve in the repository.
cp "$GA/00-brief.md.head" "$TMP/ga-head.bak"; printf '%s\n' "0123456789abcdef0123456789abcdef01234567" > "$GA/00-brief.md.head"
chk "L-02r35: unresolvable recorded head rejected" 1 "recorded head revision" pgw pre-codex "$GA" "$G2"
cp "$TMP/ga-head.bak" "$GA/00-brief.md.head"
rm -f "$GA/00-brief.md.base"
chk "L-02r35: missing recorded base rejected" 1 "00-brief.md.repo / 00-brief.md.base / 00-brief.md.head missing" bash "$PG" pre-codex "$GA" "$G2"
printf '%s\n' "$SHA2" > "$GA/00-brief.md.base"
# CX-06r36: the gate refuses a repository other than the one the brief was built for.
cp "$GA/00-brief.md.repo" "$TMP/ga-repo.bak"; printf '/nowhere/else\n' > "$GA/00-brief.md.repo"
chk "CX-06r36: repository differs from the brief's" 1 "differs from the one the brief was built for" pgw pre-codex "$GA" "$G2"
cp "$TMP/ga-repo.bak" "$GA/00-brief.md.repo"
# CX-02r38: the builder's sidecars must restate the frozen brief's Target (00-repo.txt is derived from them).
printf '%s\n' "$(git -C "$G2" rev-parse HEAD)" > "$GA/00-brief.md.head"
chk "CX-02r38: recorded head differs from the brief's Target" 1 "differs from the frozen brief's Target head" pgw pre-codex "$GA" "$G2"
cp "$TMP/ga-head.bak" "$GA/00-brief.md.head"
# CX-03r38: claim creation/rotation and a runner taking the claim share <prefix>.claim.lock.
mkdir "$GA/02-codex.claim.lock"
chk "CX-03r38: held claim lock blocks the launch gate" 1 "claim.lock is held" pgw pre-codex "$GA" "$G2"
touch -t 202001010000 "$GA/02-codex.claim.lock"
chk "CX-03r38: stale claim lock reclaimed" 0 "PREFLIGHT-OK" pgw pre-codex "$GA" "$G2"
[ ! -e "$GA/02-codex.claim.lock" ] && printf '  ok    %-42s\n' "CX-03r38: gate releases the claim lock" || { printf '  FAIL  CX-03r38: claim lock left behind\n'; FAIL=1; }
out=$(pgw pre-codex "$GA" "$G2" 2>&1); tok=$(printf '%s' "$out" | grep -oE 'claim=[0-9a-f]{16}' | cut -d= -f2)
[ -n "$tok" ] && grep -qx "token=$tok" "$GA/02-codex.claim/owner" && printf '  ok    %-42s\n' "CX-03r36: gate prints the claim token it wrote" || { printf '  FAIL  CX-03r36: token missing (%s)\n' "$out"; FAIL=1; }
( cd "$GA" && chk "gate: pre-codex with a relative ART" 0 "PREFLIGHT-OK" bash "$OLDPWD/$PG" pre-codex . "$G2" )
GN="$TMP/gate-nopre"; mkdir -p "$GN"; printf 'scope\n' > "$GN/00-scope.md"; mkbrief "$GN"; printf 'lead\n' > "$GN/01-lead.md"; chmod 000 "$GN/01-lead.md"; printf 'x\nSTATUS: PHASE 2 COMPLETE (SKIPPED — declined)\n' > "$GN/02-codex.md"
chk "gate: pre-phase3 without pre-codex" 1 "pre-codex never ran" pgw pre-phase3 "$GN"
printf 'lead\n' > "$GA/01-lead.md"; chmod 600 "$GA/01-lead.md"
chk "gate: pre-codex, lead readable"   1 "not sealed"           pgw pre-codex "$GA" "$G2"
chmod 000 "$GA/01-lead.md"
chk "gate: pre-codex, lead sealed"     0 "PREFLIGHT-OK"         pgw pre-codex "$GA" "$G2"
printf 'shard\n' > "$GA/01-lead.api.md"; chmod 600 "$GA/01-lead.api.md"
chk "gate: pre-codex, shard file readable" 1 "01-lead.api.md"   pgw pre-codex "$GA" "$G2"
chmod 000 "$GA/01-lead.api.md"
chk "gate: pre-codex, shard file sealed" 0 "PREFLIGHT-OK"       pgw pre-codex "$GA" "$G2"
rm -f "$GA/01-lead.api.md"
printf 'brief changed\n' > "$GA/00-brief.md"
chk "gate: pre-codex after brief mutated" 1 "changed since"    pgw pre-codex "$GA" "$G2"
printf 'brief mentions %s\n' "$GA" > "$GA/00-brief.md"
chk "gate: pre-codex, brief names run dir" 1 "run directory"   pgw pre-codex "$GA" "$G2"
mkbrief "$GA"
# F-08 (2.0.0 review): a failed hasher must fail the gate, never record an empty hash
GB="$TMP/gate-nohash"; mkdir -p "$GB/bin"; printf '#!/bin/sh\nexit 127\n' > "$GB/bin/python3"; printf '#!/bin/sh\nexit 127\n' > "$GB/bin/shasum"; printf '#!/bin/sh\nexit 127\n' > "$GB/bin/sha256sum"; chmod +x "$GB/bin/"*
printf 'scope\n' > "$GB/00-scope.md"; mkbrief "$GB"
out=$(PATH="$GB/bin:$PATH" pgw pre-codex "$GB" "$G2" 2>&1); code=$?
[ "$code" = 1 ] && printf '%s' "$out" | grep -q "cannot hash" && [ ! -e "$GB/00-brief.md.sha256" ] && printf '  ok    %-42s exit=1\n' "gate: no hasher → fail, nothing recorded" || { printf '  FAIL  gate: no hasher: exit=%s out=%s\n' "$code" "$out"; FAIL=1; }
# pre-phase3 — SKIPPED form needs no runner sidecar (F-02); COMPLETE form does
chk "gate: pre-phase3, no 02-codex.md"  1 "02-codex.md"         pgw pre-phase3 "$GA"
printf 'outcome\n' > "$GA/02-codex.md"
chk "gate: pre-phase3, no STATUS line" 1 "STATUS"               pgw pre-phase3 "$GA"
printf 'PROBE FAILED\nSTATUS: PHASE 2 COMPLETE (SKIPPED — probe failed)\n' > "$GA/02-codex.md"
chk "gate: pre-phase3, SKIPPED, no .exit" 0 "codex=SKIPPED"     pgw pre-phase3 "$GA"
[ -e "$GA/02-review-seal.sha256" ] && grep -q '^phase2=SKIPPED' "$GA/02-review-seal.sha256" && printf '  ok    %-42s\n' "CX-02r22: SKIPPED join writes a seal" || { printf '  FAIL  CX-02r22: no seal after SKIPPED join\n'; FAIL=1; }
printf 'outcome\nSTATUS: PHASE 2 COMPLETE\n' > "$GA/02-codex.md"
chk "gate: pre-phase3, COMPLETE, no .exit" 1 "02-codex.exit"    pgw pre-phase3 "$GA"
echo 0 > "$GA/02-codex.exit"
printf 'blind Codex output\n' > "$GA/02-codex.stdout"
chk "CX-02r22: status flip after SKIPPED join caught" 1 "status changed after JOIN-OK" pgw pre-phase3 "$GA"
chmod u+w "$GA/02-review-seal.sha256"; rm -f "$GA/02-review-seal.sha256" "$GA/00-accepted.sha256"   # fresh join (seal + ledger) for the COMPLETE cases
chk "gate: pre-phase3, COMPLETE status" 0 "JOIN-OK"             pgw pre-phase3 "$GA"
printf 'outcome\nSTATUS: PHASE 2 COMPLETE\n\n' > "$GA/02-codex.md"
chk "gate: pre-phase3, trailing blank line" 0 "JOIN-OK"         pgw pre-phase3 "$GA"
chmod 600 "$GA/01-lead.md"
chk "gate: pre-phase3, lead readable"  1 "not sealed"           pgw pre-phase3 "$GA"
: > "$GA/01-lead.md"; chmod 000 "$GA/01-lead.md"
chk "gate: pre-phase3, lead empty"     1 "empty"                pgw pre-phase3 "$GA"
rm -f "$GA/01-lead.md"
chk "gate: pre-phase3, lead absent"    1 "01-lead.md missing"   pgw pre-phase3 "$GA"
printf 'lead\n' > "$GA/01-lead.md"; chmod 000 "$GA/01-lead.md"; printf 'scope changed\n' > "$GA/00-scope.md"
chk "gate: pre-phase3, hash mismatch"  1 "changed since"        pgw pre-phase3 "$GA"
printf 'scope\n' > "$GA/00-scope.md"
# post-join (completion gate): lead unsealed by Phase 3, must end with its STATUS line (F-04)
chk "gate: post-join, lead still sealed" 1 "still sealed"       pgw post-join "$GA"
chmod 600 "$GA/01-lead.md"
chk "gate: post-join, lead lacks STATUS" 1 "PHASE 1 COMPLETE"   pgw post-join "$GA"
printf 'lead\nSTATUS: PHASE 1 COMPLETE\n' > "$GA/01-lead.md"
# the lead was rewritten above, so re-join (fresh seal) before the consistency checks
chmod 000 "$GA/01-lead.md"; chmod u+w "$GA/02-review-seal.sha256" 2>/dev/null; rm -f "$GA/02-review-seal.sha256" "$GA/00-accepted.sha256"
pgw pre-phase3 "$GA" >/dev/null || { printf '  FAIL  gate: re-join for post-join fixture\n'; FAIL=1; }
grep -q ' 02-review-seal.sha256  pre-phase3  final$' "$GA/00-accepted.sha256" && [ "$(fmode "$GA/00-accepted.sha256")" = 400 ] && printf '  ok    %-42s\n' "ledger: join accepts the review seal (mode 400)" || { printf '  FAIL  ledger: seal row missing or ledger writable\n'; FAIL=1; }
chmod 600 "$GA/01-lead.md"
chk "gate: post-join, consistent run"  0 "POST-JOIN-OK"         pgw post-join "$GA"
printf '%s\n' "0123456789abcdef0123456789abcdef01234567" > "$GA/00-brief.md.tree"
chk "post-join: vanished snapshot tree rejected" 1 "no longer resolves" pgw post-join "$GA"
rm -f "$GA/00-brief.md.tree"
# CX-02r22: post-join now verifies the sealed bodies, not just the status
printf 'lead edited\nSTATUS: PHASE 1 COMPLETE\n' > "$GA/01-lead.md"
chk "CX-02r22: post-join catches an edited lead body" 1 "initial review bodies changed" pgw post-join "$GA"
printf 'lead\nSTATUS: PHASE 1 COMPLETE\n' > "$GA/01-lead.md"
printf 'brief changed\n' > "$GA/00-brief.md"
chk "gate: post-join, hash mismatch"   1 "changed since"        pgw post-join "$GA"

# CX-01r22: pre-codex must refuse to relaunch over an exit-5 / unconfirmed-cancel
# Phase-2 sidecar even when no seal (and no 02-codex.md) exists.
PC5="$TMP/cx01r22"; mkdir -p "$PC5"; printf 'scope\n' > "$PC5/00-scope.md"; mkbrief "$PC5"
printf '5\n' > "$PC5/02-codex.exit"
chk "CX-01r22: pre-codex rejects exit-5 sidecar without seal" 1 "02-codex recorded exit 5" pgw pre-codex "$PC5" "$G2"
rm -f "$PC5/02-codex.exit"; printf 'outcome=STALLED\ncancel_confirmed=no\n' > "$PC5/02-codex.attempt1.meta"
chk "CX-01r22: pre-codex rejects rotated cancel_confirmed=no" 1 "cancel_confirmed=no" pgw pre-codex "$PC5" "$G2"
rm -f "$PC5/02-codex.attempt1.meta"
chk "CX-01r22: pre-codex passes once sidecars are gone" 0 "PREFLIGHT-OK" pgw pre-codex "$PC5" "$G2"
# CX-02r25 / CX-01r26, as simplified by the round-27 debate: a claim is in flight
# while its runner has started (.progress, no .exit) or while the claim directory
# is younger than the grace window (a directory with no owner file counts); no
# pid heuristics. Beyond that, recovery is explicit removal.
[ -d "$PC5/02-codex.claim" ] && printf '  ok    %-42s\n' "CX-02r25: pre-codex takes a claim" || { printf '  FAIL  CX-02r25: no claim directory\n'; FAIL=1; }
printf '0s launched job=x\n' > "$PC5/02-codex.progress"
chk "CX-02r25: running runner blocks a second launch" 1 "runner has started" pgw pre-codex "$PC5" "$G2"
rm -f "$PC5/02-codex.progress"
chk "CX-02r25: stale claim (past grace, no runner) reclaimed" 0 "PREFLIGHT-OK" pgw pre-codex "$PC5" "$G2"
[ -d "$PC5/02-codex.claim.spent1" ] && printf '  ok    %-42s\n' "CX-02r25: stale claim rotated aside" || { printf '  FAIL  CX-02r25: stale claim not rotated\n'; FAIL=1; }
chk "CX-01r26: fresh claim is in flight during the grace window" 1 "may still be launching" pgwg 600 pre-codex "$PC5" "$G2"
rm -f "$PC5/02-codex.claim/owner"
chk "CX-01r27: claim directory without an owner file counts as in flight" 1 "may still be launching" pgwg 600 pre-codex "$PC5" "$G2"
touch -t 202001010000 "$PC5/02-codex.claim"
chk "CX-01r26: claim older than the grace window is reclaimed" 0 "PREFLIGHT-OK" pgwg 600 pre-codex "$PC5" "$G2"
# CX-03r30: a claim whose runner took its lock (claim/runner) is in flight regardless of age.
mkdir -p "$PC5/02-codex.claim/runner"; touch -t 202001010000 "$PC5/02-codex.claim"
chk "CX-03r30: stamped claim stays in flight past the grace window" 1 "runner has started" pgwg 600 pre-codex "$PC5" "$G2"
# Round-32 debate: release is the only recovery for a started-and-died claim; it never deletes.
printf '%s\n' "$$" > "$PC5/02-codex.claim/runner/pid"
chk "release: live runner refused" 1 "is still alive" bash "$PG" release "$PC5" 02-codex
printf '2147483646\n' > "$PC5/02-codex.claim/runner/pid"
printf '0s launched job=task-fake-job1\n' > "$PC5/02-codex.progress"
chk "release: job without a reachable codex plugin refused" 1 "cannot locate the codex plugin" env HOME="$TMP/nohome" bash "$PG" release "$PC5" 02-codex
FAKE="$TMP/fakehome/.claude/plugins/cache/openai-codex/codex/9.9.9/scripts"; mkdir -p "$FAKE"
printf 'if (process.argv.includes("--all")) { console.log(JSON.stringify({running: process.env.FAKE_RUNNING ? [{id:"task-live-1", workspaceRoot: process.env.FAKE_RUNNING}] : []})); } else { console.log(JSON.stringify({job:{status:process.env.FAKE_STATUS||"running"}})); }\n' > "$FAKE/codex-companion.mjs"
chk "release: running job refused" 1 "not provably finished" env HOME="$TMP/fakehome" FAKE_STATUS=running bash "$PG" release "$PC5" 02-codex
( exec -a "task-worker --job-id task-fake-job1" sleep 30 ) & WPID=$!; sleep 1
chk "release: live worker process refused" 1 "worker process for job task-fake-job1 is still alive" env HOME="$TMP/fakehome" FAKE_STATUS=completed bash "$PG" release "$PC5" 02-codex
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
chk "release: finished job rotates the claim" 0 "RELEASED 02-codex -> 02-codex.claim.spent" env HOME="$TMP/fakehome" FAKE_STATUS=completed bash "$PG" release "$PC5" 02-codex
[ ! -d "$PC5/02-codex.claim" ] && ls -d "$PC5"/02-codex.claim.spent*/runner >/dev/null 2>&1 && grep -q '^released_by=phase-gate.sh release' "$PC5"/02-codex.claim.spent*/owner && printf '  ok    %-42s\n' "release: rotated claim keeps runner/ (still a counted launch)" || { printf '  FAIL  release: claim not rotated with runner\n'; FAIL=1; }
chk "release: nothing live to release" 1 "no live claim" bash "$PG" release "$PC5" 02-codex
rm -f "$PC5/02-codex.progress"; rm -rf "$PC5"/02-codex.claim.spent*
# CX-01r34: .progress exists but records no job id (runner killed between `task` and the append) — release must
# consult the companion and refuse while any job runs in the reviewed repository.
mkdir -p "$PC5/02-codex.claim/runner"; printf '2147483646\n' > "$PC5/02-codex.claim/runner/pid"; : > "$PC5/02-codex.progress"
fixture_revs "$PC5"
chk "CX-01r34: unrecorded job without a reachable plugin refused" 1 "cannot locate the codex plugin" env HOME="$TMP/nohome" bash "$PG" release "$PC5" 02-codex
chk "CX-01r34: unrecorded job with a running job in the repo refused" 1 "records no job id, and a Codex job is still running" env HOME="$TMP/fakehome" FAKE_RUNNING="$G2" bash "$PG" release "$PC5" 02-codex
chk "CX-01r34: unrecorded job, nothing running → released" 0 "RELEASED 02-codex" env HOME="$TMP/fakehome" bash "$PG" release "$PC5" 02-codex
rm -f "$PC5/02-codex.progress"; rm -rf "$PC5"/02-codex.claim.spent*
# CX-03r37: runner/ without a pid is a runner mid-acquisition unless it is old.
mkdir -p "$PC5/02-codex.claim/runner"
chk "CX-03r37: fresh pid-less runner dir refused" 1 "taking the 02-codex claim right now" env HOME="$TMP/nohome" bash "$PG" release "$PC5" 02-codex
touch -t 202001010000 "$PC5/02-codex.claim/runner"
chk "CX-03r37: old pid-less runner dir released" 0 "RELEASED 02-codex" env HOME="$TMP/nohome" bash "$PG" release "$PC5" 02-codex
rm -rf "$PC5"/02-codex.claim.spent*
# lock-only claim (runner/ but no .progress): provably no job, rotated after the pid check alone
mkdir -p "$PC5/02-codex.claim/runner"; printf '2147483646\n' > "$PC5/02-codex.claim/runner/pid"
chk "release: lock-only dead claim rotated" 0 "RELEASED 02-codex" env HOME="$TMP/nohome" bash "$PG" release "$PC5" 02-codex
rm -rf "$PC5"/02-codex.claim.spent*
mkdir -p "$PC5/02-codex.claim/runner"; touch -t 202001010000 "$PC5/02-codex.claim"
rm -rf "$PC5/02-codex.claim/runner"
# CX-02r27: the claim is the gate's last step, so a failing preflight check leaves no claim behind.
rm -rf "$PC5"/02-codex.claim*; printf 'lead\n' > "$PC5/01-lead.md"; chmod 600 "$PC5/01-lead.md"
chk "CX-02r27: unsealed lead fails preflight" 1 "not sealed" pgw pre-codex "$PC5" "$G2"
[ ! -d "$PC5/02-codex.claim" ] && printf '  ok    %-42s\n' "CX-02r27: failed preflight leaves no claim" || { printf '  FAIL  CX-02r27: claim left behind by a failed preflight\n'; FAIL=1; }
rm -f "$PC5/01-lead.md"
chk "CX-02r27: preflight passes again with no leftover claim" 0 "PREFLIGHT-OK" pgw pre-codex "$PC5" "$G2"
# L-01r26: spent claims are bounded.
printf '4\n' > "$PC5/02-codex.exit"
for n in $(seq 1 9); do mkdir -p "$PC5/02-codex.claim.spent$n"; done
chk "L-01r26: tenth spent claim refused" 1 "spent claims already" pgw pre-codex "$PC5" "$G2"
rm -rf "$PC5"/02-codex.claim.spent[1-9] "$PC5/02-codex.exit"
# CX-03r23: an unjoined but COMPLETE Phase 2 must not be silently redone; a SKIPPED one may be retried.
printf 'codex\nSTATUS: PHASE 2 COMPLETE\n' > "$PC5/02-codex.md"; printf '0\n' > "$PC5/02-codex.exit"; printf 'body\n' > "$PC5/02-codex.stdout"
chk "CX-03r23: pre-codex refuses to redo an unjoined completed review" 1 "already records a completed blind review" pgw pre-codex "$PC5" "$G2"
printf 'PROBE FAILED\nSTATUS: PHASE 2 COMPLETE (SKIPPED — probe failed)\n' > "$PC5/02-codex.md"; rm -f "$PC5/02-codex.exit" "$PC5/02-codex.stdout"
chk "CX-03r23: pre-codex allows retrying a SKIPPED review" 0 "PREFLIGHT-OK" pgw pre-codex "$PC5" "$G2"
# CX-01r30: a SKIPPED Phase 2 over a successful (exit 0) attempt, current or rotated, is not skippable.
printf '0\n' > "$PC5/02-codex.attempt3.exit"; printf 'body\n' > "$PC5/02-codex.attempt3.stdout"
chk "CX-01r30: SKIPPED review over a rotated exit-0 attempt refused" 1 "succeeded (exit 0, non-empty response); write the terminal artifact" pgw pre-codex "$PC5" "$G2"
rm -f "$PC5/02-codex.attempt3."*; printf '0\n' > "$PC5/02-codex.exit"; printf 'body\n' > "$PC5/02-codex.stdout"
chk "CX-01r30: SKIPPED review over a current exit-0 attempt refused" 1 "succeeded (exit 0" pgw pre-codex "$PC5" "$G2"
# L-01r31: exit 0 with an empty response is a failed attempt — skippable, and never a COMPLETE review.
: > "$PC5/02-codex.stdout"
chk "L-01r31: SKIPPED review over an empty exit-0 response allowed" 0 "PREFLIGHT-OK" pgw pre-codex "$PC5" "$G2"
printf 'codex\nSTATUS: PHASE 2 COMPLETE\n' > "$PC5/02-codex.md"
chk "L-01r31: COMPLETE review with an empty response refused" 1 "02-codex.stdout is empty" pgw pre-codex "$PC5" "$G2"
rm -f "$PC5/02-codex.md"
chk "CX-05r36: exit 0 with an empty body does not block a Phase-2 relaunch" 0 "PREFLIGHT-OK" pgw pre-codex "$PC5" "$G2"
printf 'PROBE FAILED\nSTATUS: PHASE 2 COMPLETE (SKIPPED — probe failed)\n' > "$PC5/02-codex.md"
rm -f "$PC5/02-codex.exit" "$PC5/02-codex.stdout"
# CX-01r24: an accepted current attempt with no terminal artifact must not be relaunched.
rm -f "$PC5/02-codex.md"; printf '0\n' > "$PC5/02-codex.exit"; printf 'body\n' > "$PC5/02-codex.stdout"
chk "CX-01r24: pre-codex refuses relaunch over accepted attempt without 02-codex.md" 1 "accepted attempt with no 02-codex.md" pgw pre-codex "$PC5" "$G2"
rm -f "$PC5/02-codex.exit" "$PC5/02-codex.stdout"

echo "review: consultation validator and state gates"
CV=plugins/codex-pr-review/skills/two-model-pr-review/scripts/validate-consultation.py
[ -x "$CV" ] && printf '  ok    %-42s\n' "consultation validator is executable" || { printf '  FAIL  consultation validator is not executable\n'; FAIL=1; }
CS="$TMP/consult"; mkdir -p "$CS"
printf 'scope\n' > "$CS/00-scope.md"; mkbrief "$CS"
pgw pre-codex "$CS" "$G2" >/dev/null || { printf '  FAIL  consultation fixture pre-codex\n'; FAIL=1; }
printf 'lead\nSTATUS: PHASE 1 COMPLETE\n' > "$CS/01-lead.md"; chmod 000 "$CS/01-lead.md"
printf 'codex\nSTATUS: PHASE 2 COMPLETE\n' > "$CS/02-codex.md"; printf '0\n' > "$CS/02-codex.exit"; printf 'blind codex body\n' > "$CS/02-codex.stdout"
top_up_claims "$CS"; mv "$CS/00-repo.txt" "$TMP/cs-repo.bak"
chk "CX-01r33: join requires the recorded repository" 1 "00-repo.txt missing" bash "$PG" pre-phase3 "$CS"
# CX-02r38: a 00-repo.txt redirected to another (valid) revision before the join is rejected: it must restate the frozen brief's Target.
printf 'repo=%s\nbase=%s\nhead=%s\n' "$(cd "$G2" && pwd -P)" "$SHA2" "$(git -C "$G2" rev-parse HEAD)" > "$CS/00-repo.txt"
chk "CX-02r38: redirected 00-repo.txt rejected at the join" 1 "differs from the frozen brief's Target head" bash "$PG" pre-phase3 "$CS"
mv "$TMP/cs-repo.bak" "$CS/00-repo.txt"
pgw pre-phase3 "$CS" >/dev/null || { printf '  FAIL  consultation fixture join\n'; FAIL=1; }
chmod 600 "$CS/01-lead.md"
printf 'matrix\nSTATUS: PHASE 3 COMPLETE\n' > "$CS/03-matrix.md"
printf 'F-01\tBOTH\tP2\nF-02\tCLAUDE-ONLY\tP1\nF-03\tCODEX-ONLY\tP2\n' > "$CS/03-matrix.tsv"
base_packets "$CS"
PV=plugins/codex-pr-review/skills/two-model-pr-review/scripts/validate-verifier-packets.py
[ -x "$PV" ] && printf '  ok    %-42s\n' "verifier packet validator is executable" || { printf '  FAIL  verifier packet validator is not executable\n'; FAIL=1; }
printf 'F-01\tBOTH\tP2\tINCLUDE\tBOTH\nF-02\tCLAUDE-ONLY\tP1\tINCLUDE\tprovisional-P1\nF-03\tCODEX-ONLY\tP2\tEXCLUDE\tCODEX-ONLY-P2\n' > "$CS/03-debate-selection.tsv"
chk "consultation: valid selector"      0 "OK selected=2"        python3 "$CV" --manifest "$CS/03-matrix.tsv" --selection "$CS/03-debate-selection.tsv" --validate-selection
printf 'F-01\tBOTH\tP2\tINCLUDE\tBOTH\nF-01\tBOTH\tP2\tINCLUDE\tBOTH\nF-03\tCODEX-ONLY\tP2\tEXCLUDE\tCODEX-ONLY-P2\n' > "$CS/bad-selection.tsv"
chk "consultation: duplicate selector"  1 "duplicate selector"   python3 "$CV" --manifest "$CS/03-matrix.tsv" --selection "$CS/bad-selection.tsv" --validate-selection
printf 'F-01\tBOTH\tP2\tEXCLUDE\tBOTH\nF-02\tCLAUDE-ONLY\tP1\tINCLUDE\tprovisional-P1\nF-03\tCODEX-ONLY\tP2\tEXCLUDE\tCODEX-ONLY-P2\n' > "$CS/bad-policy.tsv"
chk "consultation: policy enforced"     1 "expected INCLUDE/BOTH" python3 "$CV" --manifest "$CS/03-matrix.tsv" --selection "$CS/bad-policy.tsv" --validate-selection
mv "$CS/03-findings.ndjson" "$TMP/cs-findings.bak"
chk "CX-03r26: pre-consultation requires the base packets" 1 "03-findings.ndjson missing" pgw pre-consultation "$CS"
printf '{"id":"F-01","severity":"P2"}\n' > "$CS/03-findings.ndjson"
chk "CX-03r26: invalid base packets rejected" 1 "03-findings.ndjson is invalid" pgw pre-consultation "$CS"
python3 - "$CS" <<'PY2'
import json, sys
d = sys.argv[1]
open(d + "/03-findings.ndjson", "w").write("".join(json.dumps({"id": i, "severity": "P3", "claim": "x", "locations": ["a:1"], "trigger": "t", "impact": "i", "observations": ["a:1 \"x\""], "falsifier": "f", "proposed_checks": ["c"], "open_factual_questions": ["q"]}) + "\n" for i in ("F-01", "F-02", "F-03")))
PY2
chk "CX-04r27: base packet severity mismatch rejected at pre-consultation" 1 "03-findings.ndjson is invalid" pgw pre-consultation "$CS"
mv "$TMP/cs-findings.bak" "$CS/03-findings.ndjson"
chk "gate: pre-consultation"            0 "CONSULTATION-OK"      pgw pre-consultation "$CS"
# CX-02r33: the reconciliation matrix is frozen once consultation begins.
grep -q ' 03-matrix.tsv  pre-consultation  draft$' "$CS/00-accepted.sha256" && grep -q ' 03-matrix.md  pre-consultation  draft$' "$CS/00-accepted.sha256" && printf '  ok    %-42s\n' "CX-02r33: matrix accepted at pre-consultation" || { printf '  FAIL  CX-02r33: matrix rows missing\n'; FAIL=1; }
cp "$CS/03-matrix.tsv" "$TMP/cs-matrix.bak"; printf '# edited\n' >> "$CS/03-matrix.tsv"
chk "CX-02r33: matrix edited after consultation began rejected" 1 "03-matrix.tsv changed after it was accepted by pre-consultation" pgw pre-verification "$CS"
cp "$TMP/cs-matrix.bak" "$CS/03-matrix.tsv"
# CX-02r37: a gate that cannot allocate its scratch file fails closed instead of counting responses as unusable.
chk "CX-02r37: unwritable TMPDIR fails the gate" 1 "cannot allocate a scratch file" env TMPDIR=/nonexistent-dir bash "$PG" pre-verification "$CS"
# CX-01r36: a runner that took a claim and has not written .exit blocks every later gate.
mkdir -p "$CS/04-consultation.claim/runner"
chk "CX-01r36: in-flight consultation runner blocks pre-verification" 1 "04-consultation runner is still in flight" pgw pre-verification "$CS"
rm -rf "$CS/04-consultation.claim"
# CX-01r40: a join interrupted between its atomic steps is completed by re-running pre-phase3
# (seal without ledger; ledger without the seal row); later gates and a run with later artifacts still refuse.
JN="$TMP/join-interrupted"; mkdir -p "$JN"; printf 'scope\n' > "$JN/00-scope.md"; mkbrief "$JN"
pgw pre-codex "$JN" "$G2" >/dev/null
printf 'lead\nSTATUS: PHASE 1 COMPLETE\n' > "$JN/01-lead.md"; chmod 000 "$JN/01-lead.md"
printf 'codex\nSTATUS: PHASE 2 COMPLETE\n' > "$JN/02-codex.md"; printf '0\n' > "$JN/02-codex.exit"; printf 'blind codex body\n' > "$JN/02-codex.stdout"
jnjoin=$(pgw pre-phase3 "$JN") || { printf '  FAIL  CX-01r40 fixture join\n'; FAIL=1; }
jnseal=$(printf '%s' "$jnjoin" | grep -oE 'seal=[0-9a-f]{12}')
[ -n "$jnseal" ] && [ "$jnseal" = "seal=$(shasum -a 256 "$JN/02-review-seal.sha256" | cut -c1-12)" ] && printf '  ok    %-42s\n' "CX-01r41: JOIN-OK carries the seal fingerprint" || { printf '  FAIL  CX-01r41: JOIN-OK seal fingerprint missing or wrong (%s)\n' "$jnjoin"; FAIL=1; }
cp "$JN/00-accepted.sha256" "$TMP/jn-ledger.bak"; cp "$JN/02-review-seal.sha256" "$TMP/jn-seal.bak"
rm -f "$JN/00-accepted.sha256"
chk "CX-01r40: seal without ledger completed by pre-phase3" 0 "JOIN-OK.*$jnseal" bash "$PG" pre-phase3 "$JN"
# CX-01r41: a join re-minted over an edited body after a wipe is visible only as a changed seal fingerprint.
rm -f "$JN/00-accepted.sha256" "$JN/02-review-seal.sha256"; printf 'edited codex body\n' > "$JN/02-codex.stdout"
chk "CX-01r41: re-minted join prints a different seal fingerprint" 0 "JOIN-OK" bash "$PG" pre-phase3 "$JN"
bash "$PG" pre-phase3 "$JN" 2>&1 | grep -q "$jnseal" && { printf '  FAIL  CX-01r41: re-minted seal kept the old fingerprint\n'; FAIL=1; } || printf '  ok    %-42s\n' "CX-01r41: re-minted seal fingerprint differs"
rm -f "$JN/00-accepted.sha256" "$JN/02-review-seal.sha256"; printf 'blind codex body\n' > "$JN/02-codex.stdout"; pgw pre-phase3 "$JN" >/dev/null
cmp -s "$JN/02-review-seal.sha256" "$TMP/jn-seal.bak" || { printf '  FAIL  CX-01r41: fixture restore\n'; FAIL=1; }
rm -f "$JN/00-accepted.sha256"
chk "CX-01r40: seal without ledger completed by pre-phase3 (restored)" 0 "JOIN-OK.*$jnseal" bash "$PG" pre-phase3 "$JN"
cmp -s "$JN/00-accepted.sha256" "$TMP/jn-ledger.bak" && cmp -s "$JN/02-review-seal.sha256" "$TMP/jn-seal.bak" && printf '  ok    %-42s\n' "CX-01r40: completed join equals the original" || { printf '  FAIL  CX-01r40: completed join differs\n'; FAIL=1; }
chmod 600 "$JN/00-accepted.sha256"; grep -v ' 02-review-seal.sha256 ' "$TMP/jn-ledger.bak" > "$JN/00-accepted.sha256"; chmod 400 "$JN/00-accepted.sha256"
printf 'matrix\nSTATUS: PHASE 3 COMPLETE\n' > "$JN/03-matrix.md"
chk "CX-01r40: seal row missing refused by a later gate" 1 "has no row" bash "$PG" pre-consultation "$JN"
chk "CX-01r40: seal row missing with later artifacts refused" 1 "has no row" bash "$PG" pre-phase3 "$JN"
rm -f "$JN/03-matrix.md"
chk "CX-01r40: ledger without the seal row completed by pre-phase3" 0 "JOIN-OK" bash "$PG" pre-phase3 "$JN"
cmp -s "$JN/00-accepted.sha256" "$TMP/jn-ledger.bak" && printf '  ok    %-42s\n' "CX-01r40: completed ledger equals the original" || { printf '  FAIL  CX-01r40: completed ledger differs\n'; FAIL=1; }
rm -f "$JN/02-review-seal.sha256"
chk "CX-01r40: completed join with its seal removed refused" 1 "02-review-seal.sha256 was accepted by pre-phase3 but is missing" bash "$PG" pre-phase3 "$JN"
# CX-02r36: the repository attestation and its row are required after the join.
cp "$CS/00-accepted.sha256" "$TMP/cs-ledger2.bak"; mv "$CS/00-repo.txt" "$TMP/cs-repo2.bak"
chmod 600 "$CS/00-accepted.sha256"; grep -v ' 00-repo.txt ' "$TMP/cs-ledger2.bak" > "$CS/00-accepted.sha256"; chmod 400 "$CS/00-accepted.sha256"
chk "CX-02r36: removed repository attestation + row rejected" 1 "00-repo.txt or its ledger row is missing" bash "$PG" pre-verification "$CS"
chmod 600 "$CS/00-accepted.sha256"; cp "$TMP/cs-ledger2.bak" "$CS/00-accepted.sha256"; chmod 400 "$CS/00-accepted.sha256"; mv "$TMP/cs-repo2.bak" "$CS/00-repo.txt"
# CX-01r38: removing the seal AND its row after the join is caught (the ledger exists), and the join never re-mints a seal.
mv "$CS/02-review-seal.sha256" "$TMP/cs-seal2.bak"
chmod 600 "$CS/00-accepted.sha256"; grep -v ' 02-review-seal.sha256 ' "$TMP/cs-ledger2.bak" > "$CS/00-accepted.sha256"; chmod 400 "$CS/00-accepted.sha256"
chk "CX-01r38: removed seal + row rejected" 1 "02-review-seal.sha256 does not" bash "$PG" pre-verification "$CS"
chmod 000 "$CS/01-lead.md"
chk "CX-01r38: pre-phase3 does not re-mint a removed seal" 1 "02-review-seal.sha256 does not" bash "$PG" pre-phase3 "$CS"
chmod 600 "$CS/01-lead.md"
[ ! -e "$CS/02-review-seal.sha256" ] && printf '  ok    %-42s\n' "CX-01r38: no seal minted over a joined run" || { printf '  FAIL  CX-01r38: seal re-minted\n'; FAIL=1; }
chmod 600 "$CS/00-accepted.sha256"; cp "$TMP/cs-ledger2.bak" "$CS/00-accepted.sha256"; chmod 400 "$CS/00-accepted.sha256"; mv "$TMP/cs-seal2.bak" "$CS/02-review-seal.sha256"
grep -q ' 03-findings.ndjson  pre-consultation  draft$' "$CS/00-accepted.sha256" && grep -q ' 03-debate-selection.tsv  pre-consultation  draft$' "$CS/00-accepted.sha256" && printf '  ok    %-42s\n' "CX-03r26: base packets and selector accepted as drafts" || { printf '  FAIL  CX-03r26: base packets/selector not in the ledger\n'; FAIL=1; }
[ -s "$CS/02-review-seal.sha256" ] && [ -r "$CS/02-review-seal.sha256" ] && printf '  ok    %-42s\n' "gate: readable review seal written" || { printf '  FAIL  review seal absent/unreadable\n'; FAIL=1; }
cat > "$CS/04-consultation.stdout" <<'CONSULT'
```json
{"phase":"consultation","dispositions":[
{"id":"F-01","action":"MAINTAIN","claim":"first","severity":"P2","locations":["plugins/codex-pr-review/a:1"],"trigger":"t","impact":"i","observations":["a:1@sha \"x\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":[]},
{"id":"F-02","action":"VERIFY","claim":"second","severity":"P1","locations":["b:2"],"trigger":"t","impact":"i","observations":["b:2@sha \"y\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":["q"]}
]}
```
CONSULT
chk "consultation: exact response IDs"  0 "dispositions=2"       python3 "$CV" --manifest "$CS/03-matrix.tsv" --selection "$CS/03-debate-selection.tsv" --phase consultation --extract "$CS/04-consultation.stdout" --out "$CS/04-consultation.json"
printf 'consultation\nSTATUS: PHASE 4 COMPLETE\n' > "$CS/04-consultation.md"
printf 'thread=thread-1\noutcome=COMPLETED\n' > "$CS/02-codex.meta"
printf 'thread=thread-2\noutcome=COMPLETED\ncommand=task --fresh --background --prompt-file p\n' > "$CS/04-consultation.meta"
printf '0\n' > "$CS/04-consultation.exit"
chk "gate: pre-verification"            0 "VERIFICATION-OK"      pgw pre-verification "$CS"
[ -s "$CS/05-verifier-packets.ndjson" ] && printf '  ok    %-42s\n' "CX-03r26: pre-verification generated the verifier packets" || { printf '  FAIL  CX-03r26: verifier packets not generated\n'; FAIL=1; }
chk "CX-03r26: pre-verification re-run keeps the generated packets" 0 "VERIFICATION-OK" pgw pre-verification "$CS"
# L-01r28: an accepted consultation cannot later be recorded SKIPPED.
cp "$CS/04-consultation.md" "$TMP/cs-04md.bak"; printf 'consultation\nSTATUS: PHASE 4 COMPLETE (SKIPPED — changed my mind)\n' > "$CS/04-consultation.md"
chk "L-01r28: SKIPPED after an accepted consultation refused" 1 "an accepted consultation cannot be skipped" pgw pre-verification "$CS"
cp "$TMP/cs-04md.bak" "$CS/04-consultation.md"
grep -q ' 04-consultation.stdout  pre-verification  final$' "$CS/00-accepted.sha256" && grep -q ' 04-consultation.json  pre-verification  final$' "$CS/00-accepted.sha256" && grep -q ' 04-consultation.thread  pre-verification  final$' "$CS/00-accepted.sha256" && grep -q ' 05-verifier-packets.ndjson  pre-verification  draft$' "$CS/00-accepted.sha256" && printf '  ok    %-42s\n' "ledger: consultation response, thread and packets accepted" || { printf '  FAIL  ledger: consultation rows missing\n'; FAIL=1; }
[ "$(fmode "$CS/00-accepted.sha256")" = 400 ] && printf '  ok    %-42s\n' "CX-02r23: accept ledger is read-only (mode 400)" || { printf '  FAIL  CX-02r23: ledger missing or writable\n'; FAIL=1; }
# CX-02r23: rewriting a still-valid consultation response after pre-verification is caught later.
cp "$CS/04-consultation.stdout" "$TMP/cs-stdout.bak"
python3 - "$CS/04-consultation.stdout" <<'PY2'
import sys; p=sys.argv[1]; s=open(p).read(); open(p,'w').write(s.replace('"claim": "', '"claim": "edited ', 1) if '"claim": "' in s else s.replace('"claim":"', '"claim":"edited ', 1))
PY2
chk "CX-02r23: edited consultation response caught at pre-resolution" 1 "04-consultation.stdout changed after it was accepted by pre-verification" pgw pre-resolution "$CS"
cp "$TMP/cs-stdout.bak" "$CS/04-consultation.stdout"
# CX-04r23: a writable ledger is rejected; a ledger rewritten to drop an accepted row is caught.
chmod 600 "$CS/00-accepted.sha256"
chk "CX-04r23: writable accept ledger rejected" 1 "must be read-only" pgw pre-resolution "$CS"
chmod 400 "$CS/00-accepted.sha256"
cp "$CS/00-accepted.sha256" "$TMP/cs-ledger.bak"
chmod 600 "$CS/00-accepted.sha256"; grep -v ' 04-consultation.stdout ' "$TMP/cs-ledger.bak" > "$CS/00-accepted.sha256"; chmod 400 "$CS/00-accepted.sha256"
chk "CX-04r23: ledger with a dropped consultation row rejected" 1 "04-consultation.stdout is not accepted" pgw pre-resolution "$CS"
chmod 600 "$CS/00-accepted.sha256"; grep -v ' 02-review-seal.sha256 ' "$TMP/cs-ledger.bak" > "$CS/00-accepted.sha256"; chmod 400 "$CS/00-accepted.sha256"
chk "CX-02r32: ledger with a dropped seal row rejected" 1 "02-review-seal.sha256 exists but has no row" pgw pre-resolution "$CS"
chmod 600 "$CS/00-accepted.sha256"; { cat "$TMP/cs-ledger.bak"; echo "deadbeef  05-verdicts.tsv  pre-resolution  draft"; } > "$CS/00-accepted.sha256"; chmod 400 "$CS/00-accepted.sha256"
chk "CX-04r23: malformed ledger row rejected" 1 "malformed row" pgw pre-resolution "$CS"
chmod 600 "$CS/00-accepted.sha256"; cp "$TMP/cs-ledger.bak" "$CS/00-accepted.sha256"; chmod 400 "$CS/00-accepted.sha256"
printf 'thread=wrong\noutcome=COMPLETED\ncommand=task --resume-last --background --prompt-file p\n' > "$CS/04-consultation.meta"
chk "gate: thread mismatch"             1 "unexpected Codex thread" pgw pre-verification "$CS"
printf 'thread=thread-2\noutcome=COMPLETED\ncommand=task --fresh --background --prompt-file p\n' > "$CS/04-consultation.meta"
printf 'changed blind body\n' > "$CS/02-codex.stdout"
chk "gate: codex body tampered"         1 "initial review bodies changed" pgw pre-verification "$CS"
printf 'blind codex body\n' > "$CS/02-codex.stdout"
cp "$CS/02-review-seal.sha256" "$CS/02-review-seal.sha256.good"
chmod 600 "$CS/02-review-seal.sha256"
printf 'invalid\n' > "$CS/02-review-seal.sha256"
chmod 400 "$CS/02-review-seal.sha256"
chk "gate: malformed review seal"       1 "02-review-seal.sha256 changed after it was accepted" pgw pre-verification "$CS"
# The seal is written once, at JOIN-OK (pre-phase3); it must never be silently
# recreated later — an absent seal after that point is a hard failure (CX-04).
rm -f "$CS/02-review-seal.sha256"
chk "gate: pre-consultation, seal gone"  1 "02-review-seal.sha256 was accepted by pre-phase3 but is missing" pgw pre-consultation "$CS"
mv "$CS/02-review-seal.sha256.good" "$CS/02-review-seal.sha256"
chmod 400 "$CS/02-review-seal.sha256"
[ -s "$CS/02-review-seal.sha256" ] && [ -r "$CS/02-review-seal.sha256" ] && printf '  ok    %-42s\n' "gate: review seal restored after tamper test" || { printf '  FAIL  review seal not restored\n'; FAIL=1; }
chk "verifier packets: exact matrix"    0 "OK packets=3"         python3 "$PV" --matrix "$CS/03-matrix.tsv" --packets "$CS/05-verifier-packets.ndjson"
# CX-03r26: pre-verification generated the packets from the base packets plus the
# accepted dispositions: F-02 (VERIFY) gained the open question, F-01 (MAINTAIN) is unchanged.
grep -q '"id": "F-02".*"observations": \["a:1 \\"x\\"", "b:2@sha \\"y\\""\]' "$CS/05-verifier-packets.ndjson" && grep -q '"claim": "x", "falsifier": "f", "id": "F-01"' "$CS/05-verifier-packets.ndjson" && printf '  ok    %-42s\n' "CX-03r26: VERIFY disposition applied to packet" || { printf '  FAIL  CX-03r26: VERIFY disposition not applied\n'; FAIL=1; }
printf 'verification\nSTATUS: PHASE 5 COMPLETE\n' > "$CS/05-verification.md"
printf 'F-01\tCONFIRMED\ttrace\tf.txt:1@'"$SHA2"' "line one"\nF-02\tUNVERIFIABLE\nF-03\tCONFIRMED\ttrace\tf.txt:1@'"$SHA2"' "line one"\n' > "$CS/05-verdicts.tsv"
printf 'F-02\n' > "$CS/06-resolution-selection.ids"
chk "gate: pre-resolution"              0 "RESOLUTION-OK"        pgw pre-resolution "$CS"
# CX-03r26: the verifier packets are generated, never hand-edited; the base packets are frozen.
cp "$CS/05-verifier-packets.ndjson" "$TMP/cs-packets.bak"; chmod u+w "$CS/05-verifier-packets.ndjson"
python3 - "$CS/05-verifier-packets.ndjson" <<'PY2'
import sys; p=sys.argv[1]; s=open(p).read(); assert '"claim": "x"' in s; open(p,'w').write(s.replace('"claim": "x"', '"claim": "x, edited"', 1))
PY2
chk "CX-03r26: hand-edited verifier packets rejected at pre-resolution" 1 "05-verifier-packets.ndjson changed after it was accepted" pgw pre-resolution "$CS"
cp "$TMP/cs-packets.bak" "$CS/05-verifier-packets.ndjson"
# CL-05r40: a failed packet rebuild leaves no scratch file behind.
cp "$CS/04-consultation.json" "$TMP/cs-cjson.bak"; printf 'not json\n' > "$CS/04-consultation.json"
bash "$PG" pre-verification "$CS" >/dev/null 2>&1
[ -z "$(ls "$CS"/.packets-* 2>/dev/null)" ] && printf '  ok    %-42s\n' "CL-05r40: failed packet rebuild leaves no scratch file" || { printf '  FAIL  CL-05r40: scratch left: %s\n' "$(ls "$CS"/.packets-*)"; FAIL=1; }
cp "$TMP/cs-cjson.bak" "$CS/04-consultation.json"
cp "$CS/03-findings.ndjson" "$TMP/cs-base.bak"
python3 - "$CS/03-findings.ndjson" <<'PY2'
import sys; p=sys.argv[1]; s=open(p).read(); open(p,'w').write(s.replace('"claim": "x"', '"claim": "y"', 1))
PY2
chk "CX-03r26: base packets edited after consultation rejected" 1 "03-findings.ndjson changed after it was accepted by pre-consultation" pgw pre-resolution "$CS"
cp "$TMP/cs-base.bak" "$CS/03-findings.ndjson"
chk "CX-03r26: restored base packets pass" 0 "RESOLUTION-OK" pgw pre-resolution "$CS"
printf 'resolution skipped\nSTATUS: PHASE 6 COMPLETE (SKIPPED — no residual conflicts)\n' > "$CS/06-resolution.md"
chk "gate: pre-report rejects UNVERIFIABLE skip" 1 "UNVERIFIABLE findings" pgw pre-report "$CS"
# All-confirmed verdicts allow a legitimate SKIPPED resolution — but only if
# any leftover residual selector is also consistent (CX-04 round 14).
reverdict "$CS" 'F-01\tCONFIRMED\ttrace\tf.txt:1@'"$SHA2"' "line one"\nF-02\tCONFIRMED\ttrace\tf.txt:1@'"$SHA2"' "line one"\nF-03\tCONFIRMED\ttrace\tf.txt:1@'"$SHA2"' "line one"\n' 'resolution skipped\nSTATUS: PHASE 6 COMPLETE (SKIPPED — no residual conflicts)\n'
chk "CX-04r14: stale residual .ids rejected when resolution SKIPPED" 1 "06-resolution-selection.ids is invalid" pgw pre-report "$CS"
printf 'F-99\n' > "$CS/06-resolution-selection.ids"
chk "CX-04r14: non-manifest residual .ids rejected when SKIPPED" 1 "06-resolution-selection.ids" pgw pre-report "$CS"
rm -f "$CS/06-resolution.md" "$CS/06-resolution-selection.ids"; pgw pre-resolution "$CS" >/dev/null 2>&1
[ -z "$(grep ' 06-resolution-selection.ids ' "$CS/00-accepted.sha256")" ] && printf '  ok    %-42s\n' "ledger: removed draft selector retired by pre-resolution" || { printf '  FAIL  ledger: retired draft row still present\n'; FAIL=1; }
printf 'resolution skipped\nSTATUS: PHASE 6 COMPLETE (SKIPPED — no residual conflicts)\n' > "$CS/06-resolution.md"
chk "gate: pre-report"                  0 "REPORT-OK"            pgw pre-report "$CS"
# CX-03r26: pre-report also rebuilds the verifier packets and rejects an edit.
cp "$CS/05-verifier-packets.ndjson" "$TMP/cs-packets2.bak"; chmod u+w "$CS/05-verifier-packets.ndjson"
python3 - "$CS/05-verifier-packets.ndjson" <<'PY2'
import sys; p=sys.argv[1]; s=open(p).read(); assert '"claim": "x"' in s; open(p,'w').write(s.replace('"claim": "x"', '"claim": "x, edited"', 1))
PY2
chk "CX-03r26: hand-edited verifier packets rejected at pre-report" 1 "05-verifier-packets.ndjson changed after it was accepted" pgw pre-report "$CS"
cp "$TMP/cs-packets2.bak" "$CS/05-verifier-packets.ndjson"
# CX-02r22: deleting the seal and flipping Phase 2 to SKIPPED must not reach REPORT-OK.
cp "$CS/02-review-seal.sha256" "$TMP/cs-seal2.bak"; cp "$CS/02-codex.md" "$TMP/cs-02md.bak"
chmod u+w "$CS/02-review-seal.sha256"; rm -f "$CS/02-review-seal.sha256"
printf 'PROBE FAILED\nSTATUS: PHASE 2 COMPLETE (SKIPPED — probe failed)\n' > "$CS/02-codex.md"
chk "CX-02r22: deleted seal + SKIPPED flip rejected at pre-report" 1 "02-review-seal.sha256 was accepted by pre-phase3 but is missing" pgw pre-report "$CS"
cp "$TMP/cs-02md.bak" "$CS/02-codex.md"; cp "$TMP/cs-seal2.bak" "$CS/02-review-seal.sha256"; chmod 400 "$CS/02-review-seal.sha256"
# L-01r22: the selector is frozen at pre-consultation; editing it afterwards is caught.
cp "$CS/03-debate-selection.tsv" "$TMP/cs-sel.bak"
printf 'F-01\tBOTH\tP2\tEXCLUDE\tedited\n' > "$CS/03-debate-selection.tsv"
chk "L-01r22: selector edited after consultation rejected" 1 "03-debate-selection.tsv changed after it was accepted by pre-consultation" pgw pre-report "$CS"
cp "$TMP/cs-sel.bak" "$CS/03-debate-selection.tsv"
chk "L-01r22: restored selector passes" 0 "REPORT-OK" pgw pre-report "$CS"
# CX-05r14: pre-report must re-check consultation thread continuity, not just
# meta existence — a swapped thread after pre-verification is caught here.
printf 'thread=wrong\noutcome=COMPLETED\ncommand=task --resume-last --background --prompt-file p\n' > "$CS/04-consultation.meta"
chk "CX-05r14: pre-report rejects swapped consultation thread" 1 "resumed unexpected Codex thread" pgw pre-report "$CS"
printf 'thread=thread-2\noutcome=COMPLETED\ncommand=task --fresh --background --prompt-file p\n' > "$CS/04-consultation.meta"
chk "CX-05r14: pre-report passes with restored thread" 0 "REPORT-OK" pgw pre-report "$CS"
# CX-03r26: build-verifier-packets.py applies dispositions deterministically.
BD="$TMP/builder"; mkdir -p "$BD"
printf 'F-01\tBOTH\tP2\nF-02\tCONFLICT\tP1\nF-03\tCLAUDE-ONLY\tP3\n' > "$BD/03-matrix.tsv"; base_packets "$BD"
python3 - "$BD" <<'PY2'
import json, sys
d = sys.argv[1]
def disp(i, action, **kw):
    x = {"id": i, "action": action, "claim": "x", "severity": "P2", "locations": ["a:1"], "trigger": "t", "impact": "i", "observations": ["a:1 \"x\""], "falsifier": "f", "proposed_checks": ["c"], "open_factual_questions": []}
    x.update(kw); return x
json.dump({"phase": "consultation", "selected_ids": ["F-01", "F-02"], "dispositions": [
    disp("F-01", "REFINE", claim="refined", severity="P3", locations=["b:2"], observations=["b:2 \"y\""], proposed_checks=["c2"]),
    disp("F-02", "RETRACT", observations=["a:1 \"x\"", "z:9 \"fact\""], proposed_checks=["c", "c3"])]}, open(d + "/ok.json", "w"))
json.dump({"phase": "consultation", "selected_ids": ["F-09"], "dispositions": [disp("F-09", "MAINTAIN")]}, open(d + "/unknown-id.json", "w"))
json.dump({"phase": "consultation", "selected_ids": ["F-01"], "dispositions": [disp("F-01", "DROP")]}, open(d + "/bad-action.json", "w"))
json.dump({"phase": "resolution", "selected_ids": [], "dispositions": []}, open(d + "/wrong-phase.json", "w"))
PY2
chk "CX-03r26: builder applies REFINE and RETRACT" 0 "OK packets=3 dispositions=2 applied=2" python3 "$PB" --matrix "$BD/03-matrix.tsv" --base "$BD/03-findings.ndjson" --consultation "$BD/ok.json" --out "$BD/out.ndjson"
python3 - "$BD/out.ndjson" <<'PY2'
import json, sys
rows = {json.loads(l)["id"]: json.loads(l) for l in open(sys.argv[1]) if l.strip()}
assert rows["F-01"]["claim"] == "refined" and rows["F-01"]["severity"] == "P3" and rows["F-01"]["locations"] == ["b:2"], rows["F-01"]
assert rows["F-02"]["claim"] == "x" and rows["F-02"]["observations"] == ["a:1 \"x\"", "z:9 \"fact\""] and rows["F-02"]["proposed_checks"] == ["c", "c3"], rows["F-02"]
assert rows["F-03"]["claim"] == "x" and rows["F-03"]["proposed_checks"] == ["c"], rows["F-03"]
assert all("action" not in r for r in rows.values())
print("BUILD-OK")
PY2
[ $? = 0 ] && printf '  ok    %-42s\n' "CX-03r26: REFINE replaces, RETRACT appends, others untouched" || { printf '  FAIL  CX-03r26: merged packets wrong\n'; FAIL=1; }
chk "CX-03r26: built packets validate" 0 "OK packets=3" python3 "$PV" --matrix "$BD/03-matrix.tsv" --packets "$BD/out.ndjson"
chk "CX-03r26: builder output is byte-stable" 0 "OK packets=3" python3 "$PB" --matrix "$BD/03-matrix.tsv" --base "$BD/03-findings.ndjson" --consultation "$BD/ok.json" --out "$BD/out2.ndjson"
cmp -s "$BD/out.ndjson" "$BD/out2.ndjson" && printf '  ok    %-42s\n' "CX-03r26: rebuild is byte-identical" || { printf '  FAIL  CX-03r26: rebuild differs\n'; FAIL=1; }
chk "CX-03r26: builder rejects a disposition for an unknown ID" 1 "has no base packet" python3 "$PB" --matrix "$BD/03-matrix.tsv" --base "$BD/03-findings.ndjson" --consultation "$BD/unknown-id.json" --out "$BD/x.ndjson"
chk "CX-03r26: builder rejects an unknown action" 1 "invalid action" python3 "$PB" --matrix "$BD/03-matrix.tsv" --base "$BD/03-findings.ndjson" --consultation "$BD/bad-action.json" --out "$BD/x.ndjson"
chk "CX-03r26: builder rejects a non-consultation response" 1 "phase=consultation" python3 "$PB" --matrix "$BD/03-matrix.tsv" --base "$BD/03-findings.ndjson" --consultation "$BD/wrong-phase.json" --out "$BD/x.ndjson"
# CX-04r27: base packets must carry the matrix's provisional severity; post-consultation packets may differ (REFINE).
python3 - "$BD" <<'PY2'
import json, sys
d = sys.argv[1]
rows = [json.loads(l) for l in open(d + "/03-findings.ndjson") if l.strip()]
rows[0]["severity"] = "P3"
open(d + "/03-findings-sev.ndjson", "w").write("".join(json.dumps(r) + "\n" for r in rows))
PY2
chk "CX-04r27: base packet severity must match the matrix" 1 "differs from the matrix's provisional" python3 "$PV" --matrix "$BD/03-matrix.tsv" --packets "$BD/03-findings-sev.ndjson" --match-matrix-severity
chk "CX-04r27: post-consultation packets may differ in severity" 0 "OK packets=3" python3 "$PV" --matrix "$BD/03-matrix.tsv" --packets "$BD/03-findings-sev.ndjson"
chk "CX-04r27: builder refuses mismatched base severity" 1 "differs from the matrix's provisional" python3 "$PB" --matrix "$BD/03-matrix.tsv" --base "$BD/03-findings-sev.ndjson" --out "$BD/x.ndjson"
chk "CX-03r26: no consultation → base packets verbatim" 0 "OK packets=3 dispositions=0 applied=0" python3 "$PB" --matrix "$BD/03-matrix.tsv" --base "$BD/03-findings.ndjson" --out "$BD/plain.ndjson"
# CX-01r17: a deleted seal must not be recreated by pre-phase3 once post-join
# artifacts exist, even if the blind bodies were altered in between.
cp "$CS/02-review-seal.sha256" "$TMP/cs-seal.bak"; chmod u+w "$CS/02-review-seal.sha256"; rm -f "$CS/02-review-seal.sha256"
chmod 000 "$CS/01-lead.md"
chk "CX-01r17: pre-phase3 refuses to recreate a deleted seal" 1 "02-review-seal.sha256 was accepted by pre-phase3 but is missing" pgw pre-phase3 "$CS"
[ ! -e "$CS/02-review-seal.sha256" ] && printf '  ok    %-42s\n' "CX-01r17: no new seal minted" || { printf '  FAIL  CX-01r17: seal was recreated\n'; FAIL=1; }
chmod 600 "$CS/01-lead.md"; cp "$TMP/cs-seal.bak" "$CS/02-review-seal.sha256"; chmod 400 "$CS/02-review-seal.sha256"
# CX-06r17: a " --fresh " substring inside the prompt path must not be mistaken
# for a fresh retry; mode= is authoritative and a missing/unknown mode fails.
printf 'thread=wrong\noutcome=COMPLETED\nmode=--resume-last\ncommand=task --resume-last --background --prompt-file /tmp/run --fresh p.md\n' > "$CS/04-consultation.meta"
chk "CX-06r17: --fresh inside prompt path does not bypass thread check" 1 "resumed unexpected Codex thread" pgw pre-report "$CS"
printf 'thread=wrong\noutcome=COMPLETED\ncommand=task --resume-last --background --prompt-file /tmp/run --fresh p.md\n' > "$CS/04-consultation.meta"
chk "CX-06r17: command-token fallback also ignores the substring" 1 "resumed unexpected Codex thread" pgw pre-report "$CS"
printf 'thread=wrong\noutcome=COMPLETED\ncommand=review --bogus\n' > "$CS/04-consultation.meta"
chk "CX-06r17: unrecognisable launch mode rejected" 1 "no recognisable launch mode" pgw pre-report "$CS"
printf 'thread=thread-2\noutcome=COMPLETED\nmode=--fresh\ncommand=task --fresh --background --prompt-file p\n' > "$CS/04-consultation.meta"
chk "CX-06r17: mode=--fresh accepted" 0 "REPORT-OK" pgw pre-report "$CS"
# CX-03r18: a --fresh consultation retry needs no prior thread: with the Phase-2
# thread unknown, mode=--fresh must still pass check_thread. The thread anchor is
# a final ledger row, so removing it is caught rather than falling back.
cp "$CS/02-codex.meta" "$TMP/cs-02meta.bak"; cp "$CS/04-consultation.thread" "$TMP/cs-anchor.bak"
sed -i.bak 's/^thread=.*/thread=unknown/' "$CS/02-codex.meta" && rm -f "$CS/02-codex.meta.bak"
printf 'thread=unknown\noutcome=COMPLETED\nmode=--fresh\ncommand=task --fresh --background --prompt-file p\n' > "$CS/04-consultation.meta"
chk "CX-03r18: fresh retry passes with unknown prior thread" 0 "REPORT-OK" pgw pre-report "$CS"
printf 'thread=unknown\noutcome=COMPLETED\nmode=--resume-last\ncommand=task --resume-last --background --prompt-file p\n' > "$CS/04-consultation.meta"
chk "CX-03r18: resume-last must match the accepted thread anchor" 1 "resumed unexpected Codex thread" pgw pre-report "$CS"
chmod u+w "$CS/04-consultation.thread"; rm -f "$CS/04-consultation.thread"
chk "ledger: deleted thread anchor caught" 1 "04-consultation.thread was accepted by pre-verification but is missing" pgw pre-report "$CS"
cp "$TMP/cs-anchor.bak" "$CS/04-consultation.thread"; chmod 400 "$CS/04-consultation.thread"
cp "$TMP/cs-02meta.bak" "$CS/02-codex.meta"
printf 'thread=thread-2\noutcome=COMPLETED\nmode=--fresh\ncommand=task --fresh --background --prompt-file p\n' > "$CS/04-consultation.meta"
# CX-03r16: an exit-5 (unconfirmed cancel) consultation sidecar must block
# pre-report even when the consultation phase was recorded as SKIPPED.
cp "$CS/04-consultation.md" "$TMP/cs-04.bak"; cp "$CS/04-consultation.exit" "$TMP/cs-04exit.bak"
printf 'consultation stalled\nSTATUS: PHASE 4 COMPLETE (SKIPPED — stalled)\n' > "$CS/04-consultation.md"; printf '5\n' > "$CS/04-consultation.exit"
chk "CX-03r16: pre-report rejects exit-5 consultation when SKIPPED" 1 "recorded exit 5" pgw pre-report "$CS"
cp "$TMP/cs-04.bak" "$CS/04-consultation.md"; cp "$TMP/cs-04exit.bak" "$CS/04-consultation.exit"
chk "CX-03r16: pre-report passes once sidecar restored" 0 "REPORT-OK" pgw pre-report "$CS"
# L-01r17: a rotated exit-5 consultation attempt blocks pre-verification even
# when the current attempt completed.
printf '5\n' > "$CS/04-consultation.attempt9.exit"
chk "L-01r17: rotated exit-5 attempt blocks pre-verification" 1 "recorded exit 5" pgw pre-verification "$CS"
rm -f "$CS/04-consultation.attempt9.exit"
# L-02r15: the UNVERIFIABLE-skip check reads the verdict column, so a comment
# line ending in that word does not block a legitimate skipped resolution.
SKIP6='resolution skipped\nSTATUS: PHASE 6 COMPLETE (SKIPPED — no residual conflicts)\n'
reverdict "$CS" '# none UNVERIFIABLE\nF-01\tCONFIRMED\ttrace\tf.txt:1@'"$SHA2"' "line one"\nF-02\tCONFIRMED\ttrace\tf.txt:1@'"$SHA2"' "line one"\nF-03\tCONFIRMED\ttrace\tf.txt:1@'"$SHA2"' "line one"\n' "$SKIP6"
chk "L-02r15: comment ending in UNVERIFIABLE does not block skip" 0 "REPORT-OK" pgw pre-report "$CS"
# ledger: verdicts edited after Phase 6 exists are caught at pre-report.
printf 'F-01\tCONFIRMED\ttrace\tf.txt:1@'"$SHA2"' "line one"\nF-02\tCONFIRMED\ttrace\tf.txt:1@'"$SHA2"' "line one"\nF-03\tCONFIRMED\ttrace\tf.txt:1@'"$SHA2"' "line one"\n' > "$CS/05-verdicts.tsv"
chk "ledger: verdicts edited after resolution caught" 1 "05-verdicts.tsv changed after it was accepted by pre-resolution" pgw pre-report "$CS"
# CX-04r14: the UNVERIFIABLE-skip check must not be whitespace-sensitive.
reverdict "$CS" 'F-01\tCONFIRMED\ttrace\tf.txt:1@'"$SHA2"' "line one"\nF-02\tUNVERIFIABLE \nF-03\tCONFIRMED\ttrace\tf.txt:1@'"$SHA2"' "line one"\n' "$SKIP6" 'F-02\n'
chk "CX-04r14: trailing-space UNVERIFIABLE still blocks skip" 1 "UNVERIFIABLE findings" pgw pre-report "$CS"
# Restore UNVERIFIABLE verdict and selector for the resolution-response fixture below.
reverdict "$CS" 'F-01\tCONFIRMED\ttrace\tf.txt:1@'"$SHA2"' "line one"\nF-02\tUNVERIFIABLE\nF-03\tCONFIRMED\ttrace\tf.txt:1@'"$SHA2"' "line one"\n' 'resolution\nSTATUS: PHASE 6 COMPLETE\n' 'F-02\n'
# The residual fixture uses the accepted consultation thread anchor (already
# written by write_thread_anchor during "gate: pre-verification" above), not
# Phase 2's original thread.
[ "$(cat "$CS/04-consultation.thread" 2>/dev/null)" = "thread-2" ] || { printf '  FAIL  consultation thread anchor missing/unexpected\n'; FAIL=1; }
printf 'thread=thread-2\ncommand=task --resume-last --background --prompt-file p\n' > "$CS/06-resolution.meta"; printf '0\n' > "$CS/06-resolution.exit"
python3 - "$CS/04-consultation.stdout" "$CS/06-resolution.stdout" <<'PY2'
import json,re,sys
src,dst=sys.argv[1:]; data=json.loads(re.search(r'```json\s*(\{.*\})\s*```',open(src).read(),re.S).group(1)); data['phase']='resolution'; data['dispositions']=[data['dispositions'][1]]; open(dst,'w').write('```json\n'+json.dumps(data)+'\n```\n')
PY2
chk "gate: resolution response exact"  0 "REPORT-OK"            pgw pre-report "$CS"
# CX-03r27: the accepted residual response is final — an edit after acceptance is caught.
grep -q ' 06-resolution.stdout  pre-report  final$' "$CS/00-accepted.sha256" && grep -q ' 06-resolution.json  pre-report  final$' "$CS/00-accepted.sha256" && printf '  ok    %-42s\n' "CX-03r27: resolution response and JSON accepted as final" || { printf '  FAIL  CX-03r27: resolution rows missing\n'; FAIL=1; }
cp "$CS/06-resolution.stdout" "$TMP/cs-res.bak"; printf '\n' >> "$CS/06-resolution.stdout"
chk "CX-03r27: edited resolution response rejected at pre-report" 1 "06-resolution.stdout changed after it was accepted by pre-report" pgw pre-report "$CS"
cp "$TMP/cs-res.bak" "$CS/06-resolution.stdout"
chk "CX-03r27: restored resolution response passes" 0 "REPORT-OK" pgw pre-report "$CS"
# CX-02r30: an accepted (or valid exit-0) resolution cannot be recorded SKIPPED afterwards.
cp "$CS/06-resolution.md" "$TMP/cs-06md.bak"; printf 'resolution\nSTATUS: PHASE 6 COMPLETE (SKIPPED — changed my mind)\n' > "$CS/06-resolution.md"
chk "CX-02r30: SKIPPED after an accepted resolution refused" 1 "an accepted resolution cannot be skipped" pgw pre-report "$CS"
cp "$TMP/cs-06md.bak" "$CS/06-resolution.md"
printf '0\n' > "$CS/04-consultation.attempt1.exit"; cp "$CS/04-consultation.stdout" "$CS/04-consultation.attempt1.stdout"; printf 'mode=--fresh\n' > "$CS/04-consultation.attempt1.meta"; printf '0\n' > "$CS/06-resolution.exit"; printf 'thread=thread-2\ncommand=task --resume-last --background --prompt-file p\n' > "$CS/06-resolution.meta"
chk "gate: response cap"                1 "successful-response cap" pgw pre-report "$CS"
rm -f "$CS/04-consultation.attempt1.exit" "$CS/04-consultation.attempt1.stdout" "$CS/04-consultation.attempt1.meta" "$CS/06-resolution.exit" "$CS/06-resolution.meta"

# The strict normalized packet must reject provenance, extra fields, and partial set responses.
python3 - "$CS/04-consultation.stdout" <<'PY2'
import json,re,sys
p=sys.argv[1]; s=open(p).read(); d=json.loads(re.search(r'```json\s*(\{.*\})\s*```',s,re.S).group(1)); d['dispositions'][0]['origin']='CLAUDE-ONLY'; open(sys.argv[1]+'.bad','w').write('```json\n'+json.dumps(d)+'\n```\n')
PY2
chk "consultation: provenance key"      1 "only normalized"      python3 "$CV" --manifest "$CS/03-matrix.tsv" --selection "$CS/03-debate-selection.tsv" --phase consultation --extract "$CS/04-consultation.stdout.bad" --out "$CS/ignored.json"
python3 - "$CS/04-consultation.stdout" <<'PY2'
import json,re,sys
p=sys.argv[1]; s=open(p).read(); d=json.loads(re.search(r'```json\s*(\{.*\})\s*```',s,re.S).group(1)); d['dispositions'][0]['claim']='Claude and Codex agree'; open(sys.argv[1]+'.provenance','w').write('```json\n'+json.dumps(d)+'\n```\n')
PY2
chk "consultation: provenance text"     1 "provenance"           python3 "$CV" --manifest "$CS/03-matrix.tsv" --selection "$CS/03-debate-selection.tsv" --phase consultation --extract "$CS/04-consultation.stdout.provenance" --out "$CS/ignored.json"
python3 - "$CS/04-consultation.stdout" <<'PY2'
import json,re,sys
p=sys.argv[1]; s=open(p).read(); d=json.loads(re.search(r'```json\s*(\{.*\})\s*```',s,re.S).group(1)); d['dispositions'].pop(); open(sys.argv[1]+'.partial','w').write('```json\n'+json.dumps(d)+'\n```\n')
PY2
chk "consultation: partial response"    1 "differ from selector" python3 "$CV" --manifest "$CS/03-matrix.tsv" --selection "$CS/03-debate-selection.tsv" --phase consultation --extract "$CS/04-consultation.stdout.partial" --out "$CS/ignored.json"

echo "review: round-3 findings F-01/F-03/F-04/F-05/F-06/F-08 regressions"
# F-01: the packet-validator's provenance regex must not reject ordinary domain
# words, and must reject a possessive model-attribution phrase.
printf '{"id":"F-01","severity":"P2","claim":"The build artifact is missing from the release.","locations":["a:1"],"trigger":"t","impact":"i","observations":["a:1 \\"x\\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":["q"]}\n' > "$TMP/f01-ok.ndjson"
printf 'F-01\tCLAUDE-ONLY\tP2\n' > "$TMP/f01.tsv"
chk "F-01: ordinary domain word accepted" 0 "OK packets=1" python3 "$PV" --matrix "$TMP/f01.tsv" --packets "$TMP/f01-ok.ndjson"
printf '{"id":"F-01","severity":"P2","claim":"Codex'"'"'s review identified a bug here.","locations":["a:1"],"trigger":"t","impact":"i","observations":["a:1 \\"x\\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":["q"]}\n' > "$TMP/f01-bad.ndjson"
chk "F-01: possessive model attribution rejected" 1 "provenance" python3 "$PV" --matrix "$TMP/f01.tsv" --packets "$TMP/f01-bad.ndjson"

# F-05: the residual --ids path must reject an ID absent from the manifest,
# and reject an ID whose Phase-5 verdict is not UNVERIFIABLE or CONFLICT.
printf 'F-99\n' > "$TMP/f05-ids.txt"
printf 'F-01\tCONFIRMED\ttrace\tf.txt:1@'"$SHA2"' "line one"\n' > "$TMP/f05-verdicts.tsv"
chk "F-05: residual ID not in manifest rejected" 1 "not in the reconciliation manifest" python3 "$CV" --manifest "$TMP/f01.tsv" --verdicts "$TMP/f05-verdicts.tsv" --ids "$TMP/f05-ids.txt" --phase resolution --extract "$CS/04-consultation.stdout" --out "$TMP/ignored.json"
printf 'F-01\n' > "$TMP/f05-ids.txt"
chk "F-05: confirmed ID rejected from residual" 1 "not UNVERIFIABLE" python3 "$CV" --manifest "$TMP/f01.tsv" --verdicts "$TMP/f05-verdicts.tsv" --ids "$TMP/f05-ids.txt" --phase resolution --extract "$CS/04-consultation.stdout" --out "$TMP/ignored.json"

# F-04: a status downgrade to SKIPPED after a valid seal exists must still be
# caught, not silently take the seal-free branch.
SK4="$TMP/f04"; mkdir -p "$SK4"
printf 'scope\n' > "$SK4/00-scope.md"; mkbrief "$SK4"
pgw pre-codex "$SK4" "$G2" >/dev/null
printf 'lead\nSTATUS: PHASE 1 COMPLETE\n' > "$SK4/01-lead.md"; chmod 000 "$SK4/01-lead.md"
printf 'codex\nSTATUS: PHASE 2 COMPLETE\n' > "$SK4/02-codex.md"; printf '0\n' > "$SK4/02-codex.exit"; printf 'blind codex body\n' > "$SK4/02-codex.stdout"
pgw pre-phase3 "$SK4" >/dev/null
chmod 600 "$SK4/01-lead.md"
printf 'matrix\nSTATUS: PHASE 3 COMPLETE\n' > "$SK4/03-matrix.md"
printf 'F-01\tCLAUDE-ONLY\tP2\n' > "$SK4/03-matrix.tsv"
base_packets "$SK4"
printf 'F-01\tCLAUDE-ONLY\tP2\tEXCLUDE\tCLAUDE-ONLY-P2\n' > "$SK4/03-debate-selection.tsv"
printf 'codex declined\nSTATUS: PHASE 2 COMPLETE (SKIPPED — declined)\n' > "$SK4/02-codex.md"
chk "F-04: status downgrade after seal caught" 1 "status changed after JOIN-OK" pgw pre-consultation "$SK4"

# F-03 (round 4): pre-phase3 and post-join must also call
# check_seal_status_consistency — a status downgrade after sealing must be
# caught by these two gates too, not just the four later ones.
chmod 000 "$SK4/01-lead.md"
chk "F-03r4: pre-phase3 catches status downgrade" 1 "status changed after JOIN-OK" pgw pre-phase3 "$SK4"
chmod 600 "$SK4/01-lead.md"
chk "F-03r4: post-join catches status downgrade" 1 "status changed after JOIN-OK" pgw post-join "$SK4"

# F-04 (round 4): when Codex is SKIPPED, pre-verification and pre-report must
# reject PHASE 4 COMPLETE / PHASE 6 COMPLETE for consultation/resolution (a
# COMPLETE exchange cannot have run without Codex).
SK4B="$TMP/f04b"; mkdir -p "$SK4B"
printf 'scope\n' > "$SK4B/00-scope.md"; mkbrief "$SK4B"
pgw pre-codex "$SK4B" "$G2" >/dev/null
printf 'lead\nSTATUS: PHASE 1 COMPLETE\n' > "$SK4B/01-lead.md"; chmod 000 "$SK4B/01-lead.md"
printf 'PROBE UNAVAILABLE\nSTATUS: PHASE 2 COMPLETE (SKIPPED — declined)\n' > "$SK4B/02-codex.md"
pgw pre-phase3 "$SK4B" >/dev/null
chmod 600 "$SK4B/01-lead.md"
printf 'matrix\nSTATUS: PHASE 3 COMPLETE\n' > "$SK4B/03-matrix.md"
printf 'F-01\tCLAUDE-ONLY\tP1\n' > "$SK4B/03-matrix.tsv"
base_packets "$SK4B"
printf 'F-01\tCLAUDE-ONLY\tP1\tINCLUDE\tprovisional-P1\n' > "$SK4B/03-debate-selection.tsv"
pgw pre-consultation "$SK4B" >/dev/null
printf 'consultation completed anyway\nSTATUS: PHASE 4 COMPLETE\n' > "$SK4B/04-consultation.md"
chk "F-04r4: COMPLETE consultation rejected when Codex SKIPPED" 1 "consultation cannot have run without Codex" pgw pre-verification "$SK4B"

# F-03: the consultation gate's seal fingerprint must be a single 12-hex-char
# prefix, never the raw multi-line seal file.
CANDIDATES3="$TMP/f03"; mkdir -p "$CANDIDATES3"
printf 'scope\n' > "$CANDIDATES3/00-scope.md"; mkbrief "$CANDIDATES3"
pgw pre-codex "$CANDIDATES3" "$G2" >/dev/null
printf 'lead\nSTATUS: PHASE 1 COMPLETE\n' > "$CANDIDATES3/01-lead.md"; chmod 000 "$CANDIDATES3/01-lead.md"
printf 'codex\nSTATUS: PHASE 2 COMPLETE\n' > "$CANDIDATES3/02-codex.md"; printf '0\n' > "$CANDIDATES3/02-codex.exit"; printf 'blind codex body\n' > "$CANDIDATES3/02-codex.stdout"
pgw pre-phase3 "$CANDIDATES3" >/dev/null
chmod 600 "$CANDIDATES3/01-lead.md"
printf 'matrix\nSTATUS: PHASE 3 COMPLETE\n' > "$CANDIDATES3/03-matrix.md"
printf 'F-01\tCLAUDE-ONLY\tP2\n' > "$CANDIDATES3/03-matrix.tsv"
base_packets "$CANDIDATES3"
printf 'F-01\tCLAUDE-ONLY\tP2\tEXCLUDE\tCLAUDE-ONLY-P2\n' > "$CANDIDATES3/03-debate-selection.tsv"
out3=$(pgw pre-consultation "$CANDIDATES3")
{ case "$out3" in *$'\n'*) false;; esac; } && printf '%s' "$out3" | grep -qE 'seal=[0-9a-f]{12}$' \
  && printf '  ok    %-42s\n' "F-03: seal fingerprint is one 12-hex line" \
  || { printf '  FAIL  F-03: seal fingerprint malformed: %s\n' "$out3"; FAIL=1; }

# F-08: pre-resolution must pass with no residual-selection file at all when
# Phase 5 confirmed everything and left nothing to resolve.
SK8="$TMP/f08"; mkdir -p "$SK8"
printf 'scope\n' > "$SK8/00-scope.md"; mkbrief "$SK8"
pgw pre-codex "$SK8" "$G2" >/dev/null
printf 'lead\nSTATUS: PHASE 1 COMPLETE\n' > "$SK8/01-lead.md"; chmod 000 "$SK8/01-lead.md"
printf 'codex\nSTATUS: PHASE 2 COMPLETE\n' > "$SK8/02-codex.md"; printf '0\n' > "$SK8/02-codex.exit"; printf 'blind codex body\n' > "$SK8/02-codex.stdout"
pgw pre-phase3 "$SK8" >/dev/null
chmod 600 "$SK8/01-lead.md"
printf 'matrix\nSTATUS: PHASE 3 COMPLETE\n' > "$SK8/03-matrix.md"
printf 'F-01\tCLAUDE-ONLY\tP2\n' > "$SK8/03-matrix.tsv"
base_packets "$SK8"
printf 'F-01\tCLAUDE-ONLY\tP2\tEXCLUDE\tCLAUDE-ONLY-P2\n' > "$SK8/03-debate-selection.tsv"
pgw pre-consultation "$SK8" >/dev/null
# CX-01r24: pre-consultation refuses a second launch when an accepted attempt or the terminal artifact exists.
printf '0\n' > "$SK8/04-consultation.exit"; printf '```json\n{"phase":"consultation","dispositions":[]}\n```\n' > "$SK8/04-consultation.stdout"; printf 'mode=--fresh\n' > "$SK8/04-consultation.meta"
chk "CX-01r24: pre-consultation refuses relaunch over accepted attempt" 1 "with no 04-consultation.md yet" pgw pre-consultation "$SK8"
printf 'thread=t-sk8\noutcome=COMPLETED\n' > "$SK8/02-codex.meta"; printf 'mode=--resume-last\nthread=t-other\n' > "$SK8/04-consultation.meta"
chk "CX-04r37: valid response on the wrong thread allows the --fresh relaunch" 0 "CONSULTATION-OK" pgw pre-consultation "$SK8"
# CL-01r39/40: while the authorized launch is in flight, a failing re-entry must not re-accept edited drafts.
cp "$SK8/00-accepted.sha256" "$TMP/sk8-ledger-inflight.bak"; cp "$SK8/03-matrix.md" "$TMP/sk8-matrix.bak"
printf 'matrix edited\nSTATUS: PHASE 3 COMPLETE\n' > "$SK8/03-matrix.md"
chk "CL-01r39: re-entry during the grace window refused" 1 "may still be launching\|changed after it was accepted" env PHASE_GATE_CLAIM_GRACE_SEC=600 bash "$PG" pre-consultation "$SK8"
cmp -s "$SK8/00-accepted.sha256" "$TMP/sk8-ledger-inflight.bak" && printf '  ok    %-42s\n' "CL-01r39: drafts not re-accepted while a launch is in flight" || { printf '  FAIL  CL-01r39: ledger rewritten during an in-flight launch\n'; FAIL=1; }
cp "$TMP/sk8-matrix.bak" "$SK8/03-matrix.md"
rm -f "$SK8/04-consultation.exit" "$SK8/04-consultation.stdout" "$SK8/04-consultation.meta"; rm -rf "$SK8"/04-consultation.claim*
printf 'consultation\nSTATUS: PHASE 4 COMPLETE\n' > "$SK8/04-consultation.md"
chk "CX-01r24: pre-consultation refuses relaunch after terminal artifact" 1 "already exists: this phase is terminal" pgw pre-consultation "$SK8"
rm -f "$SK8/04-consultation.md"
printf '0\n' > "$SK8/04-consultation.attempt1.exit"; printf '```json\n{"phase":"consultation","dispositions":[]}\n```\n' > "$SK8/04-consultation.attempt1.stdout"; printf 'mode=--fresh\n' > "$SK8/04-consultation.attempt1.meta"
chk "L-01r25: rotated accepted attempt refused" 1 "with no 04-consultation.md yet" pgw pre-consultation "$SK8"
rm -f "$SK8/04-consultation.attempt1.exit" "$SK8/04-consultation.attempt1.stdout" "$SK8/04-consultation.attempt1.meta"
# CX-01r21: pre-consultation must refuse to authorize a launch over an exit-5 attempt.
printf '5\n' > "$SK8/04-consultation.attempt1.exit"
chk "CX-01r21: pre-consultation rejects exit-5 attempt" 1 "recorded exit 5" pgw pre-consultation "$SK8"
rm -f "$SK8/04-consultation.attempt1.exit"
printf 'verification\nSTATUS: PHASE 5 COMPLETE\n' > "$SK8/05-verification.md"
printf 'F-01\tCONFIRMED\ttrace\tf.txt:1@'"$SHA2"' "line one"\n' > "$SK8/05-verdicts.tsv"
# CX-04r18: Phase 4 must have a terminal artifact before Phase 6 can be authorized.
chk "CX-04r18: pre-resolution requires 04-consultation.md" 1 "04-consultation.md missing" pgw pre-resolution "$SK8"
printf 'consultation skipped\nSTATUS: PHASE 4 COMPLETE (SKIPPED — no candidates)\n' > "$SK8/04-consultation.md"
# ledger: pre-verification cannot first-accept its packets once Phase-5 artifacts exist.
chk "ledger: late first acceptance refused once later-phase artifacts exist" 1 "never accepted by pre-verification but later-phase artifacts exist" pgw pre-verification "$SK8"
rm -f "$SK8/05-verification.md" "$SK8/05-verdicts.tsv"; pgw pre-verification "$SK8" >/dev/null || { printf '  FAIL  SK8 pre-verification\n'; FAIL=1; }
printf 'verification\nSTATUS: PHASE 5 COMPLETE\n' > "$SK8/05-verification.md"
printf 'F-01\tCONFIRMED\ttrace\tf.txt:1@'"$SHA2"' "line one"\n' > "$SK8/05-verdicts.tsv"
printf 'F-01\tCONFIRMED\ttrace\tf.txt:1@'"$SHA2"' "line one"\n' > "$SK8/05-verdicts.tsv"
chk "F-08: pre-resolution needs no .ids file when nothing residual" 0 "RESOLUTION-OK" pgw pre-resolution "$SK8"
# CX-04r15: attempts that died before .meta (exit-only sidecars) still count.
# CX-02r15: an exhausted launch budget must not block a run with no residuals.
for n in 1 2 3 4; do printf '4\n' > "$SK8/04-consultation.attempt$n.exit"; done
chk "CX-02r15: 4 launches, no residual → pre-resolution passes" 0 "RESOLUTION-OK codex=COMPLETE residual=0 attempts=4" pgw pre-resolution "$SK8"
printf 'F-01\tUNVERIFIABLE\n' > "$SK8/05-verdicts.tsv"; printf 'F-01\n' > "$SK8/06-resolution-selection.ids"
chk "CX-04r15/CX-04r38: 4 exit-only launches + residual → OK with budget=exhausted, no claim" 0 "RESOLUTION-OK.*budget=exhausted" pgw pre-resolution "$SK8"
[ ! -d "$SK8/06-resolution.claim" ] && printf '  ok    %-42s\n' "CX-04r38: exhausted budget creates no claim" || { printf '  FAIL  CX-04r38: claim created on exhausted budget\n'; FAIL=1; }
grep -q ' 06-resolution-selection.ids  pre-resolution  draft$' "$SK8/00-accepted.sha256" && printf '  ok    %-42s\n' "CX-04r25: selector accepted even when budget exhausted" || { printf '  FAIL  CX-04r25: selector not accepted on exhausted-budget path\n'; FAIL=1; }
# CX-01r26: attempts that died after launching (.progress only) still count as launches.
for n in 1 2 3 4; do rm -f "$SK8/04-consultation.attempt$n.exit"; printf '1s launched job=j%s\n' "$n" > "$SK8/04-consultation.attempt$n.progress"; done
chk "CX-01r26: 4 progress-only launches + residual → budget=exhausted" 0 "RESOLUTION-OK.*budget=exhausted" pgw pre-resolution "$SK8"
for n in 1 2 3 4; do rm -f "$SK8/04-consultation.attempt$n.progress"; printf '4\n' > "$SK8/04-consultation.attempt$n.exit"; done
rm -f "$SK8/06-resolution-selection.ids"
printf 'F-01\tCONFIRMED\ttrace\tf.txt:1@'"$SHA2"' "line one"\n' > "$SK8/05-verdicts.tsv"
printf '4\n' > "$SK8/04-consultation.attempt5.exit"
chk "CX-04r15: 5 launches exceed the cap even with no residual" 1 "attempt cap exceeded" pgw pre-resolution "$SK8"
rm -f "$SK8"/04-consultation.attempt*.exit
# Budget reset for the fixtures below (spent claims are never deleted in a real
# run; this models a fresh run directory that reached the same state).
rm -rf "$SK8"/04-consultation.claim.spent*
# Launch records: a sidecar without a runner-taken claim is fatal in every gate; a runner-taken claim with no sidecar still counts as a launch.
printf '4\n' > "$SK8/04-consultation.attempt1.exit"
chk "launches: sidecar without a runner-taken claim rejected" 1 "04-consultation has sidecars for 1 attempt(s) but only 0 claim(s) taken by a runner" bash "$PG" pre-resolution "$SK8"
rm -f "$SK8/04-consultation.attempt1.exit"
for n in 1 2 3 4; do mkdir -p "$SK8/06-resolution.claim.spent$n/runner"; done
printf 'F-01\tUNVERIFIABLE\n' > "$SK8/05-verdicts.tsv"; printf 'F-01\n' > "$SK8/06-resolution-selection.ids"
chk "launches: 4 runner-taken claims with no sidecars exhaust the budget" 0 "RESOLUTION-OK.*budget=exhausted" bash "$PG" pre-resolution "$SK8"
rm -rf "$SK8"/06-resolution.claim.spent*
# CX-05r17: pre-resolution rejects a duplicate or empty residual selector before launch.
printf 'F-01\tUNVERIFIABLE\n' > "$SK8/05-verdicts.tsv"
rm -f "$SK8/06-resolution-selection.ids"
chk "CX-03r21: residual + launch possible + no selector rejected" 1 "06-resolution-selection.ids missing or empty" pgw pre-resolution "$SK8"
: > "$SK8/06-resolution-selection.ids"
chk "CX-03r21: zero-byte selector rejected" 1 "06-resolution-selection.ids missing or empty" pgw pre-resolution "$SK8"
printf 'F-01\nF-01\n' > "$SK8/06-resolution-selection.ids"
chk "CX-05r17: duplicate residual IDs rejected pre-launch" 1 "06-resolution-selection.ids is invalid" pgw pre-resolution "$SK8"
printf '# nothing\n' > "$SK8/06-resolution-selection.ids"
chk "CX-05r17: comment-only residual list rejected pre-launch" 1 "06-resolution-selection.ids is invalid" pgw pre-resolution "$SK8"
printf 'F-01\n' > "$SK8/06-resolution-selection.ids"
chk "CX-05r17: single residual ID accepted" 0 "RESOLUTION-OK codex=COMPLETE residual=1" pgw pre-resolution "$SK8"
# CL-03r42: a trailing space inside the verdict column is tolerated by every reader of 05-verdicts.tsv alike.
printf 'F-01\tUNVERIFIABLE \tnone\n' > "$SK8/05-verdicts.tsv"
chk "CL-03r42: padded verdict column accepted by the residual selector check" 0 "RESOLUTION-OK codex=COMPLETE residual=1" pgw pre-resolution "$SK8"
printf 'F-01\tUNVERIFIABLE\n' > "$SK8/05-verdicts.tsv"; rm -rf "$SK8"/06-resolution.claim*; pgw pre-resolution "$SK8" >/dev/null  # re-accept the restored draft (test-only claim reset)
grep -q ' 06-resolution-selection.ids  pre-resolution  draft$' "$SK8/00-accepted.sha256" && printf '  ok    %-42s\n' "CX-02r24: residual selector accepted at pre-resolution" || { printf '  FAIL  CX-02r24: selector not accepted\n'; FAIL=1; }
printf '0\n' > "$SK8/06-resolution.exit"; printf '```json\n{"phase":"resolution","dispositions":[{"id":"F-01","action":"MAINTAIN","claim":"first","severity":"P1","locations":["a:1"],"trigger":"t","impact":"i","observations":["a:1 \\"x\\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":[]}]}\n```\n' > "$SK8/06-resolution.stdout"
printf 'mode=--fresh\n' > "$SK8/06-resolution.meta"
chk "CX-01r24: pre-resolution refuses relaunch over accepted attempt" 1 "with no 06-resolution.md yet" pgw pre-resolution "$SK8"
# CX-05r38: validator arguments are passed as an array, so a run directory with spaces still recognizes a usable response.
SP="$TMP/with space"; rm -rf "$SP"; mkdir -p "$SP"; cp -R "$SK8" "$SP/art"
chk "CX-05r38: usable response recognized under a path with spaces" 1 "with no 06-resolution.md yet" bash "$PG" pre-resolution "$SP/art"
rm -f "$SK8/06-resolution.exit" "$SK8/06-resolution.stdout" "$SK8/06-resolution.meta"; rm -rf "$SK8"/06-resolution.claim.spent*  # test-only reset: the fixture models no launch below
# CX-02r17: a skipped Phase 6 with residuals is rejected only when nothing was
# attempted and budget remains; an attempted (failed) exchange or an exhausted
# budget is the documented fallback and must reach REPORT-OK.
printf 'consultation skipped\nSTATUS: PHASE 4 COMPLETE (SKIPPED — no candidates)\n' > "$SK8/04-consultation.md"
printf 'resolution failed\nSTATUS: PHASE 6 COMPLETE (SKIPPED — validation failed)\n' > "$SK8/06-resolution.md"
chk "CX-02r17: skip with residuals and no attempt rejected" 1 "no residual exchange was attempted" pgw pre-report "$SK8"
printf 'outcome=FAILED\nthread=x\nmode=--resume-last\ncommand=task --resume-last --background --prompt-file p\n' > "$SK8/06-resolution.meta"; printf '1\n' > "$SK8/06-resolution.exit"
chk "CX-02r17: skip after a failed attempt reaches REPORT-OK" 0 "REPORT-OK codex=COMPLETE resolution=SKIPPED" pgw pre-report "$SK8"
# L-02r31 (CX-02r30 for Phase 6): a SKIPPED resolution over an exit-0 attempt is allowed only if that response fails validation.
printf '0\n' > "$SK8/06-resolution.attempt1.exit"; printf 'no json here\n' > "$SK8/06-resolution.attempt1.stdout"
chk "L-02r31: resolution skip over a malformed exit-0 response accepted" 0 "REPORT-OK codex=COMPLETE resolution=SKIPPED" pgw pre-report "$SK8"
cat > "$SK8/06-resolution.attempt1.stdout" <<'RESOLVE'
```json
{"phase":"resolution","dispositions":[
{"id":"F-01","action":"MAINTAIN","claim":"first","severity":"P1","locations":["a:1"],"trigger":"t","impact":"i","observations":["a:1 \"x\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":[]}
]}
```
RESOLVE
printf 'mode=--fresh\n' > "$SK8/06-resolution.attempt1.meta"
chk "L-02r31: resolution skip over a valid exit-0 response refused" 1 "06-resolution.md is SKIPPED but attempt 06-resolution.attempt1 succeeded with a valid response" pgw pre-report "$SK8"
rm -f "$SK8/06-resolution.attempt1.exit" "$SK8/06-resolution.attempt1.stdout" "$SK8/06-resolution.attempt1.meta"
mv "$SK8/06-resolution-selection.ids" "$TMP/sk8-ids.bak"
chk "CX-02r24: deleted residual selector caught at pre-report" 1 "06-resolution-selection.ids was accepted by pre-resolution but is missing" pgw pre-report "$SK8"
mv "$TMP/sk8-ids.bak" "$SK8/06-resolution-selection.ids"
printf 'F-01\n# edited\n' > "$SK8/06-resolution-selection.ids"
chk "CX-02r24: edited residual selector caught by the ledger" 1 "06-resolution-selection.ids changed after it was accepted by pre-resolution" pgw pre-report "$SK8"
printf 'F-01\n' > "$SK8/06-resolution-selection.ids"
chk "CX-02r24: restored selector passes" 0 "REPORT-OK" pgw pre-report "$SK8"
rm -f "$SK8/06-resolution.meta" "$SK8/06-resolution.exit"; rm -rf "$SK8"/06-resolution.claim.spent*  # test-only reset
for n in 1 2 3 4; do printf '1\n' > "$SK8/04-consultation.attempt$n.exit"; done
chk "CX-02r17: skip with exhausted launch budget reaches REPORT-OK" 0 "REPORT-OK" pgw pre-report "$SK8"
rm -f "$SK8"/04-consultation.attempt*.exit "$SK8/06-resolution.md" "$SK8/04-consultation.md" "$SK8/06-resolution-selection.ids"
printf 'F-01\tCONFIRMED\ttrace\tf.txt:1@'"$SHA2"' "line one"\n' > "$SK8/05-verdicts.tsv"

# F-06: the codex=SKIPPED branch of the four new gates must be exercised too,
# not just the completed-Codex fixture above.
SK6="$TMP/f06"; mkdir -p "$SK6"
printf 'scope\n' > "$SK6/00-scope.md"; mkbrief "$SK6"
pgw pre-codex "$SK6" "$G2" >/dev/null
printf 'lead\nSTATUS: PHASE 1 COMPLETE\n' > "$SK6/01-lead.md"; chmod 000 "$SK6/01-lead.md"
printf 'PROBE UNAVAILABLE\nSTATUS: PHASE 2 COMPLETE (SKIPPED — declined)\n' > "$SK6/02-codex.md"
# CX-01r19: an exit-5 / unconfirmed-cancel sidecar on the initial review blocks
# the join even when the phase was recorded SKIPPED, and a rotated one too.
printf '5\n' > "$SK6/02-codex.exit"
chk "CX-01r19: pre-phase3 rejects exit-5 initial review (SKIPPED)" 1 "02-codex recorded exit 5" pgw pre-phase3 "$SK6"
rm -f "$SK6/02-codex.exit"; printf 'outcome=STALLED\ncancel_confirmed=no\n' > "$SK6/02-codex.attempt1.meta"
chk "CX-01r19: rotated cancel_confirmed=no blocks the join" 1 "cancel_confirmed=no" pgw pre-phase3 "$SK6"
rm -f "$SK6/02-codex.attempt1.meta"
pgw pre-phase3 "$SK6" >/dev/null
chmod 600 "$SK6/01-lead.md"
printf 'matrix\nSTATUS: PHASE 3 COMPLETE\n' > "$SK6/03-matrix.md"
printf 'F-01\tCLAUDE-ONLY\tP1\n' > "$SK6/03-matrix.tsv"
base_packets "$SK6"
printf 'F-01\tCLAUDE-ONLY\tP1\tINCLUDE\tprovisional-P1\n' > "$SK6/03-debate-selection.tsv"
chk "F-06: pre-consultation, codex=SKIPPED" 0 "CONSULTATION-OK codex=SKIPPED" pgw pre-consultation "$SK6"
grep -q '^phase2=SKIPPED' "$SK6/02-review-seal.sha256" 2>/dev/null && printf '  ok    %-42s\n' "F-06/CX-02r22: SKIPPED review is sealed as SKIPPED" || { printf '  FAIL  F-06: SKIPPED review not sealed\n'; FAIL=1; }
chk "CX-03r25: joined (sealed) SKIPPED run cannot relaunch Phase 2" 1 "already joined" pgw pre-codex "$SK6" "$G2"
printf 'consultation skipped\nSTATUS: PHASE 4 COMPLETE (SKIPPED — no Codex review)\n' > "$SK6/04-consultation.md"
chk "F-06: pre-verification, codex=SKIPPED" 0 "VERIFICATION-OK consultation=SKIPPED codex=SKIPPED" pgw pre-verification "$SK6"
printf 'verification\nSTATUS: PHASE 5 COMPLETE\n' > "$SK6/05-verification.md"
printf 'F-01\tCONFIRMED\ttrace\tf.txt:1@'"$SHA2"' "line one"\n' > "$SK6/05-verdicts.tsv"
chk "F-06: pre-resolution, codex=SKIPPED" 0 "RESOLUTION-OK codex=SKIPPED" pgw pre-resolution "$SK6"
# L-01r19: a COMPLETE consultation cannot coexist with a SKIPPED Codex review at pre-resolution.
printf 'consultation\nSTATUS: PHASE 4 COMPLETE\n' > "$SK6/04-consultation.md"
chk "L-01r19: COMPLETE consultation with codex=SKIPPED rejected" 1 "cannot have run without Codex" pgw pre-resolution "$SK6"
printf 'consultation skipped\nSTATUS: PHASE 4 COMPLETE (SKIPPED — no Codex review)\n' > "$SK6/04-consultation.md"
# CX-03r14: when Codex was SKIPPED, an UNVERIFIABLE verdict with a SKIPPED
# resolution is the documented single-model fallback (UNRESOLVED default) and
# must NOT block the report.
reverdict "$SK6" 'F-01\tUNVERIFIABLE\n' 'resolution skipped\nSTATUS: PHASE 6 COMPLETE (SKIPPED — no Codex review)\n'
chk "CX-03r14: UNVERIFIABLE + SKIPPED resolution allowed when codex=SKIPPED" 0 "REPORT-OK" pgw pre-report "$SK6"
reverdict "$SK6" 'F-01\tCONFIRMED\ttrace\tf.txt:1@'"$SHA2"' "line one"\n' 'resolution skipped\nSTATUS: PHASE 6 COMPLETE (SKIPPED — no Codex review)\n'
chk "F-06: pre-report, codex=SKIPPED" 0 "REPORT-OK codex=SKIPPED" pgw pre-report "$SK6"
# F-04 (round 4): pre-report must reject PHASE 6 COMPLETE when Codex SKIPPED
printf 'resolution completed anyway\nSTATUS: PHASE 6 COMPLETE\n' > "$SK6/06-resolution.md"
chk "F-04r4: COMPLETE resolution rejected when Codex SKIPPED" 1 "resolution cannot have run without Codex" pgw pre-report "$SK6"
printf 'resolution skipped\nSTATUS: PHASE 6 COMPLETE (SKIPPED — no Codex review)\n' > "$SK6/06-resolution.md"

echo "review: round-5 findings F-01r5/F-02r5/F-03r5/F-04r5 regressions"
# F-01r5: pre-resolution must validate 05-verdicts.tsv unconditionally (even
# when there are no residual findings to resolve).
SK1B="$TMP/f01r5"; mkdir -p "$SK1B"
printf 'scope\n' > "$SK1B/00-scope.md"; mkbrief "$SK1B"
pgw pre-codex "$SK1B" "$G2" >/dev/null
printf 'lead\nSTATUS: PHASE 1 COMPLETE\n' > "$SK1B/01-lead.md"; chmod 000 "$SK1B/01-lead.md"
printf 'codex\nSTATUS: PHASE 2 COMPLETE\n' > "$SK1B/02-codex.md"; printf '0\n' > "$SK1B/02-codex.exit"; printf 'blind codex body\n' > "$SK1B/02-codex.stdout"
pgw pre-phase3 "$SK1B" >/dev/null
chmod 600 "$SK1B/01-lead.md"
printf 'matrix\nSTATUS: PHASE 3 COMPLETE\n' > "$SK1B/03-matrix.md"
printf 'F-01\tCLAUDE-ONLY\tP2\n' > "$SK1B/03-matrix.tsv"
base_packets "$SK1B"
printf 'F-01\tCLAUDE-ONLY\tP2\tEXCLUDE\tCLAUDE-ONLY-P2\n' > "$SK1B/03-debate-selection.tsv"
pgw pre-consultation "$SK1B" >/dev/null
printf 'consultation skipped\nSTATUS: PHASE 4 COMPLETE (SKIPPED — no candidates)\n' > "$SK1B/04-consultation.md"
pgw pre-verification "$SK1B" >/dev/null || { printf '  FAIL  SK1B pre-verification\n'; FAIL=1; }
printf 'verification\nSTATUS: PHASE 5 COMPLETE\n' > "$SK1B/05-verification.md"
chk "F-01r5: missing verdicts ledger rejected" 1 "05-verdicts.tsv is missing or invalid" pgw pre-resolution "$SK1B"
printf 'F-01\tCONFIRMED\ttrace\tf.txt:1@'"$SHA2"' "line one"\n' > "$SK1B/05-verdicts.tsv"
chk "F-01r5: valid verdicts ledger accepted" 0 "RESOLUTION-OK" pgw pre-resolution "$SK1B"
printf 'F-01\tBAD-VERDICT\n' > "$SK1B/05-verdicts.tsv"
chk "F-03r5: invalid verdict value rejected" 1 "05-verdicts.tsv is missing or invalid" pgw pre-resolution "$SK1B"
# CX-01r23: a CONFIRMED/REFUTED verdict must carry a real method and citation- or
# command-shaped, repository-relative, provenance-free evidence.
VV=plugins/codex-pr-review/skills/two-model-pr-review/scripts/validate-verdicts.py
[ -x "$VV" ] && printf '  ok    %-42s\n' "verdict validator is executable" || { printf '  FAIL  verdict validator is not executable\n'; FAIL=1; }
printf 'F-01\tCONFIRMED\n' > "$SK1B/05-verdicts.tsv"
chk "CX-01r23: CONFIRMED without method/evidence rejected" 1 "05-verdicts.tsv is missing or invalid" pgw pre-resolution "$SK1B"
printf 'F-01\tCONFIRMED\tnone\tf.txt:1@'"$SHA2"' "line one"\n' > "$SK1B/05-verdicts.tsv"
chk "CX-01r23: method none cannot confirm" 1 "need repro, trace, suite, or history" python3 "$VV" --matrix "$SK1B/03-matrix.tsv" --verdicts "$SK1B/05-verdicts.tsv"
printf 'F-01\tREFUTED\ttrace\tjust trust me\n' > "$SK1B/05-verdicts.tsv"
chk "CX-01r23: prose evidence rejected" 1 "quoted citation" python3 "$VV" --matrix "$SK1B/03-matrix.tsv" --verdicts "$SK1B/05-verdicts.tsv"
printf 'F-01\tCONFIRMED\trepro\t/tmp/two-model-pr-review/r/05-verification.md:1 "x"\n' > "$SK1B/05-verdicts.tsv"
chk "CX-01r23: artifact-path evidence rejected" 1 "provenance" python3 "$VV" --matrix "$SK1B/03-matrix.tsv" --verdicts "$SK1B/05-verdicts.tsv"
printf 'F-01\tCONFIRMED\tsuite\tcmd: bash scripts/test-args.sh -> ALL PASSED\n' > "$SK1B/05-verdicts.tsv"
chk "CX-01r33: command-only evidence cannot confirm" 1 "command evidence cannot be verified" pgw pre-resolution "$SK1B"
printf 'F-01\tCONFIRMED\ttrace\tnope.py:999@deadbeef "fabricated"\n' > "$SK1B/05-verdicts.tsv"
chk "CX-01r33: fabricated citation rejected" 1 "does not resolve in the repository" pgw pre-resolution "$SK1B"
printf 'F-01\tCONFIRMED\ttrace\tf.txt:1@'"$SHA2"' "line nine"\n' > "$SK1B/05-verdicts.tsv"
chk "CX-01r33: quote not in the cited lines rejected" 1 "quote is not found" pgw pre-resolution "$SK1B"
printf 'F-01\tCONFIRMED\ttrace\tf.txt:7@'"$SHA2"' "line one"\n' > "$SK1B/05-verdicts.tsv"
chk "CX-01r33: line outside the file rejected" 1 "outside the file" pgw pre-resolution "$SK1B"
printf 'F-01\tCONFIRMED\ttrace\tf.txt:1-3 "LINE  two"\n' > "$SK1B/05-verdicts.tsv"
chk "CX-01r33: citation without @sha needs a reviewed head" 1 "no @sha and the run records no reviewed head" python3 "$VV" --matrix "$SK1B/03-matrix.tsv" --verdicts "$SK1B/05-verdicts.tsv" --repo "$G2"
chk "CX-01r33: citation without @sha resolves at the reviewed head (whitespace/case folded)" 0 "RESOLUTION-OK" pgw pre-resolution "$SK1B"
# CX-02r34: a citation's @sha must be a hex id whose tree is the reviewed head's or the base's.
printf 'F-01\tCONFIRMED\ttrace\tf.txt:1@HEAD "line one"\n' > "$SK1B/05-verdicts.tsv"
chk "CX-02r34: symbolic @HEAD rejected" 1 "not a hex object id" pgw pre-resolution "$SK1B"
( cd "$G2" && printf 'line one\nchanged\n' > f.txt && git add f.txt && git commit -qm later ) ; SHA2B=$(git -C "$G2" rev-parse HEAD)
printf 'F-01\tCONFIRMED\ttrace\tf.txt:1@%s "line one"\n' "$SHA2B" > "$SK1B/05-verdicts.tsv"
chk "CX-02r34: quote at an unreviewed commit rejected" 1 "neither the reviewed head nor the base" pgw pre-resolution "$SK1B"
printf 'F-01\tCONFIRMED\ttrace\tf.txt:1@%s "line one"\n' "$(git -C "$G2" rev-parse "$SHA2^{tree}")" > "$SK1B/05-verdicts.tsv"
chk "CX-02r34: citing the reviewed tree id directly accepted" 0 "RESOLUTION-OK" pgw pre-resolution "$SK1B"
printf 'F-01\tCONFIRMED\ttrace\tf.txt:1@%s "line one"\n' "$(printf %s "$SHA2" | cut -c1-12)" > "$SK1B/05-verdicts.tsv"
chk "CX-02r34: abbreviated reviewed sha accepted" 0 "RESOLUTION-OK" pgw pre-resolution "$SK1B"
chk "CX-01r23: command evidence accepted" 0 "OK verdicts=1" python3 "$VV" --matrix "$SK1B/03-matrix.tsv" --verdicts "$SK1B/05-verdicts.tsv"
# CX-01r29: a backticked citation (the Markdown habit the verifier contract used to show) is normalized, not rejected.
printf 'F-01\tCONFIRMED\ttrace\t`f.txt:1@'"$SHA2"'` "line one"\n' > "$SK1B/05-verdicts.tsv"
chk "CX-01r29: backticked citation accepted" 0 "OK verdicts=1" python3 "$VV" --matrix "$SK1B/03-matrix.tsv" --verdicts "$SK1B/05-verdicts.tsv"
printf 'F-01\tCONFIRMED\ttrace\t`just trust me` "x"\n' > "$SK1B/05-verdicts.tsv"
chk "CX-01r29: backticked prose still rejected" 1 "quoted citation" python3 "$VV" --matrix "$SK1B/03-matrix.tsv" --verdicts "$SK1B/05-verdicts.tsv"
printf 'F-01\tCONFIRMED\t(b) trace\tf.txt:1@'"$SHA2"' "line one"\n' > "$SK1B/05-verdicts.tsv"
chk "CX-01r25: verifier rung spelling '(b) trace' accepted" 0 "OK verdicts=1" python3 "$VV" --matrix "$SK1B/03-matrix.tsv" --verdicts "$SK1B/05-verdicts.tsv"
printf 'F-01\tCONFIRMED\t(b) repro\tf.txt:1@'"$SHA2"' "line one"\n' > "$SK1B/05-verdicts.tsv"
chk "CX-01r25: mismatched rung letter rejected" 1 "need repro, trace, suite, or history" python3 "$VV" --matrix "$SK1B/03-matrix.tsv" --verdicts "$SK1B/05-verdicts.tsv"
printf 'F-01\tUNVERIFIABLE\n' > "$SK1B/05-verdicts.tsv"
chk "CX-01r23: UNVERIFIABLE needs no evidence" 0 "OK verdicts=1" python3 "$VV" --matrix "$SK1B/03-matrix.tsv" --verdicts "$SK1B/05-verdicts.tsv"
chk "CX-01r23: validator runs on /usr/bin/python3" 0 "OK verdicts=1" /usr/bin/python3 "$VV" --matrix "$SK1B/03-matrix.tsv" --verdicts "$SK1B/05-verdicts.tsv"
printf 'F-01\tCONFIRMED\ttrace\tf.txt:1@'"$SHA2"' "line one"\n' > "$SK1B/05-verdicts.tsv"

# F-04r5: whitespace-only fields must be rejected by the packet validator.
printf 'F-01\tCLAUDE-ONLY\tP2\n' > "$TMP/f04r5.tsv"
printf '{"id":"F-01","severity":"P2","claim":" ","locations":["a:1"],"trigger":"t","impact":"i","observations":["a:1 \\"x\\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":["q"]}\n' > "$TMP/f04r5-ws.ndjson"
chk "F-04r5: whitespace-only claim rejected" 1 "non-blank" python3 "$PV" --matrix "$TMP/f04r5.tsv" --packets "$TMP/f04r5-ws.ndjson"

echo "review: round-6 findings F-01r6/F-02r6/F-03r6/F-04r6/F-05r6 regressions"
# F-03r6: the provenance filter must catch "lead reviewer says", "Codex reviewed
# this", and "See 04-consultation.json".
python3 - "$CV" "$CS/03-matrix.tsv" "$CS/03-debate-selection.tsv" "$CS/04-consultation.stdout" <<'PY2'
import json,re,sys
cv,manifest,selection,src=sys.argv[1:5]
s=open(src).read(); d=json.loads(re.search(r'```json\s*(\{.*\})\s*```',s,re.S).group(1))
d['dispositions'][0]['claim']='The lead reviewer says this is broken'
open(src+'.r6bad','w').write('```json\n'+json.dumps(d)+'\n```\n')
PY2
chk "F-03r6: 'lead reviewer says' rejected" 1 "provenance" python3 "$CV" --manifest "$CS/03-matrix.tsv" --selection "$CS/03-debate-selection.tsv" --phase consultation --extract "$CS/04-consultation.stdout.r6bad" --out "$CS/ignored.json"

# F-05r6: VERIFY with whitespace-only open_factual_questions must be rejected.
python3 - "$CS/04-consultation.stdout" <<'PY2'
import json,re,sys
src=sys.argv[1]; s=open(src).read(); d=json.loads(re.search(r'```json\s*(\{.*\})\s*```',s,re.S).group(1))
d['dispositions'][1]['action']='VERIFY'; d['dispositions'][1]['open_factual_questions']=[' ']
open(src+'.r6ws','w').write('```json\n'+json.dumps(d)+'\n```\n')
PY2
chk "F-05r6: VERIFY whitespace-only question rejected" 1 "non-blank open factual" python3 "$CV" --manifest "$CS/03-matrix.tsv" --selection "$CS/03-debate-selection.tsv" --phase consultation --extract "$CS/04-consultation.stdout.r6ws" --out "$CS/ignored.json"

# F-01r6: normalizeFinding must reject an ID that doesn't match F-[0-9]{2,}.
# Verified via the workflow smoke test's ID validation below.
# F-02r6: reject_unconfirmed_cancel must reject exit-5 sidecars.
SK2R6="$TMP/f02r6"; mkdir -p "$SK2R6"
printf 'scope\n' > "$SK2R6/00-scope.md"; mkbrief "$SK2R6"
pgw pre-codex "$SK2R6" "$G2" >/dev/null
printf 'lead\nSTATUS: PHASE 1 COMPLETE\n' > "$SK2R6/01-lead.md"; chmod 000 "$SK2R6/01-lead.md"
printf 'codex\nSTATUS: PHASE 2 COMPLETE\n' > "$SK2R6/02-codex.md"; printf '0\n' > "$SK2R6/02-codex.exit"; printf 'blind codex body\n' > "$SK2R6/02-codex.stdout"
pgw pre-phase3 "$SK2R6" >/dev/null
chmod 600 "$SK2R6/01-lead.md"
printf 'matrix\nSTATUS: PHASE 3 COMPLETE\n' > "$SK2R6/03-matrix.md"
printf 'F-01\tCLAUDE-ONLY\tP1\n' > "$SK2R6/03-matrix.tsv"
base_packets "$SK2R6"
printf 'F-01\tCLAUDE-ONLY\tP1\tINCLUDE\tprovisional-P1\n' > "$SK2R6/03-debate-selection.tsv"
pgw pre-consultation "$SK2R6" >/dev/null
printf 'consultation\nSTATUS: PHASE 4 COMPLETE (SKIPPED — exit 5)\n' > "$SK2R6/04-consultation.md"
printf '5\n' > "$SK2R6/04-consultation.exit"
printf 'thread=bad\noutcome=STALLED\ncancel_confirmed=no\n' > "$SK2R6/04-consultation.meta"
chk "F-02r6: exit-5 consultation rejected" 1 "exit 5" pgw pre-verification "$SK2R6"

# F-04r6: pre-codex must reject a sealed run whose status was tampered with.
SK4R6="$TMP/f04r6"; mkdir -p "$SK4R6"
printf 'scope\n' > "$SK4R6/00-scope.md"; mkbrief "$SK4R6"
pgw pre-codex "$SK4R6" "$G2" >/dev/null
printf 'lead\nSTATUS: PHASE 1 COMPLETE\n' > "$SK4R6/01-lead.md"; chmod 000 "$SK4R6/01-lead.md"
printf 'codex\nSTATUS: PHASE 2 COMPLETE\n' > "$SK4R6/02-codex.md"; printf '0\n' > "$SK4R6/02-codex.exit"; printf 'blind codex body\n' > "$SK4R6/02-codex.stdout"
pgw pre-phase3 "$SK4R6" >/dev/null
printf 'codex declined\nSTATUS: PHASE 2 COMPLETE (SKIPPED — declined)\n' > "$SK4R6/02-codex.md"
chk "F-04r6: pre-codex catches sealed-run tampering" 1 "status changed after JOIN-OK" pgw pre-codex "$SK4R6" "$G2"

echo "review: round-7 findings F-01r7/F-02r7 regressions"
# F-01r7: the provenance filter must catch 05-verification.md, 05-verdicts.tsv,
# and paths preceded by =.
printf 'F-01\tCLAUDE-ONLY\tP1\n' > "$TMP/f01r7.tsv"
printf '{"id":"F-01","severity":"P1","claim":"See 05-verification.md","locations":["a:1"],"trigger":"t","impact":"i","observations":["a:1 \\"x\\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":["q"]}\n' > "$TMP/f01r7-bad.ndjson"
chk "F-01r7: 05-verification.md rejected" 1 "provenance" python3 "$PV" --matrix "$TMP/f01r7.tsv" --packets "$TMP/f01r7-bad.ndjson"
printf '{"id":"F-01","severity":"P1","claim":"run=/tmp/x","locations":["a:1"],"trigger":"t","impact":"i","observations":["a:1 \\"x\\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":["q"]}\n' > "$TMP/f01r7-bad2.ndjson"
chk "F-01r7: =/tmp/ path rejected" 1 "provenance" python3 "$PV" --matrix "$TMP/f01r7.tsv" --packets "$TMP/f01r7-bad2.ndjson"

# F-02r7: pre-report must independently validate packets/verdicts even when
# Codex is SKIPPED.
SK2R7="$TMP/f02r7"; mkdir -p "$SK2R7"
printf 'scope\n' > "$SK2R7/00-scope.md"; mkbrief "$SK2R7"
pgw pre-codex "$SK2R7" "$G2" >/dev/null
printf 'lead\nSTATUS: PHASE 1 COMPLETE\n' > "$SK2R7/01-lead.md"; chmod 000 "$SK2R7/01-lead.md"
printf 'PROBE UNAVAILABLE\nSTATUS: PHASE 2 COMPLETE (SKIPPED — declined)\n' > "$SK2R7/02-codex.md"
pgw pre-phase3 "$SK2R7" >/dev/null
chmod 600 "$SK2R7/01-lead.md"
printf 'matrix\nSTATUS: PHASE 3 COMPLETE\n' > "$SK2R7/03-matrix.md"
printf 'F-01\tCLAUDE-ONLY\tP1\n' > "$SK2R7/03-matrix.tsv"
base_packets "$SK2R7"
printf 'F-01\tCLAUDE-ONLY\tP1\tINCLUDE\tprovisional-P1\n' > "$SK2R7/03-debate-selection.tsv"
pgw pre-consultation "$SK2R7" >/dev/null
printf 'consultation skipped\nSTATUS: PHASE 4 COMPLETE (SKIPPED — no Codex)\n' > "$SK2R7/04-consultation.md"
pgw pre-verification "$SK2R7" >/dev/null
printf 'verification\nSTATUS: PHASE 5 COMPLETE\n' > "$SK2R7/05-verification.md"
printf 'resolution skipped\nSTATUS: PHASE 6 COMPLETE (SKIPPED — no residual)\n' > "$SK2R7/06-resolution.md"
rm -f "$SK2R7/05-verifier-packets.ndjson"
chk "F-02r7: pre-report rejects missing packets (SKIPPED Codex)" 1 "05-verifier-packets.ndjson was accepted by pre-verification but is missing" pgw pre-report "$SK2R7"
printf '{"id":"F-01"}\n' > "$SK2R7/05-verifier-packets.ndjson"
chk "F-02r7: pre-report rejects malformed packets (SKIPPED Codex)" 1 "05-verifier-packets.ndjson changed after it was accepted" pgw pre-report "$SK2R7"

echo "review: round-8 findings F-01r8/F-02r8 regressions"
# F-01r8: the provenance filter must catch "reviewers agree", "second opinion",
# and 06-resolution.md.
python3 - "$CV" "$CS/03-matrix.tsv" "$CS/03-debate-selection.tsv" "$CS/04-consultation.stdout" <<'PY2'
import json,re,sys
cv,manifest,selection,src=sys.argv[1:5]
s=open(src).read(); d=json.loads(re.search(r'```json\s*(\{.*\})\s*```',s,re.S).group(1))
d['dispositions'][0]['claim']='Both reviewers agree this is safe'
open(src+'.r8bad','w').write('```json\n'+json.dumps(d)+'\n```\n')
PY2
chk "F-01r8: 'reviewers agree' rejected" 1 "provenance" python3 "$CV" --manifest "$CS/03-matrix.tsv" --selection "$CS/03-debate-selection.tsv" --phase consultation --extract "$CS/04-consultation.stdout.r8bad" --out "$CS/ignored.json"

# F-02r8: a zero-finding review must pass with empty packets/verdicts.
SK2R8="$TMP/f02r8"; mkdir -p "$SK2R8"
printf 'scope\n' > "$SK2R8/00-scope.md"; mkbrief "$SK2R8"
pgw pre-codex "$SK2R8" "$G2" >/dev/null
printf 'lead\nSTATUS: PHASE 1 COMPLETE\n' > "$SK2R8/01-lead.md"; chmod 000 "$SK2R8/01-lead.md"
printf 'codex\nSTATUS: PHASE 2 COMPLETE\n' > "$SK2R8/02-codex.md"; printf '0\n' > "$SK2R8/02-codex.exit"; printf 'blind codex body\n' > "$SK2R8/02-codex.stdout"
pgw pre-phase3 "$SK2R8" >/dev/null
chmod 600 "$SK2R8/01-lead.md"
printf 'matrix\nSTATUS: PHASE 3 COMPLETE\n' > "$SK2R8/03-matrix.md"
printf '' > "$SK2R8/03-matrix.tsv"
base_packets "$SK2R8"
printf '' > "$SK2R8/03-debate-selection.tsv"
pgw pre-consultation "$SK2R8" >/dev/null || { printf '  FAIL  SK2R8 pre-consultation\n'; FAIL=1; }
printf 'consultation skipped\nSTATUS: PHASE 4 COMPLETE (SKIPPED — no candidates)\n' > "$SK2R8/04-consultation.md"
pgw pre-verification "$SK2R8" >/dev/null || { printf '  FAIL  SK2R8 pre-verification\n'; FAIL=1; }
printf 'verification\nSTATUS: PHASE 5 COMPLETE\n' > "$SK2R8/05-verification.md"
printf '' > "$SK2R8/05-verdicts.tsv"
chk "F-02r8: zero-finding review passes" 0 "RESOLUTION-OK" pgw pre-resolution "$SK2R8"

echo "review: round-9 finding F-01r9 regression"
# F-01r9: the provenance filter must catch /private/tmp/..., .ids, .thread,
# .joblog, .progress, .sha256, and .prompt.md artifact suffixes.
printf 'F-01\tCLAUDE-ONLY\tP1\n' > "$TMP/f01r9.tsv"
printf '{"id":"F-01","severity":"P1","claim":"See 06-resolution-selection.ids","locations":["a:1"],"trigger":"t","impact":"i","observations":["a:1 \\"x\\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":["q"]}\n' > "$TMP/f01r9-bad.ndjson"
chk "F-01r9: .ids suffix rejected" 1 "provenance" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/f01r9-bad.ndjson"
printf '{"id":"F-01","severity":"P1","claim":"path=/private/tmp/run","locations":["a:1"],"trigger":"t","impact":"i","observations":["a:1 \\"x\\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":["q"]}\n' > "$TMP/f01r9-bad2.ndjson"
chk "F-01r9: /private/tmp/ rejected" 1 "provenance" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/f01r9-bad2.ndjson"

echo "review: round-10 findings F-01r10/F-02r10/F-03r10 regressions"
# F-02r10: the provenance filter must catch "determined", "recommended", "identified".
printf '{"id":"F-01","severity":"P1","claim":"Codex determined the finding is valid","locations":["a:1"],"trigger":"t","impact":"i","observations":["a:1 \\"x\\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":["q"]}\n' > "$TMP/f02r10-bad.ndjson"
chk "F-02r10: 'determined' rejected" 1 "provenance" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/f02r10-bad.ndjson"
# F-01r10: pre-report must reject exit-5 from 06-resolution.
SK1R10="$TMP/f01r10"; mkdir -p "$SK1R10"
printf 'scope\n' > "$SK1R10/00-scope.md"; mkbrief "$SK1R10"
pgw pre-codex "$SK1R10" "$G2" >/dev/null
printf 'lead\nSTATUS: PHASE 1 COMPLETE\n' > "$SK1R10/01-lead.md"; chmod 000 "$SK1R10/01-lead.md"
printf 'codex\nSTATUS: PHASE 2 COMPLETE\n' > "$SK1R10/02-codex.md"; printf '0\n' > "$SK1R10/02-codex.exit"; printf 'blind codex body\n' > "$SK1R10/02-codex.stdout"
pgw pre-phase3 "$SK1R10" >/dev/null
chmod 600 "$SK1R10/01-lead.md"
printf 'matrix\nSTATUS: PHASE 3 COMPLETE\n' > "$SK1R10/03-matrix.md"
printf 'F-01\tCLAUDE-ONLY\tP1\n' > "$SK1R10/03-matrix.tsv"
base_packets "$SK1R10"
printf 'F-01\tCLAUDE-ONLY\tP1\tINCLUDE\tprovisional-P1\n' > "$SK1R10/03-debate-selection.tsv"
pgw pre-consultation "$SK1R10" >/dev/null
printf 'consultation\nSTATUS: PHASE 4 COMPLETE (SKIPPED — not run)\n' > "$SK1R10/04-consultation.md"
# CX-02r21: an eligible consultation (candidates>0, Codex COMPLETE) may not be
# skipped without a recorded attempt.
chk "CX-02r21: eligible consultation skipped with no attempt rejected" 1 "no consultation attempt was recorded" pgw pre-verification "$SK1R10"
printf 'outcome=FAILED\nthread=x\nmode=--fresh\ncommand=task --fresh --background --prompt-file p\n' > "$SK1R10/04-consultation.meta"; printf '1\n' > "$SK1R10/04-consultation.exit"
printf 'consultation\nSTATUS: PHASE 4 COMPLETE (SKIPPED — runner failed)\n' > "$SK1R10/04-consultation.md"
chk "CX-02r21: skip after a failed attempt accepted" 0 "VERIFICATION-OK consultation=SKIPPED" pgw pre-verification "$SK1R10"
# CX-02r30: a SKIPPED consultation over an exit-0 attempt is allowed only if that response fails validation.
printf '0\n' > "$SK1R10/04-consultation.attempt1.exit"; printf 'no json here\n' > "$SK1R10/04-consultation.attempt1.stdout"
chk "CX-02r30: skip over a malformed exit-0 response accepted" 0 "VERIFICATION-OK consultation=SKIPPED" pgw pre-verification "$SK1R10"
printf 'thread=t-sk1\noutcome=COMPLETED\n' > "$SK1R10/02-codex.meta"
printf '```json\n{"phase":"consultation","dispositions":[{"id":"F-01","action":"MAINTAIN","claim":"first","severity":"P1","locations":["a:1"],"trigger":"t","impact":"i","observations":["a:1 \\"x\\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":[]}]}\n```\n' > "$SK1R10/04-consultation.attempt1.stdout"
printf 'mode=--resume-last\nthread=t-other\n' > "$SK1R10/04-consultation.attempt1.meta"
chk "CX-04r37: valid response on the wrong thread is skippable" 0 "VERIFICATION-OK consultation=SKIPPED" pgw pre-verification "$SK1R10"
printf 'mode=--resume-last\nthread=t-sk1\n' > "$SK1R10/04-consultation.attempt1.meta"
chk "CX-04r37: valid response on the expected thread is not skippable" 1 "valid response on the expected thread" pgw pre-verification "$SK1R10"
printf 'mode=--fresh\nthread=t-other\n' > "$SK1R10/04-consultation.attempt1.meta"
chk "CX-04r37: valid --fresh response is not skippable" 1 "valid response on the expected thread" pgw pre-verification "$SK1R10"
# CL-02r39: a --fresh response whose runner recorded thread=unknown can never be anchored, so it is skippable.
printf 'mode=--fresh\nthread=unknown\n' > "$SK1R10/04-consultation.attempt1.meta"
chk "CL-02r39: --fresh response with thread=unknown is skippable" 0 "VERIFICATION-OK consultation=SKIPPED" pgw pre-verification "$SK1R10"
printf 'mode=--fresh\nthread=t-other\n' > "$SK1R10/04-consultation.attempt1.meta"
rm -f "$SK1R10/04-consultation.attempt1.meta"
cat > "$SK1R10/04-consultation.attempt1.stdout" <<'CONSULT'
```json
{"phase":"consultation","dispositions":[
{"id":"F-01","action":"MAINTAIN","claim":"first","severity":"P1","locations":["a:1"],"trigger":"t","impact":"i","observations":["a:1 \"x\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":[]}
]}
```
CONSULT
printf 'mode=--fresh\n' > "$SK1R10/04-consultation.attempt1.meta"
chk "CX-02r30: skip over a valid exit-0 response refused" 1 "succeeded with a valid response" pgw pre-verification "$SK1R10"
rm -f "$SK1R10/04-consultation.attempt1.exit" "$SK1R10/04-consultation.attempt1.stdout" "$SK1R10/04-consultation.attempt1.meta"
for n in 1 2; do printf '0\n' > "$SK1R10/04-consultation.attempt$n.exit"; printf 'no json here\n' > "$SK1R10/04-consultation.attempt$n.stdout"; done
chk "CX-05r36: two malformed exit-0 attempts consume no response budget" 0 "VERIFICATION-OK consultation=SKIPPED" pgw pre-verification "$SK1R10"
rm -f "$SK1R10"/04-consultation.attempt[12].exit "$SK1R10"/04-consultation.attempt[12].stdout
printf 'verification\nSTATUS: PHASE 5 COMPLETE\n' > "$SK1R10/05-verification.md"
printf 'F-01\tCONFIRMED\ttrace\tf.txt:1@'"$SHA2"' "line one"\n' > "$SK1R10/05-verdicts.tsv"
pgw pre-resolution "$SK1R10" >/dev/null || { printf '  FAIL  SK1R10 pre-resolution\n'; FAIL=1; }
printf 'resolution\nSTATUS: PHASE 6 COMPLETE (SKIPPED — exit 5)\n' > "$SK1R10/06-resolution.md"
printf '5\n' > "$SK1R10/06-resolution.exit"
printf 'thread=bad\noutcome=STALLED\ncancel_confirmed=no\n' > "$SK1R10/06-resolution.meta"
chk "F-01r10: pre-report rejects exit-5 resolution" 1 "exit 5" pgw pre-report "$SK1R10"

echo "review: round-11 findings F-01r11/F-02r11/F-03r11 regressions"
# F-01r11: the provenance filter must catch backtick-quoted /tmp/ paths.
python3 - "$TMP/f01r9.tsv" <<'PY2'
import json, sys
tsv = sys.argv[1]
d = {"id":"F-01","severity":"P1","claim":"See `/tmp/run/secret.txt` here","locations":["a:1"],"trigger":"t","impact":"i","observations":["a:1 \"x\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":["q"]}
open(tsv.rsplit("/",1)[0] + "/f01r11-bad.ndjson", "w").write(json.dumps(d) + "\n")
PY2
chk "F-01r11: backtick-quoted tmp path rejected" 1 "provenance" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/f01r11-bad.ndjson"
printf '{"id":"F-01","severity":"P1","claim":"See the attempt1 output","locations":["a:1"],"trigger":"t","impact":"i","observations":["a:1 \\"x\\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":["q"]}\n' > "$TMP/f01r11-ok.ndjson"
chk "F-01r11: ordinary text accepted" 0 "OK packets=1" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/f01r11-ok.ndjson"

echo "review: round-11 structural fix — LOCATION_RE on structured fields"
# locations and observations must be path:line or path:line@sha "quote"
printf '{"id":"F-01","severity":"P1","claim":"x","locations":["See the sidecar file"],"trigger":"t","impact":"i","observations":["a:1 \\"x\\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":["q"]}\n' > "$TMP/struct-bad-loc.ndjson"
chk "struct: non-path:line location rejected" 1 "path:line or path:line@sha" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/struct-bad-loc.ndjson"
printf '{"id":"F-01","severity":"P1","claim":"x","locations":["a:1"],"trigger":"t","impact":"i","observations":["just some text"],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":["q"]}\n' > "$TMP/struct-bad-obs.ndjson"
chk "struct: non-path:line observation rejected" 1 "path:line or path:line@sha" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/struct-bad-obs.ndjson"
printf '{"id":"F-01","severity":"P1","claim":"x","locations":["plugins/path:42"],"trigger":"t","impact":"i","observations":["src:1@sha \\"q\\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":["q"]}\n' > "$TMP/struct-ok.ndjson"
chk "struct: valid path:line citations accepted" 0 "OK packets=1" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/struct-ok.ndjson"

echo "review: round-13 findings F-01r13/F-03r13/F-04r13 regressions"
# F-03r13: provenance filter must catch 02-review-seal.sha256 and 01-lead.<shard>.md in structured fields
python3 - "$TMP/f01r9.tsv" <<'PY2'
import json,sys
tsv=sys.argv[1]
d={"id":"F-01","severity":"P1","claim":"x","locations":["02-review-seal.sha256:1"],"trigger":"t","impact":"i","observations":["01-lead.web.md:1"],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":["q"]}
open(tsv.rsplit("/",1)[0]+"/f01r13-bad.ndjson","w").write(json.dumps(d)+"\n")
PY2
chk "F-03r13: review-seal/lead-shard in structured field rejected" 1 "review artifact" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/f01r13-bad.ndjson"

# F-04r13: JS LOCATION_RE must accept Unicode paths (matching Python)
python3 - "$TMP/f01r9.tsv" <<'PY2'
import json,sys
tsv=sys.argv[1]
d={"id":"F-01","severity":"P1","claim":"x","locations":["src/café.py:1"],"trigger":"t","impact":"i","observations":["src:1@sha \"q\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":["q"]}
open(tsv.rsplit("/",1)[0]+"/f01r13-unicode.ndjson","w").write(json.dumps(d)+"\n")
PY2
chk "F-04r13: Unicode path in structured field accepted" 0 "OK packets=1" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/f01r13-unicode.ndjson"

echo "review: round-14 findings CX-01/CX-02/CX-06 regressions"
# CX-06r14: an absolute run-directory path after "(" must be rejected (Python).
python3 - "$TMP/f01r9.tsv" <<'PY2'
import json,sys
tsv=sys.argv[1]
d={"id":"F-01","severity":"P1","claim":"See(/tmp/two-model-pr-review/run/secret.txt)","locations":["a:1"],"trigger":"t","impact":"i","observations":["a:1 \"x\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":["q"]}
open(tsv.rsplit("/",1)[0]+"/cx06r14-bad.ndjson","w").write(json.dumps(d)+"\n")
d["claim"]="ordinary claim"; d["locations"]=["src/foo_bar.py:10"]; d["observations"]=["src/foo_bar.py:10@abc123 \"q\""]
open(tsv.rsplit("/",1)[0]+"/cx01r14-ok.ndjson","w").write(json.dumps(d)+"\n")
PY2
chk "CX-06r14: paren-prefixed /tmp path rejected (python)" 1 "provenance" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/cx06r14-bad.ndjson"
chk "CX-01r14: underscore path accepted (python)" 0 "OK packets=1" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/cx01r14-ok.ndjson"
# CX-01r14 / CX-02r14 / CX-06r14 on the JS side: underscore paths accepted,
# whitespace-only evidence coerces CONFIRMED→UNVERIFIABLE, "(" + /tmp rejected.
WF=plugins/codex-pr-review/skills/two-model-pr-review/templates/review-workflow.js
out=$(node - "$WF" <<'JSEOF' 2>&1
const fs = require("fs"); const src = fs.readFileSync(process.argv[2], "utf8").replace(/^export /mg, "");
const AF = Object.getPrototypeOf(async function () {}).constructor;
const log = () => {}; const phase = () => {};
const parallel = async thunks => Promise.all(thunks.map(t => t()));
const pipeline = async (items, ...stages) => Promise.all(items.map(async (it, i) => { let r = it; for (const s of stages) r = await s(r, it, i); return r; }));
async function run(args, agent) { const f = new AF("args","phase","log","agent","parallel","pipeline","workflow","budget", src); return f(args, phase, log, agent, parallel, pipeline, null, {total:null}); }
const base = { severity: "P1", claim: "x", trigger: "t", impact: "i", falsifier: "f", proposed_checks: ["c"] };
(async () => {
  // CX-01: underscore path must pass normalization
  const blank = async () => ({ verdict: "CONFIRMED", method: "(b) trace", evidence: [" "], trigger: "t", severity_note: "unchanged", refutation_searched: "r", finding: "F-01" });
  const v = await run({ stage: "verify", art: "/a", repo: "/r", findings: [{ ...base, id: "F-01", locations: ["src/foo_bar.py:10"], observations: ["src/foo_bar.py:10@abc_1 \"q\""] }] }, blank);
  if (v.verdicts.length !== 1) throw new Error("underscore path rejected: " + JSON.stringify(v));
  // CX-02: whitespace-only evidence must not yield CONFIRMED
  if (v.verdicts[0].verdict !== "UNVERIFIABLE") throw new Error("blank evidence accepted as CONFIRMED: " + JSON.stringify(v.verdicts[0]));
  // CX-06: "(" + absolute run path in free text must be rejected
  let threw = false;
  try { await run({ stage: "verify", art: "/a", repo: "/r", findings: [{ ...base, id: "F-01", claim: "See(/tmp/two-model-pr-review/run/x.txt)", locations: ["a:1"], observations: ["a:1"] }] }, blank); } catch (e) { threw = /provenance or artifact path/.test(e.message); }
  if (!threw) throw new Error("paren-prefixed /tmp path accepted by JS filter");
  console.log("R14-OK");
})().catch(e => { console.log("R14-FAIL " + e.message); process.exit(1); });
JSEOF
); code=$?
[ "$code" = 0 ] && printf '%s' "$out" | grep -q R14-OK && printf '  ok    %-42s\n' "CX-01/02/06r14: JS underscore/blank-evidence/paren-path" || { printf '  FAIL  r14 JS probes: %s\n' "$out"; FAIL=1; }

echo "review: round-15 findings CX-01/CX-03/CX-05 regressions"
python3 - "$TMP/f01r9.tsv" <<'PY2'
import json,sys
tsv=sys.argv[1]; d0={"id":"F-01","severity":"P1","claim":"x","locations":["a:1"],"trigger":"t","impact":"i","observations":["a:1 \"x\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":["q"]}
def w(name, **kw):
    d=dict(d0); d.update(kw); open(tsv.rsplit("/",1)[0]+"/"+name,"w").write(json.dumps(d)+"\n")
w("cx01r15-abs.ndjson", locations=["/var/run/review.txt:12"])
w("cx01r15-dotdot.ndjson", observations=["../outside.md:1 \"x\""])
w("cx01r15-scratch.ndjson", locations=["verify-scratch/F-01/repro.log:1"])
w("cx05r15-space.ndjson", locations=["\"docs/API guide.md\":42"], observations=["\"docs/API guide.md\":42@abc123 \"q\""])
w("cx03r15-attrib.ndjson", claim="The Codex review concluded this is safe")
w("cx03r15-attrib2.ndjson", falsifier="wrong if the review from Codex is right")
w("cx03r15-plain.ndjson", claim="the codex runner exits 4 when the plugin is missing")
PY2
chk "CX-01r15: absolute path citation rejected" 1 "repository-relative" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/cx01r15-abs.ndjson"
chk "CX-01r15: ../ citation rejected" 1 "must not contain" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/cx01r15-dotdot.ndjson"
chk "CX-01r15: scratch-dir citation rejected" 1 "scratch directory" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/cx01r15-scratch.ndjson"
chk "CX-05r15: quoted path with spaces accepted" 0 "OK packets=1" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/cx05r15-space.ndjson"
chk "CX-03r15: 'Codex review concluded' rejected" 1 "provenance" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/cx03r15-attrib.ndjson"
chk "CX-03r15: 'review from Codex' rejected" 1 "provenance" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/cx03r15-attrib2.ndjson"
chk "CX-03r15: plain domain mention of the runner accepted" 0 "OK packets=1" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/cx03r15-plain.ndjson"
WF=plugins/codex-pr-review/skills/two-model-pr-review/templates/review-workflow.js
out=$(node - "$WF" <<'JSEOF' 2>&1
const fs = require("fs"); const src = fs.readFileSync(process.argv[2], "utf8").replace(/^export /mg, "");
const AF = Object.getPrototypeOf(async function () {}).constructor;
const log = () => {}; const phase = () => {};
const parallel = async thunks => Promise.all(thunks.map(t => t()));
const pipeline = async (items, ...stages) => Promise.all(items.map(async (it, i) => { let r = it; for (const s of stages) r = await s(r, it, i); return r; }));
async function run(args, agent) { const f = new AF("args","phase","log","agent","parallel","pipeline","workflow","budget", src); return f(args, phase, log, agent, parallel, pipeline, null, {total:null}); }
const base = { id: "F-01", severity: "P1", claim: "x", trigger: "t", impact: "i", falsifier: "f", proposed_checks: ["c"] };
const ok = async () => ({ verdict: "CONFIRMED", method: "(b) trace", evidence: ["a:1@sha \"x\""], trigger: "t", severity_note: "unchanged", refutation_searched: "r", finding: "F-01" });
const expectThrow = async (f, re, what) => { let threw = false; try { await run({ stage: "verify", art: "/a", repo: "/r", findings: [f] }, ok); } catch (e) { threw = re.test(e.message); } if (!threw) throw new Error(what + " accepted"); };
(async () => {
  await expectThrow({ ...base, locations: ["/var/run/review.txt:12"], observations: ["a:1"] }, /repository-relative/, "absolute path");
  await expectThrow({ ...base, locations: ["a:1"], observations: ["../x.md:1"] }, /must not contain/, "../ path");
  await expectThrow({ ...base, locations: ["verify-scratch/F-01/r.log:1"], observations: ["a:1"] }, /scratch directory/, "scratch path");
  await expectThrow({ ...base, claim: "The Codex review concluded this is safe", locations: ["a:1"], observations: ["a:1"] }, /provenance/, "attribution phrase");
  const v = await run({ stage: "verify", art: "/a", repo: "/r", findings: [{ ...base, locations: ['"docs/API guide.md":42'], observations: ['"docs/API guide.md":42@abc123 "q"'] }] }, ok);
  if (v.verdicts.length !== 1 || v.verdicts[0].verdict !== "CONFIRMED") throw new Error("quoted space path rejected: " + JSON.stringify(v));
  const tick = async () => ({ verdict: "CONFIRMED", method: "(b) trace", evidence: ["`a:1@sha` \"x\""], trigger: "t", severity_note: "unchanged", refutation_searched: "r", finding: "F-01" });
  const v2 = await run({ stage: "verify", art: "/a", repo: "/r", findings: [{ ...base, locations: ["a:1"], observations: ["a:1"] }] }, tick);
  if (v2.verdicts[0].verdict !== "CONFIRMED") throw new Error("backticked citation coerced: " + JSON.stringify(v2));
  console.log("R15-OK");
})().catch(e => { console.log("R15-FAIL " + e.message); process.exit(1); });
JSEOF
); code=$?
[ "$code" = 0 ] && printf '%s' "$out" | grep -q R15-OK && printf '  ok    %-42s\n' "CX-01/03/05r15: JS repo-relative/attribution/quoted-space" || { printf '  FAIL  r15 JS probes: %s\n' "$out"; FAIL=1; }

echo "review: round-16 findings CX-01/CX-02 + L-01/L-02 regressions"
# CX-01r16: the shared module must import on the Python 3.9 shipped with macOS.
if [ -x /usr/bin/python3 ]; then
  /usr/bin/python3 -c "import sys; sys.path.insert(0, '$(dirname "$PV")'); import review_common" >/dev/null 2>&1 && printf '  ok    %-42s\n' "CX-01r16: review_common imports on /usr/bin/python3 ($(/usr/bin/python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])'))" || { printf '  FAIL  CX-01r16: review_common does not import on /usr/bin/python3\n'; FAIL=1; }
  chk "CX-01r16: packet validator runs on /usr/bin/python3" 0 "OK packets=1" /usr/bin/python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/cx05r15-space.ndjson"
fi
# CX-01r37: a repository path that merely contains an agent name is citable; the quote still gets the full filter.
python3 - "$TMP/f01r9.tsv" <<'PY2'
import json,sys
tsv=sys.argv[1]; d={"id":"F-01","severity":"P1","claim":"x","locations":["plugins/codex-pr-review/agents/finding-verifier.md:12"],"trigger":"t","impact":"i","observations":["plugins/codex-pr-review/agents/finding-verifier.md:12@abc \"quoted\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":["q"]}
open(tsv.rsplit("/",1)[0]+"/cx01r37-ok.ndjson","w").write(json.dumps(d)+"\n")
d["observations"]=["src/a.py:1 \"as codex noted here\""]
open(tsv.rsplit("/",1)[0]+"/cx01r37-bad.ndjson","w").write(json.dumps(d)+"\n")
d["observations"]=["00-notes.md:1 \"x\""]
open(tsv.rsplit("/",1)[0]+"/cx01r37-art.ndjson","w").write(json.dumps(d)+"\n")
PY2
chk "CX-01r37: path naming an agent file accepted" 0 "OK packets=1" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/cx01r37-ok.ndjson"
chk "CX-01r37: provenance in the quote still rejected" 1 "provenance" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/cx01r37-bad.ndjson"
chk "CX-01r37: artifact-shaped root path still rejected" 1 "provenance or artifact" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/cx01r37-art.ndjson"
# CX-02r16: table-driven — every shipped artifact name is rejected in free text
# and in structured fields; ordinary repo paths that merely start with digits are not.
n=0; bad=""
for name in 00-scope.md 00-accepted.sha256 run/00-accepted.sha256 00-brief.md 00-brief.md.tree 00-brief.md.baseline 00-brief.md.sha256 00-run.md 00-intent.txt 00-conventions.txt 01-lead.md 01-lead.web.md 02-codex.stdout 02-codex.stderr 02-codex.joblog 02-codex.progress 02-codex.meta 02-codex.exit 02-codex.attempt2.stderr 03-findings.ndjson 03-findings.sha256 07-review.md 02-review-seal.sha256 03-matrix.tsv 03-debate-selection.tsv 04-consultation.thread 04-consultation.prompt.md 05-verifier-packets.ndjson 05-verdicts.tsv 06-resolution-selection.ids 06-resolution.json verify-scratch lead-scratch; do
  python3 - "$TMP/f01r9.tsv" "$name" <<'PY2'
import json,sys
tsv,name=sys.argv[1],sys.argv[2]
d={"id":"F-01","severity":"P1","claim":"See %s for details" % name,"locations":["a:1"],"trigger":"t","impact":"i","observations":["a:1 \"x\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":["q"]}
open(tsv.rsplit("/",1)[0]+"/cx02r16.ndjson","w").write(json.dumps(d)+"\n")
d["claim"]="x"; d["locations"]=["%s:1" % name]
open(tsv.rsplit("/",1)[0]+"/cx02r16-loc.ndjson","w").write(json.dumps(d)+"\n")
PY2
  python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/cx02r16.ndjson" >/dev/null 2>&1 && bad="$bad $name(text)"
  python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/cx02r16-loc.ndjson" >/dev/null 2>&1 && bad="$bad $name(loc)"
  n=$((n+1))
done
[ -z "$bad" ] && printf '  ok    %-42s\n' "CX-02r16: $n artifact names rejected in text and locations" || { printf '  FAIL  CX-02r16: accepted:%s\n' "$bad"; FAIL=1; }
# CX-02r26: the final report is 07-review.md, an artifact name at any depth; the template path stays citable.
python3 - "$TMP/f01r9.tsv" <<'PY2'
import json, sys
tsv = sys.argv[1]
d = {"id":"F-01","severity":"P1","claim":"x","locations":["run/07-review.md:1"],"trigger":"t","impact":"i","observations":["a:1 \"x\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":["q"]}
open(tsv.rsplit("/",1)[0]+"/cx02r26-bad.ndjson","w").write(json.dumps(d)+"\n")
d["locations"] = ["plugins/codex-pr-review/skills/two-model-pr-review/templates/REVIEW.md:3"]
open(tsv.rsplit("/",1)[0]+"/cx02r26-ok.ndjson","w").write(json.dumps(d)+"\n")
PY2
chk "CX-02r26: run/07-review.md rejected as a location" 1 "review artifact" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/cx02r26-bad.ndjson"
chk "CX-02r26: templates/REVIEW.md still citable" 0 "OK packets=1" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/cx02r26-ok.ndjson"
python3 - "$TMP/f01r9.tsv" <<'PY2'
import json,sys
tsv=sys.argv[1]
d={"id":"F-01","severity":"P1","claim":"the anthropic client retries twice; a haiku about opus","locations":["docs/00-intro.md:3","migrations/01-init.sql:9"],"trigger":"t","impact":"i","observations":["docs/00-intro.md:3 \"x\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":["q"]}
open(tsv.rsplit("/",1)[0]+"/l01r16-ok.ndjson","w").write(json.dumps(d)+"\n")
d["claim"]="claude opus decided this"; open(tsv.rsplit("/",1)[0]+"/l01r16-bad.ndjson","w").write(json.dumps(d)+"\n")
d["claim"]="x"; d["locations"]=["\"a\\\\b.md\":1"]; open(tsv.rsplit("/",1)[0]+"/l02r16-bs.ndjson","w").write(json.dumps(d)+"\n")
d["locations"]=["\"docs/API guide.md:1"]; open(tsv.rsplit("/",1)[0]+"/l02r16-unterm.ndjson","w").write(json.dumps(d)+"\n")
PY2
chk "L-01r16: vendor words + digit-prefixed repo paths accepted" 0 "OK packets=1" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/l01r16-ok.ndjson"
chk "L-01r16: 'claude opus' identity phrase rejected" 1 "provenance" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/l01r16-bad.ndjson"
# CX-01r28: attribution by preposition or verb is provenance; tool names and paths are not.
n=0; bad=""
for phrase in "This was checked by Codex" "According to Codex the loop exits early" "per Claude this is fine" "Codex confirmed the bug" "claude noted the retry" "the change from the lead" "Codex claims otherwise"; do
  python3 - "$TMP/f01r9.tsv" "$phrase" <<'PY2'
import json,sys
tsv,phrase=sys.argv[1],sys.argv[2]
d={"id":"F-01","severity":"P1","claim":phrase,"locations":["a:1"],"trigger":"t","impact":"i","observations":["a:1 \"x\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":["q"]}
open(tsv.rsplit("/",1)[0]+"/cx01r28.ndjson","w").write(json.dumps(d)+"\n")
PY2
  python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/cx01r28.ndjson" >/dev/null 2>&1 && bad="$bad [$phrase]"
  n=$((n+1))
done
[ -z "$bad" ] && printf '  ok    %-42s\n' "CX-01r28: $n attribution phrases rejected" || { printf '  FAIL  CX-01r28: accepted:%s\n' "$bad"; FAIL=1; }
python3 - "$TMP/f01r9.tsv" <<'PY2'
import json,sys
tsv=sys.argv[1]
d={"id":"F-01","severity":"P1","claim":"launched by codex-run.sh from plugins/codex-pr-review/scripts; falls back to codex/setup.md","locations":["a:1"],"trigger":"t","impact":"i","observations":["a:1 \"x\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":["q"]}
open(tsv.rsplit("/",1)[0]+"/cx01r28-ok.ndjson","w").write(json.dumps(d)+"\n")
PY2
chk "CX-01r28: tool names and paths after a preposition accepted" 0 "OK packets=1" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/cx01r28-ok.ndjson"
out=$(node - "$WF" <<'JSEOF' 2>&1
const fs = require("fs"); const src = fs.readFileSync(process.argv[2], "utf8");
const P = eval(src.match(/const PROVENANCE_RE = (.*)\n/)[1]);
const bad = ["This was checked by Codex","According to Codex it fails","Codex confirmed the bug","per Claude this is fine"];
const good = ["launched by codex-run.sh","see plugins/codex-pr-review/scripts"];
for (const t of bad) if (!P.test(t)) throw new Error("JS accepted: " + t);
for (const t of good) if (P.test(t)) throw new Error("JS rejected: " + t);
console.log("R28-OK");
JSEOF
); code=$?
[ "$code" = 0 ] && printf '%s' "$out" | grep -q R28-OK && printf '  ok    %-42s\n' "CX-01r28: JS mirror attribution arms" || { printf '  FAIL  r28 JS probes: %s\n' "$out"; FAIL=1; }
chk "L-02r16: backslash inside quoted path rejected" 1 "path:line" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/l02r16-bs.ndjson"
chk "L-02r16: unterminated quoted path rejected" 1 "path:line" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/l02r16-unterm.ndjson"
out=$(node - "$WF" <<'JSEOF' 2>&1
const fs = require("fs"); const src = fs.readFileSync(process.argv[2], "utf8");
const P = eval(src.match(/const PROVENANCE_RE = (.*)\n/)[1]);
const bad = ["See 07-review.md","see run/07-review.md","open 02-codex.stderr","the 00-brief.md.tree hash","wrote verify-scratch/F-01","claude opus decided"];
const good = ["the anthropic client retries twice","docs/00-intro.md:3","a haiku about opus","templates/REVIEW.md:12"];
for (const t of bad) if (!P.test(t)) throw new Error("JS accepted: " + t);
for (const t of good) if (P.test(t)) throw new Error("JS rejected: " + t);
console.log("R16-OK");
JSEOF
); code=$?
[ "$code" = 0 ] && printf '%s' "$out" | grep -q R16-OK && printf '  ok    %-42s\n' "CX-02/L-01r16: JS mirror artifact/identity arms" || { printf '  FAIL  r16 JS probes: %s\n' "$out"; FAIL=1; }

echo "review: round-17 findings CX-03/CX-04 + L-02 regressions"
python3 - "$TMP/f01r9.tsv" <<'PY2'
import json,sys
tsv=sys.argv[1]
d={"id":"F-01","severity":"P1","claim":"x","locations":["src/x.py:1"],"trigger":"t","impact":"i","observations":["src/x.py:1@abc \"print(\"hi\")\"","src/y.py:3-5 \"a \"b\" c\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":["q"]}
open(tsv.rsplit("/",1)[0]+"/cx04r17-ok.ndjson","w").write(json.dumps(d)+"\n")
d["claim"]="compare against claude-codex-duo/local-HEAD-round17-20260905-161331/00-brief.md"
open(tsv.rsplit("/",1)[0]+"/l02r17-bad.ndjson","w").write(json.dumps(d)+"\n")
PY2
chk "CX-04r17: inner double quotes and line ranges accepted" 0 "OK packets=1" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/cx04r17-ok.ndjson"
chk "L-02r17: relative run-directory path rejected" 1 "provenance" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/l02r17-bad.ndjson"
out=$(node - "$WF" <<'JSEOF' 2>&1
const fs = require("fs"); const src = fs.readFileSync(process.argv[2], "utf8").replace(/^export /mg, "");
const AF = Object.getPrototypeOf(async function () {}).constructor;
const log = () => {}; const phase = () => {};
const parallel = async thunks => Promise.all(thunks.map(t => t()));
const pipeline = async (items, ...stages) => Promise.all(items.map(async (it, i) => { let r = it; for (const s of stages) r = await s(r, it, i); return r; }));
async function run(args, agent) { const f = new AF("args","phase","log","agent","parallel","pipeline","workflow","budget", src); return f(args, phase, log, agent, parallel, pipeline, null, {total:null}); }
const base = { id: "F-01", severity: "P1", claim: "x", trigger: "t", impact: "i", falsifier: "f", proposed_checks: ["c"], locations: ["src/x.py:1"], observations: ['src/x.py:1@abc "print("hi")"'] };
const mk = ev => async () => ({ verdict: "CONFIRMED", method: "(b) trace", evidence: ev, trigger: "t", severity_note: "unchanged", refutation_searched: "r", finding: "F-01" });
(async () => {
  let v = await run({ stage: "verify", art: "/a", repo: "/r", findings: [base] }, mk(["x"]));
  if (v.verdicts[0].verdict !== "UNVERIFIABLE") throw new Error("prose evidence confirmed: " + JSON.stringify(v.verdicts[0]));
  v = await run({ stage: "verify", art: "/a", repo: "/r", findings: [base] }, mk(['src/x.py:12@abc "quoted line"', "cmd: git grep foo -> 3 hits"]));
  if (v.verdicts[0].verdict !== "CONFIRMED") throw new Error("citation evidence not accepted: " + JSON.stringify(v.verdicts[0]));
  v = await run({ stage: "verify", art: "/a", repo: "/r", findings: [base] }, mk(["cmd: npm run repro -> failure"]));
  if (v.verdicts[0].verdict !== "UNVERIFIABLE") throw new Error("CX-01r35: command-only evidence confirmed: " + JSON.stringify(v.verdicts[0]));
  v = await run({ stage: "verify", art: "/a", repo: "/r", findings: [base] }, mk(['plugins/codex-pr-review/agents/finding-verifier.md:12@abc "quoted"']));
  if (v.verdicts[0].verdict !== "CONFIRMED") throw new Error("CX-01r37: agent-file path rejected as provenance: " + JSON.stringify(v.verdicts[0]));
  v = await run({ stage: "verify", art: "/a", repo: "/r", findings: [base] }, mk(['src/a.py:1@abc "as codex noted"']));
  if (v.verdicts[0].verdict !== "UNVERIFIABLE") throw new Error("CX-01r37: provenance in quote confirmed: " + JSON.stringify(v.verdicts[0]));
  const fvBase = { ...base, locations: ["plugins/codex-pr-review/agents/finding-verifier.md:1"] };
  v = await run({ stage: "verify", art: "/a", repo: "/r", findings: [fvBase] }, mk(['src/a.py:1@abc "ok"']));
  if (v.verdicts[0].verdict !== "CONFIRMED") throw new Error("CX-01r37: agent-file location rejected: " + JSON.stringify(v.verdicts[0]));
  const P = eval(fs.readFileSync(process.argv[2], "utf8").match(/const PROVENANCE_RE = (.*)\n/)[1]);
  if (!P.test("see claude-codex-duo/local-HEAD-round17-20260905-161331/00-brief.md")) throw new Error("JS accepted relative run-dir path");
  console.log("R17-OK");
})().catch(e => { console.log("R17-FAIL " + e.message); process.exit(1); });
JSEOF
); code=$?
[ "$code" = 0 ] && printf '%s' "$out" | grep -q R17-OK && printf '  ok    %-42s\n' "CX-03/CX-04/L-02r17: JS evidence shape, inner quotes, run-dir" || { printf '  FAIL  r17 JS probes: %s\n' "$out"; FAIL=1; }

echo "review: round-18 findings CX-01/CX-02 + L-01 regressions"
python3 - "$TMP/f01r9.tsv" <<'PY2'
import json,sys
tsv=sys.argv[1]
d0={"id":"F-01","severity":"P1","claim":"x","locations":["a:1"],"trigger":"t","impact":"i","observations":["a:1 \"x\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":["q"]}
def w(name, **kw):
    d=dict(d0); d.update(kw); open(tsv.rsplit("/",1)[0]+"/"+name,"w").write(json.dumps(d)+"\n")
w("cx01r18-nested.ndjson", locations=["run/00-brief.md:1"])
w("cx01r18-nested2.ndjson", observations=["x/verify-scratch/F-01/r.log:1 \"q\""])
w("cx01r18-text.ndjson", claim="compare with run/05-verdicts.tsv")
w("cx01r18-ok.ndjson", locations=["docs/00-intro.md:3","plugins/x/templates/REVIEW.md:12","tests/repro/a.py:1"], claim="see docs/00-intro.md and tests/repro")
w("l01r18-newline.ndjson", observations=["a:1-2 \"x\ny\""])
PY2
chk "CX-01r18: nested artifact path rejected" 1 "any depth" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/cx01r18-nested.ndjson"
chk "CX-01r18: nested scratch dir rejected" 1 "any depth" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/cx01r18-nested2.ndjson"
chk "CX-01r18: nested artifact name in free text rejected" 1 "provenance" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/cx01r18-text.ndjson"
chk "CX-01r18: ordinary digit-prefixed / template / repro paths accepted" 0 "OK packets=1" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/cx01r18-ok.ndjson"
chk "L-01r18: multi-line quote accepted (python)" 0 "OK packets=1" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/l01r18-newline.ndjson"
out=$(node - "$WF" <<'JSEOF' 2>&1
const fs = require("fs"); const src = fs.readFileSync(process.argv[2], "utf8").replace(/^export /mg, "");
const AF = Object.getPrototypeOf(async function () {}).constructor;
const log = () => {}; const phase = () => {};
const parallel = async thunks => Promise.all(thunks.map(t => t()));
const pipeline = async (items, ...stages) => Promise.all(items.map(async (it, i) => { let r = it; for (const s of stages) r = await s(r, it, i); return r; }));
async function run(args, agent) { const f = new AF("args","phase","log","agent","parallel","pipeline","workflow","budget", src); return f(args, phase, log, agent, parallel, pipeline, null, {total:null}); }
const base = { id: "F-01", severity: "P1", claim: "x", trigger: "t", impact: "i", falsifier: "f", proposed_checks: ["c"], locations: ["a:1"], observations: ['a:1 "x"'] };
const ok = async () => ({ verdict: "CONFIRMED", method: "(b) trace", evidence: ['src/a.py:1@sha "x"'], trigger: "t", severity_note: "unchanged", refutation_searched: "r", finding: "F-01" });
const expectThrow = async (f, re, what) => { let threw = false; try { await run({ stage: "verify", art: "/a", repo: "/r", findings: [f] }, ok); } catch (e) { threw = re.test(e.message); } if (!threw) throw new Error(what + " accepted"); };
(async () => {
  await expectThrow({ ...base, locations: ["run/00-brief.md:1"] }, /any depth/, "nested artifact path");
  await expectThrow({ ...base, observations: ['x/verify-scratch/F-01/r.log:1 "q"'] }, /any depth/, "nested scratch dir");
  await expectThrow({ ...base, open_factual_questions: false }, /must be an array/, "open_factual_questions:false");
  await expectThrow({ ...base, open_factual_questions: null }, /must be an array/, "open_factual_questions:null");
  let v = await run({ stage: "verify", art: "/a", repo: "/r", findings: [{ ...base, locations: ["docs/00-intro.md:3", "plugins/x/templates/REVIEW.md:12"], observations: ['a:1-2 "x\ny"'] }] }, ok);
  if (v.verdicts.length !== 1) throw new Error("ordinary paths / multi-line quote rejected");
  v = await run({ stage: "verify", art: "/a", repo: "/r", findings: [{ ...base }] }, ok); // open_factual_questions undefined → []
  if (v.verdicts.length !== 1) throw new Error("undefined open_factual_questions rejected");
  console.log("R18-OK");
})().catch(e => { console.log("R18-FAIL " + e.message); process.exit(1); });
JSEOF
); code=$?
[ "$code" = 0 ] && printf '%s' "$out" | grep -q R18-OK && printf '  ok    %-42s\n' "CX-01/CX-02/L-01r18: JS nested paths, falsey OFQ, newline quote" || { printf '  FAIL  r18 JS probes: %s\n' "$out"; FAIL=1; }

echo "review: round-19 findings CX-02/CX-03 regressions"
python3 - "$TMP/f01r9.tsv" <<'PY2'
import json,sys
tsv=sys.argv[1]
d0={"id":"F-01","severity":"P1","claim":"x","locations":["a:1"],"trigger":"t","impact":"i","observations":["a:1 \"x\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":["q"]}
for i,(name,claim) in enumerate([("cx02r19-a.ndjson","Claude Code found the bug"),("cx02r19-b.ndjson","Codex CLI concluded this is safe"),("cx02r19-c.ndjson","The lead agent found this is broken"),("cx02r19-d.ndjson","the other model disagreed")]):
    d=dict(d0); d["claim"]=claim; open(tsv.rsplit("/",1)[0]+"/"+name,"w").write(json.dumps(d)+"\n")
PY2
for f in a b c; do chk "CX-02r19: identity phrase $f rejected" 1 "provenance" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/cx02r19-$f.ndjson"; done
python3 - "$TMP/f01r9.tsv" <<'PY2'
import json,sys
tsv=sys.argv[1]
d0={"id":"F-01","severity":"P1","claim":"x","locations":["a:1"],"trigger":"t","impact":"i","observations":["a:1 \"x\""],"falsifier":"f","proposed_checks":["c"],"open_factual_questions":["q"]}
for name,claim in [("cx04r21-a.ndjson","CLAUDE-ONLY finding"),("cx04r21-b.ndjson","The lead's finding is still valid"),("cx04r21-c.ndjson","see repro/F-01.log"),("cx04r21-d.ndjson","CX-03 covers this"),("cx04r21-ok.ndjson","merge conflict handling in tests/repro/x is fine for both paths")]:
    d=dict(d0); d["claim"]=claim; open(tsv.rsplit("/",1)[0]+"/"+name,"w").write(json.dumps(d)+"\n")
PY2
for f in a b c d; do chk "CX-04r21: origin label / lead's / repro $f rejected" 1 "provenance" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/cx04r21-$f.ndjson"; done
chk "CX-04r21: 'conflict', 'both', nested repro accepted" 0 "OK packets=1" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/cx04r21-ok.ndjson"
chk "L-01r20: ML vocabulary ('the other model') accepted" 0 "OK packets=1" python3 "$PV" --matrix "$TMP/f01r9.tsv" --packets "$TMP/cx02r19-d.ndjson"
out=$(node - "$WF" <<'JSEOF' 2>&1
const fs = require("fs"); const src = fs.readFileSync(process.argv[2], "utf8").replace(/^export /mg, "");
const AF = Object.getPrototypeOf(async function () {}).constructor;
const log = () => {}; const phase = () => {};
const parallel = async thunks => Promise.all(thunks.map(t => t()));
const pipeline = async (items, ...stages) => Promise.all(items.map(async (it, i) => { let r = it; for (const s of stages) r = await s(r, it, i); return r; }));
async function run(args, agent) { const f = new AF("args","phase","log","agent","parallel","pipeline","workflow","budget", src); return f(args, phase, log, agent, parallel, pipeline, null, {total:null}); }
const base = { id: "F-01", severity: "P1", claim: "x", trigger: "t", impact: "i", falsifier: "f", proposed_checks: ["c"], locations: ["a:1"], observations: ['a:1 "x"'] };
const mk = ev => async () => ({ verdict: "CONFIRMED", method: "(b) trace", evidence: ev, trigger: "t", severity_note: "unchanged", refutation_searched: "r", finding: "F-01" });
(async () => {
  let v = await run({ stage: "verify", art: "/a", repo: "/r", findings: [base] }, mk(['src/x.py:1 " "']));
  if (v.verdicts[0].verdict !== "UNVERIFIABLE") throw new Error("whitespace-only quote confirmed");
  v = await run({ stage: "verify", art: "/a", repo: "/r", findings: [base] }, mk(['src/x.py:1 ""']));
  if (v.verdicts[0].verdict !== "UNVERIFIABLE") throw new Error("empty quote confirmed");
  const P = eval(fs.readFileSync(process.argv[2], "utf8").match(/const PROVENANCE_RE = (.*)\n/)[1]);
  for (const t of ["Claude Code found the bug","Codex CLI concluded x","The lead agent found this"]) if (!P.test(t)) throw new Error("JS accepted: " + t);
  if (P.test("the codex runner exits 4")) throw new Error("JS rejected runner mention");
  // CX-01r20: evidence citations must be repository-relative and artifact/provenance-free
  for (const ev of ['/tmp/two-model-pr-review/r/05-verification.md:1 "not source"', 'run/05-verification.md:1 "x"', '../x.py:1 "x"', 'src/x.py:1 "the codex reviewer said so"', 'cmd: cat /tmp/two-model-pr-review/r/01-lead.md -> text']) {
    v = await run({ stage: "verify", art: "/a", repo: "/r", findings: [base] }, mk([ev]));
    if (v.verdicts[0].verdict !== "UNVERIFIABLE") throw new Error("unsafe evidence confirmed: " + ev);
  }
  v = await run({ stage: "verify", art: "/a", repo: "/r", findings: [base] }, mk(['src/x.py:1-3@abc "ok"', 'cmd: git grep foo -> 3 hits']));
  if (v.verdicts[0].verdict !== "CONFIRMED") throw new Error("safe evidence rejected");
  if (P.test("the second model's weights are never freed")) throw new Error("JS rejected ML vocabulary");
  for (const t of ["CLAUDE-ONLY finding", "The lead's finding is still valid", "see repro/F-01.log", "CX-03 covers this"]) if (!P.test(t)) throw new Error("JS accepted: " + t);
  if (P.test("merge conflict handling in tests/repro/x for both paths")) throw new Error("JS rejected ordinary words");
  console.log("R19-OK");
})().catch(e => { console.log("R19-FAIL " + e.message); process.exit(1); });
JSEOF
); code=$?
[ "$code" = 0 ] && printf '%s' "$out" | grep -q R19-OK && printf '  ok    %-42s\n' "CX-02/CX-03r19 + CX-01r20: JS identity, blank quote, unsafe evidence" || { printf '  FAIL  r19 JS probes: %s\n' "$out"; FAIL=1; }

# F-02r5: the JS provenance filter must reject bare artifact filenames, not
# just paths. Verified via the workflow smoke test's provenance assertion below.
echo "review: workflow script compiles the way the Workflow tool evaluates it (scripts/js-check.sh)"
JS=scripts/js-check.sh; WF=plugins/codex-pr-review/skills/two-model-pr-review/templates/review-workflow.js
chk "js-check: no arguments"           2 "usage"                bash "$JS"
printf 'export const x = 1\nconst = ;\n' > "$TMP/broken.js"
chk "js-check: broken module rejected" 1 "SyntaxError"          bash "$JS" "$TMP/broken.js"
node --check "$TMP/broken.js" >/dev/null 2>&1 && printf '  ok    %-42s\n' "js-check: (node --check accepts it — the reason js-check exists)" || printf '  ok    %-42s\n' "js-check: node --check also rejects it on this node"
printf 'export const meta = { name: "m" }\nconst r = await agent("x")\nreturn { r }\n' > "$TMP/good.js"
bash "$JS" "$TMP/good.js" >/dev/null 2>&1 && printf '  ok    %-42s exit=0\n' "js-check: top-level await/return ok" || { printf '  FAIL  js-check rejected good.js\n'; FAIL=1; }
GEN=plugins/codex-pr-review/skills/two-model-pr-review/scripts/gen-workflow-constants.py
python3 "$GEN" --check >/dev/null 2>&1 && printf '  ok    %-42s\n' "gen: review-workflow.js constants match review_common.py" || { printf '  FAIL  gen: review-workflow.js constants drifted from review_common.py\n'; FAIL=1; }
# A drifted block is caught: mutate a copy of the JS and run the generator against it.
mkdir -p "$TMP/gen/scripts" "$TMP/gen/templates"; cp "$GEN" plugins/codex-pr-review/skills/two-model-pr-review/scripts/review_common.py "$TMP/gen/scripts/"; sed "s/const SCRATCH_DIRS = \['verify-scratch', 'lead-scratch'\]/const SCRATCH_DIRS = ['verify-scratch']/" "$WF" > "$TMP/gen/templates/review-workflow.js"
python3 "$TMP/gen/scripts/gen-workflow-constants.py" --check >/dev/null 2>&1 && { printf '  FAIL  gen: drifted constants not detected\n'; FAIL=1; } || printf '  ok    %-42s\n' "gen: drifted constants detected"
python3 "$TMP/gen/scripts/gen-workflow-constants.py" --write >/dev/null 2>&1 && cmp -s "$TMP/gen/templates/review-workflow.js" "$WF" && printf '  ok    %-42s\n' "gen: --write restores the shipped block" || { printf '  FAIL  gen: --write did not restore the block\n'; FAIL=1; }
bash "$JS" "$WF" >/dev/null 2>&1 && printf '  ok    %-42s exit=0\n' "js-check: shipped review-workflow.js" || { printf '  FAIL  js-check rejected the shipped script\n'; FAIL=1; }
# executed smoke test of both stages with stubbed Workflow globals (F-12/F-13 of the 2.0.0 review)
out=$(node - "$WF" <<'JSEOF' 2>&1
const fs = require("fs"); const src = fs.readFileSync(process.argv[2], "utf8").replace(/^export /mg, "");
const AF = Object.getPrototypeOf(async function () {}).constructor;
const calls = []; const log = m => calls.push("log:" + m); const phase = p => calls.push("phase:" + p);
const parallel = async thunks => Promise.all(thunks.map(t => t()));
const pipeline = async (items, ...stages) => Promise.all(items.map(async (it, i) => { let r = it; for (const s of stages) r = await s(r, it, i); return r; }));
async function run(args, agent) { const f = new AF("args","phase","log","agent","parallel","pipeline","workflow","budget", src); return f(args, phase, log, agent, parallel, pipeline, null, {total:null}); }
(async () => {
  // verify: two findings, second agent returns null
  let n = 0; const agentV = async (prompt, opts) => { n++; if (!prompt.includes('"id":"F-0') || !prompt.includes('"claim":"') || !prompt.includes('"locations":["')) throw new Error("prompt lacks normalized finding fields"); if (/origin|CLAUDE-ONLY|CODEX-ONLY|CONSULTATION-OK/.test(prompt)) throw new Error("verifier prompt leaked provenance"); if (opts.agentType !== "codex-pr-review:finding-verifier") throw new Error("wrong agentType"); return n === 1 ? { verdict: "CONFIRMED", method: "(b) trace", evidence: ["a:1@sha \"x\""], trigger: "t", severity_note: "unchanged", refutation_searched: "r", finding: "F-01" } : null; };
  let threwVerify = false; try { await run({ stage: "verify", art: "/a", repo: "/r", findings: [{ id: "F-01", origin: "CLAUDE-ONLY" }] }, agentV); } catch (e) { threwVerify = /forbidden fields: origin/.test(e.message); }
  if (!threwVerify) throw new Error("verifier accepted provenance field");
  const v = await run({ stage: "verify", art: "/a", repo: "/r", findings: [{ id: "F-01", severity: "P1", claim: "x", locations: ["a:1"], trigger: "t", impact: "i", observations: ["a:1"], falsifier: "f", proposed_checks: ["c"] }, { id: "F-02", severity: "P2", claim: "y", locations: ["b:2"], trigger: "t", impact: "i", observations: ["b:2"], falsifier: "f", proposed_checks: ["c"] }] }, agentV);
  if (v.verdicts.length !== 2 || v.verdicts[0].verdict !== "CONFIRMED" || v.verdicts[1].verdict !== "UNVERIFIABLE" || v.nulls.join() !== "F-02") throw new Error("verify stage wrong: " + JSON.stringify(v));
  // lead: bad manifest must throw before any agent call
  let leadCalls = 0; const agentL = async (prompt, opts) => { leadCalls++; if (prompt.includes('shard "web"') && !prompt.includes('"dir/first\\nsecond.md"')) throw new Error("newline path not JSON-encoded: " + prompt); if (opts.agentType !== "codex-pr-review:lead-reviewer") throw new Error("wrong agentType"); return { status: "LEAD SEALED", file: "/a/01-lead.api.md", findings: 1, questions: 0, mode: "0" }; };
  let threw = false; try { await run({ stage: "lead", art: "/a", repo: "/r", files: ["a", "b"], shards: { api: ["a"] } }, agentL); } catch (e) { threw = /unowned/.test(e.message); }
  if (!threw || leadCalls !== 0) throw new Error("bad manifest not rejected before spawning");
  threw = false; try { await run({ stage: "lead", art: "/a", repo: "/r", files: ["a"], shards: { "bad name": ["a"] } }, agentL); } catch (e) { threw = /shard name/.test(e.message); }
  if (!threw) throw new Error("bad shard name accepted");
  const l = await run({ stage: "lead", art: "/a", repo: "/r", files: ["a", "dir/first\nsecond.md"], shards: { api: ["a"], web: ["dir/first\nsecond.md"] } }, agentL);
  if (leadCalls !== 2 || l.shards.length !== 2 || l.failed.length !== 0) throw new Error("lead stage wrong: " + JSON.stringify(l));
  console.log("SMOKE-OK");
})().catch(e => { console.log("SMOKE-FAIL " + e.message); process.exit(1); });
JSEOF
); code=$?
[ "$code" = 0 ] && printf '%s' "$out" | grep -q SMOKE-OK && printf '  ok    %-42s\n' "workflow: both stages run under stubbed globals" || { printf '  FAIL  workflow smoke: %s\n' "$out"; FAIL=1; }

echo "review: agent-watch.sh (supervision of an asynchronous review unit)"
AW=plugins/codex-pr-review/skills/two-model-pr-review/scripts/agent-watch.sh
WD="$TMP/watch"; mkdir -p "$WD"
chk "watch: no arguments"              2 "out-prefix"           bash "$AW"
chk "watch: option as first argument"  2 "out-prefix"           bash "$AW" --expect x
chk "watch: --expect with no value"    2 "requires a value"     bash "$AW" "$WD/a" --expect
chk "watch: --after with no value"     2 "requires a value"     bash "$AW" "$WD/a" --expect x --after
chk "watch: --after followed by option" 2 "requires a value"    bash "$AW" "$WD/a" --expect x --after --label l
chk "watch: non-numeric --after"       2 "whole number"         bash "$AW" "$WD/a" --expect x --after abc
chk "watch: --expect is required"      2 "--expect is required" bash "$AW" "$WD/a" --after 1
chk "watch: a deadline is required"    2 "--after"              bash "$AW" "$WD/a" --expect x
chk "watch: unknown arg"               2 "unknown arg"          bash "$AW" "$WD/a" --bogus
# T-5 / T-7: the expected artifact is already there — exit 0 without waiting out the deadline
printf 'lead\n' > "$WD/present.md"
S=$(date +%s); chk "watch: artifact present → 0" 0 "WATCH-OK" bash "$AW" "$WD/p" --expect "$WD/present.md" --after-sec 30 --poll-sec 1
[ $(( $(date +%s) - S )) -lt 10 ] && printf '  ok    %-42s\n' "watch: returned at once, did not wait" || { printf '  FAIL  watch: waited out the deadline\n'; FAIL=1; }
[ "$(cat "$WD/p.exit" 2>/dev/null)" = "0" ] && printf '  ok    %-42s\n' "watch: .exit sidecar records 0" || { printf '  FAIL  watch: .exit sidecar\n'; FAIL=1; }
# The lead SEALS its file (chmod 000) the moment it writes it, so the sealed file is the normal
# success case: -s stats, it does not open, and the watcher must still see it.
printf 'lead\nSTATUS: PHASE 1 COMPLETE\n' > "$WD/sealed.md"; chmod 000 "$WD/sealed.md"
chk "watch: sealed (mode 000) artifact → 0"  0 "WATCH-OK"      bash "$AW" "$WD/sl" --expect "$WD/sealed.md" --after-sec 20 --poll-sec 1
chmod 600 "$WD/sealed.md"
# and the watcher's own sidecars must not collide with the glob pre-codex uses to refuse a
# resumed run while any lead file is readable
bash "$AW" "$WD/01-lead.advisory" --expect "$WD/present.md" --after-sec 5 --poll-sec 1 >/dev/null 2>&1
set -- "$WD"/01-lead*.md
[ ! -e "$1" ] && printf '  ok    %-42s\n' "watch: sidecars miss the 01-lead*.md glob" || { printf '  FAIL  watch: sidecar matches the gate glob: %s\n' "$1"; FAIL=1; }
# an empty artifact is not an artifact
: > "$WD/empty.md"
chk "watch: artifact empty → deadline"  3 "WATCH-OVERDUE"       bash "$AW" "$WD/e" --expect "$WD/empty.md" --after-sec 2 --poll-sec 1
# T-3 / T-4: absent artifact, deadline passes
chk "watch: artifact absent → 3"        3 "WATCH-OVERDUE"       bash "$AW" "$WD/d" --expect "$WD/never.md" --after-sec 2 --poll-sec 1
grep -q "expect=" "$WD/d.progress" 2>/dev/null && printf '  ok    %-42s\n' "watch: .progress sidecar written" || { printf '  FAIL  watch: no .progress sidecar\n'; FAIL=1; }
# T-10: the paired-watcher lifecycle — one process, one verdict, so two processes are used.
# The advisory must fire while the deadline watcher is STILL ALIVE; that is the sequence a
# single three-exit watcher provably cannot produce (round-2 blocker X-10).
rm -f "$WD/paired.md"
bash "$AW" "$WD/adv" --expect "$WD/paired.md" --after-sec 2  --poll-sec 1 >/dev/null 2>&1 & ADV=$!
bash "$AW" "$WD/dln" --expect "$WD/paired.md" --after-sec 12 --poll-sec 1 >/dev/null 2>&1 & DLN=$!
wait "$ADV"; ADVRC=$?
if kill -0 "$DLN" 2>/dev/null; then ALIVE=yes; else ALIVE=no; fi
[ "$ADVRC" = 3 ] && [ "$ALIVE" = yes ] && printf '  ok    %-42s\n' "watch: advisory fired, deadline still alive" || { printf '  FAIL  watch: paired lifecycle advisory=%s deadline_alive=%s\n' "$ADVRC" "$ALIVE"; FAIL=1; }
# the artifact appears between the two thresholds → the deadline watcher exits 0, never 3
printf 'lead\n' > "$WD/paired.md"
wait "$DLN"; DLNRC=$?
[ "$DLNRC" = 0 ] && printf '  ok    %-42s\n' "watch: artifact between thresholds → 0" || { printf '  FAIL  watch: deadline watcher exit=%s (want 0)\n' "$DLNRC"; FAIL=1; }
# T-11: the stage sentinel — a stage with no watchable file still has a success condition, so a
# watcher can never outlive the work it watches (round-3 X-11)
rm -f "$WD/.stage-verify.done"
bash "$AW" "$WD/s1" --expect "$WD/.stage-verify.done" --after-sec 12 --poll-sec 1 >/dev/null 2>&1 & S1=$!
bash "$AW" "$WD/s2" --expect "$WD/.stage-verify.done" --after-sec 12 --poll-sec 1 >/dev/null 2>&1 & S2=$!
printf 'done\n' > "$WD/.stage-verify.done"
wait "$S1"; R1=$?; wait "$S2"; R2=$?
[ "$R1" = 0 ] && [ "$R2" = 0 ] && printf '  ok    %-42s\n' "watch: stage sentinel ends both watchers" || { printf '  FAIL  watch: sentinel exits %s/%s (want 0/0)\n' "$R1" "$R2"; FAIL=1; }


echo
[ $FAIL -eq 0 ] && { echo "ALL ARGUMENT AND BUILDER TESTS PASSED"; exit 0; } || { echo "TESTS FAILED"; exit 1; }
