#!/usr/bin/env python3
"""next-opponent.py — the moderator's scheduler for an N-participant debate (codex-debate 1.2.0).

  next-opponent.py --art <dir> --rounds <per-pair cap> [--total-rounds <global cap>]

Reads, from the artifact directory:
  00-participants.tsv     p<k><TAB>codex|ccr<TAB>alias-or-dash   (the opponents, in order)
  03-ledger.md            the living ledger: a markdown table
                          | ID | Owner | Claim | Grade | Evidence | Status | Changed in |
                          Owner is claude | p<k> | seed; Grade E0..E4; Status one of the protocol's
                          (OPEN, VERIFY-PENDING, CONCEDED-BY-CLAUDE, CONCEDED-BY-P<k>, VERIFIED-TRUE,
                          VERIFIED-FALSE, SUPERSEDED-BY <id>, UNRESOLVED, LATE); "Changed in" is r<n>.
  03-round-<n>-p<k>.md    one file per pairwise round already held (n = global round number)

Prints exactly one line:
  NEXT p<k> round=<n> pair_round=<m> score=<s> reason=<why>     — hold round n against p<k>
  DONE <reason>                                                 — every pair terminated
  UNRESOLVED-GLOBAL p<i> p<j> …                                 — the global budget is spent while
                                                                  these pairs are not terminated

Rules (references/protocol.md §N participants):
  * dissent score of p<k> = Σ over its OPEN/VERIFY-PENDING rows of weight(grade), E0=4 E1=3 E2=2
    E3=1 E4=0, counting only rows that name a C-nn id (they attack a Claude claim); a participant
    with no such row scores over all its open rows instead; the highest score is picked, ties by
    lowest k;
  * one-turn coverage: a participant already faced since the last time every eligible
    participant had a turn is skipped, unless it has a VERIFY-PENDING row (the one exception);
  * a pair terminates by convergence (no open row of that participant), stalemate (its last two
    rounds changed no row), or its own cap (`--rounds`, hard cap 5); the global cap
    (`--total-rounds`, default N × rounds, hard cap 5 × N) never converts an unfinished pair into
    a converged one: it prints UNRESOLVED-GLOBAL for what is left.
Exit 0 on NEXT/DONE/UNRESOLVED-GLOBAL, 2 on a usage or file error.
"""
from __future__ import annotations

import os
import re
import sys

WEIGHT = {"E0": 4, "E1": 3, "E2": 2, "E3": 1, "E4": 0}
OPEN = ("OPEN", "VERIFY-PENDING")
C_ID = re.compile(r"\bC-\d+\b")
ROUND_FILE = re.compile(r"^03-round-(\d+)-(p\d+)\.md$")


def die(msg: str) -> None:
    print(f"next-opponent.py: {msg}", file=sys.stderr)
    sys.exit(2)


def read_participants(path: str) -> list[str]:
    try:
        rows = [l.split("\t") for l in open(path, encoding="utf-8").read().splitlines() if l.strip()]
    except OSError as e:
        die(f"cannot read participants: {e}")
    ids = [r[0].strip() for r in rows]
    for i, pid in enumerate(ids, 1):
        if pid != f"p{i}":
            die(f"participants row {i}: expected p{i}, got {pid}")
    if not ids:
        die("no participants")
    return ids


def read_ledger(path: str) -> list[dict]:
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError as e:
        die(f"cannot read ledger: {e}")
    rows = []
    for line in lines:
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 7 or cells[0] in ("ID", "") or set(cells[0]) <= {"-", ":"}:
            continue
        rows.append({"id": cells[0], "owner": cells[1].lower(), "claim": cells[2], "grade": cells[3].upper(),
                     "evidence": cells[4], "status": cells[5].upper(), "changed": cells[6]})
    return rows


def history(art: str) -> list[tuple[int, str]]:
    out = []
    for name in os.listdir(art):
        m = ROUND_FILE.match(name)
        if m:
            out.append((int(m.group(1)), m.group(2)))
    return sorted(out)


