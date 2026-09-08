#!/bin/bash
# build-brief.sh — fill templates/codex-brief.md deterministically.
#   Range mode:    build-brief.sh --repo <path> --base-ref <name> --base <sha> --head-ref <name> --head <sha> \
#                                 --intent-file <f> --conventions-file <f> --out <file>
#   Worktree mode: build-brief.sh --repo <path> --base-ref <name> --base <sha> --head WORKTREE \
#                                 --intent-file <f> --conventions-file <f> --out <file>
#     Captures the aggregate working tree (staged + unstaged + deleted + non-ignored untracked) as a TREE
#     object via an artifact-local scratch index, never touching the repo's index, refs, stash or files.
#     Writes <out>.tree (the tree SHA) and <out>.baseline (NUL-separated status).
#     Both modes write <out>.repo (canonical repository path), <out>.base (base commit) and <out>.head (reviewed head: the snapshot tree or the head commit);
#     phase-gate.sh pins Phase-5 citations to those two revisions.
#   Exit 3 = nothing to review, in BOTH modes: worktree mode when the captured tree equals the base
#     tree, range mode when `base..head` is empty. Exit 2 = usage error. Exit 0 = brief written.
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
#
# Worktree mode gets the SAME correction. The old guard keyed on the head literal `WORKTREE`, but
# the question is not "is the head a commit", it is "can an ancestry question be asked" — and a
# snapshot tree has an anchor: the commit it was captured from (HEAD). --base is caller-supplied in
# both modes (`/review-pr local <base-ref> …`), so a worktree run against a moved trunk tip had all
# three failures this correction exists to prevent: the brief listed trunk work as changes by the
# review target, the frozen sidecar asserted `merge_base_applicable: false` when the correction was
# merely never attempted, and changed_paths() — hence the change-anchor rule — was computed from the
# uncorrected base, so a CONFIRMED P0/P1 could be anchored entirely in trunk work.
REQUESTED_BREF="$BREF"; REQUESTED_BSHA="$BSHA"; MERGE_BASE_APPLIED=no
MB_ANCHOR="$HSHA"
if [ "$HSHA" = "WORKTREE" ]; then
  # The tree is uncommitted work on top of HEAD, so HEAD is its ancestry anchor. If HEAD cannot be
  # resolved (an unborn branch) there is no anchor and the correction genuinely does not apply.
  MB_ANCHOR=$(git -C "$REPO" rev-parse --verify --quiet "HEAD^{commit}") || MB_ANCHOR=""
fi
if [ -n "$MB_ANCHOR" ]; then
  HSHA_FOR_MB="$MB_ANCHOR"
  MB=$(git -C "$REPO" merge-base --all "$BSHA" "$HSHA_FOR_MB" 2>/dev/null) || MB=""
  [ -n "$MB" ] || die2 "no common ancestor between base $BSHA and head $HSHA_FOR_MB: the comparison is undefined — name a base that shares history with the head"
  # Several merge bases means a criss-cross merge and no single defensible fork point. Stopping is
  # correct here: silently picking one would review a scope nobody chose.
  if [ "$(printf '%s\n' "$MB" | wc -l | tr -d ' ')" -gt 1 ]; then
    die2 "ambiguous history: $(printf '%s\n' "$MB" | wc -l | tr -d ' ') merge bases between $BSHA and $HSHA_FOR_MB ($(printf '%s' "$MB" | tr '\n' ' ')) — name an explicit base commit"
  fi
  MB=$(git -C "$REPO" rev-parse --verify --quiet "$MB^{commit}") || die2 "merge base $MB does not resolve to a commit in $REPO"
  if [ "$MB" != "$BSHA" ]; then
    # A uniquely resolvable non-ancestor base is corrected automatically and visibly: it costs the
    # operator a round-trip otherwise, and the corrected scope is the one the rubric already asks for.
    MERGE_BASE_APPLIED=yes
    BSHA="$MB"
    # Name the anchor the merge base was actually computed against. In worktree mode $HREF is the
    # literal WORKTREE, which would make the recorded ref read merge-base(main, WORKTREE) — a
    # comparison git cannot reproduce from the brief alone.
    if [ "$HSHA" = "WORKTREE" ]; then BREF="merge-base($REQUESTED_BREF, HEAD)"; else BREF="merge-base($REQUESTED_BREF, $HREF)"; fi
  fi
fi
# The Base ref field reaches an anchored parser (phase-gate.sh brief_target): backticks delimit it
# and the 40-hex id must end the line, so a ref name may never contain a backtick.
case "$BREF" in *'`'*) die2 "base ref name may not contain a backtick: $BREF";; esac
# The Head ref field reaches the SAME anchored parser (phase-gate.sh brief_target reads Head, Base
# and Requested base identically), so it needs the same guard — validating one of two fields that
# share a parser is an accident waiting for the other input.
case "${HREF:-}" in *'`'*) die2 "head ref name may not contain a backtick: $HREF";; esac
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
  # Range mode needs the same "nothing to review" refusal worktree mode has at :86. When the head
  # is already an ancestor of the requested base — a merged or stale branch — merge-base returns
  # the HEAD, the correction sets base = head, and `git diff H..H` is empty. Before the correction
  # that input produced a wrong-but-visible two-dot diff; without this guard it produces an
  # invisible empty one, and both reviewers spend a full review on a brief naming zero files.
  # No later gate catches it: repo_check compares base and head against the brief, never against
  # each other, and anchor_error cannot discriminate on an empty change set.
  if [ -z "$FILES" ]; then
    # State the observed fact, not an inference from it: [ -z "$FILES" ] means the DIFF is empty,
    # which ancestry produces but so does a full revert or an empty commit. Naming ancestry as the
    # cause sends an operator whose branch merely nets to zero to fix a relationship that is fine.
    # Name the REQUESTED base as the thing the operator chose, and the reviewed comparison
    # separately. By this point $BREF/$BSHA are the corrected base, so phrasing the cause in terms
    # of them produced "merge-base(main, feature) (abc) already contains feature (abc)" — a
    # sentence about one commit containing itself, which tells the operator nothing.
    echo "nothing to review: the reviewed comparison $BSHA..$HSHA is empty (requested base $REQUESTED_BREF $REQUESTED_BSHA, head $HREF $HSHA) — the base already contains the head, or the head's tree is identical to the base's; review a head whose tree differs from the base's and that the base does not already contain" >&2
    exit 3
  fi
  DIFFCMD="git diff ${BSHA}..${HSHA}"
