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
chk "deep-plan copy behaves identically" 4 "requires a value"      bash "$P" "$PFX" --max-min
rm -f "$PFX.exit"; bash "$R" "$PFX" --bogus >/dev/null 2>&1
[ "$(cat "$PFX.exit" 2>/dev/null)" = "4" ] && printf '  ok    %-42s\n' ".exit sidecar records 4" || { printf '  FAIL  %-42s\n' ".exit sidecar"; FAIL=1; }

echo "builder: every usage error exits 2"
for o in --repo --base-ref --base --head --head-ref --intent-file --conventions-file --out; do chk "$o with no value" 2 "requires a value" bash "$B" $o; done
chk "missing required option"  2 "is required"     bash "$B" --repo .
chk "unknown arg"              2 "unknown arg"     bash "$B" --nope x
chk "--repo not a directory"   2 "not a directory" bash "$B" --repo "$TMP/absent" --base-ref H --base H --head WORKTREE --intent-file "$PROMPT" --conventions-file "$PROMPT" --out "$TMP/o.md"
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
G2="$TMP/repo2"; mkdir -p "$G2"; ( cd "$G2" && git init -q && git config user.email t@t && git config user.name t && printf 'line one\nline two\nline three\n' > f.txt && git add f.txt && git commit -qm init ) || { echo "  FAIL  fixture2"; FAIL=1; }
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

echo "deep-plan: check-citations.py string-matches quotes against git show"
C="$DS/check-citations.py"; L="$DS/lint-claims.py"
chk "citations: no file"               2 "usage"                python3 "$C"
chk "citations: --repo with no value"  2 "requires a value"     python3 "$C" --repo
printf '| F-1 | [FACT] | second line exists | `f.txt:2-2@%s` "line two" |\n' "$SHA2" > "$TMP/ev-ok.md"
chk "citations: correct quote passes"  0 "OK"                   python3 "$C" --repo "$G2" "$TMP/ev-ok.md"
printf '| F-1 | [FACT] | wrong | `f.txt:2-2@%s` "line nine" |\n' "$SHA2" > "$TMP/ev-bad.md"
chk "citations: wrong quote fails"     1 "quote not found"      python3 "$C" --repo "$G2" "$TMP/ev-bad.md"
printf '| F-1 | [FACT] | oob | `f.txt:9-12@%s` "line two" |\n' "$SHA2" > "$TMP/ev-oob.md"
chk "citations: out-of-range fails"    1 "out of range"         python3 "$C" --repo "$G2" "$TMP/ev-oob.md"
printf '| F-1 | [FACT] | nosha | `f.txt:2-2@0123456789abcdef` "line two" |\n' > "$TMP/ev-nosha.md"
chk "citations: unknown sha fails"     1 "not found at"         python3 "$C" --repo "$G2" "$TMP/ev-nosha.md"
printf '| F-1 | [FACT] | noquote | `f.txt:2-2@%s` |\n' "$SHA2" > "$TMP/ev-noq.md"
chk "citations: missing quote fails"   1 "no verbatim"          python3 "$C" --repo "$G2" "$TMP/ev-noq.md"
printf 'no citations here\n' > "$TMP/ev-empty.md"
chk "citations: zero citations fails"  1 "zero citations"       python3 "$C" --repo "$G2" "$TMP/ev-empty.md"
chk "citations: --allow-empty"         0 "OK"                   python3 "$C" --repo "$G2" --allow-empty "$TMP/ev-empty.md"
cp "$TMP/ev-ok.md" "$A/01-evidence.md"
chk "citations: repo taken from meta.json" 0 "OK"               python3 "$C" "$A/01-evidence.md"
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
chk "lint: decision without id"        1 "cites no evidence id" python3 "$L" "$TMP/l-dec.md"
printf 'Decision: use the cache (F-9)\n' > "$TMP/l-dang.md"
chk "lint: dangling id"                1 "never defined"        python3 "$L" "$TMP/l-dang.md"
printf '```\nthis should be ignored inside a fence\n```\n' > "$TMP/l-fence.md"
chk "lint: fenced code skipped"        0 "OK"                   python3 "$L" "$TMP/l-fence.md"
mkdir -p "$A/inputs2"; cp "$TMP/l-hedge.md" "$A/inputs/issue-1.md"
chk "lint: inputs/ dir skipped"        0 "OK"                   python3 "$L" "$A"

echo "deep-plan: validate-verdict.py enforces the objection contract"
V="$DS/validate-verdict.py"
chk "verdict: missing args"            2 "usage"                python3 "$V" --extract "$TMP/absent"
mkobj() { cat > "$1" <<JSON
{"role":"codex","round":$2,"verdict":"$3","summary":"s",
 "root_causes":[{"id":"RC-1","explains":["request-1"],"cause_class":"absent_constraint","statement":"no limiter","evidence":["f.txt:2-2@$SHA2 \\"line two\\""]}],
 "designs":[{"id":"DS-1","one_sentence":"a","addresses":["RC-1"],"files":["f.txt"],"blast_radius":"1","reversibility":"yes","risks":"none","preferred":true},
            {"id":"DS-2","one_sentence":"b","addresses":["RC-1"],"files":["f.txt"],"blast_radius":"2","reversibility":"yes","risks":"none","preferred":false}],
 "single_pr_recommendation":{"verdict":"ONE_PR","because":"one cause"},
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

echo
[ $FAIL -eq 0 ] && { echo "ALL ARGUMENT AND BUILDER TESTS PASSED"; exit 0; } || { echo "TESTS FAILED"; exit 1; }
