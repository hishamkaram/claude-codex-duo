#!/usr/bin/env python3
"""validate-provenance.py — check 03-provenance.tsv against the reconciliation matrix and the
participants file.

  validate-provenance.py --matrix 03-matrix.tsv --participants 00-participants.tsv --provenance 03-provenance.tsv

Rows of 03-provenance.tsv (tab-separated, no header, one row per raiser of a canonical finding):

    F-01<TAB>lead<TAB>CL-03
    F-01<TAB>p2<TAB>CX-07
    F-02<TAB>p1<TAB>CX-02

Rules (codex-pr-review 4.0.0, N blind reviewers):
  * every matrix ID appears at least once; every provenance ID is a matrix ID;
  * a raiser is `lead` or a participant id from 00-participants.tsv (p1..pN); no raiser twice per ID;
  * the original id is `CL-nn`/`CL-Qn` for the lead and `CX-nn`/`CX-Qn` for a participant;
  * the matrix origin is consistent with the raiser set:
        BOTH        ⇔ lead and at least one participant raised it
        CLAUDE-ONLY ⇔ only the lead raised it
        CODEX-ONLY  ⇔ only participants raised it (any number)
        CONFLICT    → any non-empty raiser set (the disagreement is recorded in the matrix, not here)
Exit 0 with `OK rows=<n> ids=<m>`; exit 1 with one reason per line; exit 2 on usage.
"""
from __future__ import annotations

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from review_common import ID_RE, ORIGINS  # noqa: E402

RAISER_ID_RE = {"lead": re.compile(r"^CL-(?:[0-9]{2,}|Q[0-9]+)$"), "p": re.compile(r"^CX-(?:[0-9]{2,}|Q[0-9]+)$")}
PARTICIPANT_RE = re.compile(r"^p[1-9][0-9]*$")


def usage(msg: str) -> None:
    print(f"validate-provenance.py: {msg}", file=sys.stderr)
    print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
    sys.exit(2)


def read_tsv(path: str, what: str):
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError as e:
        usage(f"cannot read {what}: {e}")
    rows = []
    for n, line in enumerate(lines, 1):
        if not line.strip() or line.startswith("#"):
            continue
        rows.append((n, line.split("\t")))
    return rows


def main(argv: list[str]) -> int:
    args = {"--matrix": None, "--participants": None, "--provenance": None}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in args:
            if i + 1 >= len(argv) or argv[i + 1].startswith("--"):
                usage(f"{a} requires a value")
            args[a] = argv[i + 1]
            i += 2
        else:
            usage(f"unknown arg {a}")
    for k, v in args.items():
        if not v:
            usage(f"{k} is required")

    errors: list[str] = []
    origins: dict[str, str] = {}
    for n, cols in read_tsv(args["--matrix"], "matrix"):
        if len(cols) < 3 or not ID_RE.fullmatch(cols[0].strip()) or cols[1].strip() not in ORIGINS:
            errors.append(f"matrix line {n}: expected F-nn<TAB>origin<TAB>severity")
            continue
        origins[cols[0].strip()] = cols[1].strip()

    participants: list[str] = []
    for n, cols in read_tsv(args["--participants"], "participants"):
        pid = cols[0].strip()
        if not PARTICIPANT_RE.match(pid) or len(cols) < 2 or cols[1].strip() not in ("codex", "ccr"):
            errors.append(f"participants line {n}: expected p<k><TAB>codex|ccr<TAB>alias-or-dash")
            continue
        if pid in participants:
            errors.append(f"participants line {n}: {pid} listed twice")
        participants.append(pid)
    if not participants:
        errors.append("participants file lists no participant")

    raisers: dict[str, dict[str, str]] = {}
    rows = 0
    for n, cols in read_tsv(args["--provenance"], "provenance"):
        if len(cols) != 3:
            errors.append(f"provenance line {n}: expected F-nn<TAB>lead|p<k><TAB>original-id")
            continue
        fid, raiser, orig = (c.strip() for c in cols)
        rows += 1
        if not ID_RE.fullmatch(fid):
            errors.append(f"provenance line {n}: '{fid}' is not a canonical F-nn id")
            continue
        if fid not in origins:
            errors.append(f"provenance line {n}: {fid} is not in the matrix")
            continue
        if raiser == "lead":
            pat = RAISER_ID_RE["lead"]
        elif raiser in participants:
            pat = RAISER_ID_RE["p"]
        else:
            errors.append(f"provenance line {n}: raiser '{raiser}' is neither lead nor a listed participant")
            continue
        if not pat.match(orig):
            errors.append(f"provenance line {n}: original id '{orig}' does not fit raiser {raiser} (lead: CL-nn/CL-Qn; participant: CX-nn/CX-Qn)")
        if raiser in raisers.setdefault(fid, {}):
            errors.append(f"provenance line {n}: {fid} lists raiser {raiser} twice")
        raisers.setdefault(fid, {})[raiser] = orig

    for fid, origin in sorted(origins.items()):
        rs = raisers.get(fid, {})
        if not rs:
            errors.append(f"{fid}: no provenance row (every matrix id needs at least one raiser)")
            continue
        has_lead = "lead" in rs
        has_p = any(r != "lead" for r in rs)
        if origin == "BOTH" and not (has_lead and has_p):
            errors.append(f"{fid}: origin BOTH but raisers are {sorted(rs)} (needs lead and at least one participant)")
        elif origin == "CLAUDE-ONLY" and (not has_lead or has_p):
            errors.append(f"{fid}: origin CLAUDE-ONLY but raisers are {sorted(rs)} (needs the lead only)")
        elif origin == "CODEX-ONLY" and (has_lead or not has_p):
            errors.append(f"{fid}: origin CODEX-ONLY but raisers are {sorted(rs)} (needs participants only)")

    if errors:
        print("\n".join(errors))
        return 1
    print(f"OK rows={rows} ids={len(origins)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
