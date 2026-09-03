# PLAN — {{slug}}

Review status: {{REVIEWED by Codex, N rounds, termination Tn | SOLO — unreviewed by second model: <reason>}} · Mode: {{light | standard | deep}}{{, escalated from light at Phase n: <trigger>}}
Base SHA: {{7-char sha}} ({{branch}}) · Written: {{date}} · Revalidate if implementation has not started by {{date + 14 days}}
Artifacts: {{artifact dir}} — evidence in 01-evidence.md, scoring/risks/unknowns/debate in PLAN-EVIDENCE.md

## Summary

{{At most eight lines. What changes and why (one sentence per input); which files; how it is
tested; whether one PR or a split; open risks: n (R-ids) and blocking unknowns: n (U-ids) — details
in PLAN-EVIDENCE.md; what Codex disputed and how it was settled, in one line.}}

## 1. Root cause → change → test → closure

| Input | Root cause (cause class) | Change | Test that fails at base SHA | Closure criterion |
|---|---|---|---|---|
| {{issue-123}} | {{RC-1: one sentence (violated_invariant)}} | {{CH-1}} | {{T-1}} | {{observable}} |

## 2. File-by-file plan

| # | File | Change | Why (evidence ids) |
|---|---|---|---|
| CH-1 | {{path}} | {{what changes}} | {{F-3, V-1}} |

## 3. Test matrix

| Test | Exercises | Fails at base SHA because | Passes after |
|---|---|---|---|
| T-1 | {{mechanism, not just the reported input}} | {{...}} | {{CH-n}} |

## 4. Order and rollback

{{Implementation order and any ordering constraint (e.g. "CH-3 first so T-1 is observed
failing"); migrations and flags (a flag is a rollout mechanism, never the fix); how to revert
after production writes.}}

STATUS: PHASE 8 COMPLETE
