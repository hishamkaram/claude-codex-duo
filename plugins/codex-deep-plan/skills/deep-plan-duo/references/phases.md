# Phases in detail — read only the section for the phase you are in

## Phase 0 — Scope → `00-scope.md`

1. Resolve inputs (SKILL.md Step 0). Run `init-plan.sh` once with every input; it pins the base
   SHA, writes `meta.json`, the status baseline and `inputs/*.md` verbatim. Exit 3 names the inputs
   `gh` could not fetch: ask the user to paste them, then re-run into a fresh `--out`.
2. Classify **intent** and **scale** (SKILL.md Step 0) and write both into `00-scope.md` under
   `## Mode`, each with the sentence of the input that decided it, and into `meta.json` as
   `"mode": "question" | "light" | "standard" | "deep"` (write it with a one-line python edit; the
   script only records `mode_requested` from `--deep`). Quote the deciding words: "is the README
   current" is a question; "fix the README row for X" is a light change request; "issue 12 crashes
   on empty input" is standard; "issues 12 and 13 crash on empty input" is deep (several issues,
   SKILL.md Step 0). When in doubt choose the deeper mode; the cost of a wrong
   `light` is a missed mechanism, the cost of a wrong `standard` is reading time.
   Modes and the phases they run:

   | Mode | Phases | Output |
   |---|---|---|
   | question | 0, 1, 5 (one blind round 0 unless `--solo` or the answer is settled by a single `[VERIFIED]` row), 8 | `ANSWER.md` |
   | light | 0, 1, 2 (short chain ending in `incorrect_authoritative_content`), 4, 5 (one blind round 0), 8 | `PLAN.md` + `PLAN-EVIDENCE.md` |
   | standard / deep | all | `PLAN.md` + `PLAN-EVIDENCE.md` or `DECISION-REQUIRED.md` |

   `deep` differs from `standard` only in defaults: rounds 3, fact-checker dispatched for every
   inference, largest-correct candidate scored in full.
3. Write the rest of `00-scope.md`: a table of inputs with the closure criterion of each
   (observable, not "fixed"); base SHA and branch; dirty-tree note; rounds and solo flag; the
   mismatch note and the question, if the argument list and the user's wording disagree; a
   `## In-scope paths` section
   with one `- path` bullet per directory or file you expect to matter (Codex gets this list).
   Nothing in this file may mention Codex, a comparison, or the run directory: the blind brief
   is built from it.
4. Probe Codex (`codex-invocation.md`) and record the line. Confirm content may leave the machine.
5. Build the blind brief now: `build-prompt.sh --art "$ART" --round 0`. It must exist before any
   evidence does. A leak (exit 3) is fixed by rewording `00-scope.md`, never by editing the brief.
6. `STATUS: PHASE 0 COMPLETE`.

## Phase 1 — Evidence → `01-evidence.md`

Follow `evidence-rules.md` (collection order, tags, layout). Every input claim enters as `I-`
with the input as its source. Reproduce current behaviour or write why you could not. Run:

```bash
check-citations.py "$ART/01-evidence.md" && lint-claims.py "$ART"
```

Both must print OK. Dispatch `fact-checker` for every `I-` a design might rest on; record its
verdict as new `F-`/`V-` rows.

**Light and question modes — authority of the edited content.** Record, as `V-` rows, the bounded
searches that show the file you would edit is the source of truth: no generator writes it
(`git grep -l '<filename>' -- '*.sh' '*.py' '*.mk' Makefile`), no duplicate carries the same text
(`git grep -F '<distinctive phrase>'`), no override or precedence rule replaces the value at
runtime, and who consumes it. **Re-evaluate scale now**: escalate `light` → `standard` (write the
trigger under `## Mode` in `00-scope.md`) when any holds: a blocking unknown; the content is
generated, duplicated or overridden; the evidence points at behaviour rather than content.
Several wrong sentences in one authoritative file are several plan rows, not a trigger (review
F-06, settled with Codex). `STATUS: PHASE 1 COMPLETE`.

## Phase 2 — Root cause → `02-root-cause.md`

For each input: a causal chain from the observable symptom back through cited facts (`F-`/`V-`
ids at every link) to a cause class: violated invariant, missing abstraction, wrong domain model,
broken contract, absent constraint, or incorrect authoritative content (`solution-rubric.md`
§Proportionality: the source-of-truth text or value is wrong and nothing regenerates it). "The
code was wrong" means the chain stopped early; so does reaching for `absent_constraint` because a
document has no checker — a document that is simply wrong is `incorrect_authoritative_content`,
and a checker is a follow-up, not the cause. Then the
**shared-cause verdict** (SHARED / PARTIAL / DISTINCT, see `solution-rubric.md`) with the evidence
ids that decide it. DISTINCT → tell the user now that a split is recommended, and continue planning
as separate PRs inside one run unless told otherwise. `STATUS: PHASE 2 COMPLETE`.

