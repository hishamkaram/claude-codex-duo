#!/usr/bin/env python3
"""validate-verdict.py — extract the JSON verdict from a Codex reply and enforce the
objection contract and the anti-flattery rules.

usage: validate-verdict.py --extract <reply.stdout> --out <verdict.json> --round <n> --role codex
                           [--repo <path>] [--prior <previous-round.json>]

A verdict that is not produced by this script from a runner `.stdout` is not a verdict.
Exit 0 = valid (summary printed), 1 = invalid (reasons on stderr), 2 = usage.
"""
import argparse, json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CITE = re.compile(r"(^|[\s`(])[A-Za-z_.][\w./\-]*\.\w+:\d+(-\d+)?(@[0-9a-f]{7,40})?|(^|\s)cmd:\s*\S+")
SHA_CITE = re.compile(r"[A-Za-z_.][\w./\-]*:\d+(-\d+)?@[0-9a-f]{7,40}")
PRAISE = re.compile(r"\b(great|excellent|as you (correctly|rightly)|well done|i (fully )?agree|"
                    r"good (catch|point|plan|idea)|solid plan|nice work|impressive)\b", re.I)
SEV = ["BLOCKER", "MAJOR", "MINOR", "NIT"]
CLASSES = {"FACT_ERROR", "MISSING_EVIDENCE", "ROOT_CAUSE_WRONG", "SUPERIOR_ALTERNATIVE",
           "RISK_UNMANAGED", "SCOPE", "TEST_GAP", "MIGRATION_UNSAFE"}
VERDICTS = {"APPROVE", "APPROVE_WITH_CONDITIONS", "REJECT", "NO_OPINION_INSUFFICIENT_EVIDENCE"}
RESOLUTIONS = {"SUSTAINED", "WITHDRAWN", "DOWNGRADED"}
CAUSE_CLASSES = {"violated_invariant", "missing_abstraction", "wrong_domain_model", "broken_contract", "absent_constraint"}
PR_VERDICTS = {"ONE_PR", "SPLIT", "INSUFFICIENT_EVIDENCE"}


def extract(text):
    blocks = re.findall(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.S)
    if not blocks:
        m = re.search(r"(\{.*\})", text, re.S)
        blocks = [m.group(1)] if m else []
    for b in reversed(blocks):
        try:
            return json.loads(b)
        except json.JSONDecodeError:
            continue
    return None


def has_cite(strings):
    return any(CITE.search(str(x)) for x in strings)


def validate(v, round_, role, prior):
    e, warn = [], []
    if not isinstance(v, dict):
        return ["top level is not a JSON object"], warn
    if v.get("verdict") not in VERDICTS:
        e.append(f"verdict not in {sorted(VERDICTS)}")
    if role and v.get("role") != role:
        e.append(f"role must be {role!r}")
    if round_ is not None and v.get("round") != round_:
        e.append(f"round must be {round_}")
    att = v.get("attestations") or {}
    checks, files = att.get("checks_performed") or [], att.get("files_read") or []
    if not checks:
        e.append("attestations.checks_performed is empty")
    if not files and v.get("verdict") != "NO_OPINION_INSUFFICIENT_EVIDENCE":
        e.append("attestations.files_read is empty: no evidence of independent reading")

    objs = v.get("objections") or []
    seen = set()
    for o in objs:
        oid = o.get("id", "?")
        if oid in seen:
            e.append(f"{oid}: duplicate objection id")
        seen.add(oid)
        if o.get("class") not in CLASSES:
            e.append(f"{oid}: bad class {o.get('class')!r}")
        if o.get("severity") not in SEV:
            e.append(f"{oid}: bad severity {o.get('severity')!r}")
        if not (o.get("claim") or "").strip():
            e.append(f"{oid}: missing claim")
        ev = o.get("evidence") or []
        if not ev:
            e.append(f"{oid}: no evidence[]")
        elif not has_cite(ev):
            e.append(f"{oid}: evidence has no path:line or cmd: citation")
        if not (o.get("falsifier") or "").strip():
            e.append(f"{oid}: missing falsifier")
        if not (o.get("proposed_change") or "").strip():
            e.append(f"{oid}: missing proposed_change")
        if o.get("severity") in ("BLOCKER", "MAJOR") and ev and all("hypothes" in str(x).lower() for x in ev):
            e.append(f"{oid}: hypothesis-only objection cannot be BLOCKER/MAJOR")

    if v.get("verdict") == "APPROVE" and not objs:
        if not (att.get("adversarial_attempt") or "").strip():
            e.append("bare APPROVE requires attestations.adversarial_attempt")
        if len(checks) < 3:
            e.append("bare APPROVE requires at least 3 checks_performed")

    for cp in v.get("changed_positions") or []:
        because = str(cp.get("because", ""))
        if not CITE.search(because) and not re.search(r"\b[FVIUX]-\d+\b", because):
            e.append(f"changed_positions[{cp.get('objection_id', '?')}]: evidence-free concession")

    for r in v.get("objection_resolutions") or []:
        rid = r.get("id", "?")
        if r.get("status") not in RESOLUTIONS:
            e.append(f"objection_resolutions[{rid}]: status not in {sorted(RESOLUTIONS)}")
        if r.get("status") in ("WITHDRAWN", "DOWNGRADED"):
            because = str(r.get("because", ""))
            if not CITE.search(because) and not re.search(r"\b[FVIUX]-\d+\b", because):
                e.append(f"objection_resolutions[{rid}]: {r.get('status')} without a citation or evidence id")

    if round_ == 0 and role == "codex":
        for k in ("root_causes", "designs", "single_pr_recommendation"):
            if not v.get(k):
                e.append(f"round 0 requires independent {k}")
        for rc in v.get("root_causes") or []:
            if rc.get("cause_class") not in CAUSE_CLASSES:
                e.append(f"root_causes[{rc.get('id', '?')}]: cause_class not in {sorted(CAUSE_CLASSES)}")
            if not has_cite(rc.get("evidence") or []):
                e.append(f"root_causes[{rc.get('id', '?')}]: no path:line or cmd: evidence")
        if len(v.get("designs") or []) < 2:
            e.append("round 0 requires at least 2 designs")
        spr = v.get("single_pr_recommendation") or {}
        if isinstance(spr, dict) and spr.get("verdict") not in PR_VERDICTS:
            e.append(f"single_pr_recommendation.verdict not in {sorted(PR_VERDICTS)}")
    elif round_ and round_ >= 2 and prior:
        prior_ids = {o.get("id") for o in prior.get("objections") or []}
        res_ids = {r.get("id") for r in v.get("objection_resolutions") or []}
        missing = sorted(prior_ids - res_ids - {None})
        if missing:
            e.append("round %d must resolve every prior objection; missing: %s" % (round_, ", ".join(missing)))

    if PRAISE.search(json.dumps(v)):
        e.append("praise/agreement language present: strip it and state the evidence instead")

    # Concession ledger: capture in either direction is flagged, never silently accepted.
    if prior:
        prior_objs = prior.get("objections") or []
        if len(prior_objs) >= 3:
            withdrawn = [r for r in v.get("objection_resolutions") or [] if r.get("status") == "WITHDRAWN"]
            if len(withdrawn) / len(prior_objs) > 0.8:
                if not any(SHA_CITE.search(str(r.get("because", ""))) for r in withdrawn):
                    warn.append("CAPTURE_SUSPECTED: >80%% of prior objections withdrawn without a new sha-pinned citation "
                                "— re-derive the two most consequential disputed facts with the fact-checker")
    return e, warn


