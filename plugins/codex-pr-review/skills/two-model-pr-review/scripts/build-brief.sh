#!/bin/bash
# build-brief.sh — fill templates/codex-brief.md deterministically.
#   Range mode:    build-brief.sh --repo <path> --base-ref <name> --base <sha> --head-ref <name> --head <sha> \
#                                 --intent-file <f> --conventions-file <f> --out <file>
#   Worktree mode: build-brief.sh --repo <path> --base-ref <name> --base <sha> --head WORKTREE \
#                                 --intent-file <f> --conventions-file <f> --out <file>
#     Captures the aggregate working tree (staged + unstaged + deleted + non-ignored untracked) as a TREE
#     object via an artifact-local scratch index, never touching the repo's index, refs, stash or files.
#     Writes <out>.tree (the tree SHA) and <out>.baseline (NUL-separated status). Exit 3 = nothing to review.
#     Both modes write <out>.repo (canonical repository path), <out>.base (base commit) and <out>.head (reviewed head: the snapshot tree or the head commit);
#     phase-gate.sh pins Phase-5 citations to those two revisions.
set -euo pipefail
SK="$(cd "$(dirname "$0")/.." && pwd)"
USAGE='usage: build-brief.sh --repo <path> --base-ref <name> --base <sha> (--head-ref <name> --head <sha> | --head WORKTREE) \\
                       --intent-file <file> --conventions-file <file> --out <file> [--tier compact-v1|full]'
# Every usage error exits 2, as documented in references/codex-protocol.md.
die2() { echo "build-brief.sh: $1" >&2; echo "$USAGE" >&2; exit 2; }
need() { [ $# -ge 2 ] || die2 "$1 requires a value"; case "$2" in -*) die2 "$1 requires a value (got option $2)";; esac; }
TIER=compact-v1   # the default: the reduced output contract (references/review-rubric.md §Output contract)
while [ $# -gt 0 ]; do case "$1" in
  --repo) need "$@"; REPO="$2";; --base-ref) need "$@"; BREF="$2";; --base) need "$@"; BSHA="$2";;
  --head-ref) need "$@"; HREF="$2";; --head) need "$@"; HSHA="$2";;
  --intent-file) need "$@"; INTENT="$2";; --conventions-file) need "$@"; CONV="$2";; --out) need "$@"; OUT="$2";;
  --tier) need "$@"; TIER="$2";;
  *) die2 "unknown arg $1";; esac; shift 2; done
for v in REPO BREF BSHA HSHA INTENT CONV OUT; do
  eval "val=\${$v:-}"; [ -n "$val" ] || die2 "--$(echo "$v" | tr 'A-Z' 'a-z') is required"
done
# Strict enum: an unknown tier must never silently fall back to a contract nobody chose.
case "$TIER" in compact-v1|full) ;; *) die2 "--tier must be compact-v1 or full (got '$TIER')";; esac
if [ "$HSHA" != "WORKTREE" ] && [ -z "${HREF:-}" ]; then die2 "--head-ref is required in range mode (omit it only with --head WORKTREE)"; fi
[ -d "$REPO" ] || die2 "--repo is not a directory: $REPO"
[ -r "$INTENT" ] || die2 "--intent-file not readable: $INTENT"
[ -r "$CONV" ] || die2 "--conventions-file not readable: $CONV"
REPO="$(cd "$REPO" && pwd -P)"; OUTDIR="$(cd "$(dirname "$OUT")" && pwd -P)"
# Full object ids only: the gates pin citations to the 40-hex ids in the brief's Target lines.
BSHA=$(git -C "$REPO" rev-parse --verify --quiet "$BSHA^{commit}") || die2 "--base does not resolve to a commit in $REPO"
if [ "$HSHA" != "WORKTREE" ]; then HSHA=$(git -C "$REPO" rev-parse --verify --quiet "$HSHA^{commit}") || die2 "--head does not resolve to a commit in $REPO"; fi

