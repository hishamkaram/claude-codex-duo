# Phases in detail — read only the section for the phase you are in

## Phase 0 — Scope → `00-scope.md`

1. Resolve inputs (SKILL.md Step 0). Run `init-plan.sh` once with every input; it pins the base
   SHA, writes `meta.json`, the status baseline and `inputs/*.md` verbatim. Exit 3 names the inputs
   `gh` could not fetch: ask the user to paste them, then re-run into a fresh `--out`.
2. Write `00-scope.md`: a table of inputs with the closure criterion of each (observable, not
   "fixed"); base SHA and branch; dirty-tree note; rounds and solo flag; the mismatch note and the
   question, if the argument list and the user's wording disagree; a `## In-scope paths` section
   with one `- path` bullet per directory or file you expect to matter (Codex gets this list).
   Nothing in this file may mention Codex, a comparison, or the run directory: the blind brief
   is built from it.
3. Probe Codex (`codex-invocation.md`) and record the line. Confirm content may leave the machine.
4. Build the blind brief now: `build-prompt.sh --art "$ART" --round 0`. It must exist before any
   evidence does. A leak (exit 3) is fixed by rewording `00-scope.md`, never by editing the brief.
5. `STATUS: PHASE 0 COMPLETE`.

## Phase 1 — Evidence → `01-evidence.md`

Follow `evidence-rules.md` (collection order, tags, layout). Every input claim enters as `I-`
with the input as its source. Reproduce current behaviour or write why you could not. Run:

```bash
check-citations.py "$ART/01-evidence.md" && lint-claims.py "$ART"
```

Both must print OK. Dispatch `fact-checker` for every `I-` a design might rest on; record its
verdict as new `F-`/`V-` rows. `STATUS: PHASE 1 COMPLETE`.

## Phase 2 — Root cause → `02-root-cause.md`

For each input: a causal chain from the observable symptom back through cited facts (`F-`/`V-`
ids at every link) to a cause class: violated invariant, missing abstraction, wrong domain model,
broken contract, absent constraint. "The code was wrong" means the chain stopped early. Then the
**shared-cause verdict** (SHARED / PARTIAL / DISTINCT, see `solution-rubric.md`) with the evidence
ids that decide it. DISTINCT → tell the user now that a split is recommended, and continue planning
as separate PRs inside one run unless told otherwise. `STATUS: PHASE 2 COMPLETE`.

## Phase 3 — Designs → `03-designs.md`

Follow `solution-rubric.md`. At least three candidates including the three mandatory ones, each
scored on G1–G5 and the four counterweights, every cell citing an id or `n/a`. One-sentence
description per candidate that names neither symptom nor input. Chosen design with the specific
reason it beats each mandatory candidate. `STATUS: PHASE 3 COMPLETE`.

## Phase 4 — Draft plan → `04-plan-draft.md`

Fill `templates/PLAN.md` as far as the evidence allows; every decision line cites `F-`/`V-` ids
(`lint-claims.py` checks). Test matrix rows state why each test fails at the base SHA. Then
`chmod 000 01-evidence.md 02-root-cause.md 03-designs.md 04-plan-draft.md` — keep their content in
context; you cannot re-read them until round 0 returns. `STATUS: PHASE 4 COMPLETE`.

## Phase 5 — Codex round 0 (blind) → `debate/r0-codex.json` + sidecars

Pre-flight: the four files above are mode 000; `debate/r0-prompt.md` predates `01-evidence.md`
(`ls -l --time-style=full-iso` or `stat`). Run the round per `codex-invocation.md` with `--fresh`.
Validate with `--repo` so Codex's citations are checked against the code. On T5 write
`debate/r0-codex.md` with the verbatim failure and `STATUS: PHASE 5 COMPLETE (SKIPPED — <reason>)`,
`chmod 600` the four files, and jump to Phase 8 in SOLO mode. Otherwise `chmod 600` the four files
and write `debate/r0-codex.md` = the validator summary line + `debate-status.py` block + `STATUS:
PHASE 5 COMPLETE`. `--solo`: write the SKIPPED artifact without running anything.

## Phase 6 — Divergence → `debate/divergence.md`

Per `debate-protocol.md`. Compare root causes, designs and single-PR verdicts side by side; every
difference becomes `D-nn` with the exact question round 1 must answer; every agreement is listed as
"agreed, not evidence". Where Codex's root cause is better supported by ids than yours, say so here,
not in round 3. `STATUS: PHASE 6 COMPLETE`.

## Phase 7 — Rounds 1..N → `05-disagreements.md`, `debate/rN-*`

Create the ledger from `divergence.md` and Codex's r0 objections. For each round: write your
rebuttals (ACCEPT / REJECT / DEFER / CRUX, with evidence) into the ledger; revise
`04-plan-draft.md` for every ACCEPT; build the prompt; run the round `--resume-last`; validate with
`--prior`; run `debate-status.py`; rule on every touched row; append the status block. Stop at the
first termination condition. Fact disputes go to `fact-checker` between rounds, never to another
round. `STATUS: PHASE 7 COMPLETE (<Tn>)`.

## Phase 8 — Final → `PLAN.md` | `DECISION-REQUIRED.md`

Decide by the termination table. Fill the template completely; line 1 is the review status stamp.
Run `check-citations.py` on `PLAN.md` and `lint-claims.py "$ART"`; both OK. Then the completion gate
in SKILL.md, then the plan-mode handoff (SKILL.md), then print the file.
