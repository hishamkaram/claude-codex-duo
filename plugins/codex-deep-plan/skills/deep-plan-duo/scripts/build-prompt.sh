#!/bin/bash
# build-prompt.sh — fill one round's Codex prompt deterministically from the run's own files.
#
#   build-prompt.sh --art <dir> --round <n> [--budget <n>] [--out <file>]
#
# Round 0 (blind): templates/codex-r0.md from meta.json, inputs/*.md, the in-scope paths in
#   00-scope.md and templates/verdict-schema.md. The brief is leak-checked BEFORE the verbatim
#   inputs and the repository path are inserted: a hit means wording that would tell Codex
#   another analysis exists. Inputs and the repo path are the user's own text and are exempt.
# Round n>=1: templates/codex-round.md from the files that round is allowed to see
#   (r1: 01-evidence, 02-root-cause, 03-designs, debate/divergence; r>=2: 01-evidence,
#   04-plan-draft, 05-disagreements) plus debate/r<n-1>-codex.stdout verbatim.
# Writes <art>/debate/r<n>-prompt.md unless --out. Exit 0 ok · 2 usage · 3 leak in the blind brief.
set -euo pipefail
SK="$(cd "$(dirname "$0")/.." && pwd)"
USAGE='usage: build-prompt.sh --art <dir> --round <n> [--budget <n>] [--out <file>]'
die2() { echo "build-prompt.sh: $1" >&2; echo "$USAGE" >&2; exit 2; }
need() { [ $# -ge 2 ] || die2 "$1 requires a value"; case "$2" in -*) die2 "$1 requires a value (got option $2)";; esac; }
ART=""; ROUND=""; BUDGET=""; OUT=""
while [ $# -gt 0 ]; do case "$1" in
  --art) need "$@"; ART="$2";; --round) need "$@"; ROUND="$2";;
  --budget) need "$@"; BUDGET="$2";; --out) need "$@"; OUT="$2";;
  *) die2 "unknown arg $1";; esac; shift 2; done
[ -n "$ART" ] || die2 "--art is required"
[ -n "$ROUND" ] || die2 "--round is required"
[ -d "$ART" ] || die2 "--art is not a directory: $ART"
[ -r "$ART/meta.json" ] || die2 "no meta.json in $ART (run init-plan.sh first)"
for v in ROUND BUDGET; do
  eval "val=\${$v:-}"; [ -n "$val" ] || continue
  case "$val" in *[!0-9]*) die2 "--$(echo "$v" | tr 'A-Z' 'a-z') requires a whole number (got '$val')";; esac
  val=$(printf '%s' "$val" | sed 's/^0*//'); [ -n "$val" ] || val=0; [ "${#val}" -le 3 ] || die2 "--$(echo "$v" | tr 'A-Z' 'a-z') is too large"
  eval "$v=\$val"
done
[ "$ROUND" -le 3 ] || die2 "--round must be 0..3"
CAP=$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1])).get("rounds") or 2))' "$ART/meta.json" 2>/dev/null || echo 2)
[ "$ROUND" -le "$CAP" ] || die2 "--round $ROUND exceeds the run's round cap ($CAP in meta.json); the cap is never extended"
[ -n "$OUT" ] || OUT="$ART/debate/r$ROUND-prompt.md"
mkdir -p "$(dirname "$OUT")"
python3 - "$SK" "$ART" "$ROUND" "${BUDGET:-}" "$OUT" <<'PY'
import json, os, re, subprocess, sys
sk, art, rnd, budget, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5]
meta = json.load(open(os.path.join(art, "meta.json"), encoding="utf-8"))
sha = meta["base_sha"]

def die(msg, code=2):
    print(f"build-prompt.sh: {msg}", file=sys.stderr); sys.exit(code)

def read(rel, required=True):
    p = os.path.join(art, rel)
    if not os.path.isfile(p):
        if required: die(f"required file missing for round {rnd}: {rel}")
        return None
    return open(p, encoding="utf-8", errors="replace").read()

def fill(t, rep):
    for k, v in rep.items():
        assert k in t, f"placeholder missing from template: {k}"
        t = t.replace(k, v)
    left = re.findall(r"\{\{[^}]+\}\}", t)
    assert not left, f"unfilled placeholders: {left}"
    return t

def inputs_block():
    parts = []
    for r in meta.get("inputs") or []:
        body = read(r["file"]).rstrip()
        parts.append(f"<input kind=\"{r['kind']}\" id=\"{r['id']}\">\n{body}\n</input>")
    if not parts: die("meta.json lists no inputs")
    return "\n\n".join(parts)

