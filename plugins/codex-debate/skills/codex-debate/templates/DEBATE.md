# Debate: {{motion}}

{{if no participant ever answered: `NO DEBATE — Codex unavailable: <verbatim reason>. Only Claude's position follows.`}}
{{if a participant failed mid-debate: `DEBATE TRUNCATED at round <k> (participant p<k>): <verbatim reason>.`}}

## 1. RULING
**{{UPHELD | OVERTURNED | REFINED | UNRESOLVED | NO DEBATE}}** · confidence: {{HIGH | MEDIUM | LOW}}

{{one paragraph: what the ruling is and which ledger rows it rests on, by ID and grade}}
{{N ≥ 2 participants: one line per participant — `p<k> (<backend[:alias]>): UPHELD | OVERTURNED | REFINED | UNRESOLVED | UNRESOLVED (global budget) | NOT DEBATED` — then the aggregation per protocol.md §N participants (dissent score schedule, pair-local termination, confidence capped at the lowest pair)}}

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
**By Codex:** {{same; with N ≥ 2 participants one line per participant, `By p<k>:` …}}

## 6. STRONGEST SURVIVING ARGUMENT AGAINST THE RULING
{{the best OPEN or UNRESOLVED opposing claim, stated fairly, with its grade. Mandatory; may be "none" only if the ledger has no such row.}}

## 7. VERIFICATIONS PERFORMED
{{every VERIFY: command, result, which row it decided. Exact commands only.}}

## 8. DEBATE SUMMARY
Rounds run: {{k}} of {{N}} · ended by: {{convergence | stalemate | cap | failure}}
{{N ≥ 2 participants: per participant — `p<k>: rounds <m> of <N> · ended by: convergence | stalemate | pair cap | global budget | failure` · global: <n> of <total-rounds>}}
Blind round: {{on | off}} · Codex status: {{…; with N ≥ 2, per participant: p<k> <backend[:alias]> SUCCEEDED | UNAVAILABLE | FAILED | DECLINED}}
Protocol failures logged: {{list by side and round, or "none"}}
LATE claims (not ruled on): {{ids or "none"}}

## 9. HUMAN SHOULD STILL CHECK
{{what neither side could verify and why}}
