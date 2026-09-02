#!/usr/bin/env python3
"""validate-verdict.py — extract the JSON verdict from a Codex reply and enforce the
objection contract, the round-0 shape, resolution completeness, and the anti-flattery rules.

usage: validate-verdict.py --extract <reply.stdout> --out <verdict.json> --round <n> --role codex
                           [--repo <path>] [--base-sha <sha>] [--art <dir>] [--prior <json>]

--art defaults to the parent of the reply's directory (…/debate/r<n>-codex.stdout → …);
its meta.json supplies --repo and --base-sha, and its debate/r<k>-codex.json files (k < n)
supply the outstanding objections that round n must resolve. --prior adds one more
earlier verdict (used by tests and by callers without an artifact dir).

A verdict that is not produced by this script from a runner `.stdout` is not a verdict.
Exit 0 = valid (summary printed), 1 = invalid (reasons on stderr), 2 = usage.
"""
import argparse, json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True   # never write __pycache__ into the plugin (validator check 5, review F-14)
sys.path.insert(0, HERE)
from duo_common import CITE_RE, has_citation, has_evidence_ref, load_rounds, fold, outstanding  # noqa: E402

PRAISE = re.compile(r"\b(great|excellent|as you (correctly|rightly)|well done|i (fully )?agree|"
                    r"good (catch|point|plan|idea)|solid plan|nice work|impressive)\b", re.I)
PROSE_KEYS = ("summary", "claim", "proposed_change", "because", "adversarial_attempt", "statement",
              "one_sentence", "from", "to", "risks", "blast_radius", "reversibility", "how_to_verify")
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


def nonempty_str(x):
    return isinstance(x, str) and x.strip() != ""


def str_list(x):
    return isinstance(x, list) and len(x) > 0 and all(nonempty_str(i) for i in x)


def prose(v):
    """Codex's own words: every prose-keyed string anywhere in the verdict. Evidence strings,
    file lists and command records are quoted material and are excluded (review finding F-13)."""
    out = []

    def walk(x):
        if isinstance(x, dict):
            for k, val in x.items():
                if k in PROSE_KEYS and isinstance(val, str):
                    out.append(val)
                elif k not in ("evidence", "files_read", "checks_performed", "files"):
                    walk(val)
        elif isinstance(x, list):
            for i in x:
                walk(i)
    walk(v)
    return "\n".join(out)


def check_objection(o, e):
    oid = o.get("id", "?")
    if not nonempty_str(o.get("id")):
        e.append("objection without an id")
    if o.get("class") not in CLASSES:
        e.append(f"{oid}: bad class {o.get('class')!r}")
    if o.get("severity") not in SEV:
        e.append(f"{oid}: bad severity {o.get('severity')!r}")
    if not nonempty_str(o.get("claim")):
        e.append(f"{oid}: missing claim")
    ev = o.get("evidence") or []
    if not isinstance(ev, list) or not ev:
        e.append(f"{oid}: no evidence[]")
    elif not has_citation(ev):
        e.append(f"{oid}: evidence has no sha-pinned path:lines@sha or cmd: citation")
    if not nonempty_str(o.get("falsifier")):
        e.append(f"{oid}: missing falsifier")
    if not nonempty_str(o.get("proposed_change")):
        e.append(f"{oid}: missing proposed_change")
    if o.get("severity") in ("BLOCKER", "MAJOR") and ev and all("hypothes" in str(x).lower() for x in ev):
        e.append(f"{oid}: hypothesis-only objection cannot be BLOCKER/MAJOR")


