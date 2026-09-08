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
import json
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from review_common import EVIDENCE_RE, normalize_evidence, ID_RE, PROVENANCE_RE, SEVERITIES, citation_has_provenance, location_error  # noqa: E402

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


def manifest_rows(matrix: Path) -> dict[str, str]:
    """Every matrix id mapped to its severity ("" when the row carries none).

    The severity column is already in 03-matrix.tsv (id<TAB>origin<TAB>severity); it used to be
    discarded here. The change-anchor rule below needs it to tell a blocking finding from a nit,
    and reading it costs nothing extra.
    """
    rows: dict[str, str] = {}
    for line in matrix.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("STATUS:"):
            continue
        parts = line.split("\t")
        if ID_RE.fullmatch(parts[0]):
            rows[parts[0]] = parts[2].strip().upper() if len(parts) > 2 else ""
    return rows


_changed: dict[tuple[str, str, str], set[str] | None] = {}


def changed_paths(repo: str, base: str, head: str) -> set[str] | None:
    """Paths the reviewed change touches, or None when git cannot answer.

    build-brief.sh pins the base to the merge base in range mode, so `base..head` here is the
    rubric's `<BASE>...HEAD` — what this change introduces, not what the trunk did meanwhile.
    """
    key = (repo, base, head)
    if key not in _changed:
        # -z, not plain --name-only: git C-quotes any path outside its "safe" set, so
        # `src/café.py` comes back as `"src/caf\303\251.py"` while the citation parser yields the
        # real path. Comparing those two strings would reject a valid blocking finding for
        # touching a file the change demonstrably touched. NUL-delimited output is never quoted.
        #
        # --no-renames, because this set answers "did the change touch this path", and rename
        # detection answers a different question. For a detected rename git prints ONLY the
        # destination (verified: a pure R100 rename yields `authz.py` alone under --name-only,
        # with or without -z), so the source path — which the change removed, and which no longer
        # exists at head — looked untouched. A CONFIRMED P0/P1 whose strongest evidence is the
        # base-side line a rename deleted ("this rename dropped an authorization check") was then
        # rejected for citing a file the change demonstrably touched, and the diagnostic advised
        # demoting it to the non-blocking list. --no-renames contributes both endpoints.
        proc = subprocess.run(
            ["git", "-C", repo, "diff", "--name-only", "--no-renames", "-z", f"{base}..{head}"],
            capture_output=True,
        )
        _changed[key] = (
            {p for p in proc.stdout.decode("utf-8", errors="replace").split("\0") if p}
            if proc.returncode == 0
            else None
        )
    return _changed[key]


def anchor_error(value: str, repo: str, head: str | None, base: str | None) -> str | None:
    """Why a blocking finding's evidence is not anchored in the reviewed change, or None.

    A P0/P1 says this change is not safe to merge, so its recorded evidence must point at
    something the change actually did. Nothing else in the pipeline tests this: citation_error
    accepts any path that exists at head or base, which is how findings about untouched trunk
    code reached P1 in a production run.

    Deliberately narrow:
      * CONFIRMED P0/P1 only. A REFUTED verdict often cites the base precisely to show the
        problem predates the change, and P2/P3 are not merge-blocking.
      * `cmd:` evidence is exempt — it carries no path, and citation_error already refuses to let
        it confirm anything on its own.
      * A finding on unchanged code that a changed caller newly reaches keeps its anchor in the
        diff and passes; the rubric requires that repo-wide consumer search and this must not
        punish it.
    """
    if not head or not base:
        return None
    value = normalize_evidence(value)
    if value.startswith("cmd:"):
        return None
    m = CITATION_RE.match(value)
    if not m:
        return None  # shape is citation_error's business, not ours
    path = m.group("path")
    if path.startswith('"'):
        path = path[1:-1]
    changed = changed_paths(repo, base, head)
    if changed is None:
        return None  # git could not answer; citation_error already proved the revisions resolve
    if path in changed:
        return None
    if not changed:
        # An empty comparison does not make the rule vacuous — it makes it total: nothing was
        # changed, so no path can be an anchor. Passing here would disable attribution exactly
        # when every candidate finding is necessarily about code outside the reviewed change.
        # build-brief.sh refuses to build a brief for an empty comparison in either mode, so
        # reaching this line means the recorded revisions were pinned by hand.
        return (
            f"the reviewed comparison {base[:12]}..{head[:12]} is empty, so no path can anchor a "
            f"blocking finding: this run has no reviewed change and should not have been built"
        )
    return (
        f"evidence cites {path}, which the reviewed change does not touch: a blocking finding "
        f"must anchor its evidence in a path inside {base[:12]}..{head[:12]}. If the defect is in "
        f"unchanged code that this change newly reaches, cite the changed line that reaches it and "
        f"name the affected site among the other locations; if it is pre-existing, it belongs in "
        f"the non-blocking list, not at P0/P1"
    )


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


