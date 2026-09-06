#!/usr/bin/env python3
"""Validate provenance-free normalized finding packets against the full matrix.

Used for the Phase-3 base packets (03-findings.ndjson) and the Phase-5 verifier
packets (05-verifier-packets.ndjson) alike: one JSON object per line, exactly one
per matrix ID, only the normalized fields."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from review_common import ID_RE, ORIGINS, SEVERITIES, PROVENANCE_RE, citation_has_provenance, location_error

FIELDS = {
    "id", "severity", "claim", "locations", "trigger", "impact", "observations",
    "falsifier", "proposed_checks", "open_factual_questions",
}
LIST_FIELDS = {"locations", "observations", "proposed_checks", "open_factual_questions"}


def fail(message: str) -> None:
    print(f"validate-verifier-packets.py: {message}", file=sys.stderr)
    raise SystemExit(1)


def matrix_severities(path: Path) -> dict[str, str]:
    """Return {finding_id: provisional severity} from 03-matrix.tsv."""
    result: dict[str, str] = {}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line or line.startswith("#") or line.startswith("STATUS:"):
            continue
        values = line.split("\t")
        if len(values) != 3 or not ID_RE.fullmatch(values[0]) or values[1] not in ORIGINS or values[2] not in SEVERITIES:
            fail(f"{path}:{number}: expected F-nn<TAB>origin<TAB>P0|P1|P2|P3")
        if values[0] in result:
            fail(f"{path}:{number}: duplicate matrix ID {values[0]}")
        result[values[0]] = values[2]
    return result


def matrix_ids(path: Path) -> set[str]:
    return set(matrix_severities(path))


def text_is_safe(value: str, record: int, field: str) -> None:
    if PROVENANCE_RE.search(value):
        fail(f"packet {record} {field} contains review provenance or artifact path")


def validate_value(value: object, record: int, field: str) -> None:
    if field in LIST_FIELDS:
        if not isinstance(value, list) or (field != "open_factual_questions" and not value) or not all(isinstance(item, str) and item.strip() for item in value):
            fail(f"packet {record} {field} must be a non-empty array of non-blank strings")
        for item in value:
            if field in ("locations", "observations"):
                err = location_error(item)
                if err:
                    fail(f"packet {record} {field} {err}, got: {item[:80]}")
                if citation_has_provenance(item):  # quote checked in full; path only for artifact shapes
                    fail(f"packet {record} {field} contains review provenance or artifact path")
            else:
                text_is_safe(item, record, field)
    elif not isinstance(value, str) or not value.strip():
        fail(f"packet {record} {field} must be a non-blank string")
    else:
        text_is_safe(value, record, field)


def load_packets(path: Path, expected: set[str], severities: dict[str, str] | None = None) -> dict[str, dict]:
    """Parse and validate one packet per matrix ID; return them in file order.

    With `severities` (the Phase-3 base packets), each packet's severity must
    equal the matrix's provisional severity (round-27 CX-04); post-consultation
    packets are exempt because REFINE may change severity. Shared with
    build-verifier-packets.py, which loads 03-findings.ndjson with the same rules
    before applying consultation dispositions."""
    found: dict[str, dict] = {}
    lines = path.read_text(encoding="utf-8").splitlines()
    for number, line in enumerate(lines, 1):
        if not line:
            continue
        try:
            packet = json.loads(line)
        except json.JSONDecodeError as exc:
            fail(f"{path}:{number}: invalid JSON: {exc.msg}")
        if not isinstance(packet, dict) or set(packet) != FIELDS:
            fail(f"{path}:{number}: packet must contain only normalized fields")
        finding_id = packet["id"]
        if not isinstance(finding_id, str) or not ID_RE.fullmatch(finding_id):
            fail(f"{path}:{number}: invalid finding ID")
        if packet["severity"] not in SEVERITIES:
            fail(f"{path}:{number}: severity must be P0, P1, P2, or P3")
        if severities is not None and finding_id in severities and packet["severity"] != severities[finding_id]:
            fail(f"{path}:{number}: {finding_id} severity {packet['severity']} differs from the matrix's provisional {severities[finding_id]}")
        for field in FIELDS - {"id", "severity"}:
            validate_value(packet[field], number, field)
        if finding_id in found:
            fail(f"{path}:{number}: duplicate packet ID {finding_id}")
        found[finding_id] = packet
    if set(found) != expected:
        fail(f"packet IDs differ from matrix (missing={sorted(expected - set(found)) or 'none'} extra={sorted(set(found) - expected) or 'none'})")
    return found


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--matrix", required=True, type=Path)
    parser.add_argument("--packets", required=True, type=Path)
    parser.add_argument("--match-matrix-severity", action="store_true", help="require each packet's severity to equal the matrix's (Phase-3 base packets)")
    args = parser.parse_args()
    if not args.matrix.is_file() or not args.packets.is_file():
        fail("--matrix and --packets must be readable files")
    severities = matrix_severities(args.matrix)
    found = load_packets(args.packets, set(severities), severities if args.match_matrix_severity else None)
    print(f"OK packets={len(found)}")


if __name__ == "__main__":
    main()
