#!/usr/bin/env python3
"""Write 05-scope-attribution.tsv: what the merge-base correction did to each finding.

The correction in build-brief.sh silently changes what a run is allowed to see. Without a
record, "would the old two-dot scope have produced this finding, and did the fix suppress
one that mattered?" is an archaeology exercise across a run directory. This makes it a
lookup.

One row per 03-matrix.tsv id, tab-separated:

    id  severity  verdict  path  in_requested  in_effective  disposition

path          the repository path of the finding's recorded evidence citation, or "-"
in_requested  yes|no|unknown — is that path in `git diff <requested base>..<head>`
in_effective  yes|no|unknown — is that path in `git diff <effective base>..<head>`, the
              reviewed comparison (the merge base in range mode). In worktree mode the two bases
              are the same commit and the head is a snapshot tree; there is no correction to
              attribute, but membership is still a fact, so both columns agree rather than say
              "unknown"
disposition   in-scope           both comparisons contain it — the correction changed nothing
              trunk-only         the requested base saw it, the reviewed comparison did not:
                                 the correction is what kept this finding out of the diff
              introduced-by-fix  only the reviewed comparison contains it (possible when the
                                 requested base was AHEAD of the fork point)
              outside-both       neither contains it — an unchanged path, cited under the
                                 rubric's repo-wide consumer search
              unanchored         no path to attribute: command evidence, an empty verdict
                                 row, or evidence that is not a citation
              unknown            git could not answer, or the run recorded no usable revisions

The file is descriptive, never a gate: nothing here fails a run. The blocking rule lives in
validate-verdicts.py's anchor_error(), which refuses a CONFIRMED P0/P1 whose evidence is not
anchored in the reviewed change.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path

_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE))

# validate-verdicts.py is not an importable module name (the hyphen), and duplicating its
# citation regex and diff memoization is the drift review_common.py exists to prevent — so
# load it by path and reuse the definitions rather than restating them.
_spec = importlib.util.spec_from_file_location("_vv", _HERE / "validate-verdicts.py")
_vv = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(_vv)

from review_common import ID_RE, normalize_evidence  # noqa: E402


def fail(message: str) -> None:
    print(f"scope-attribution.py: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_rows(path: Path, columns: int) -> list[list[str]]:
    rows = []
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        fail(f"cannot read {path}: {exc}")
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split("\t")
        parts += [""] * (columns - len(parts))
        rows.append(parts)
    return rows


def evidence_path(evidence: str) -> str | None:
    """The repository path a verdict's evidence cites, or None when it names none."""
    value = normalize_evidence(evidence)
    if not value or value.startswith("cmd:"):
        return None
    m = _vv.CITATION_RE.match(value)
    if not m:
        return None
    path = m.group("path")
    return path[1:-1] if path.startswith('"') else path


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--matrix", required=True)
    ap.add_argument("--verdicts", required=True)
    ap.add_argument("--scope", required=True, help="00-brief.md.scope.json")
    ap.add_argument("--repo", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    try:
        scope = json.loads(Path(args.scope).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        fail(f"cannot read the scope sidecar {args.scope}: {exc}")
    if not isinstance(scope, dict):
        fail(f"{args.scope} is not a JSON object")

    head = (scope.get("head") or {}).get("rev", "")
    effective = (scope.get("effective_base") or {}).get("commit", "")
    requested = (scope.get("requested_base") or {}).get("commit", "")
    # Membership is not the same question as merge-base applicability. Worktree mode cannot compute
    # commit ancestry for a snapshot tree, so no CORRECTION is possible there — but `git diff
    # <base> <tree>` still answers "is this path in the reviewed change", which is all a row needs.
    # Reporting `unknown` there threw away the record this file exists to provide; in that mode the
    # requested and effective bases are the same commit, so both columns simply agree.
    def membership(base: str) -> set[str] | None:
        if not head or not base:
            return None
        return _vv.changed_paths(args.repo, base, head)

    eff_paths = membership(effective)
    req_paths = membership(requested)

    verdicts: dict[str, str] = {}
    evidence: dict[str, str] = {}
    for parts in read_rows(Path(args.verdicts), 4):
        fid = parts[0].strip()
        if not ID_RE.fullmatch(fid):
            continue
        verdicts[fid] = parts[1].strip()
        evidence[fid] = parts[3].strip()

    out_lines = []
    for parts in read_rows(Path(args.matrix), 3):
        fid = parts[0].strip()
        if not ID_RE.fullmatch(fid):
            continue
        severity = parts[2].strip() or "-"
        verdict = verdicts.get(fid, "-") or "-"
        path = evidence_path(evidence.get(fid, ""))
        if path is None:
            in_req = in_eff = "-"
            disposition = "unanchored"
        elif eff_paths is None or req_paths is None:
            in_req = in_eff = "unknown"
            disposition = "unknown"
        else:
            in_req = "yes" if path in req_paths else "no"
            in_eff = "yes" if path in eff_paths else "no"
            disposition = {
                ("yes", "yes"): "in-scope",
                ("yes", "no"): "trunk-only",
                ("no", "yes"): "introduced-by-fix",
                ("no", "no"): "outside-both",
            }[(in_req, in_eff)]
        out_lines.append("\t".join([fid, severity, verdict, path or "-", in_req, in_eff, disposition]))

    try:
        Path(args.out).write_text("".join(l + "\n" for l in out_lines), encoding="utf-8")
    except OSError as exc:
        fail(f"cannot write {args.out}: {exc}")
    suppressed = sum(1 for l in out_lines if l.endswith("\ttrunk-only"))
    print(f"OK findings={len(out_lines)} trunk_only={suppressed}")


if __name__ == "__main__":
    main()