def final_severities(path: Path) -> dict[str, str]:
    """Severity as PHASE 5 left it — the value the merge decision is made on.

    adjudication.md makes Phase-5 evidence the final word on severity, but the verifier reports a
    change as prose (`severity_note`), so nothing structural carried it: the anchor rule keyed on
    the pre-verification classification. A finding promoted P2 -> P1 during verification could then
    confirm with no change anchor at all, which is exactly the case the rule exists for, and a
    finding demoted P1 -> P2 stayed subject to a restriction that no longer applied.

    Rows are `F-nn<TAB>P0|P1|P2|P3`; a `#` comment or a blank line is skipped. Absent file means
    Phase 5 changed no severity.
    """
    out: dict[str, str] = {}
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        fail(f"cannot read {path}: {exc}")
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith("STATUS:"):
            continue
        parts = line.split("\t")
        if len(parts) != 2 or not ID_RE.fullmatch(parts[0].strip()):
            fail(f"{path}: row {number}: expected F-nn<TAB>P0|P1|P2|P3")
        fid, sev = parts[0].strip(), parts[1].strip().upper()
        if sev not in SEVERITIES:
            fail(f"{path}: row {number}: {fid} has invalid severity '{sev}' (expected one of {', '.join(sorted(SEVERITIES))})")
        if fid in out:
            fail(f"{path}: row {number}: duplicate final severity for {fid}")
        out[fid] = sev
    return out


def packet_severities(packets: Path) -> dict[str, str]:
    """Severity per finding as the Phase-5 verifier actually saw it.

    A consultation disposition of REFINE replaces every packet field, severity included, and
    validate-verifier-packets.py stops enforcing equality with the matrix for exactly that reason.
    So once packets exist, the matrix's severity is a stale provisional value: reading it would
    (a) let a finding REFINEd UP to P1 confirm with no anchor, defeating the rule, and (b) block a
    run where a finding REFINEd DOWN to P3 was confirmed on an unchanged consumer, which the
    verifier was correctly told is exempt.
    """
    out: dict[str, str] = {}
    try:
        text = packets.read_text(encoding="utf-8")
    except OSError:
        return out
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        fid, sev = obj.get("id"), obj.get("severity")
        if isinstance(fid, str) and isinstance(sev, str):
            out[fid] = sev.strip().upper()
    return out


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--matrix", required=True)
    parser.add_argument("--verdicts", required=True)
    parser.add_argument("--packets", help="05-verifier-packets.ndjson; its severities override the matrix's provisional ones")
    parser.add_argument("--final-severities", help="05-final-severity.tsv; Phase-5 severities, which outrank both the matrix and the packets")
    parser.add_argument("--repo", help="resolve CONFIRMED/REFUTED citations in this repository")
    parser.add_argument("--head", help="the reviewed head (snapshot tree or head commit); citations without @sha are read here")
    parser.add_argument("--base", help="the base commit; a citation may also be pinned to it")
    args = parser.parse_args()
    matrix, ledger = Path(args.matrix), Path(args.verdicts)
    if not matrix.is_file() or not ledger.is_file():
        fail("--matrix and --verdicts must be readable files")
    if args.repo and subprocess.run(["git", "-C", args.repo, "rev-parse", "--git-dir"], capture_output=True).returncode != 0:
        fail(f"--repo {args.repo} is not a git repository")
    # Read once, before the row loop: the anchor rule needs each finding's severity — the one the
    # verifier was given, which a consultation REFINE may have changed from the matrix's.
    severities = manifest_rows(matrix)
    manifest = set(severities)   # the identity check below names "the manifest", so it must stay the matrix
    if args.packets:
        # A packet severity OVERRIDES the matrix's (post-consultation the packet is authoritative),
        # but a packet id the matrix does not carry must never become a required verdict id: in the
        # pipeline load_packets() already forbids that, and this script is also used standalone.
        severities.update({k: v for k, v in packet_severities(Path(args.packets)).items() if k in manifest})
    # Phase 5 outranks both: the matrix is provisional, the packet is what the verifier was GIVEN,
    # and this is what the verifier concluded. Same manifest restriction — a severity row can change
    # a finding's classification, never introduce a finding.
    if args.final_severities:
        final = final_severities(Path(args.final_severities))
        # REJECT an unknown id rather than filter it (round-5 CX-03). This file is authored by hand
        # and has no upstream manifest check — unlike the packets, which load_packets() already
        # reconciles — so silently dropping a mistyped row preserves the pre-verification severity
        # and quietly suppresses the anchor check the row was written to trigger. Omitting an id is
        # still fine: it simply inherits its packet or matrix severity.
        unknown = sorted(set(final) - manifest)
        if unknown:
            fail(f"{args.final_severities}: {', '.join(unknown)} not in the manifest 03-matrix.tsv: a final-severity row can change a finding's severity, never introduce a finding — check for a typo")
        severities.update(final)
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
                # A CONFIRMED blocking finding must also be anchored in the change itself.
                if verdict == "CONFIRMED" and severities.get(fid, "") in ("P0", "P1"):
                    err = anchor_error(normalize_evidence(evidence), args.repo, args.head, args.base)
                    if err:
                        fail(f"row {number}: {fid} is CONFIRMED {severities[fid]} but its {err}")
        seen[fid] = verdict
    ids = manifest
    if set(seen) != ids:
        fail(f"verdict IDs differ from manifest (missing={sorted(ids - set(seen)) or 'none'} extra={sorted(set(seen) - ids) or 'none'})")
    print(f"OK verdicts={len(seen)}")


if __name__ == "__main__":
    main()
