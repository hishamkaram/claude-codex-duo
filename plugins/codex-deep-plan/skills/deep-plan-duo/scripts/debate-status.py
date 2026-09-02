#!/usr/bin/env python3
"""debate-status.py — one screen of convergence facts across the debate rounds so the
caller never has to read a raw Codex transcript to decide what happens next.

usage: debate-status.py --art <artifact-dir>

Reads debate/r<n>-codex.json (validated verdicts), meta.json (round cap) and
05-disagreements.md (the caller's side of the ledger). Objection state is folded
cumulatively across rounds (duo_common.fold): a WITHDRAWN objection stays withdrawn unless
re-raised. Prints the termination condition reached, if any: T1 converged · T2 round cap ·
T3 no new information for two rounds · T4 a BLOCKER whose falsifier needs a human decision.
T5 (Codex unavailable) is decided by the runner's exit code, not here.
Exit 0 always unless usage (2) or no rounds (1).
"""
import json, os, re, sys

sys.dont_write_bytecode = True   # never write __pycache__ into the plugin (validator check 5, review F-14)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from duo_common import CITE_RE, load_rounds, fold, outstanding  # noqa: E402

HUMAN = re.compile(r"\b(human|product|business|stakeholder|owner)\b.*\b(decide|decision|choose|choice|prefer)\b|"
                   r"\b(decide|decision|choose|choice)\b.*\b(human|product|business|stakeholder|owner)\b", re.I)


def norm(s):
    return re.sub(r"\W+", " ", str(s)).strip().lower()


def citations(v):
    out = set()
    for o in v.get("objections") or []:
        for x in o.get("evidence") or []:
            out.update(c.group(0) for c in CITE_RE.finditer(str(x)))
    for rc in v.get("root_causes") or []:
        for x in rc.get("evidence") or []:
            out.update(c.group(0) for c in CITE_RE.finditer(str(x)))
    return out


def open_ledger_rows(art):
    """Rows of 05-disagreements.md whose status column is OPEN (format in references/debate-protocol.md)."""
    f = os.path.join(art, "05-disagreements.md")
    if not os.path.isfile(f):
        return None
    rows = []
    for line in open(f, encoding="utf-8", errors="replace"):
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if cells and re.match(r"^D-\d+$", cells[0]) and any(c == "OPEN" for c in cells[1:]):
            rows.append(cells[0])
    return rows


def main(argv):
    if len(argv) != 2 or argv[0] != "--art" or argv[1].startswith("-"):
        print("usage: debate-status.py --art <artifact-dir>", file=sys.stderr); return 2
    art = argv[1]
    if not os.path.isdir(art):
        print(f"debate-status.py: not a directory: {art}", file=sys.stderr); return 2
    rounds = load_rounds(art)
    if not rounds:
        print("STATUS: NO_ROUNDS (no debate/r*-codex.json found)"); return 1
    meta = {}
    mp = os.path.join(art, "meta.json")
    if os.path.isfile(mp):
        meta = json.load(open(mp, encoding="utf-8"))
    cap = int(meta.get("rounds") or 2)

    # New-information streak: a round adds information if it raises a new claim, a new class,
    # a new citation, or records a changed position.
    prev_claims, prev_classes, prev_cites = set(), set(), set()
    streak, per_round = 0, []
    for n, v in rounds.items():
        objs = v.get("objections") or []
        claims = {norm(o.get("claim")) for o in objs}
        classes = {o.get("class") for o in objs}
        cites = citations(v)
        changed = v.get("changed_positions") or []
        new_objs = [o for o in objs if norm(o.get("claim")) not in prev_claims]
        new_info = bool(new_objs) or bool(classes - prev_classes) or bool(cites - prev_cites) or bool(changed)
        if n > 0:
            streak = 0 if new_info else streak + 1
        per_round.append((n, v, new_objs, changed, new_info))
        prev_claims |= claims; prev_classes |= classes; prev_cites |= cites

    n, v, new_objs, changed, new_info = per_round[-1]
    state = outstanding(fold(rounds))
    open_objs = [(oid, s["severity"], s["obj"].get("claim", ""), s["obj"].get("falsifier", "")) for oid, s in state.items()]
    blockers = [r for r in open_objs if r[1] == "BLOCKER"]
    majors = [r for r in open_objs if r[1] == "MAJOR"]
    ledger_open = open_ledger_rows(art)
    t4 = [r for r in blockers if HUMAN.search(r[3] or "")]

    term = "none"
    if v.get("verdict") in ("APPROVE", "APPROVE_WITH_CONDITIONS") and not blockers and not majors and not (ledger_open or []):
        term = "T1"
    elif t4:
        term = "T4"
    elif n >= cap:
        term = "T2"
    elif streak >= 2:
        term = "T3"

    def one(s, w=110):
        s = re.sub(r"\s+", " ", str(s)).strip()
        return s if len(s) <= w else s[:w - 1] + "…"

    print(f"STATUS: OK round={n} cap={cap} rounds_run={sorted(rounds)}")
    print(f"VERDICT: {v.get('verdict')}")
    print("NEW_BLOCKERS: " + ("; ".join(f"{o.get('id')}: {one(o.get('claim'))}" for o in new_objs if o.get("severity") == "BLOCKER") or "none"))
    print("NEW_MAJORS: " + ("; ".join(f"{o.get('id')}: {one(o.get('claim'))}" for o in new_objs if o.get("severity") == "MAJOR") or "none"))
    print("OPEN_BLOCKERS: " + ("; ".join(f"{r[0]}: {one(r[2])}" for r in blockers) or "none"))
    print("OPEN_MAJORS: " + ("; ".join(f"{r[0]}: {one(r[2])}" for r in majors) or "none"))
    print("CHANGED_POSITIONS: " + ("; ".join(f"{c.get('objection_id')}: {one(c.get('from'), 40)} -> {one(c.get('to'), 40)}" for c in changed) or "none"))
    print("EVIDENCE_REQUESTS: " + ("; ".join(f"{r.get('id')}: {one(r.get('claim'))}" for r in v.get("evidence_requests") or []) or "none"))
    print("FLAGS: " + (", ".join(v.get("flags") or []) or "none"))
    print("LEDGER_OPEN: " + ("n/a (05-disagreements.md absent)" if ledger_open is None else (", ".join(ledger_open) or "none")))
    print(f"CONVERGENCE: new_info={'yes' if new_info else 'no'} rounds_without_new_info={streak} termination={term}")
    if t4:
        print("T4_CANDIDATES: " + "; ".join(f"{r[0]}: falsifier={one(r[3], 80)}" for r in t4))
    print(f"FILE: {os.path.join(art, 'debate', f'r{n}-codex.json')}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