def check_round0(v, e):
    """Round 0 must be a complete independent analysis (review finding F-05)."""
    rcs = v.get("root_causes")
    if not isinstance(rcs, list) or not rcs:
        e.append("round 0 requires independent root_causes[]"); rcs = []
    rc_ids = set()
    for i, rc in enumerate(rcs):
        rid = rc.get("id") if isinstance(rc, dict) else None
        tag = rid or f"root_causes[{i}]"
        if not isinstance(rc, dict) or not nonempty_str(rid):
            e.append(f"{tag}: root cause without an id"); continue
        rc_ids.add(rid)
        if rc.get("cause_class") not in CAUSE_CLASSES:
            e.append(f"{tag}: cause_class not in {sorted(CAUSE_CLASSES)}")
        if not nonempty_str(rc.get("statement")):
            e.append(f"{tag}: missing statement")
        if not str_list(rc.get("explains")):
            e.append(f"{tag}: explains[] must name at least one input")
        if not has_citation(rc.get("evidence") or []):
            e.append(f"{tag}: no sha-pinned path:line or cmd: evidence")
    ds = v.get("designs")
    if not isinstance(ds, list) or len(ds) < 2:
        e.append("round 0 requires at least 2 designs"); ds = ds if isinstance(ds, list) else []
    preferred = 0
    for i, d in enumerate(ds):
        did = d.get("id") if isinstance(d, dict) else None
        tag = did or f"designs[{i}]"
        if not isinstance(d, dict) or not nonempty_str(did):
            e.append(f"{tag}: design without an id"); continue
        for k in ("one_sentence", "blast_radius", "reversibility", "risks"):
            if not nonempty_str(d.get(k)):
                e.append(f"{tag}: missing {k}")
        if not str_list(d.get("files")):
            e.append(f"{tag}: files[] must list at least one path")
        adds = d.get("addresses")
        if not str_list(adds):
            e.append(f"{tag}: addresses[] must reference root cause ids")
        elif rc_ids and not set(adds) <= rc_ids:
            e.append(f"{tag}: addresses unknown root cause(s) {sorted(set(adds) - rc_ids)}")
        if not isinstance(d.get("preferred"), bool):
            e.append(f"{tag}: preferred must be true or false")
        elif d["preferred"]:
            preferred += 1
    if ds and preferred != 1:
        e.append(f"exactly one design must be preferred (found {preferred})")
    spr = v.get("single_pr_recommendation")
    if not isinstance(spr, dict):
        e.append("round 0 requires single_pr_recommendation {verdict, because}")
    else:
        if spr.get("verdict") not in PR_VERDICTS:
            e.append(f"single_pr_recommendation.verdict not in {sorted(PR_VERDICTS)}")
        if not nonempty_str(spr.get("because")) or not (has_evidence_ref(spr["because"]) or any(r in spr["because"] for r in rc_ids)):
            e.append("single_pr_recommendation.because must cite evidence or a root cause id")


def validate(v, round_, role, prior_rounds):
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
        if not isinstance(o, dict):
            e.append("objection is not an object"); continue
        if o.get("id") in seen:
            e.append(f"{o.get('id')}: duplicate objection id")
        seen.add(o.get("id"))
        check_objection(o, e)

    if v.get("verdict") == "APPROVE" and not objs:
        if not nonempty_str(att.get("adversarial_attempt")):
            e.append("bare APPROVE requires attestations.adversarial_attempt")
        if len(checks) < 3:
            e.append("bare APPROVE requires at least 3 checks_performed")

    for cp in v.get("changed_positions") or []:
        if not has_evidence_ref(cp.get("because", "")):
            e.append(f"changed_positions[{cp.get('objection_id', '?')}]: evidence-free concession")

    res_ids = set()
    for r in v.get("objection_resolutions") or []:
        rid = r.get("id", "?")
        res_ids.add(rid)
        if r.get("status") not in RESOLUTIONS:
            e.append(f"objection_resolutions[{rid}]: status not in {sorted(RESOLUTIONS)}")
        if r.get("status") in ("WITHDRAWN", "DOWNGRADED") and not has_evidence_ref(r.get("because", "")):
            e.append(f"objection_resolutions[{rid}]: {r.get('status')} without a citation or evidence id")
        if r.get("status") == "DOWNGRADED" and r.get("severity") not in SEV:
            e.append(f"objection_resolutions[{rid}]: DOWNGRADED needs a new severity")

    if round_ == 0 and role == "codex":
        check_round0(v, e)
    elif round_ and round_ >= 1:
        # Every objection still outstanding from earlier rounds must be resolved in EVERY later
        # round, round 1 included (review finding F-06), against cumulative state (F-07).
        pending = outstanding(fold(prior_rounds))
        missing = sorted(set(pending) - res_ids - {None})
        if missing:
            e.append("round %d must resolve every prior objection; missing: %s" % (round_, ", ".join(missing)))

    if PRAISE.search(prose(v)):
        e.append("praise/agreement language present: strip it and state the evidence instead")

    # Concession ledger: capture in either direction is flagged, never silently accepted.
    if prior_rounds:
        pending = outstanding(fold(prior_rounds))
        if len(pending) >= 3:
            withdrawn = [r for r in v.get("objection_resolutions") or [] if r.get("status") == "WITHDRAWN"]
            if len(withdrawn) / len(pending) > 0.8 and not any(CITE_RE.search(str(r.get("because", ""))) for r in withdrawn):
                warn.append("CAPTURE_SUSPECTED: >80% of outstanding objections withdrawn without a new sha-pinned citation "
                            "— re-derive the two most consequential disputed facts with the fact-checker")
    return e, warn