# MERGE BASE (range mode only). review-rubric.md §Scope makes the review's primary object
# `<BASE>...HEAD` — the three-dot diff — but a caller resolves --base from a branch TIP
# (origin/main), which is not the fork point once the trunk moves on. A two-dot diff against a
# non-ancestor tip then shows the trunk's own post-divergence commits as DELETIONS BY THE PR, and
# no later gate can tell such a finding from one about the PR's work. Measured over stored runs:
# 5 of 15 checkable range-mode runs had a non-ancestor base, median scope inflation 3.5x.
#
# The builder owns this translation, not the caller: the caller owns which target to review, and
# one place must make the file list, the diff command and the recorded base agree.
# Not --fork-point: that selects via the ref's reflog, a different rule that depends on local
# reflog state. REQUESTED_BASE keeps the caller's intent visible in the brief.
REQUESTED_BREF="$BREF"; REQUESTED_BSHA="$BSHA"; MERGE_BASE_APPLIED=no
if [ "$HSHA" != "WORKTREE" ]; then
  MB=$(git -C "$REPO" merge-base --all "$BSHA" "$HSHA" 2>/dev/null) || MB=""
  [ -n "$MB" ] || die2 "no common ancestor between base $BSHA and head $HSHA: the comparison is undefined — name a base that shares history with the head"
  # Several merge bases means a criss-cross merge and no single defensible fork point. Stopping is
  # correct here: silently picking one would review a scope nobody chose.
  if [ "$(printf '%s\n' "$MB" | wc -l | tr -d ' ')" -gt 1 ]; then
    die2 "ambiguous history: $(printf '%s\n' "$MB" | wc -l | tr -d ' ') merge bases between $BSHA and $HSHA ($(printf '%s' "$MB" | tr '\n' ' ')) — name an explicit base commit"
  fi
  MB=$(git -C "$REPO" rev-parse --verify --quiet "$MB^{commit}") || die2 "merge base $MB does not resolve to a commit in $REPO"
  if [ "$MB" != "$BSHA" ]; then
    # A uniquely resolvable non-ancestor base is corrected automatically and visibly: it costs the
    # operator a round-trip otherwise, and the corrected scope is the one the rubric already asks for.
    MERGE_BASE_APPLIED=yes
    BSHA="$MB"
    BREF="merge-base($REQUESTED_BREF, $HREF)"
  fi