def main(argv: list[str]) -> int:
    art = rounds = total = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--art", "--rounds", "--total-rounds"):
            if i + 1 >= len(argv):
                die(f"{a} requires a value")
            v = argv[i + 1]
            if a == "--art":
                art = v
            elif a == "--rounds":
                rounds = v
            else:
                total = v
            i += 2
        else:
            die(f"unknown arg {a}")
    if not art or not rounds:
        die("--art and --rounds are required")
    if not rounds.isdigit() or not 1 <= int(rounds) <= 5:
        die("--rounds must be 1..5")
    rounds_n = int(rounds)
    parts = read_participants(os.path.join(art, "00-participants.tsv"))
    n = len(parts)
    if total is None:
        total_n = n * rounds_n
    elif not total.isdigit() or int(total) < 1:
        die("--total-rounds must be a positive whole number")
    else:
        total_n = min(int(total), 5 * n)
    ledger = read_ledger(os.path.join(art, "03-ledger.md"))
    hist = history(art)
    held = {p: [r for r, q in hist if q == p] for p in parts}
    global_round = len(hist)
    if any(r != k + 1 for k, (r, _) in enumerate(hist)):
        die("round files are not numbered 1..n without gaps: " + ", ".join(f"r{r}-{q}" for r, q in hist))

    def open_rows(p: str) -> list[dict]:
        return [r for r in ledger if r["owner"] == p and r["status"] in OPEN]

    def score(p: str) -> int:
        rows = open_rows(p)
        attacking = [r for r in rows if C_ID.search(r["claim"] + " " + r["evidence"])]
        return sum(WEIGHT.get(r["grade"], 0) for r in (attacking or rows))

    def changed_in(p: str, rnd: int) -> bool:
        # Round rnd was held against p by construction of hist, so every row changed in it — the
        # opponent's or a Claude claim conceded, verified or superseded — moved that pair; a
        # stalemate is "pure MAINTAIN on both sides" (protocol.md), not "the opponent did not move"
        # (review round 1: F-03).
        tag = f"r{rnd}"
        return any(r["changed"] == tag for r in ledger)

    def terminal(p: str) -> str | None:
        if not open_rows(p):
            return "convergence"
        if len(held[p]) >= rounds_n:
            return "pair cap"
        last = held[p][-2:]
        if len(last) == 2 and not any(changed_in(p, r) for r in last) and not any(r["status"] == "VERIFY-PENDING" for r in open_rows(p)):
            return "stalemate"
        return None

    states = {p: terminal(p) for p in parts}
    eligible = [p for p in parts if states[p] is None]
    if not eligible:
        print("DONE " + "; ".join(f"{p}:{states[p]}" for p in parts))
        return 0
    if global_round >= total_n:
        print("UNRESOLVED-GLOBAL " + " ".join(eligible) + f" (global budget {total_n} spent; " + "; ".join(f"{p}:{states[p] or 'open'}" for p in parts) + ")")
        return 0
    # one-turn coverage: the current cycle is the tail of the history since the last point at
    # which every eligible participant had been faced at least once.
    # Walk the history forwards: a cycle closes when every currently eligible participant has been
    # faced once, and what follows the last closed cycle is the cycle in progress (review round 1:
    # F-15 — a backward scan could reach the previous complete cycle and clear the current one).
    faced: set[str] = set()
    for _, q in hist:
        if q in eligible:
            faced.add(q)
        if faced >= set(eligible):
            faced = set()
    verify_pending = [p for p in eligible if any(r["status"] == "VERIFY-PENDING" for r in open_rows(p))]
    if verify_pending and hist and hist[-1][1] in verify_pending:
        pick, why = hist[-1][1], "VERIFY pending with the participant just faced"
    else:
        pool = [p for p in eligible if p not in faced] or eligible
        pool.sort(key=lambda p: (-score(p), int(p[1:])))
        pick = pool[0]
        why = "highest dissent score" + (", coverage turn" if faced else "") + (", tie by lowest k" if len(pool) > 1 and score(pool[1]) == score(pick) else "")
    print(f"NEXT {pick} round={global_round + 1} pair_round={len(held[pick]) + 1} score={score(pick)} reason={why}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
