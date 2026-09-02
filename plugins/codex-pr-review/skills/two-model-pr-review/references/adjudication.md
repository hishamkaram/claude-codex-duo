# Adjudication

## Phase 3 — Reconciliation matrix

Table every distinct finding from both reviews. Assign canonical `F-` IDs here;
keep the originating `CL-`/`CX-` ID in a column.

Merge duplicates only when same root cause at same location. Two consequences of
one root cause = one finding. Two independent defects at one location = two
findings.

Label each: **BOTH** | **CLAUDE-ONLY** | **CODEX-ONLY** | **CONFLICT**.
CONFLICT means both looked and disagree on existence, on root cause, or on
severity in a way that crosses a verdict boundary (P0↔P1, P1↔P2) or spans 2+
levels. A P1-vs-P2 disagreement is therefore a CONFLICT.

Every merged finding gets ONE canonical severity in the matrix. Provisionally
record the higher of the two; Phase 4 evidence sets the final severity. Never
average severities and never let the last speaker decide.

## Phase 4 — Verification

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
as `04-<id>-repro.log`.

Codex cannot execute tests or builds in its sandbox, so every rung-(a) and
rung-(c) proof is the lead's to run. Budget Phase 4 accordingly.

Mark each CONFIRMED / REFUTED / UNVERIFIABLE with the method used. Delete
REFUTED from the main report; list them in the false-positive appendix with the
refuting evidence. Agreement between you and Codex is NOT evidence. Report exact
commands and results.

## Phase 5 — Bounded debate

Only for items still UNVERIFIABLE or CONFLICT. Maximum 2 exchanges.

Send Codex: the finding, both positions stated fairly, and your verification
evidence. Require exactly one response type, each with a code citation:
- **MAINTAIN** — the specific trigger, and why the counter-evidence fails
- **RETRACT** — the specific fact that changed its mind
- **REFINE** — restated claim, possibly at different severity
- **VERIFY** — the point is factual and checkable; commit to a specific command
  or trace, run it, and let the output decide. Prefer this over arguing.

Hold yourself to the same discipline, including retracting your own findings.
Change position ONLY for new code-level evidence — never because Codex sounds
confident, never to end the exchange, never because it is the "second opinion."

New unrelated claims raised here are logged as LATE and unverified; they can
never be blocking.

After 2 exchanges, anything still contested is reported UNRESOLVED with both
positions, the strongest evidence for each, and your recommended default —
usually a QUESTION for the author, but P1 if the downside is data loss or a
security hole (asymmetric risk breaks ties toward caution).

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

A finding that was never verified in Phase 4 cannot be CONFIRMED; it is
UNRESOLVED and still counts for clauses 2–4 at its canonical severity.