def check_citations(v, repo):
    """Run check-citations.py on every sha-pinned citation Codex offered."""
    lines = []
    for o in v.get("objections") or []:
        for x in o.get("evidence") or []:
            if SHA_CITE.search(str(x)):
                lines.append(str(x))
    for rc in v.get("root_causes") or []:
        for x in rc.get("evidence") or []:
            if SHA_CITE.search(str(x)):
                lines.append(str(x))
    if not lines:
        return [], 0
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as t:
        t.write("\n".join(lines) + "\n"); tmp = t.name
    try:
        r = subprocess.run([sys.executable, os.path.join(HERE, "check-citations.py"), "--repo", repo, tmp],
                           capture_output=True, text=True)
    finally:
        os.unlink(tmp)
    if r.returncode == 0:
        return [], len(lines)
    return [l[2:].replace(tmp + ":", "codex citation #") for l in r.stderr.splitlines() if l.startswith("- ")], len(lines)


def main():
    p = argparse.ArgumentParser(add_help=False)
    p.add_argument("--extract"); p.add_argument("--out"); p.add_argument("--round", type=int)
    p.add_argument("--role", default="codex"); p.add_argument("--repo"); p.add_argument("--prior")
    try:
        a = p.parse_args()
    except SystemExit:
        return 2
    if not a.extract or a.round is None:
        print("usage: validate-verdict.py --extract <reply.stdout> --out <verdict.json> --round <n> --role codex [--repo <path>] [--prior <json>]", file=sys.stderr)
        return 2
    if not os.path.isfile(a.extract):
        print(f"validate-verdict.py: not readable: {a.extract}", file=sys.stderr); return 2
    prior = None
    if a.prior:
        if not os.path.isfile(a.prior):
            print(f"validate-verdict.py: --prior not readable: {a.prior}", file=sys.stderr); return 2
        prior = json.load(open(a.prior, encoding="utf-8"))
    v = extract(open(a.extract, encoding="utf-8", errors="replace").read())
    if v is None:
        print("FAIL: no parseable JSON object in the reply", file=sys.stderr); return 1
    errs, warns = validate(v, a.round, a.role, prior)
    cited = 0
    if a.repo and not errs:
        cite_fails, cited = check_citations(v, a.repo)
        errs.extend(cite_fails)
    if errs:
        print("FAIL:\n- " + "\n- ".join(errs), file=sys.stderr); return 1
    if warns:
        v.setdefault("flags", []).extend(w.split(":")[0] for w in warns)
        for w in warns:
            print("WARN " + w, file=sys.stderr)
    if a.out:
        json.dump(v, open(a.out, "w", encoding="utf-8"), indent=2); open(a.out, "a").write("\n")
    o = v.get("objections") or []
    counts = " ".join(f"{s.lower()}={sum(1 for x in o if x.get('severity') == s)}" for s in SEV)
    print(f"OK verdict={v['verdict']} objections={len(o)} {counts} "
          f"changed_positions={len(v.get('changed_positions') or [])} sha_citations_verified={cited}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