fi
printf '%s\n' "$BSHA" > "$OUT.base"; printf '%s\n' "$HSHA" > "$OUT.head"; (cd "$REPO" && pwd -P) > "$OUT.repo"

# Scope sidecar: the evidence for what the merge-base correction changed. 00-run.md is never
# hashed and no gate reads it, so the record that must survive an audit lives here, frozen with
# the other packets.
#
# The set difference is computed in PYTHON from raw NUL-delimited bytes, never in the shell
# (round-4 CX-04). `tr '\0' '\n'` destroys filename boundaries before the comparison: one trunk
# path named "trunk\nname.txt" became the two phantom exclusions "trunk" and "name.txt" in a
# hashed, accept-final audit artifact — the earlier comment claimed the degradation was toward a
# false NOT-excluded, which is the opposite of what it does. Keeping the bytes NUL-delimited also
# removes the LC_ALL=C `comm` collation hazard entirely, since Python compares exact byte strings.
#
# --no-renames on both sides: rename detection is a per-comparison heuristic, so the requested and
# effective comparisons can disagree about whether one edit is a rename. A feature that renames
# a.py to b.py while the trunk edits a.py heavily gives a rename in one and a delete+add in the
# other, and a.py was then frozen as "excluded by the merge base" although the feature deletes it.
# Both sides now list both endpoints, agreeing with the anchor rule's membership set.
#
# -z rather than plain --name-only: git C-quotes unusual paths ("caf\303\251.txt"), which would
# put a quoted string in a frozen artifact every other reader compares against real paths.
SCOPE_OLD_Z=$(mktemp "${TMPDIR:-/tmp}/build-brief.old.XXXXXX") || die2 "cannot allocate a scratch file in ${TMPDIR:-/tmp}"
SCOPE_NEW_Z=$(mktemp "${TMPDIR:-/tmp}/build-brief.new.XXXXXX") || die2 "cannot allocate a scratch file in ${TMPDIR:-/tmp}"
trap 'rm -f "$SCOPE_OLD_Z" "$SCOPE_NEW_Z"' EXIT
if [ "$MERGE_BASE_APPLIED" = yes ]; then
  git -C "$REPO" diff --name-only --no-renames -z "$REQUESTED_BSHA..$HSHA" > "$SCOPE_OLD_Z"
  git -C "$REPO" diff --name-only --no-renames -z "$BSHA..$HSHA" > "$SCOPE_NEW_Z"
fi
# Plain if, not `test && assign`: under `set -e` a false test makes the whole statement non-zero
# and aborts the script.
if [ "$HREF" = WORKTREE ]; then MODE_LABEL=worktree; else MODE_LABEL=range; fi
# The correction is APPLICABLE wherever an ancestry anchor exists, which is both modes now that a
# snapshot tree is anchored at the commit it was captured from — not "mode == range" (round-4 CL-01).
if [ -n "$MB_ANCHOR" ]; then MB_APPLICABLE=yes; else MB_APPLICABLE=no; fi
python3 - "$OUT.scope.json" "$MODE_LABEL" "$REPO" "$REQUESTED_BREF" "$REQUESTED_BSHA" "$BREF" "$BSHA" "$HREF" "$HSHA" "$MERGE_BASE_APPLIED" "$MB_APPLICABLE" "$MB_ANCHOR" "$SCOPE_OLD_Z" "$SCOPE_NEW_Z" <<'PY'
import json,sys
out,mode,repo,rbref,rbsha,bref,bsha,href,hsha,applied,applicable,anchor,oldz,newz=sys.argv[1:]
def paths(p):
    with open(p,"rb") as fh:
        return [x.decode("utf-8","surrogateescape") for x in fh.read().split(b"\0") if x]
old_set,new_set=paths(oldz),paths(newz)
excluded=sorted(set(old_set)-set(new_set))
doc={"schema":"scope/1","mode":mode,"repository":repo,
     "requested_base":{"ref":rbref,"commit":rbsha},
     "effective_base":{"ref":bref,"commit":bsha},
     "head":{"ref":href,"rev":hsha},
     "merge_base_applied":applied=="yes",
     "merge_base_applicable":applicable=="yes",
     # The corrected base IS the fork point, so `M..H` is byte-identical to the rubric's `B...H`.
     # equivalent_three_dot only where both endpoints are COMMITS. A snapshot tree has no ancestry,
     # so `<commit>...<tree>` is an expression git rejects (exit 128) — and extending the correction
     # to worktree mode is what made that reachable. The ancestry anchor the merge base was actually
     # computed against is recorded separately, so the calculation stays replayable there.
     "comparison":{"old":f"{rbsha}..{hsha}","corrected":f"{bsha}..{hsha}",
                   "equivalent_three_dot":f"{rbsha}...{hsha}" if applied=="yes" and mode!="worktree" else None},
     "ancestry_anchor":anchor or None,
     "excluded_by_merge_base":excluded}
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
