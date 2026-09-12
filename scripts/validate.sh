#!/bin/bash
# validate.sh — dependency-free packaging checks for claude-codex-duo.
# Catches the defect class that shipped in 1.0.0 and 1.0.1: frontmatter that is
# not valid strict YAML, manifest drift, unresolvable ${CLAUDE_PLUGIN_ROOT}
# paths, non-executable scripts, and shell syntax errors.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
note() { printf '  %-7s %s\n' "$1" "$2"; [ "$1" = "FAIL" ] && FAIL=1; return 0; }

echo "1. Markdown frontmatter is valid strict YAML"
while IFS= read -r f; do
  head -1 "$f" | grep -q -- '---' || continue
  msg=$(awk 'NR==1&&/^---/{i=1;next} i&&/^---/{exit} i' "$f" | python3 -c '
import sys,re
bad=[]
for n,l in enumerate(sys.stdin.read().splitlines(),2):
    if not l.strip() or l.startswith(("#"," ","\t","-")): continue
    m=re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", l)
    if not m: bad.append(f"line {n}: not a key: value mapping"); continue
    v=m.group(2)
    if not v: continue
    if v[0] in "\"'"'"'":
        q=v[0]
        if not (len(v)>1 and v.endswith(q)): bad.append(f"line {n}: value opens with {q} but does not close it (quoted scalar must quote the WHOLE value)")
    else:
        if ": " in v or v.endswith(":"): bad.append(f"line {n}: unquoted value contains \": \" — YAML reads it as a nested mapping; quote the whole value or use \" — \"")
        if v.lstrip()[:1] in "[{&*!|>%@`": bad.append(f"line {n}: unquoted value starts with a YAML indicator character")
print("\n".join(bad))')
  [ -n "$msg" ] && note FAIL "$f"$'\n'"$(printf '%s' "$msg" | sed 's/^/          /')" || note ok "$f"
done < <(find plugins -name '*.md' | sort)

echo "2. Manifests parse and agree"
python3 - <<'PY' || FAIL=1
import json,os,sys
m=json.load(open('.claude-plugin/marketplace.json')); ok=True
for p in m['plugins']:
    src=p['source']
    if not os.path.isdir(src): print(f"  FAIL    marketplace source missing: {src}"); ok=False; continue
    pj=json.load(open(os.path.join(src,'.claude-plugin/plugin.json')))
    for k in ('name','version'):
        if pj[k]!=p[k]: print(f"  FAIL    {src}: plugin.json {k}={pj[k]!r} != marketplace {k}={p[k]!r}"); ok=False
    if ok: print(f"  ok      {p['name']} {p['version']}")
sys.exit(0 if ok else 1)
PY

echo "3. \${CLAUDE_PLUGIN_ROOT} references resolve inside their own plugin"
for p in plugins/*/; do
  p="${p%/}"
  while IFS= read -r ref; do
    rel="${ref#\$\{CLAUDE_PLUGIN_ROOT\}}"
    [ -e "$p$rel" ] && note ok "$p$rel" || note FAIL "$p$rel (referenced but absent)"
  done < <(grep -rho '\${CLAUDE_PLUGIN_ROOT}[A-Za-z0-9_./-]*' "$p" | sort -u)
done

echo "4. Scripts are executable and syntactically valid"
while IFS= read -r s; do
  [ -x "$s" ] || note FAIL "$s is not executable"
  bash -n "$s" 2>/dev/null && note ok "$s" || note FAIL "$s has a bash syntax error"
done < <(find plugins scripts -name '*.sh' | sort)
while IFS= read -r s; do
  [ -x "$s" ] || note FAIL "$s is not executable"
  # ast.parse, not py_compile: the validator must not write __pycache__ into the tree it validates.
  python3 -c 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1])' "$s" 2>/dev/null && note ok "$s" || note FAIL "$s has a python syntax error"
done < <(find plugins -name '*.py' | sort)

echo "4b. Every plugin ships the same monitored runner"
REF=plugins/codex-pr-review/scripts/codex-run.sh
for r in plugins/*/scripts/codex-run.sh; do
  [ "$r" = "$REF" ] && continue
  cmp -s "$REF" "$r" && note ok "$r identical to $REF" || note FAIL "$r differs from $REF (the runner is shared by copy; keep the copies byte-identical)"
done

REF=plugins/codex-pr-review/scripts/ccr-job.py
for r in plugins/*/scripts/ccr-job.py; do
  cmp -s "$REF" "$r" && note ok "$r shared CCR protocol" || note FAIL "$r differs from $REF"
done

echo "4b1. The runner and the phase gate agree on the CCR launch protocol"
# The gate reads <prefix>.ccr-prelaunch as proof that a launch was interrupted before it submitted
# any workload, and releases the claim on that proof alone. That is only sound while both sides
# mean the same thing by the protocol number: a gate that accepted a marker written under an
# ordering it does not understand would free a claim whose job may be alive.
RUN_PROTO=$(sed -n 's/^CCR_PROTOCOL=\([0-9][0-9]*\).*/\1/p' plugins/codex-pr-review/scripts/codex-run.sh | head -1)
GATE_PROTO=$(sed -n 's/^CCR_PROTOCOL=\([0-9][0-9]*\).*/\1/p' plugins/codex-pr-review/skills/two-model-pr-review/scripts/phase-gate.sh | head -1)
if [ -n "$RUN_PROTO" ] && [ "$RUN_PROTO" = "$GATE_PROTO" ]; then
  note ok "CCR_PROTOCOL=$RUN_PROTO in both codex-run.sh and phase-gate.sh"
else
  note FAIL "CCR_PROTOCOL differs or is missing (codex-run.sh='${RUN_PROTO:-none}', phase-gate.sh='${GATE_PROTO:-none}'): the pre-submission release proof is only sound while both agree"
fi

echo "4b2. review-workflow.js constants are generated from review_common.py (gen-workflow-constants.py --check)"
python3 plugins/codex-pr-review/skills/two-model-pr-review/scripts/gen-workflow-constants.py --check >/dev/null 2>&1 && note ok "workflow constants match review_common.py" || note FAIL "review-workflow.js constants differ from review_common.py: run scripts/gen-workflow-constants.py --write"

echo "4c. Workflow scripts compile as the Workflow tool evaluates them (scripts/js-check.sh)"
if command -v node >/dev/null 2>&1; then
  while IFS= read -r s; do
    bash scripts/js-check.sh "$s" 2>/dev/null && note ok "$s" || note FAIL "$s has a JavaScript syntax error (js-check.sh)"
  done < <(find plugins -name '*.js' | sort)
else
  note FAIL "node is not installed; workflow scripts cannot be checked"
fi

echo "5. No absolute or home-relative paths leak into shipped files"
if grep -rn --exclude-dir=__pycache__ --exclude='*.pyc' '~/\.claude/skills/\|~/\.claude/scripts/\|/Users/' plugins >/dev/null 2>&1; then
  grep -rn --exclude-dir=__pycache__ --exclude='*.pyc' '~/\.claude/skills/\|~/\.claude/scripts/\|/Users/' plugins | sed 's/^/  FAIL    /'; FAIL=1
else note ok "no machine-specific paths"; fi

echo "6. Every runner exit code is documented in every skill and the README"
CODES=$(grep -oE 'RC=[0-9]|exit [0-9]' plugins/codex-pr-review/scripts/codex-run.sh | grep -oE '[0-9]' | sort -u)
for c in $CODES; do
  miss=""
  grep -q "^| $c |" plugins/codex-pr-review/skills/two-model-pr-review/references/codex-protocol.md || miss="$miss codex-protocol.md"
  grep -q "^| $c |" plugins/codex-debate/skills/codex-debate/references/codex-invocation.md || miss="$miss codex-invocation.md"
  grep -q "^| $c |" plugins/codex-deep-plan/skills/deep-plan-duo/references/codex-invocation.md || miss="$miss deep-plan-duo/codex-invocation.md"
  grep -q "\`$c\`" README.md || miss="$miss README.md"
  [ -z "$miss" ] && note ok "exit $c documented" || note FAIL "exit $c undocumented in:$miss"
done

echo "7. Command-line handling regression tests (executed)"
if bash scripts/test-args.sh > /tmp/ccd-test-args.$$ 2>&1; then
  sed 's/^/  /' /tmp/ccd-test-args.$$ | grep -E 'ok|PASSED' | tail -3
else
  sed 's/^/  /' /tmp/ccd-test-args.$$; FAIL=1
fi
rm -f /tmp/ccd-test-args.$$

echo "8. Every context that composes commands carries the path-form rule"
CLAUSE='address every path absolutely; never `cd` inside a tool command'
for f in \
  plugins/codex-pr-review/skills/two-model-pr-review/SKILL.md \
  plugins/codex-pr-review/agents/finding-verifier.md \
  plugins/codex-deep-plan/skills/deep-plan-duo/SKILL.md \
  plugins/codex-debate/skills/codex-debate/SKILL.md \
  plugins/codex-pr-review/agents/lead-reviewer.md \
  plugins/codex-deep-plan/agents/fact-checker.md; do
  if [ ! -f "$f" ]; then note FAIL "$f missing (the rule must live in every command-composing context)"
  elif tr '\n' ' ' < "$f" | tr -s ' \t' ' ' | grep -Fq "$CLAUSE"; then note ok "$f"
  else note FAIL "$f does not carry the path-form clause: $CLAUSE"; fi
done

echo "9. No shipped instruction publishes a directory change in a command"
# The rule in check 8 is worthless if a reference file demonstrates the shape it forbids
# (review objection X-1). The constraint text itself writes `cd` in backticks, never `cd <operand>`,
# so it does not match. Scripts are exempt: the harness parses only top-level tool commands.
HITS=$(grep -rnE '(^|[ (;&`])cd[[:space:]]+[^[:space:]]' plugins --include='*.md' 2>/dev/null)
if [ -n "$HITS" ]; then
  printf '%s\n' "$HITS" | while IFS= read -r h; do note FAIL "publishes a directory change: $h"; done
  FAIL=1
else note ok "no shipped instruction publishes a directory change"; fi

echo "10. Every file that gives an agent a search instruction names the Grep/Glob tools"
# Non-load-bearing regression coverage: the wording edits are what remove the cause (the agent
# contracts are authoritative text, not generated). This check asserts the instrument rule is
# PRESENT — it must not forbid the word `grep`, because `git grep` at a pinned SHA is the
# sanctioned fallback for when the checkout is not the review head, and check 8's path-form
# clause legitimately names the shell search commands it constrains.
for f in \
  plugins/codex-pr-review/agents/lead-reviewer.md \
  plugins/codex-pr-review/agents/finding-verifier.md \
  plugins/codex-deep-plan/agents/fact-checker.md \
  plugins/codex-pr-review/skills/two-model-pr-review/references/review-rubric.md; do
  if [ ! -f "$f" ]; then note FAIL "$f missing (it delivers a search instruction to an agent)"; continue; fi
  flat=$(tr '\n' ' ' < "$f" | tr -s ' \t' ' ')
  miss=""
  printf '%s' "$flat" | grep -Fq "Grep tool" || miss="$miss no-Grep-tool"
  printf '%s' "$flat" | grep -Fq "Glob tool" || miss="$miss no-Glob-tool"
  # the rule has to say WHY, so it survives a reader who disagrees with it
  printf '%s' "$flat" | grep -Eq "never (wait|block)|cannot (wait|block)|without waiting" || miss="$miss no-rationale"
  [ -z "$miss" ] && note ok "$f" || note FAIL "$f lacks the instrument rule:$miss"
done

echo "11. Every recorded plugin install resolves to a directory whose manifest matches"
# A release reaches the repository and the user's sessions by different routes. The harness records
# an installed version and an install path; if that path does not exist, sessions keep running
# whatever cache directory is still there, and `claude plugin update` reports "already at the
# latest version" because the version record was already bumped. Observed 2026-09-04 with all three
# of this marketplace's plugins recorded at directories that did not exist.
# It inspects the developer's machine, not the repository, so "not installed here" is not a failure.
python3 - <<'PLUGINCHECK' || FAIL=1
import json, os, sys
reg = os.path.expanduser("~/.claude/plugins/installed_plugins.json")
names = {p["name"] for p in json.load(open(".claude-plugin/marketplace.json"))["plugins"]}
if not os.path.exists(reg):
    print("  ok      no installed-plugin record on this machine; nothing to verify"); sys.exit(0)
try:
    plugins = json.load(open(reg)).get("plugins", {})
except Exception as e:
    print(f"  FAIL    installed_plugins.json is unreadable: {e}"); sys.exit(1)
seen = ok = 0; bad = []
for key, entries in plugins.items():
    if key.split("@", 1)[0] not in names: continue
    for e in entries:
        seen += 1
        path, want = e.get("installPath", ""), e.get("version", "")
        man = os.path.join(path, ".claude-plugin", "plugin.json")
        if not os.path.isdir(path):
            bad.append(f"{key.split('@')[0]} {want}: installPath does not exist ({path})")
        elif not os.path.exists(man):
            bad.append(f"{key.split('@')[0]} {want}: no plugin.json under {path}")
        else:
            got = json.load(open(man)).get("version")
            if got != want: bad.append(f"{key.split('@')[0]}: recorded {want}, directory holds {got}")
            else: ok += 1
if not seen:
    print("  ok      none of this marketplace's plugins are installed here")
elif bad:
    for b in bad: print(f"  FAIL    {b}")
    print('  FAIL    a recorded version does not match what is on disk, so "claude plugin update"')
    print('          reports "already at the latest version". Recover with "claude plugin uninstall"')
    print('          then "claude plugin install <name>@<marketplace> --scope user".')
    sys.exit(1)
else:
    print(f"  ok      {ok}/{seen} recorded install(s) resolve to a matching directory")
PLUGINCHECK

echo "12. No ccr alias literal ships in a plugin (aliases are machine-local; only the placeholder <alias> may appear)"
# `ccr:` followed by an alias-like character is a literal; `ccr:<alias>`, `ccr:$var`, `ccr:?*` (case patterns) and prose are not.
HITS=$(grep -rnE --include='*.md' --include='*.sh' --include='*.py' --include='*.js' --include='*.json' 'ccr:[A-Za-z0-9]' plugins 2>/dev/null)
if [ -n "$HITS" ]; then printf '%s\n' "$HITS" | while IFS= read -r h; do note FAIL "alias literal: $h"; done; FAIL=1
else note ok "no alias literal under plugins/"; fi

echo "13. The read-only runner never carries a write mode; the implementer is the only write-capable launcher"
for r in plugins/*/scripts/codex-run.sh; do
  grep -q 'acceptEdits' "$r" && note FAIL "$r mentions acceptEdits (write mode belongs to implement-run.sh only)" || note ok "$r has no write mode"
  grep -q -- '--write is refused' "$r" || note FAIL "$r lost the --write refusal"
  grep -q -- '--permission-mode plan' "$r" || note FAIL "$r lost --permission-mode plan on the ccr launch line"
done
IMPL=plugins/codex-deep-plan/scripts/implement-run.sh
if [ -f "$IMPL" ]; then
  grep -q -- '--permission-mode acceptEdits' "$IMPL" && note ok "$IMPL is the write-capable launcher" || note FAIL "$IMPL does not launch with --permission-mode acceptEdits"
  grep -q 'write mode is ccr-only' "$IMPL" && note ok "$IMPL refuses every backend but ccr" || note FAIL "$IMPL must refuse --via codex (write mode is ccr-only)"
fi

echo "14. Every command's argument hint lists --via, and every command body forwards \$ARGUMENTS verbatim"
# A body that expands only $1..$N drops every argument it does not name — the advertised --via never
# reached the skill until the two-model review of the ccr backend caught it (F-08, F-09).
for f in plugins/*/commands/*.md; do
  grep -q -- '--via' "$f" && note ok "$f" || note FAIL "$f argument hint does not list --via"
  grep -q '\$ARGUMENTS' "$f" && note ok "$f forwards \$ARGUMENTS" || note FAIL "$f does not forward \$ARGUMENTS (positional \$N expansions drop the options they do not name)"
done

echo "15. The debate protocol carries both the one-opponent and the N-participant grammars"
PROTO=plugins/codex-debate/skills/codex-debate/references/protocol.md
for needle in 'X-nn' 'CONCEDED-BY-CODEX' 'X<k>-nn' 'CONCEDED-BY-P<k>' 'dissent score' 'UNRESOLVED (global budget)'; do
  grep -Fq -- "$needle" "$PROTO" && note ok "protocol.md: $needle" || note FAIL "protocol.md lacks '$needle'"
done
grep -Fq 'dissent score' plugins/codex-debate/skills/codex-debate/templates/DEBATE.md && note ok "DEBATE.md carries the aggregation rule" || note FAIL "DEBATE.md lacks the aggregation rule (dissent score)"

echo
[ $FAIL -eq 0 ] && { echo "ALL CHECKS PASSED"; exit 0; } || { echo "VALIDATION FAILED"; exit 1; }
