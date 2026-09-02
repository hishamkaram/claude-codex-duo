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
FAIL=0
chk() {
  local n="$1" e="$2" sub="$3"; shift 3
  local out code; out=$("$@" 2>&1); code=$?
  if [ "$code" = "$e" ] && printf '%s' "$out" | grep -q -- "$sub"; then
    printf '  ok    %-42s exit=%s\n' "$n" "$code"
  else
    printf '  FAIL  %-42s exit=%s (want %s) out=%s\n' "$n" "$code" "$e" "$(printf '%s' "$out" | head -1)"; FAIL=1
  fi
}
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
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
rm -f "$PFX.exit"; bash "$R" "$PFX" --bogus >/dev/null 2>&1
[ "$(cat "$PFX.exit" 2>/dev/null)" = "4" ] && printf '  ok    %-42s\n' ".exit sidecar records 4" || { printf '  FAIL  %-42s\n' ".exit sidecar"; FAIL=1; }

echo "builder: every usage error exits 2"
for o in --repo --base-ref --base --head --head-ref --intent-file --conventions-file --out; do chk "$o with no value" 2 "requires a value" bash "$B" $o; done
chk "missing required option"  2 "is required"     bash "$B" --repo .
chk "unknown arg"              2 "unknown arg"     bash "$B" --nope x
chk "--repo not a directory"   2 "not a directory" bash "$B" --repo "$TMP/absent" --base-ref H --base H --head WORKTREE --intent-file "$PROMPT" --conventions-file "$PROMPT" --out "$TMP/o.md"
chk "--intent-file unreadable" 2 "not readable"    bash "$B" --repo . --base-ref H --base H --head WORKTREE --intent-file "$TMP/absent" --conventions-file "$PROMPT" --out "$TMP/o.md"
chk "--out inside the repo"    2 "outside the repository" bash "$B" --repo . --base-ref HEAD --base HEAD --head WORKTREE --intent-file "$PROMPT" --conventions-file "$PROMPT" --out ./brief.md

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

echo
[ $FAIL -eq 0 ] && { echo "ALL ARGUMENT AND BUILDER TESTS PASSED"; exit 0; } || { echo "TESTS FAILED"; exit 1; }
