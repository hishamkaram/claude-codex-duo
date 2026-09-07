# Adjudication

## Phase 3 — Reconciliation matrix

Table every distinct finding from the lead review and from every participant's blind
review (`02-p<k>.stdout`, one per row of `00-participants.tsv`). Assign canonical `F-` IDs
here; keep every originating `CL-`/`CX-` ID with its raiser in a column.

Merge duplicates only when same root cause at same location — the rule is the same across
any number of raisers: a finding raised by the lead and by three participants at the same
location for the same cause is ONE canonical finding with four provenance rows. Two
consequences of one root cause = one finding. Two independent defects at one location =
two findings. Participant agreement is not evidence: three participants raising the same
finding make it no more true than one (Phase 5 verifies every finding regardless).

Label each: **BOTH** | **CLAUDE-ONLY** | **CODEX-ONLY** | **CONFLICT**. These four literals
are the origin vocabulary every validator enforces; with N participants they mean:
BOTH — the lead and at least one participant raised it; CLAUDE-ONLY — only the lead;
CODEX-ONLY — only participants (any number of them, whichever backend ran them);
CONFLICT — any two raisers looked and disagree on existence, on root cause, or on
severity in a way that crosses a verdict boundary (P0↔P1, P1↔P2) or spans 2+ levels. A
P1-vs-P2 disagreement is therefore a CONFLICT, between the lead and a participant or
between two participants alike.

Every merged finding gets ONE canonical severity in the matrix. Provisionally
record the highest any raiser gave; Phase 5 evidence sets the final severity. Never
average severities and never let the last speaker decide.

Who raised what is recorded once, in `03-provenance.tsv` — one tab-separated row per
raiser of each canonical ID and no header:

```
F-01	lead	CL-03
F-01	p2	CX-07
F-03	p1	CX-02
```

`pre-consultation` validates it with `validate-provenance.py` (every matrix ID at least
once, raisers are `lead` or a listed participant, no raiser twice per ID, original ids
`CL-`/`CX-`, origin consistent with the raiser set) and accepts it as a draft. It is the
report's source for per-participant counts and it never reaches a consultation packet,
which stays provenance-free.

Then write a machine-readable `03-matrix.tsv` with one tab-separated row per
canonical finding and no header:

```
F-01	BOTH	P2
F-02	CLAUDE-ONLY	P1
F-03	CODEX-ONLY	P2
```

Then write `03-debate-selection.tsv`, one tab-separated row for every manifest
ID and no header:

```
F-01	BOTH	P2	INCLUDE	BOTH
F-02	CLAUDE-ONLY	P1	INCLUDE	provisional-P1
F-03	CODEX-ONLY	P2	EXCLUDE	CODEX-ONLY-P2
```

Then write `03-findings.ndjson`, the normalized base packet of every canonical
ID, one JSON object per line with exactly `id`, `severity`, `claim`,
`locations`, `trigger`, `impact`, `observations`, `falsifier`,
`proposed_checks`, `open_factual_questions` (the citation rules under Phase 5
apply). It carries no origin, verdict, or provenance. `pre-consultation`
validates it with `validate-verifier-packets.py --match-matrix-severity` (each
base packet's severity equals the matrix's provisional severity; only a REFINE
disposition may change it later) and accepts it into the ledger
(`00-accepted.sha256`, see SKILL.md §Phase gate); it is the input every
verifier packet is built from and may not change once consultation has begun.

All three artifacts are complete ledgers, not best-effort shortlists. Deduplicate by
canonical ID. The validator requires the selector to mirror every manifest ID,
origin, and provisional severity exactly. **INCLUDE** every `CONFLICT`, every
`BOTH`, and every provisional P0/P1 finding; **EXCLUDE** all others. The final
predicate is the reason that row was selected or excluded.

## Phase 4 — Set-level consultation

Only after `phase-gate.sh pre-consultation` prints `CONSULTATION-OK` may the
orchestrator consult Codex — with N participants, the exchange participant the join
recorded in `02-exchange-participant` (the lowest-numbered COMPLETE one), on that
participant's session; the others are never consulted in this version. The initial
reviews remain blind and immutable; this
is the first phase allowed to describe canonical findings and fair positions.
The orchestrator is Claude's advocate, never the sealed lead agent. It records
its position and any concession in `04-consultation.md`; it never changes
`01-lead.md`.

