#!/usr/bin/env python3
"""Build 05-verifier-packets.ndjson from the frozen Phase-3 base packets and the
validated Phase-4 consultation response.

    build-verifier-packets.py --matrix 03-matrix.tsv --base 03-findings.ndjson \\
        [--consultation 04-consultation.json] --out 05-verifier-packets.ndjson

Deterministic merge, one output packet per base packet, base order preserved:

  no consultation / SKIPPED   every packet is the base packet, unchanged
  MAINTAIN                    base packet unchanged
  REFINE                      the disposition's packet fields replace the base fields
  VERIFY, RETRACT             base packet, plus the disposition's observations,
                              proposed_checks and open_factual_questions appended
                              (deduplicated, order preserved); claim, severity,
                              locations, trigger, impact and falsifier stay as based

A retraction is not evidence: the verifier still tests the original claim and
only Phase 5 may record REFUTED. The action itself never reaches the output —
the verifier packet carries no disposition, origin, or provenance field.
`phase-gate.sh pre-verification` writes the file with this script; later gates
rebuild it and reject any difference.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from review_common import ID_RE  # noqa: E402

_spec = importlib.util.spec_from_file_location("validate_verifier_packets", HERE / "validate-verifier-packets.py")
_validator = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_validator)

ACTIONS = {"MAINTAIN", "RETRACT", "REFINE", "VERIFY"}
PACKET_FIELDS = _validator.FIELDS
APPEND_FIELDS = ("observations", "proposed_checks", "open_factual_questions")


def fail(message: str) -> None:
    print(f"build-verifier-packets.py: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_consultation(path: Path, base: dict[str, dict]) -> dict[str, dict]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"{path}: cannot read consultation response: {exc}")
    if not isinstance(data, dict) or data.get("phase") != "consultation" or not isinstance(data.get("dispositions"), list):
        fail(f"{path}: expected a validated consultation response (phase=consultation, dispositions=[...])")
    selected = data.get("selected_ids")
    if not isinstance(selected, list) or not all(isinstance(i, str) and ID_RE.fullmatch(i) for i in selected):
        fail(f"{path}: selected_ids must be a list of F-nn IDs")
    dispositions: dict[str, dict] = {}
    for index, disposition in enumerate(data["dispositions"], 1):
        if not isinstance(disposition, dict) or set(disposition) != PACKET_FIELDS | {"action"}:
            fail(f"{path}: disposition {index} must contain only normalized packet fields plus action")
        finding_id = disposition["id"]
        if finding_id not in base:
            fail(f"{path}: disposition {index} names {finding_id}, which has no base packet")
        if finding_id in dispositions:
            fail(f"{path}: duplicate disposition for {finding_id}")
        if disposition["action"] not in ACTIONS:
            fail(f"{path}: disposition {index} has invalid action {disposition['action']!r}")
        dispositions[finding_id] = disposition
    if set(dispositions) != set(selected):
        fail(f"{path}: disposition IDs differ from selected_ids")
    return dispositions


def merged(item_lists: list[list[str]]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for items in item_lists:
        for item in items:
            if item not in seen:
                seen.add(item)
                out.append(item)
    return out


def apply(base: dict, disposition: dict | None) -> dict:
    packet = {field: base[field] for field in PACKET_FIELDS}
    if disposition is None or disposition["action"] == "MAINTAIN":
        return packet
    if disposition["action"] == "REFINE":
        return {field: disposition[field] for field in PACKET_FIELDS}
    for field in APPEND_FIELDS:
        packet[field] = merged([base[field], disposition[field]])
    return packet


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--matrix", required=True, type=Path)
    parser.add_argument("--base", required=True, type=Path, help="03-findings.ndjson")
    parser.add_argument("--consultation", type=Path, help="04-consultation.json (omit when consultation was skipped)")
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    if not args.matrix.is_file() or not args.base.is_file():
        fail("--matrix and --base must be readable files")
    severities = _validator.matrix_severities(args.matrix)
    base = _validator.load_packets(args.base, set(severities), severities)
    dispositions: dict[str, dict] = {}
    if args.consultation is not None:
        if not args.consultation.is_file():
            fail("--consultation must be a readable file")
        dispositions = load_consultation(args.consultation, base)
    lines = [json.dumps(apply(packet, dispositions.get(finding_id)), ensure_ascii=False, sort_keys=True) for finding_id, packet in base.items()]
    temporary = args.out.with_name(args.out.name + ".tmp")
    temporary.write_text("\n".join(lines) + "\n", encoding="utf-8")
    temporary.replace(args.out)
    applied = sum(1 for d in dispositions.values() if d["action"] != "MAINTAIN")
    print(f"OK packets={len(lines)} dispositions={len(dispositions)} applied={applied}")


if __name__ == "__main__":
    main()
