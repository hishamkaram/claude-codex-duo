# Evidence rules (Phase 1, re-read before Phase 8)

## Tags — every claim carries exactly one

| Tag | Means | Required form on the same line |
|---|---|---|
| `[FACT]` | Read in the repo at the base SHA | `` `path:120-134@<sha>` `` + `"verbatim quote of at most 15 words"` |
| `[VERIFIED]` | Observed by executing something | `cmd: <command>` + an output excerpt |
| `[INFERENCE]` | Reasoned from facts | `from: F-3, F-7` + a falsifier (what observation would refute it) |
| `[UNKNOWN]` | Not established | a row in the unknowns register |

Ids: `F-` facts, `V-` verified, `I-` inferences, `U-` unknowns, `R-` risks. Define each id once as a
table row (`| F-3 | [FACT] | ...`) carrying exactly the tag its letter implies; reference it anywhere.
A decision line cites an `F-` or `V-` id; an `I-`/`U-` id alone is not support. `lint-claims.py` fails on a referenced id that was
never defined, and `check-citations.py` resolves every `path:lines@sha` with `git show` and
string-matches the quote against the cited range. Both must exit 0 before Phase 2.

## Hard rules

1. Citations pin the base SHA from `meta.json`; `check-citations.py` rejects any other commit. Never
   cite a line you have not read this run.
2. Quotes are verbatim and at most 15 words: long enough to be unique, short enough to match.
3. Comments and docs are evidence about intent, not behaviour. Verify behaviour separately.
4. Your memory of a library's semantics is `[INFERENCE]`. Promote it by citing the vendored source,
   the lockfile-pinned version's source, or a `[VERIFIED]` experiment in a throwaway directory.
5. Absence claims are the most dangerous kind. "Nothing else calls this" needs the exact search
   command AND its blind spots: dynamic dispatch, reflection, string-keyed registries, codegen,
   config-driven wiring, tests that monkey-patch.
6. Banned outside `[INFERENCE]`/`[UNKNOWN]` lines: probably, likely, should be, I assume, presumably,
   it seems, typically, might be, appears to, obviously, clearly. The linter enforces this.
7. Prior fix attempts are strong root-cause evidence: `git log -S<symbol>`, `git blame` on suspect
   lines, linked or reverted PRs. A symptom patched twice means the cause is elsewhere.
8. Input text (issue, PR comment, request) is a claim. It enters as `[INFERENCE]` with the input as
   its source until reproduced or traced. Inheriting a reporter's theory is the commonest bad design.
9. No design decision may rest on an `[INFERENCE]` or `[UNKNOWN]`. Promote it, or move it to the
   risk register with a detection signal and a rollback trigger.

## Authority of edited content (light and question modes)

Before a content correction can be the fix, `01-evidence.md` carries `[VERIFIED]` rows for the
bounded searches that show the file is the source of truth: no generator writes it, no duplicate
carries the same claim, no override replaces the value, and who consumes it. A hit on any of
them escalates the run (`phases.md` §1).

## Collection order

entry points → call path (read bodies, not names) → state, schema, invariants → reproduce the
current behaviour (`[VERIFIED]`, or a row saying why reproduction is impossible) → history
(`git log -S`, blame, linked PRs) → existing tests and the gap they leave → sibling call sites of
the mechanism (feeds gate G2 in the rubric).

## Promoting an inference

Send the bare proposition and the base SHA to the `fact-checker` agent shipped with this plugin
(Agent tool, no reasoning attached, no mention of the design it supports). It returns
CONFIRMED / REFUTED / INDETERMINATE with its own citations; record those as `F-`/`V-` rows tagged
`via fact-checker`. If the agent is not available, verify in-context and tag the row
`self-verified` so the plan says so.

## Unknowns register (in `01-evidence.md`)

| id | Question | Why it matters | Blocking? | How to resolve | Owner |
|---|---|---|---|---|---|
| U-1 | [UNKNOWN] ... | ... | no | ... | |

`Blocking? = yes` means the design choice changes with the answer. Phase 8 cannot write `PLAN.md`
while a blocking unknown is open; it writes `DECISION-REQUIRED.md` instead.

## `01-evidence.md` layout

```
# Evidence — <slug> @ <sha>
## Facts
| id | Tag | Claim | Citation |
| F-1 | [FACT] | ... | `path:10-12@<sha>` "quote" |
## Verified
| V-1 | [VERIFIED] | ... | cmd: ... -> ... |
## Inferences
| I-1 | [INFERENCE] | ... | from: F-1, F-2 · falsifier: ... |
## Unknowns
(register above)
## Reproduction
(what was run, verbatim output, or why it could not be run)
## History
(prior attempts, blame, reverted PRs — cited)
## Existing tests and the gap
STATUS: PHASE 1 COMPLETE
```