One self-contained prompt (`templates/codex-exchange.md`) contains **every**
selected canonical ID, each finding's fair positions, source quotes/citations,
and one falsifiable challenge. It must never name the artifact directory. Run exactly one monitored
`--resume-last` consultation call for the entire set while a response remains
in the unified budget. The JSON response has exactly one disposition per
selected ID:

- **MAINTAIN** — the specific trigger and why counter-evidence fails;
- **RETRACT** — the specific fact that changes the position;
- **REFINE** — a restated claim or severity; or
- **VERIFY** — a factual question plus the specific command or trace that can
  decide it.

The response is one fenced `json` object with exactly `phase: "consultation"`
and `dispositions`. It is validated with `validate-consultation.py`. Every
strict normalized disposition contains only `id`, `action`, `claim`, `severity`,
`locations`, `trigger`, `impact`, `observations`, `falsifier`,
`proposed_checks`, and `open_factual_questions`; required factual fields are
non-empty. It must not contain identity, origin, selection reason, review count,
consensus, concession, rhetoric, transcript reference, debate verdict, or an
artifact path. An exit-0 non-empty response that fails canonical validation
gets exactly one correction with the gate-generated sealed retry prompt and its
stable validation diagnostic. A second malformed response, any missing/extra ID
that remains after that correction, or a failed runner produces `STATUS: PHASE 4
COMPLETE (SKIPPED — <reason>)`; Phase 5 then verifies the original normalized
finding data.

Accepted dispositions reach the verifiers only through
`build-verifier-packets.py`, which `pre-verification` runs over the frozen
base packets to produce `05-verifier-packets.ndjson`: **MAINTAIN** leaves the
base packet unchanged; **REFINE** replaces every packet field with the
disposition's; **VERIFY** and **RETRACT** keep the base claim, severity,
locations, trigger, impact and falsifier and append the disposition's
`observations`, `proposed_checks` and `open_factual_questions` (deduplicated,
order preserved). The action itself is never written to a packet. A retraction
is therefore a fact for the verifier to check, not a verdict: only Phase 5 may
record REFUTED. New unrelated claims are logged as LATE and
never block.

The unified exchange budget is at most **two successful round-wide Codex
responses** and **four total runner launches** across Phase 4 consultation and
Phase 6 residual resolution. Consultation uses one successful response at most,
leaving one for residual resolution. A retry counts as another launch.

## Phase 5 — Verification

For EVERY P0–P3 finding and every CONFLICT, regardless of who raised it or
whether both did, establish ground truth, preferring in order:

(a) a failing test or minimal repro in `/tmp` demonstrating the defect;
(b) exhaustive call-site trace with the decisive lines quoted;
(c) the project's existing tests, linter, typechecker — BUILD WORKSPACE
    DEPENDENCIES FIRST (a stale `dist` makes suites fail on missing exports at
    base and head alike; that is staleness, not a finding), then distinguish
    failures introduced by this change from failures already present on the
    base revision;
(d) git log/blame or ADRs for original intent.

Prefer a throwaway `git worktree` for anything that could touch the working
tree. Never auto-clean or restore the user's worktree.

Recipe for rung (a) without touching the repo (verified 2026-09-02 on a pnpm +
vitest workspace): create `<artifact>/repro/`, symlink the repo's root
`node_modules` into it, write a minimal `vitest.config.ts` whose `resolve.alias`
maps each workspace package by EXACT match (`{ find: /^@scope\/pkg$/, replacement:
'<repo>/packages/pkg/dist/index.js' }`, one more entry per subpath export such as
`/contract`), import the repo's test helpers by absolute path, then run
`npx --prefix <repo> vitest run --config <artifact>/repro/vitest.config.ts --root <artifact>/repro`.
A test that FAILS at head for the predicted reason is the E0 proof; keep its log
as `05-<id>-repro.log`.

