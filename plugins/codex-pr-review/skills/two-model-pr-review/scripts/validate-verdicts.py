#!/usr/bin/env python3
"""Validate 05-verdicts.tsv, the machine-readable Phase-5 ledger.

One row per 03-matrix.tsv ID:
    F-nn<TAB>VERDICT<TAB>METHOD<TAB>EVIDENCE
VERDICT  CONFIRMED | REFUTED | UNVERIFIABLE
METHOD   repro | trace | suite | history | none (or the rung form "(b) trace")
EVIDENCE a repository-relative citation `path:line[-line][@sha] "quote"` or a
         recorded command `cmd: <command> -> <output excerpt>`; may be empty
         only when VERDICT is UNVERIFIABLE.
A CONFIRMED or REFUTED verdict needs a real method (not none) and evidence that
passes the same repository-relative, artifact-free, provenance-free checks as
verifier packets (round-23 CX-01). With --repo, that evidence must also be a
citation that RESOLVES AT A REVIEWED REVISION (round-33 CX-01, round-34
CX-02): the @sha must be a hex object id (never a symbolic ref such as HEAD)
whose tree is the reviewed head's (--head: the snapshot tree or head commit)
or the base's (--base); a citation without @sha is read at --head; the path
must exist there, the line range must be inside the file, and the quote must
appear (whitespace-folded, case-folded) inside the cited lines. Command
evidence cannot be verified after the fact, so with --repo it cannot carry a
CONFIRMED or REFUTED verdict on its own. Exit 0 and print `OK verdicts=N`.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from review_common import EVIDENCE_RE, normalize_evidence, ID_RE, PROVENANCE_RE, citation_has_provenance, location_error  # noqa: E402

VERDICTS = {"CONFIRMED", "REFUTED", "UNVERIFIABLE"}
METHODS = {"repro", "trace", "suite", "history", "none"}
# The verifier contract spells methods as rungs: "(a) repro", "(b) trace",
# "(c) suite", "(d) history". Both spellings are accepted (round-25 CX-01).
RUNG_PREFIX = {"(a)": "repro", "(b)": "trace", "(c)": "suite", "(d)": "history"}


def normalize_method(value: str) -> str:
    value = value.strip()
    parts = value.split(None, 1)
    if len(parts) == 2 and parts[0] in RUNG_PREFIX and parts[1].strip() == RUNG_PREFIX[parts[0]]:
        return RUNG_PREFIX[parts[0]]
    if value in RUNG_PREFIX:
        return RUNG_PREFIX[value]
    return value


def fail(message: str) -> None:
    print(f"validate-verdicts.py: {message}", file=sys.stderr)
    raise SystemExit(1)


def manifest_ids(matrix: Path) -> set[str]:
    ids = set()
    for line in matrix.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("STATUS:"):
            continue
        head = line.split("\t")[0]
        if ID_RE.fullmatch(head):
            ids.add(head)
    return ids


def evidence_ok(value: str) -> str | None:
    value = normalize_evidence(value)
    if not EVIDENCE_RE.match(value):
        return "evidence must be a quoted citation or `cmd: ... -> ...`"
    if value.startswith("cmd:"):
        if PROVENANCE_RE.search(value):
            return "evidence contains review provenance or artifact path"
    else:
        if citation_has_provenance(value):
            return "evidence contains review provenance or artifact path"
        err = location_error(value)
        if err:
            return f"evidence citation {err}"
    return None


CITATION_RE = re.compile(r'^(?P<path>[\w./@+-]+|"[^"\\]+"):(?P<start>\d+)(?:-(?P<end>\d+))?(?:@(?P<sha>\w+))?\s+"(?P<quote>.*)"$', re.DOTALL)
_blobs: dict[tuple[str, str], list[str] | None] = {}


def fold(text: str) -> str:
    return re.sub(r"\s+", " ", unicodedata.normalize("NFKC", text)).strip().lower()


def blob_lines(repo: str, rev: str, path: str) -> list[str] | None:
    key = (rev, path)
    if key not in _blobs:
        proc = subprocess.run(["git", "-C", repo, "show", f"{rev}:{path}"], capture_output=True)
        _blobs[key] = proc.stdout.decode("utf-8", errors="replace").splitlines() if proc.returncode == 0 else None
    return _blobs[key]


HEX_RE = re.compile(r"^[0-9a-f]{7,64}$")


def tree_of(repo: str, rev: str) -> str | None:
    proc = subprocess.run(["git", "-C", repo, "rev-parse", "--verify", "-q", f"{rev}^{{tree}}"], capture_output=True)
    return proc.stdout.decode().strip() if proc.returncode == 0 else None


def citation_error(value: str, repo: str, head: str | None, base: str | None) -> str | None:
    """Why a citation does not resolve at a reviewed revision, or None when it does."""
    if value.startswith("cmd:"):
        return "command evidence cannot be verified after the fact; cite the code it exercised (path:lines@sha \"quote\")"
    m = CITATION_RE.match(value)
    if not m:
        return "evidence citation is not path:line[-line][@sha] \"quote\""
    path = m.group("path").strip('"')
    reviewed = {}
    for label, rev in (("head", head), ("base", base)):
        if rev:
            tree = tree_of(repo, rev)
            if tree is None:
                return f"the run's recorded {label} revision {rev} does not resolve in the repository"
            reviewed[tree] = f"{label} {rev[:12]}"
    rev = m.group("sha")
    if rev is None:
        if not head:
            return "evidence citation has no @sha and the run records no reviewed head"
        rev = head
    elif not HEX_RE.match(rev):
        return f"evidence cites @{rev}, which is not a hex object id (symbolic refs such as HEAD are not a reviewed revision)"
    tree = tree_of(repo, rev)
    if tree is None:
        return f"evidence cites @{rev}, which does not resolve in the repository"
    if reviewed and tree not in reviewed:
        return f"evidence cites @{rev}, which is neither the reviewed head nor the base ({', '.join(reviewed.values())})"
    lines = blob_lines(repo, rev, path)
    if lines is None:
        return f"evidence cites {path}, which does not exist at {rev}"
    start, end = int(m.group("start")), int(m.group("end") or m.group("start"))
    if start < 1 or end < start or end > len(lines):
        return f"evidence cites {path}:{start}-{end}, outside the file's {len(lines)} lines at {rev}"
    quote = fold(m.group("quote"))
    if not quote:
        return "evidence quote is empty"
    if quote not in fold(" ".join(lines[start - 1:end])):
        return f"evidence quote is not found in {path}:{start}-{end} at {rev}"
    return None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--matrix", required=True)
    parser.add_argument("--verdicts", required=True)
    parser.add_argument("--repo", help="resolve CONFIRMED/REFUTED citations in this repository")
    parser.add_argument("--head", help="the reviewed head (snapshot tree or head commit); citations without @sha are read here")
    parser.add_argument("--base", help="the base commit; a citation may also be pinned to it")
    args = parser.parse_args()
    matrix, ledger = Path(args.matrix), Path(args.verdicts)
    if not matrix.is_file() or not ledger.is_file():
        fail("--matrix and --verdicts must be readable files")
    if args.repo and subprocess.run(["git", "-C", args.repo, "rev-parse", "--git-dir"], capture_output=True).returncode != 0:
        fail(f"--repo {args.repo} is not a git repository")
    seen: dict[str, str] = {}
    for number, raw in enumerate(ledger.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 2 or not ID_RE.fullmatch(parts[0]):
            fail(f"row {number}: expected F-nn<TAB>verdict[<TAB>method<TAB>evidence]")
        fid, verdict = parts[0], parts[1].strip()
        method = normalize_method(parts[2]) if len(parts) > 2 else ""
        evidence = "\t".join(parts[3:]).strip() if len(parts) > 3 else ""
        if verdict not in VERDICTS:
            fail(f"row {number}: {fid} has invalid verdict '{verdict}' (expected CONFIRMED, REFUTED, or UNVERIFIABLE)")
        if fid in seen:
            fail(f"row {number}: duplicate verdict for {fid}")
        if verdict == "UNVERIFIABLE":
            if method and method not in METHODS:
                fail(f"row {number}: {fid} has invalid method '{method}'")
            if evidence:
                err = evidence_ok(evidence)
                if err:
                    fail(f"row {number}: {fid} {err}")
        else:
            if method not in METHODS - {"none"}:
                fail(f"row {number}: {fid} is {verdict} but method is '{method or 'missing'}' (need repro, trace, suite, or history)")
            if not evidence:
                fail(f"row {number}: {fid} is {verdict} without evidence")
            err = evidence_ok(evidence)
            if err:
                fail(f"row {number}: {fid} {err}")
            if args.repo:
                err = citation_error(normalize_evidence(evidence), args.repo, args.head, args.base)
                if err:
                    fail(f"row {number}: {fid} is {verdict} but its {err}")
        seen[fid] = verdict
    ids = manifest_ids(matrix)
    if set(seen) != ids:
        fail(f"verdict IDs differ from manifest (missing={sorted(ids - set(seen)) or 'none'} extra={sorted(set(seen) - ids) or 'none'})")
    print(f"OK verdicts={len(seen)}")


if __name__ == "__main__":
    main()
