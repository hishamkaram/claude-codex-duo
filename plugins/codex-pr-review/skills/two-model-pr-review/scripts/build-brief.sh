#!/bin/bash
# build-brief.sh — fill templates/codex-brief.md deterministically.
#   Range mode:    build-brief.sh --repo <path> --base-ref <name> --base <sha> --head-ref <name> --head <sha> \
#                                 --intent-file <f> --conventions-file <f> --out <file>
#   Worktree mode: build-brief.sh --repo <path> --base-ref <name> --base <sha> --head WORKTREE \
#                                 --intent-file <f> --conventions-file <f> --out <file>
#     Captures the aggregate working tree (staged + unstaged + deleted + non-ignored untracked) as a TREE
#     object via an artifact-local scratch index, never touching the repo's index, refs, stash or files.
#     Writes <out>.tree (the tree SHA) and <out>.baseline (NUL-separated status). Exit 3 = nothing to review.
set -euo pipefail
SK="$(cd "$(dirname "$0")/.." && pwd)"
USAGE='usage: build-brief.sh --repo <path> --base-ref <name> --base <sha> (--head-ref <name> --head <sha> | --head WORKTREE) \\
                       --intent-file <file> --conventions-file <file> --out <file>'
# Every usage error exits 2, as documented in references/codex-protocol.md.
die2() { echo "build-brief.sh: $1" >&2; echo "$USAGE" >&2; exit 2; }
need() { [ $# -ge 2 ] || die2 "$1 requires a value"; case "$2" in -*) die2 "$1 requires a value (got option $2)";; esac; }
while [ $# -gt 0 ]; do case "$1" in
  --repo) need "$@"; REPO="$2";; --base-ref) need "$@"; BREF="$2";; --base) need "$@"; BSHA="$2";;
  --head-ref) need "$@"; HREF="$2";; --head) need "$@"; HSHA="$2";;
  --intent-file) need "$@"; INTENT="$2";; --conventions-file) need "$@"; CONV="$2";; --out) need "$@"; OUT="$2";;
  *) die2 "unknown arg $1";; esac; shift 2; done
for v in REPO BREF BSHA HSHA INTENT CONV OUT; do
  eval "val=\${$v:-}"; [ -n "$val" ] || die2 "--$(echo "$v" | tr 'A-Z' 'a-z') is required"
done
[ -d "$REPO" ] || die2 "--repo is not a directory: $REPO"
[ -r "$INTENT" ] || die2 "--intent-file not readable: $INTENT"
[ -r "$CONV" ] || die2 "--conventions-file not readable: $CONV"
REPO="$(cd "$REPO" && pwd -P)"; OUTDIR="$(cd "$(dirname "$OUT")" && pwd -P)"
case "$OUTDIR" in "$REPO"/*|"$REPO") echo "refusing: --out must be outside the repository (scratch index would leak into the snapshot)" >&2; exit 2;; esac
HEADNOTE=""
if [ "$HSHA" = "WORKTREE" ]; then
  HREF="WORKTREE"
  # Baseline (audit): NUL-safe, no index refresh, individual untracked files, submodules visible.
  git -C "$REPO" --no-optional-locks status --porcelain=v1 -z --untracked-files=all --ignore-submodules=none > "$OUT.baseline"
  SCRATCH="$OUTDIR/tmp-index.$$"; rm -f "$SCRATCH"
  # GIT_INDEX_FILE must cover BOTH commands (exported inside one subshell).
  TREE=$( cd "$REPO" && export GIT_INDEX_FILE="$SCRATCH" && git add -A . >/dev/null && git write-tree )
  rm -f "$SCRATCH" "$SCRATCH.lock"
  printf '%s\n' "$TREE" > "$OUT.tree"
  BASETREE=$(git -C "$REPO" rev-parse "$BSHA^{tree}")
  if [ "$TREE" = "$BASETREE" ]; then echo "nothing to review: working tree equals $BREF ($BSHA) — tree $TREE" >&2; exit 3; fi
  HSHA="$TREE"
  IDX_DIFFERS="no"; git -C "$REPO" diff --quiet --cached || IDX_DIFFERS="yes"
  SUBS=$(git -C "$REPO" submodule status --recursive 2>/dev/null | awk '{print $2}' | tr '\n' ' ' || true)
  HEADNOTE="Head is a SNAPSHOT TREE of the uncommitted working tree (staged, unstaged, deleted and non-ignored untracked files), not a commit. It is authoritative: read a file exactly as reviewed with \`git show ${TREE}:<path>\`; the working tree should match it. Ignored files are out of scope. Staged intermediate state is not a separate review target (index differs from working tree: ${IDX_DIFFERS}). Submodules present: ${SUBS:-none}; an outer gitlink change is in scope, uncommitted contents inside a submodule are not."
  FILES=$(git -C "$REPO" diff --name-status -M -z "$BSHA" "$TREE" | python3 -c '
import sys
t=sys.stdin.buffer.read().split(b"\0"); out=[]; i=0
while i<len(t) and t[i]:
    st=t[i].decode(); i+=1
    if st[0] in "RC": old=t[i].decode(); new=t[i+1].decode(); i+=2; out.append(f"  - {new}  ({st[0]} from {old}, similarity {st[1:]})")
    else: out.append(f"  - {t[i].decode()}  ({st})"); i+=1
print("\n".join(sorted(out)))')
  DIFFCMD="git diff ${BSHA} ${TREE}"
else
  : "${HREF:?}"
  FILES=$(git -C "$REPO" diff --name-only "$BSHA..$HSHA" | LC_ALL=C sort | sed 's/^/  - /')
  DIFFCMD="git diff ${BSHA}..${HSHA}"
fi
python3 - "$SK" "$REPO" "$BREF" "$BSHA" "$HREF" "$HSHA" "$INTENT" "$CONV" "$OUT" "$FILES" "$DIFFCMD" "$HEADNOTE" <<'PY'
import sys,re
sk,repo,bref,bsha,href,hsha,intent,conv,out,files,diffcmd,headnote=sys.argv[1:]
t=open(f"{sk}/templates/codex-brief.md").read()
rubric=open(f"{sk}/references/review-rubric.md").read().replace("# Review rubric\n","",1)
schema="\n".join(l for l in open(f"{sk}/templates/finding.md").read().splitlines() if "Raised by" not in l and "Status:" not in l)
schema_key='{{paste templates/finding.md, omitting "Raised by" and "Status"}}'
rep={"{{repo path}}":repo,"{{head ref}}":href,"{{head SHA}}":hsha,"{{base ref}}":bref,"{{base SHA}}":bsha,
     "{{diff command}}":diffcmd,"{{head note}}":headnote,
     "{{list — never reordered by suspicion}}":"\n"+files,
     "{{verbatim PR body / linked issue / spec — do not paraphrase}}":open(intent).read().rstrip(),
     "{{paths to CLAUDE.md, CONTRIBUTING.md, ADRs, and the test/lint/typecheck\ncommands available}}":open(conv).read().rstrip(),
     "{{paste references/review-rubric.md in full}}":rubric.strip(), schema_key:schema}
for k,v in rep.items():
    assert k in t, f"placeholder missing from template: {k}"
    if k!=schema_key: t=t.replace(k,v)
left=[x for x in re.findall(r"\{\{[^}]+\}\}",t) if x!=schema_key]; assert not left, f"unfilled: {left}"
t=t.replace(schema_key,rep[schema_key])
t=re.sub(r"\n- \n","\n",t)  # drop the empty head-note bullet in range mode
open(out,"w").write(t); print(f"brief written: {out} ({len(t)} bytes) head={hsha}")
PY