schema = open(os.path.join(sk, "templates", "verdict-schema.md"), encoding="utf-8").read().strip()
LEAK = re.compile(r"claude(?!\.md|/)|debate|artifact|second[- ](opinion|model|reviewer|analysis)|\bauthor(?!it)|/tmp/deep-plan-duo|"
                  r"01-evidence|02-root-cause|03-designs|04-plan-draft|05-disagreements|divergence\.md|blind", re.I)

if rnd == 0:
    scope = read("00-scope.md", required=False) or ""
    paths = []
    take = False
    for line in scope.splitlines():
        if line.startswith("## "):
            take = line.lower().startswith("## in-scope paths")
        elif take and line.strip().startswith("- "):
            paths.append(line.strip()[2:].strip())
    # A bullet that is a real repository path is exempt from the leak check: this repo's own
    # paths contain "debate" and ".claude" (live-run friction 2026-09-03). Anything else on the
    # bullet (a comment after the path) is checked.
    def is_repo_path(p):
        if subprocess.run(["git", "-C", meta["repo"], "cat-file", "-e", f"{sha}:{p}"], capture_output=True).returncode == 0:
            return True
        return os.path.exists(os.path.join(meta["repo"], p))
    marks = {}
    bullets = []
    for i, p in enumerate(paths):
        tok = p.split()[0].rstrip("/") if p.split() else p
        if tok and is_repo_path(tok):
            marks[f"@@PATH{i}@@"] = tok
            bullets.append(f"- @@PATH{i}@@" + p[len(tok):] if p.startswith(tok) else f"- {p}")
        else:
            bullets.append(f"- {p}")
    paths_txt = "\n".join(bullets) if paths else "no restriction given; start from the inputs and the repository layout"
    t = open(os.path.join(sk, "templates", "codex-r0.md"), encoding="utf-8").read()
    # The inputs and the repository path are the user's own text: substituted after the leak check.
    INPUT_MARK, REPO_MARK = "@@INPUTS@@", "@@REPO@@"
    t = fill(t, {"{{repo path}}": REPO_MARK, "{{base SHA}}": sha, "{{base SHA short}}": sha[:7],
                 "{{in-scope paths}}": paths_txt, "{{tool budget}}": budget or "12",
                 "{{inputs}}": INPUT_MARK, "{{verdict schema}}": schema})
    hits = sorted({m.group(0).lower() for m in LEAK.finditer(t)})
    if hits:
        print("build-prompt.sh: LEAK in the blind brief (wording that reveals another analysis exists): " + ", ".join(hits), file=sys.stderr)
        print("  fix 00-scope.md's in-scope paths section or the template; inputs and existing repository paths are not checked", file=sys.stderr)
        sys.exit(3)
    t = t.replace(INPUT_MARK, inputs_block()).replace(REPO_MARK, meta["repo"])
    for k, v in marks.items():
        t = t.replace(k, v)
else:
    cap = int(meta.get("rounds") or 2)
    prev = read(f"debate/r{rnd-1}-codex.stdout")
    mats = [("01-evidence.md", read("01-evidence.md"))]
    if rnd == 1:
        mats += [("02-root-cause.md", read("02-root-cause.md")), ("03-designs.md", read("03-designs.md")),
                 ("debate/divergence.md", read("debate/divergence.md"))]
    else:
        mats += [("04-plan-draft.md", read("04-plan-draft.md")), ("05-disagreements.md", read("05-disagreements.md"))]
    materials = "\n\n".join(f"<file name=\"{n}\">\n{c.rstrip()}\n</file>" for n, c in mats)
    t = open(os.path.join(sk, "templates", "codex-round.md"), encoding="utf-8").read()
    t = fill(t, {"{{k}}": str(rnd), "{{N}}": str(cap), "{{repo path}}": meta["repo"], "{{base SHA}}": sha,
                 "{{base SHA short}}": sha[:7], "{{inputs}}": inputs_block(), "{{materials}}": materials,
                 "{{previous reply}}": "```text\n" + prev.rstrip() + "\n```", "{{tool budget}}": budget or "8",
                 "{{verdict schema}}": schema})
open(out, "w", encoding="utf-8").write(t)
size = len(t.encode("utf-8"))
print(f"prompt written: {out} ({size} bytes) round={rnd} base={sha[:12]}")
if size > 400_000:
    print(f"WARNING: prompt is {size} bytes (>400 KB); trim materials or split the run", file=sys.stderr)
PY
