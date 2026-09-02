# PLAN — {{slug}}

Review status: {{REVIEWED by Codex, N rounds, termination Tn | SOLO — unreviewed by second model: <reason>}}
Base SHA: {{base sha}} ({{branch}}) · Written: {{date}} · Revalidate if implementation has not started by {{date + 14 days}}
Artifacts: {{artifact dir}} (evidence in 01-evidence.md, debate transcripts in debate/)

## 1. Scope contract

| Input | Kind | Closure criterion (observable) | Covered by |
|---|---|---|---|
| {{issue-123}} | issue | {{what must be true for this to be closable}} | {{change ids}} |

Single-PR verdict: {{ONE_PR | SPLIT}} — {{because, citing F-/V- ids and the shared-cause verdict in 02-root-cause.md}}

## 2. Root cause → change → test → closure

| Input | Root cause (cause class) | Change | Test that fails at base SHA | Closure criterion |
|---|---|---|---|---|
| {{issue-123}} | {{RC-1: one sentence (violated_invariant)}} | {{CH-1}} | {{T-1}} | {{...}} |

## 3. Chosen design and rejected alternatives

Decision: {{DS-n}} because {{F-/V- ids}}.

| Candidate | G1 | G2 | G3 | G4 | G5 | Blast radius | Reversibility | Verifiability | Cost of being wrong | Result |
|---|---|---|---|---|---|---|---|---|---|---|
| do-nothing | | | | | | | | | | rejected: {{cost of status quo}} |
| {{tempting workaround}} | | | | | | | | | | rejected: workaround ({{which gate fails}}) |
| {{largest correct change}} | | | | | | | | | | rejected: {{blast radius / reversibility}} |
| {{chosen}} | | | | | | | | | | chosen |

## 4. File-by-file plan

| # | File | Change | Why (evidence ids) |
|---|---|---|---|
| CH-1 | {{path}} | {{what changes}} | {{F-3, V-1}} |

## 5. Test matrix

| Test | Exercises | Fails at base SHA because | Passes after |
|---|---|---|---|
| T-1 | {{mechanism, not just the reported input}} | {{...}} | {{CH-n}} |

## 6. Rollout and rollback

{{ordering, migrations, flags used as rollout mechanism (never as the fix), how to revert after production writes}}

## 7. Risk register

| id | Risk | Detection signal | Rollback trigger | Owner |
|---|---|---|---|---|
| R-1 | {{...}} | {{...}} | {{...}} | |

## 8. Residual unknowns

| id | Question | Why it matters | Blocking? | How to resolve |
|---|---|---|---|---|
| U-1 | {{...}} | {{...}} | no | {{...}} |

## 9. Debate closure

| Objection | Class | Severity | Final status | Resolution (evidence) |
|---|---|---|---|---|
| X-1 | {{...}} | {{...}} | {{ACCEPTED → CH-n | REJECTED (F-n) | DEFERRED → R-n | CRUX → U-n}} | {{...}} |

Residual disagreements: {{none | list, with both positions and the recommended default}}
Concessions by the plan author: {{list with round numbers, or "none — the ledger shows why"}}

STATUS: PHASE 8 COMPLETE
