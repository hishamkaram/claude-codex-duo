#!/usr/bin/env python3
"""Validate review selection ledgers and set-level Codex exchange responses.

A reconciliation manifest has one tab-separated row per canonical finding:
    F-01<TAB>BOTH<TAB>P2

A selection ledger has one tab-separated row per manifest finding:
    F-01<TAB>BOTH<TAB>P2<TAB>INCLUDE<TAB>BOTH

The final column records the deciding selector predicate. Rows are complete and
machine-checkable: CONFLICT, BOTH, and provisional P0/P1 must be INCLUDE; all
other rows must be EXCLUDE. A successful response is one fenced JSON object
whose strict normalized dispositions cover exactly the included IDs.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

from review_common import ID_RE, ORIGINS, SEVERITIES, PROVENANCE_RE as FORBIDDEN_TEXT, citation_has_provenance, location_error

ACTIONS = {"MAINTAIN", "RETRACT", "REFINE", "VERIFY"}
ROOT_FIELDS = {"phase", "dispositions"}
DISPOSITION_FIELDS = {
    "id", "action", "claim", "severity", "locations", "trigger", "impact",
    "observations", "falsifier", "proposed_checks", "open_factual_questions",
}
LIST_FIELDS = {"locations", "observations", "proposed_checks", "open_factual_questions"}


def fail(message: str) -> None:
    # Callers use this prefix to distinguish a completed-but-noncanonical reply
    # from a launch failure. The validator still rejects every bad response.
    print(f"VALIDATION_CLASS={failure_class(message)}", file=sys.stderr)
    print(f"validate-consultation.py: {message}", file=sys.stderr)
    raise SystemExit(1)


def failure_class(message: str) -> str:
    """Return a stable class for a rejected response without weakening validation."""
    if "fenced json object" in message or "invalid JSON" in message or "response must be an object" in message:
        return "envelope"
    if "response must have only" in message or "must contain only normalized" in message or "disposition IDs differ" in message:
        return "schema"
    if "citation" in message or "provenance" in message or "artifact path" in message:
        return "citation"
    return "content"


def rows(path: Path, columns: int) -> list[list[str]]:
    result: list[list[str]] = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line or line.startswith("#") or line.startswith("STATUS:"):
            continue
        parts = line.split("\t")
        if len(parts) != columns or not all(parts):
            fail(f"{path}:{number}: expected {columns} non-empty tab-separated columns")
        result.append(parts)
    return result


def manifest(path: Path) -> dict[str, tuple[str, str]]:
    values: dict[str, tuple[str, str]] = {}
    for number, (finding_id, origin, severity) in enumerate(rows(path, 3), 1):
        if not ID_RE.fullmatch(finding_id) or origin not in ORIGINS or severity not in SEVERITIES:
            fail(f"{path}: row {number}: expected F-nn<TAB>origin<TAB>P0|P1|P2|P3")
        if finding_id in values:
            fail(f"{path}: row {number}: duplicate manifest row for {finding_id}")
        values[finding_id] = (origin, severity)
    return values


def ids_file(path: Path, finding_manifest: dict[str, tuple[str, str]], verdicts_path: Path) -> list[str]:
    values: list[str] = []
    # Read the Phase-5 verdict ledger: one F-nn<TAB>verdict line per finding.
    verdicts: dict[str, str] = {}
    for number, line in enumerate(verdicts_path.read_text(encoding="utf-8").splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 2 or not ID_RE.fullmatch(parts[0]):
            fail(f"{verdicts_path}: row {number}: expected F-nn<TAB>verdict[<TAB>method<TAB>evidence]")
        if parts[0] in verdicts:
            fail(f"{verdicts_path}: row {number}: duplicate verdict for {parts[0]}")
        verdicts[parts[0]] = parts[1].strip()  # the same tolerance as validate-verdicts.py and residual_count
    # Validate every verdict value, not just the residual IDs — the ledger
    # is a machine-readable audit artifact and must be well-formed throughout.
    for finding_id, verdict in verdicts.items():
        if verdict not in {"CONFIRMED", "REFUTED", "UNVERIFIABLE"}:
            fail(f"{verdicts_path}: {finding_id} has invalid verdict '{verdict}' (expected CONFIRMED, REFUTED, or UNVERIFIABLE)")
    if set(verdicts) != set(finding_manifest):
        fail(f"{verdicts_path}: verdict IDs differ from manifest (missing={sorted(set(finding_manifest) - set(verdicts)) or 'none'} extra={sorted(set(verdicts) - set(finding_manifest)) or 'none'})")
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if not ID_RE.fullmatch(line):
            fail(f"{path}: row {number}: expected one F-nn ID per line")
        if line not in finding_manifest:
            fail(f"{path}: row {number}: {line} is not in the reconciliation manifest")
        verdict = verdicts.get(line, "MISSING")
        if verdict != "UNVERIFIABLE":
            fail(f"{path}: row {number}: {line} is {verdict} in Phase 5, not UNVERIFIABLE")
        if line in values:
            fail(f"{path}: row {number}: duplicate id {line}")
        values.append(line)
    if not values:
        fail(f"{path}: no residual IDs listed")
    return values


def expected_decision(origin: str, severity: str) -> tuple[str, str]:
    if origin == "CONFLICT":
        return "INCLUDE", "CONFLICT"
    if origin == "BOTH":
        return "INCLUDE", "BOTH"
    if severity in {"P0", "P1"}:
        return "INCLUDE", f"provisional-{severity}"
    return "EXCLUDE", f"{origin}-{severity}"


def selection(path: Path, finding_manifest: dict[str, tuple[str, str]]) -> list[str]:
    values: dict[str, tuple[str, str, str, str]] = {}
    for number, (finding_id, origin, severity, decision, predicate) in enumerate(rows(path, 5), 1):
        if not ID_RE.fullmatch(finding_id) or origin not in ORIGINS or severity not in SEVERITIES:
            fail(f"{path}: row {number}: invalid finding ID, origin, or severity")
        if decision not in {"INCLUDE", "EXCLUDE"}:
            fail(f"{path}: row {number}: decision must be INCLUDE or EXCLUDE")
        if finding_id in values:
            fail(f"{path}: row {number}: duplicate selector row for {finding_id}")
        values[finding_id] = (origin, severity, decision, predicate)
    if set(values) != set(finding_manifest):
        missing = sorted(set(finding_manifest) - set(values))
        extra = sorted(set(values) - set(finding_manifest))
        fail(f"{path}: selector IDs differ from manifest (missing={missing or 'none'} extra={extra or 'none'})")
    selected: list[str] = []
    for finding_id, (origin, severity) in finding_manifest.items():
        row = values[finding_id]
        if row[:2] != (origin, severity):
            fail(f"{path}: {finding_id}: origin/severity differ from manifest")
        decision, predicate = expected_decision(origin, severity)
        if row[2:] != (decision, predicate):
            fail(f"{path}: {finding_id}: expected {decision}/{predicate}, got {row[2]}/{row[3]}")
        if decision == "INCLUDE":
            selected.append(finding_id)
    return selected


def json_block(text: str, source: Path) -> dict:
    blocks = re.findall(r"```json\s*(\{.*?\})\s*```", text, flags=re.DOTALL)
    if len(blocks) != 1:
        fail(f"{source}: expected exactly one fenced json object")
    try:
        value = json.loads(blocks[0])
    except json.JSONDecodeError as exc:
        fail(f"{source}: invalid JSON: {exc.msg}")
    if not isinstance(value, dict):
        fail(f"{source}: response must be an object")
    return value


def check_text(value: str, source: Path, index: int, field: str) -> None:
    if FORBIDDEN_TEXT.search(value):
        fail(f"{source}: disposition {index} {field} contains review provenance or artifact path")


def require_nonempty(value: str | list[str], source: Path, index: int, field: str) -> None:
    if isinstance(value, str) and not value.strip():
        fail(f"{source}: disposition {index} {field} must not be empty or blank")
    if isinstance(value, list) and field != "open_factual_questions" and (not value or not all(isinstance(item, str) and item.strip() for item in value)):
        fail(f"{source}: disposition {index} {field} must not be empty or contain blank strings")


def action_requirements(disposition: dict, source: Path, index: int) -> None:
    action = disposition["action"]
    for field in ("claim", "locations", "trigger", "impact", "observations", "falsifier", "proposed_checks"):
        require_nonempty(disposition[field], source, index, field)
    if action == "RETRACT" and not disposition["observations"]:
        fail(f"{source}: disposition {index} RETRACT needs a fact in observations")
    ofq = disposition["open_factual_questions"]
    if action == "VERIFY" and (not ofq or not all(isinstance(q, str) and q.strip() for q in ofq)):
        fail(f"{source}: disposition {index} VERIFY needs a non-blank open factual question")
    if action != "VERIFY" and ofq:
        fail(f"{source}: disposition {index} only VERIFY may leave open factual questions")



def validate_response(response: dict, expected: list[str], phase: str, source: Path) -> list[dict]:
    if set(response) != ROOT_FIELDS or response.get("phase") != phase or not isinstance(response.get("dispositions"), list):
        fail(f"{source}: response must have only phase={phase!r} and dispositions")
    dispositions = response["dispositions"]
    found: list[str] = []
    for index, disposition in enumerate(dispositions, 1):
        if not isinstance(disposition, dict) or set(disposition) != DISPOSITION_FIELDS:
            fail(f"{source}: disposition {index} must contain only normalized packet fields")
        finding_id = disposition["id"]
        if not isinstance(finding_id, str) or not ID_RE.fullmatch(finding_id):
            fail(f"{source}: disposition {index} has invalid id")
        if disposition["action"] not in ACTIONS:
            fail(f"{source}: disposition {index} action must be one of {', '.join(sorted(ACTIONS))}")
        if disposition["severity"] not in SEVERITIES:
            fail(f"{source}: disposition {index} severity must be P0, P1, P2, or P3")
        for field in DISPOSITION_FIELDS - {"id", "action", "severity"}:
            value = disposition[field]
            if field in LIST_FIELDS:
                if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
                    fail(f"{source}: disposition {index} {field} must be an array of strings")
                for item in value:
                    if field in ("locations", "observations"):
                        err = location_error(item)
                        if err:
                            fail(f"{source}: disposition {index} {field} {err}, got: {item[:80]}")
                        if citation_has_provenance(item):
                            fail(f"{source}: disposition {index} {field} contains review provenance or artifact path")
                    else:
                        check_text(item, source, index, field)
            elif not isinstance(value, str):
                fail(f"{source}: disposition {index} {field} must be a string")
            else:
                check_text(value, source, index, field)
        action_requirements(disposition, source, index)
        found.append(finding_id)
    if len(found) != len(set(found)):
        fail(f"{source}: duplicate disposition id")
    if set(found) != set(expected):
        missing = sorted(set(expected) - set(found))
        extra = sorted(set(found) - set(expected))
        fail(f"{source}: disposition IDs differ from selector (missing={missing or 'none'} extra={extra or 'none'})")
    return dispositions


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--selection", type=Path)
    parser.add_argument("--ids", type=Path, help="One residual F-nn ID per line")
    parser.add_argument("--verdicts", type=Path, help="Phase-5 verdict ledger: F-nn<TAB>verdict per line")
    parser.add_argument("--phase", choices=("consultation", "resolution"))
    parser.add_argument("--extract", type=Path, help="Raw Codex stdout")
    parser.add_argument("--out", type=Path, help="Validated normalized response JSON")
    parser.add_argument("--validate-selection", action="store_true")
    args = parser.parse_args()
    using_selector = bool(args.selection)
    if using_selector:
        if not args.manifest or not args.manifest.is_file() or not args.selection.is_file():
            fail("--manifest and --selection must be readable files together")
        selected = selection(args.selection, manifest(args.manifest))
    elif args.ids and args.ids.is_file():
        if not args.manifest or not args.manifest.is_file():
            fail("--ids requires a readable --manifest to check finding membership")
        if not args.verdicts or not args.verdicts.is_file():
            fail("--ids requires a readable --verdicts (the Phase-5 verdict ledger)")
        selected = ids_file(args.ids, manifest(args.manifest), args.verdicts)
    else:
        fail("provide readable --manifest/--selection or --manifest/--ids")
    if args.validate_selection:
        if args.extract or args.out or args.phase:
            fail("--validate-selection takes --manifest/--selection or --manifest/--verdicts/--ids only")
        print(f"OK selected={len(selected)}")
        return
    if not args.extract or not args.out or not args.phase:
        fail("--phase, --extract, and --out are required unless --validate-selection is used")
    if not args.extract.is_file():
        fail("--extract must be a readable file")
    response = json_block(args.extract.read_text(encoding="utf-8", errors="replace"), args.extract)
    dispositions = validate_response(response, selected, args.phase, args.extract)
    output = {"phase": args.phase, "selected_ids": sorted(selected), "dispositions": dispositions}
    temporary = args.out.with_name(args.out.name + ".tmp")
    temporary.write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")
    temporary.replace(args.out)
    print(f"OK phase={args.phase} selected={len(selected)} dispositions={len(dispositions)}")


if __name__ == "__main__":
    main()
