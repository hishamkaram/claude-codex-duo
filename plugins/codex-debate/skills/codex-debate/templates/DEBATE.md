# Debate: {{motion}}

{{if Codex never answered: `NO DEBATE — Codex unavailable: <verbatim reason>. Only Claude's position follows.`}}
{{if Codex failed mid-debate: `DEBATE TRUNCATED at round <k>: <verbatim reason>.`}}

## 1. RULING
**{{UPHELD | OVERTURNED | REFINED | UNRESOLVED | NO DEBATE}}** · confidence: {{HIGH | MEDIUM | LOW}}

{{one paragraph: what the ruling is and which ledger rows it rests on, by ID and grade}}

{{if REFINED: **Amended motion:** …}}
{{if UNRESOLVED: **Recommended default:** … because stakes are …}}

## 2. RECOMMENDED ACTION
{{what to do now, concretely; or "no action, position stands"}}

## 3. WHAT WOULD OVERTURN THIS RULING
{{specific evidence, not "new information"}}

## 4. FINAL LEDGER
| ID | Owner | Claim | Grade | Evidence | Status | Changed in |
|---|---|---|---|---|---|---|
{{every row, no omissions}}

## 5. CONCESSIONS
**By Claude:** {{each C-nn conceded or retracted, the round, and the fact that moved it. If none across all rounds: "none — Claude conceded nothing; treat the ruling with corresponding skepticism."}}
**By Codex:** {{same}}

## 6. STRONGEST SURVIVING ARGUMENT AGAINST THE RULING
{{the best OPEN or UNRESOLVED opposing claim, stated fairly, with its grade. Mandatory; may be "none" only if the ledger has no such row.}}

## 7. VERIFICATIONS PERFORMED
{{every VERIFY: command, result, which row it decided. Exact commands only.}}

## 8. DEBATE SUMMARY
Rounds run: {{k}} of {{N}} · ended by: {{convergence | stalemate | cap | failure}}
Blind round: {{on | off}} · Codex status: {{…}}
Protocol failures logged: {{list by side and round, or "none"}}
LATE claims (not ruled on): {{ids or "none"}}

## 9. HUMAN SHOULD STILL CHECK
{{what neither side could verify and why}}