fi
# The Base ref field reaches an anchored parser (phase-gate.sh brief_target): backticks delimit it
# and the 40-hex id must end the line, so a ref name may never contain a backtick.
case "$BREF" in *'`'*) die2 "base ref name may not contain a backtick: $BREF";; esac
case "$OUTDIR" in "$REPO"/*|"$REPO") echo "refusing: --out must be outside the repository (scratch index would leak into the snapshot)" >&2; exit 2;; esac
HEADNOTE=""
if [ "$HSHA" = "WORKTREE" ]; then
  HREF="WORKTREE"
  # Baseline (audit): NUL-safe, no index refresh, individual untracked files, submodules visible.
  git -C "$REPO" --no-optional-locks status --porcelain=v1 -z --untracked-files=all --ignore-submodules=none > "$OUT.baseline"
  SCRATCH="$OUTDIR/tmp-index.$$"; rm -f "$SCRATCH"
  # GIT_INDEX_FILE must cover BOTH commands; `git -C` keeps the shell where it is, so the
  # documented form never teaches a `cd` plus a relative operand (review X-1).
  GIT_INDEX_FILE="$SCRATCH" git -C "$REPO" add -A "$REPO" >/dev/null || { echo "refusing: could not stage the working tree" >&2; exit 2; }
  TREE=$(GIT_INDEX_FILE="$SCRATCH" git -C "$REPO" write-tree)
  rm -f "$SCRATCH" "$SCRATCH.lock"
  printf '%s\n' "$TREE" > "$OUT.tree"
  BASETREE=$(git -C "$REPO" rev-parse "$BSHA^{tree}")
  if [ "$TREE" = "$BASETREE" ]; then echo "nothing to review: working tree equals $BREF ($BSHA) — tree $TREE" >&2; exit 3; fi
  HSHA="$TREE"
  IDX_DIFFERS="no"; git -C "$REPO" diff --quiet --cached || IDX_DIFFERS="yes"
  SUBS=$(git -C "$REPO" submodule status --recursive 2>/dev/null | awk '{print $2}' | tr '\n' ' ' || true)
  HEADNOTE="Head is a SNAPSHOT TREE of the uncommitted working tree (staged, unstaged, deleted and non-ignored untracked files), not a commit. It is authoritative: read a file exactly as reviewed with \`git show ${TREE}:<path>\`; the working tree should match it. A path printed in double quotes in the file list below is quoted the way git quotes unusual paths (C escapes, \\ooo octal for raw bytes); read such a file with \`git diff ${BSHA} ${TREE} -- <path>\` or list it with \`git ls-tree -r -z ${TREE}\` rather than pasting the quoted text into \`git show\`. Ignored files are out of scope. Staged intermediate state is not a separate review target (index differs from working tree: ${IDX_DIFFERS}). Submodules present: ${SUBS:-none}; an outer gitlink change is in scope, uncommitted contents inside a submodule are not."
  FILES=$(git -C "$REPO" diff --name-status -M -z "$BSHA" "$TREE" | python3 "$SK/scripts/quote-name-status.py")
  DIFFCMD="git diff ${BSHA} ${TREE}"
else
  FILES=$(git -C "$REPO" diff --name-only "$BSHA..$HSHA" | LC_ALL=C sort | sed 's/^/  - /')
  DIFFCMD="git diff ${BSHA}..${HSHA}"
fi
printf '%s\n' "$BSHA" > "$OUT.base"; printf '%s\n' "$HSHA" > "$OUT.head"; (cd "$REPO" && pwd -P) > "$OUT.repo"

# Scope sidecar: the evidence for what the merge-base correction changed. 00-run.md is never
# hashed and no gate reads it, so the record that must survive an audit lives here, frozen with
# the other packets. In worktree mode the head is a tree object with no commit ancestry, so the
# correction does not apply and the sidecar says so rather than omitting the field.
if [ "$MERGE_BASE_APPLIED" = yes ]; then
  OLD_FILES=$(git -C "$REPO" diff --name-only "$REQUESTED_BSHA..$HSHA" | LC_ALL=C sort)
  NEW_FILES=$(git -C "$REPO" diff --name-only "$BSHA..$HSHA" | LC_ALL=C sort)
  EXCLUDED=$(comm -23 <(printf '%s\n' "$OLD_FILES") <(printf '%s\n' "$NEW_FILES"))
else
  OLD_FILES=""; NEW_FILES=""; EXCLUDED=""
fi
# Plain if, not `test && assign`: under `set -e` a false test makes the whole statement non-zero
# and aborts the script.
if [ "$HREF" = WORKTREE ]; then MODE_LABEL=worktree; else MODE_LABEL=range; fi
python3 - "$OUT.scope.json" "$MODE_LABEL" "$REPO" "$REQUESTED_BREF" "$REQUESTED_BSHA" "$BREF" "$BSHA" "$HREF" "$HSHA" "$MERGE_BASE_APPLIED" "$EXCLUDED" <<'PY'
import json,sys
out,mode,repo,rbref,rbsha,bref,bsha,href,hsha,applied,excluded=sys.argv[1:]
doc={"schema":"scope/1","mode":mode,"repository":repo,
     "requested_base":{"ref":rbref,"commit":rbsha},
     "effective_base":{"ref":bref,"commit":bsha},
     "head":{"ref":href,"rev":hsha},
     "merge_base_applied":applied=="yes",
     "merge_base_applicable":mode=="range",
     # The corrected base IS the fork point, so `M..H` is byte-identical to the rubric's `B...H`.
     "comparison":{"old":f"{rbsha}..{hsha}","corrected":f"{bsha}..{hsha}",
                   "equivalent_three_dot":f"{rbsha}...{hsha}" if applied=="yes" else None},
     "excluded_by_merge_base":[p for p in excluded.split("\n") if p]}
doc["excluded_count"]=len(doc["excluded_by_merge_base"])
open(out,"w").write(json.dumps(doc,indent=2,sort_keys=True)+"\n")
print(f"scope sidecar: {out} (merge_base_applied={applied}, excluded={doc['excluded_count']})")
PY
python3 - "$SK" "$REPO" "$BREF" "$BSHA" "$HREF" "$HSHA" "$INTENT" "$CONV" "$OUT" "$FILES" "$DIFFCMD" "$HEADNOTE" "$TIER" "$REQUESTED_BREF" "$REQUESTED_BSHA" "$MERGE_BASE_APPLIED" <<'PY'
import sys,re
sk,repo,bref,bsha,href,hsha,intent,conv,out,files,diffcmd,headnote,tier,rbref,rbsha,applied=sys.argv[1:]
t=open(f"{sk}/templates/codex-brief.md").read()
rubric=open(f"{sk}/references/review-rubric.md").read().replace("# Review rubric\n","",1)
schema="\n".join(l for l in open(f"{sk}/templates/finding.md").read().splitlines() if "Raised by" not in l and "Status:" not in l)
schema_key='{{paste templates/finding.md, omitting "Raised by" and "Status"}}'
requested = (f"`{rbref}` ({rbsha}) — not the review base: the trunk moved on after this branch "
             f"diverged, so the base below is the fork point and the diff is what this change "
             f"introduces, not what the trunk changed meanwhile") if applied=="yes" else \
            f"`{rbref}` ({rbsha}) — same as the review base below"
rep={"{{repo path}}":repo,"{{head ref}}":href,"{{head SHA}}":hsha,"{{base ref}}":bref,"{{base SHA}}":bsha,
     "{{tier}}":tier,"{{requested base}}":requested,
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
