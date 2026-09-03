# PLAN-EVIDENCE — {{slug}}

Companion to PLAN.md; same base SHA {{7-char sha}}. Everything an approver may want to inspect,
nothing they must read to approve.

## 1. Scope contract

| Input | Kind | Closure criterion (observable) | Covered by |
|---|---|---|---|
| {{issue-123}} | issue | {{what must be true for this to be closable}} | {{change ids}} |

Single-PR verdict: {{ONE_PR | SPLIT}} — {{because, citing F-/V- ids and the shared-cause verdict}}
Mode: {{light | standard | deep}} — {{deciding words of the input}}{{; escalated at Phase n: <trigger>}}

## 2. Chosen design and rejected alternatives

Decision: {{DS-n}} because {{F-/V- ids}}. {{light mode: "not scored: light mode — direct correction of authoritative content (cause class incorrect_authoritative_content; authority rows V-n, V-m)"}}

| Candidate | G1 | G2 | G3 | G4 | G5 | Blast radius | Reversibility | Verifiability | Cost of being wrong | Result |
|---|---|---|---|---|---|---|---|---|---|---|
| do-nothing | | | | | | | | | | rejected: {{cost of status quo}} |
| {{tempting workaround}} | | | | | | | | | | rejected: workaround ({{which gate fails}}) |
| {{largest correct change}} | | | | | | | | | | rejected: {{blast radius / reversibility}} |
| {{chosen}} | | | | | | | | | | chosen |

## 3. Risk register

| id | Risk | Detection signal | Rollback trigger | Owner |
|---|---|---|---|---|
| R-1 | {{...}} | {{...}} | {{...}} | |

## 4. Residual unknowns

| id | Question | Why it matters | Blocking? | How to resolve |
|---|---|---|---|---|
| U-1 | [UNKNOWN] {{question}} | {{...}} | no | {{...}} |

## 5. Debate closure

| Objection | Class | Severity | Final status | Resolution (evidence) |
|---|---|---|---|---|
| X-1 | {{...}} | {{...}} | {{ACCEPTED → CH-n | REJECTED (F-n) | DEFERRED → R-n | CRUX → U-n}} | {{...}} |

Residual disagreements: {{none | list, with both positions and the recommended default}}
Concessions by the plan author: {{list with round numbers, or "none — the ledger shows why"}}
Concessions by Codex: {{list with round numbers}}

## 6. Optional follow-ups (not part of this PR)

{{Enforcement machinery, refactors or tests that would prevent recurrence, each with the
condition under which it becomes worth doing (e.g. "if this claim drifts again — git log shows no
earlier correction"). "none" is a valid entry.}}

STATUS: PHASE 8 COMPLETE
