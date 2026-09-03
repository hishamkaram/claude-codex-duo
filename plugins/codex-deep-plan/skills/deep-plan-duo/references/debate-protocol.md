# Debate protocol (Phases 5–8)

Goal: extract independent information from a second model. Agreement is worthless unless it was
reachable independently; disagreement is worthless unless it is evidence-bearing and falsifiable.

## Rounds

| Round | Codex sees | Codex must produce |
|---|---|---|
| 0 (blind) | inputs verbatim, base SHA, in-scope paths. Nothing of yours. | own `root_causes[]`, own `designs[]`, `single_pr_recommendation`, objections against the inputs, attestations |
| 1 | `01-evidence.md`, `02-root-cause.md`, `03-designs.md`, `debate/divergence.md`, its own r0 reply | resolution of each r0 objection, answers to every D-id, `changed_positions`, `evidence_requests` |
| 2 | `01-evidence.md`, `04-plan-draft.md` (revised), `05-disagreements.md` with your rebuttals, its r1 reply | each prior objection SUSTAINED / WITHDRAWN / DOWNGRADED; new objections only for risks the plan introduced |
| 3 | same as 2, revised | verdict; new objections must be BLOCKER with newly available evidence |

Round 0's blindness is the single most important structural choice. Codex shown a design mostly
ratifies it. `build-prompt.sh --round 0` refuses to emit a brief containing wording that reveals
another analysis exists; `01`–`04` are mode 000 while round 0 runs (defense-in-depth only; see
`codex-invocation.md`).

## Objection contract (enforced by `validate-verdict.py`)

Every objection carries `id` (X-nn), `class`, `severity`, `claim`, `evidence[]`, `proposed_change`,
`falsifier`. Classes: FACT_ERROR · MISSING_EVIDENCE · ROOT_CAUSE_WRONG · SUPERIOR_ALTERNATIVE ·
RISK_UNMANAGED · SCOPE · TEST_GAP · MIGRATION_UNSAFE. Severity: BLOCKER · MAJOR · MINOR · NIT.

1. No `evidence[]` or no `falsifier` → rejected by the validator, not debated. Same rule binds you.
2. Hypothesis-only objections cannot be BLOCKER or MAJOR; they become `evidence_requests` and you
   dispatch the `fact-checker` agent on them.
3. Fact disputes are never settled by argument. Dispatch `fact-checker` on the disputed proposition;
   its verdict decides. Most deadlocks are unresolved facts wearing a costume.
4. Value disputes (latency vs simplicity, scope vs speed) are never settled by more rounds →
   `DECISION-REQUIRED.md`.
5. Conceding requires a citation or an evidence id in `because`. "Good point" fails validation.
6. `NO_OPINION_INSUFFICIENT_EVIDENCE` is a legitimate, respected answer.
7. Codex's sha-pinned citations are run through `check-citations.py` before its verdict is
   accepted. Correlated hallucination across two models is the real failure mode; only mechanical
   verification catches it.

## `debate/divergence.md` (Phase 6)

Side-by-side table: your root causes vs Codex's; your designs vs Codex's; both single-PR verdicts.
Each row of disagreement becomes `D-nn` with: what differs, whose evidence is stronger by
`F-`/`V-`/`X-` id, and the exact question round 1 must answer. Agreement rows are listed too, with
the note that agreement is not evidence.

## `05-disagreements.md` — the ledger (Phase 7, one table, updated every round)

```
| id | Source | Claim | Class | Severity | Your verdict | Status | Evidence | Round |
| D-1 | X-2 | ... | ROOT_CAUSE_WRONG | MAJOR | REJECT | OPEN | F-4 vs X-2's src/a.ts:10@sha | 1 |
```

Your verdict per objection: **ACCEPT** (name the exact plan delta, CH-n) · **REJECT** (cite
counter-evidence; "I disagree" is invalid) · **DEFER** (risk register entry R-n with detection signal
and rollback trigger) · **CRUX** (reduce to an empirical question and the cheapest experiment; run it
if you can). Status: OPEN · RESOLVED · DEFERRED · DECISION. `debate-status.py` counts OPEN rows.

Below the table, one section per round: your rebuttals to Codex, then the compact status block
printed by `debate-status.py`. Codex's raw reply is never pasted here; it lives verbatim in
`debate/rN-codex.stdout` and validated in `rN-codex.json`.

## Termination — stop at the FIRST condition met, in this order

| | Condition | Result |
|---|---|---|
| T0 | light or question mode: round 0 ruled on directly, no escalation trigger fired (`phases.md` §5) | `PLAN.md` + `PLAN-EVIDENCE.md` / `ANSWER.md` |
| T1 | Codex verdict APPROVE or APPROVE_WITH_CONDITIONS, zero open BLOCKER/MAJOR, zero OPEN ledger rows | `PLAN.md` + `PLAN-EVIDENCE.md` |
| T4 | An open BLOCKER whose falsifier is "a human must choose X over Y" | `DECISION-REQUIRED.md` |
| T2 | Round cap reached (default 2, 3 with `--deep`, hard cap 3, never extended) | `DECISION-REQUIRED.md` if any BLOCKER/MAJOR is open, else `PLAN.md` + §Residual disagreements |
| T3 | Two consecutive rounds with no new objection, class, citation or changed position | `PLAN.md` + §Residual disagreements |
| T5 | Codex unavailable, or verdict invalid after the retry (runner exit ≠ 0 twice, or validator FAIL twice) | continue solo; `PLAN.md` stamped `SOLO`. Never simulate Codex. |

T3 matters more than T2: the cap invites padding rounds to look thorough. Repetition is not
convergence. A debate where nobody moved and nothing escalated is a failed debate; record that
rather than pretending consensus.

## Anti-sycophancy measures that bite

- Blind round 0: no anchor to copy.
- Machine validation rejects praise language and evidence-free concessions, from Codex and (by
  the same rules, applied by you to your own ledger) from you.
- Bare APPROVE costs more than objecting: it needs `adversarial_attempt` and three
  `checks_performed`. Flattery is the expensive path.
- `changed_positions` is a first-class field. A side that never moves across rounds and a side that
  folds on everything are both flagged; the validator warns `CAPTURE_SUSPECTED` when more than 80%
  of objections are withdrawn without a new sha-pinned citation, and you then re-derive the two
  most consequential disputed facts with `fact-checker`.
- Before writing each round's rebuttal, answer in the ledger: did I concede anything? name the
  fact or undo it. Did I reject anything by restating? produce evidence or ACCEPT.
