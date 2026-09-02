# Debate protocol

## Claims and the ledger

Every assertion that bears on the motion becomes a ledger row:

| ID | Owner | Claim (one sentence, falsifiable) | Grade | Evidence | Status | Changed in |
|---|---|---|---|---|---|---|

- IDs: `C-nn` yours, `X-nn` Codex's, `S-nn` seeded from a prior record (`--seed`). Never renumber. A refined claim gets a
  new ID and the old one is marked SUPERSEDED-BY.
- One claim per row. "X is slow and also unsafe" is two rows.
- Status: OPEN · CONCEDED-BY-CLAUDE · CONCEDED-BY-CODEX · VERIFIED-TRUE ·
  VERIFIED-FALSE · SUPERSEDED-BY <id> · UNRESOLVED · LATE (raised after round
  N-1, cannot decide the ruling).

## Evidence grades — use exactly these

- **E0 Executed** — a command, test, or repro run in this debate whose output
  is quoted. Decisive for factual claims.
- **E1 Traced** — every relevant call site or code path read and the decisive
  lines quoted with `path:line`.
- **E2 Cited** — a specific doc, ADR, spec, vendor reference, or git history
  entry quoted.
- **E3 Reasoned** — sound argument from stated premises, premises themselves
  graded.
- **E4 Asserted** — no evidence. Allowed in the ledger, never allowed to
  decide anything.

A claim's grade is the grade of its weakest load-bearing premise. Higher grade
beats lower grade on a factual question. On a judgment question (which design
is better), grades bound how confident the ruling may be: a ruling resting only
on E3 must say so.

## Response discipline — binds both sides equally

Every reply to an opposing claim is exactly one of:

- **MAINTAIN** — the claim stands. Must name the specific evidence the
  opponent's attack fails to overcome, or new evidence. Restating is not
  maintaining.
- **RETRACT** — the claim is withdrawn. Must name the specific fact that
  changed the position.
- **REFINE** — the claim is restated more narrowly or at different strength,
  with a new ID. Must say what was wrong with the old version.
- **VERIFY** — the claim is factual and checkable; the side commits to a
  specific check (command, file, test) and the result decides it. Prefer this
  over arguing whenever it applies. For tool or language semantics (git, node,
  shell) the zero-footprint check is a throwaway `git init` repo or script in
  the scratchpad, not the user's repository.

Forbidden moves, each logged as a protocol failure in the round file:
- conceding without naming the fact that moved you;
- maintaining by restating;
- appeals to authority, popularity, confidence, or "best practice" without a
  citation;
- widening the motion mid-debate (new scope goes to LATE);
- answering a claim you weren't asked about instead of the one you were.

## Round structure

Each round, your message to Codex contains, in order:
1. the ledger as it stands (full table);
2. for every OPEN claim of Codex's: your response type and evidence;
3. for every OPEN claim of yours that Codex attacked: your response type and
   evidence;
4. at most 2 new claims of yours, each with evidence and grade;
5. the exact question Codex must answer for each OPEN row.

After Codex replies, you rule on every touched row and record the ruling in
part (c) of the round file BEFORE composing the next round. Verify anything
marked VERIFY now, quote the output, and set VERIFIED-TRUE/FALSE.

## Coupled defects

A debate about a fix can silently absorb a neighbouring defect (a second bug at
the same site that the opponent's argument leans on). When that happens, give
the coupled defect its own ledger row, state its own fix, and ask explicitly
whether the motion is conditional on it. Rule on the motion with the coupled
defect assumed fixed by its own remedy, and record the coupled defect as a
separate recommendation.

## Convergence and stalemate

Stop before the round cap when either holds after a round:
- **Convergence** — no row is OPEN. Every row is conceded, verified, or
  superseded.
- **Stalemate** — no row changed status in the last round AND no VERIFY is
  pending. Two consecutive rounds of pure MAINTAIN on both sides is a
  stalemate; a third round will not fix it.

## Anti-sycophancy checks — run before writing each ruling

- Did I concede anything this round? If yes, name the fact. If I cannot, undo
  the concession.
- Did I maintain anything by restating? If yes, either produce evidence or
  downgrade the claim to E4.
- Has any Codex claim been sitting OPEN at E0 or E1 while mine sits at E3 on
  the same point? If yes, the ledger already says who is winning that point.
- Across the whole debate, if I conceded nothing and Codex conceded nothing,
  the ruling must say so and must be labelled low-confidence.

## Verdict policy

Rule on the motion, not on who argued better.

- **UPHELD** — the position stands; every material opposing claim is
  CONCEDED-BY-CODEX, VERIFIED-FALSE, or SUPERSEDED into something conceded.
- **OVERTURNED** — a material opposing claim is VERIFIED-TRUE or your
  load-bearing claim is VERIFIED-FALSE / CONCEDED-BY-CLAUDE.
- **REFINED** — the original motion is wrong as stated but a narrower or
  amended version is upheld; state the amended motion.
- **UNRESOLVED** — material rows remain OPEN or UNRESOLVED after stalemate or
  the cap. State both positions, the strongest evidence for each, and the
  recommended default. Asymmetric stakes break ties toward the safer option.
- **NO DEBATE** — Codex could not be reached; only your position exists.

A ruling that rests on any E4 row is invalid. A ruling that rests only on E3
rows must carry `confidence: LOW`.