With `--workflow` (`references/workflow-mode.md`): rungs (a), (b) and (d) run
per finding, concurrently, in `finding-verifier` agents through the shipped
workflow script; each receives only the strict normalized packet and returns
CONFIRMED / REFUTED / UNVERIFIABLE with its method and quoted evidence. Rung
(c) — the project's suite, linter, typechecker — is never run by those agents
(concurrent suites in one checkout collide on build output); run it once,
sequentially, for the findings that still need it. A verifier that returns
nothing (null) leaves its finding to you, in-context.

Only this phase may mark a finding CONFIRMED or REFUTED. Consultation agreement
is not evidence. Delete REFUTED from the main report; list it in the
false-positive appendix with the refuting evidence. Report exact commands and
results.

`05-verifier-packets.ndjson` is generated by `pre-verification` (see Phase 4)
and covers every `03-matrix.tsv` ID exactly once; verify from it and never
edit it — `pre-resolution` and `pre-report` rebuild it from `03-findings.ndjson`
and `04-consultation.json` and reject any difference. Write `05-verdicts.tsv` with one
`F-nn<TAB>verdict<TAB>method<TAB>evidence` line per matrix ID (verdict =
CONFIRMED, REFUTED, or UNVERIFIABLE; method = repro, trace, suite, history, or
none, or the rung spelling the verifier returns such as `(b) trace`; evidence = the strongest single `path:line[@sha] "quote"` citation or
`cmd: <command> -> <output excerpt>`). A CONFIRMED or REFUTED row needs a real
method and evidence that passes the packet citation rules; `validate-verdicts.py`
enforces this at `pre-resolution` and `pre-report`. This is the machine-readable
ledger `pre-report` cross-checks
`06-resolution-selection.ids` against, rejecting any ID not marked
UNVERIFIABLE. Citations in `locations`/`observations` are repository-relative
`path:line` or `path:line@sha "quote"`; wrap a path that contains spaces in
double quotes (`"docs/API guide.md":42`). Absolute paths, `.`/`..` segments,
scratch directories and this skill's run-artifact names (`00-brief.md`,
`05-verdicts.tsv`, …) at any depth are rejected by the validators.

## Phase 6 — Residual resolution

Only for items still UNVERIFIABLE after Phase 5 (a CONFLICT-origin item the
verifier could settle is CONFIRMED or REFUTED like any other), only if Phase 2
SUCCEEDED, and only when the shared successful-response/launch budget allows it.
Write `06-resolution-selection.ids` with one residual canonical ID per line;
`pre-report` validates it against `05-verdicts.tsv` and rejects any ID whose
verdict is not UNVERIFIABLE. Use the same fenced JSON exchange
protocol once with the executed verification evidence; `validate-consultation.py
--manifest ... --verdicts 05-verdicts.tsv --ids ... --phase resolution` requires
one complete disposition per residual ID before report generation. Change
position ONLY for new code-level evidence — never because the second opinion
sounds confident, never to end the exchange, and never because it is the second
opinion. If skipped, write `06-resolution.md` with the reason and its STATUS
line.

Anything still contested is reported UNRESOLVED with both positions, the
strongest evidence for each, and the recommended default — usually a QUESTION
for the author, but P1 if the downside is data loss or a security hole.

## Verdict policy

Apply the first clause that matches, top to bottom. Exactly one verdict results.

1. **BLOCK** — at least one CONFIRMED P0.
2. **REQUEST CHANGES** — at least one CONFIRMED P1; or an UNRESOLVED item whose
   downside is data loss or a security hole.
3. **NEEDS CLARIFICATION** — intent, base, or target is missing; or an
   UNRESOLVED P0/P1 (not covered by clause 2) prevents a defensible decision.
4. **APPROVE WITH COMMENTS** — at least one P2 or P3 finding remains
   (CONFIRMED or UNRESOLVED); QUESTIONs may also remain.
5. **APPROVE** — no P0–P3 finding remains; only QUESTIONs, if any.

A finding that was never verified in Phase 5 cannot be CONFIRMED; it is
UNRESOLVED and still counts for clauses 2–4 at its canonical severity.