## Phase 3 — Designs → `03-designs.md`

Light mode: skipped. Write `03-designs.md` with one line — the direct correction, the reason it is
the real fix (cause class, authority rows), and any optional follow-up (checker, test) named as
such — and `STATUS: PHASE 3 COMPLETE (SKIPPED — light mode)`.

Standard and deep: follow `solution-rubric.md`. At least three candidates including the three mandatory ones, each
scored on G1–G5 and the four counterweights, every cell citing an id or `n/a`. One-sentence
description per candidate that names neither symptom nor input. Chosen design with the specific
reason it beats each mandatory candidate. `STATUS: PHASE 3 COMPLETE`.

## Phase 4 — Draft plan → `04-plan-draft.md`

Fill `templates/PLAN.md` as far as the evidence allows; every decision line cites `F-`/`V-` ids
(`lint-claims.py` checks). Test matrix rows state why each test fails at the base SHA. Then
`chmod 000 01-evidence.md 02-root-cause.md 03-designs.md 04-plan-draft.md` — keep their content in
context; you cannot re-read them until round 0 returns. `STATUS: PHASE 4 COMPLETE`.

## Phase 5 — Codex round 0 (blind) → `debate/r0-codex.json` + sidecars

Pre-flight: the four files above (those that exist in this mode; a question has only `01-evidence.md`) are mode 000; `debate/r0-prompt.md` predates `01-evidence.md`
(`ls -l --time-style=full-iso` or `stat`). Run the round per `codex-invocation.md` with `--fresh`.
The validator reads repo and base SHA from `meta.json` and checks Codex's citations against the code at the base commit. On T5 write
`debate/r0-codex.md` with the verbatim failure and `STATUS: PHASE 5 COMPLETE (SKIPPED — <reason>)`,
`chmod 600` the four files, and jump to Phase 8 in SOLO mode. Otherwise `chmod 600` the four files
and write `debate/r0-codex.md` = the validator summary line + `debate-status.py` block + `STATUS:
PHASE 5 COMPLETE`. `--solo`: write the SKIPPED artifact without running anything.

**Light and question modes — re-evaluate scale after round 0.** Rule on every Codex objection
directly in `05-disagreements.md` (ACCEPT / REJECT / DEFER / CRUX with evidence; no rounds follow).
Escalate to `standard` (trigger recorded in `00-scope.md`, then continue at Phase 3) when: an
accepted objection of any severity, or new evidence, requires a change that is not an edit of the
authoritative content; the content fails the authority test; Codex cites a different mechanism
and the citation survives verification; or a blocking unknown appears. Otherwise proceed to
Phase 8 with termination `T0 (light)`.

## Phase 6 — Divergence → `debate/divergence.md`

Per `debate-protocol.md`. Compare root causes, designs and single-PR verdicts side by side; every
difference becomes `D-nn` with the exact question round 1 must answer; every agreement is listed as
"agreed, not evidence". Where Codex's root cause is better supported by ids than yours, say so here,
not in round 3. `STATUS: PHASE 6 COMPLETE`.

## Phase 7 — Rounds 1..N → `05-disagreements.md`, `debate/rN-*`

Create the ledger from `divergence.md` and Codex's r0 objections. For each round: write your
rebuttals (ACCEPT / REJECT / DEFER / CRUX, with evidence) into the ledger; revise
`04-plan-draft.md` for every ACCEPT; build the prompt; run the round `--resume-last`; validate (earlier
rounds are folded in automatically); run `debate-status.py`; rule on every touched row; append the status block. Stop at the
first termination condition. Fact disputes go to `fact-checker` between rounds, never to another
round. `STATUS: PHASE 7 COMPLETE (<Tn>)`.

## Phase 8 — Final → `PLAN.md` + `PLAN-EVIDENCE.md` | `DECISION-REQUIRED.md` | `ANSWER.md`

Decide by the termination table. Fill both templates completely; line 1 of `PLAN.md` is the
review status stamp. `PLAN.md` holds only what an approver acts on: summary, root cause → change →
test → closure table, file-by-file plan, test matrix, order and rollback. `PLAN-EVIDENCE.md`
holds the scope contract, candidate scoring (or "not scored: light mode"), risk register,
unknowns, debate closure, concessions and optional follow-ups. Prose uses 7-character SHAs; ids
appear in table cells, not in sentences. Run `check-citations.py --allow-empty` on both files (they
cite by id; `01-evidence.md` is re-checked without the flag) and `lint-claims.py "$ART"`; all OK.
Then the completion gate in SKILL.md, then the plan-mode handoff.

Question mode: fill `templates/ANSWER.md` instead — the answer in one paragraph, the evidence
rows it rests on, what Codex's blind round added or disputed, and the defects found (if any) with
the sentence "say 'plan it' to turn these into a plan". Print it; never enter plan mode.