def check_citations(v, repo, base):
    """Run check-citations.py on every sha-pinned citation Codex offered."""
    lines = []
    for o in v.get("objections") or []:
        lines += [str(x) for x in (o.get("evidence") or []) if CITE_RE.search(str(x))]
    for rc in v.get("root_causes") or []:
        lines += [str(x) for x in (rc.get("evidence") or []) if CITE_RE.search(str(x))]
    if not lines:
        return [], 0
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as t:
        t.write("\n".join(lines) + "\n"); tmp = t.name
    try:
        cmd = [sys.executable, os.path.join(HERE, "check-citations.py"), "--repo", repo]
        if base:
            cmd += ["--base-sha", base]
        r = subprocess.run(cmd + [tmp], capture_output=True, text=True)
    finally:
        os.unlink(tmp)
    if r.returncode == 0:
        return [], len(lines)
    return [l[2:].replace(tmp + ":", "codex citation #") for l in r.stderr.splitlines() if l.startswith("- ")], len(lines)


def main():
    p = argparse.ArgumentParser(add_help=False)
    p.add_argument("--extract"); p.add_argument("--out"); p.add_argument("--round", type=int)
    p.add_argument("--role", default="codex"); p.add_argument("--repo"); p.add_argument("--base-sha")
    p.add_argument("--art"); p.add_argument("--prior")
    try:
        a = p.parse_args()
    except SystemExit:
        return 2
    usage = "usage: validate-verdict.py --extract <reply.stdout> --out <verdict.json> --round <n> --role codex [--repo <path>] [--base-sha <sha>] [--art <dir>] [--prior <json>]"
    if not a.extract or a.round is None:
        print(usage, file=sys.stderr); return 2
    if not os.path.isfile(a.extract):
        print(f"validate-verdict.py: not readable: {a.extract}", file=sys.stderr); return 2
    art = a.art or os.path.dirname(os.path.dirname(os.path.abspath(a.extract)))
    meta = {}
    mp = os.path.join(art, "meta.json")
    if os.path.isfile(mp):
        try:
            meta = json.load(open(mp, encoding="utf-8"))
        except Exception:
            meta = {}
    repo, base = a.repo or meta.get("repo"), a.base_sha or meta.get("base_sha")
    prior_rounds = {k: r for k, r in load_rounds(art).items() if k < a.round} if os.path.isdir(os.path.join(art, "debate")) else {}
    if a.prior:
        if not os.path.isfile(a.prior):
            print(f"validate-verdict.py: --prior not readable: {a.prior}", file=sys.stderr); return 2
        pv = json.load(open(a.prior, encoding="utf-8"))
        prior_rounds[int(pv.get("round", a.round - 1))] = pv
    v = extract(open(a.extract, encoding="utf-8", errors="replace").read())
    if v is None:
        print("FAIL: no parseable JSON object in the reply", file=sys.stderr); return 1
    errs, warns = validate(v, a.round, a.role, prior_rounds)
    cited = 0
    if repo and not errs:
        cite_fails, cited = check_citations(v, repo, base)
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
          f"changed_positions={len(v.get('changed_positions') or [])} sha_citations_verified={cited}"
          + ("" if repo else " (no repo: citations not checked)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
