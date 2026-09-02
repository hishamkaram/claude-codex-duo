#!/usr/bin/env python3
"""duo_common.py — the one citation grammar and the one debate-state reducer shared by
check-citations.py, lint-claims.py, validate-verdict.py and debate-status.py.

Review finding 2026-09-02: four scripts carried four slightly different citation regexes
(one made the SHA optional, one demanded a file extension) and two of them kept debate
state per round instead of cumulatively. Everything below is import-only; running this
file prints the grammar and exits 0.
"""
import glob, json, os, re

# A code citation always pins a commit: `path:lines@sha`. Paths are ordinary git paths
# (dot-files and extensionless files included). Backticks optional.
CITE_RE = re.compile(r"`?(?P<path>[A-Za-z_.][\w./\-]*):(?P<a>\d+)(?:-(?P<b>\d+))?@(?P<sha>[0-9a-f]{7,40})`?")
# An executed check: `cmd: <command> -> <excerpt>`.
CMD_RE = re.compile(r"(^|[\s`(])cmd:\s*\S+")
# Evidence ids: F- facts, V- verified, I- inferences, U- unknowns, X- Codex objections, RC- root causes.
ID_RE = re.compile(r"\b(F|V|I|U|X|RC)-(\d+)\b")
HARD_ID_RE = re.compile(r"\b[FV]-\d+\b")   # ids a decision may rest on


def has_citation(strings):
    """True if any string carries a sha-pinned code citation or a cmd: record."""
    return any(CITE_RE.search(str(x)) or CMD_RE.search(str(x)) for x in strings)


def has_evidence_ref(text):
    """A citation, a cmd:, or an evidence id — what a concession or rationale must carry."""
    t = str(text)
    return bool(CITE_RE.search(t) or CMD_RE.search(t) or ID_RE.search(t))


def load_rounds(art):
    """{round: verdict} for every validated debate/r<n>-codex.json under an artifact dir."""
    rounds = {}
    for f in glob.glob(os.path.join(art, "debate", "r*-codex.json")):
        m = re.search(r"r(\d+)-codex\.json$", os.path.basename(f))
        if m:
            rounds[int(m.group(1))] = json.load(open(f, encoding="utf-8"))
    return dict(sorted(rounds.items()))


def fold(rounds):
    """Cumulative objection state across rounds, in round order.

    Returns {id: {"round": raised_in, "obj": objection, "status": OPEN|SUSTAINED|WITHDRAWN|DOWNGRADED,
                  "severity": current severity, "resolved_in": round or None}}.
    A resolution applies to the objection outstanding under that id; an id raised again in
    a later round starts a new OPEN objection (Codex reuses ids — observed 2026-09-02).
    A WITHDRAWN objection stays withdrawn unless re-raised; a later round need not repeat it.
    """
    state = {}
    for n in sorted(rounds):
        v = rounds[n] or {}
        for r in v.get("objection_resolutions") or []:
            oid, st = r.get("id"), r.get("status")
            if oid in state and st in ("SUSTAINED", "WITHDRAWN", "DOWNGRADED"):
                state[oid]["status"] = st
                state[oid]["resolved_in"] = n
                if st == "DOWNGRADED" and r.get("severity"):
                    state[oid]["severity"] = r["severity"]
        for o in v.get("objections") or []:
            oid = o.get("id")
            state[oid] = {"round": n, "obj": o, "status": "OPEN", "severity": o.get("severity"), "resolved_in": None}
    return state


def outstanding(state):
    """Objections that still need an answer: everything not WITHDRAWN."""
    return {k: s for k, s in state.items() if s["status"] != "WITHDRAWN"}


if __name__ == "__main__":
    print("citation grammar:", CITE_RE.pattern)
    print("command grammar:", CMD_RE.pattern)
