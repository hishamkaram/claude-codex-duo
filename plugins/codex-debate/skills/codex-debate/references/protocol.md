# Debate protocol

## Claims and the ledger

Every assertion that bears on the motion becomes a ledger row:

| ID | Owner | Claim (one sentence, falsifiable) | Grade | Evidence | Status | Changed in |
|---|---|---|---|---|---|---|

- IDs: `C-nn` yours, `X-nn` Codex's, `S-nn` seeded from a prior record (`--seed`). Never renumber. A refined claim gets a
  new ID and the old one is marked SUPERSEDED-BY.
- One claim per row. "X is slow and also unsafe" is two rows.
- Status: OPEN · VERIFY-PENDING (a VERIFY was committed to and not yet run) · CONCEDED-BY-CLAUDE ·
  CONCEDED-BY-CODEX · VERIFIED-TRUE · VERIFIED-FALSE · SUPERSEDED-BY <id> · UNRESOLVED · LATE
  (raised after round N-1, cannot decide the ruling).
- With one opponent the Owner column reads `claude`, `codex`, `seed`, and the grammar above is
  the whole grammar. With N ≥ 2 participants (§N participants below) the opponents' ids are
  `X<k>-nn` (participant p<k>: `X1-01`, `X2-01`, …), their owner is `p<k>`, and a concession by
  participant k is `CONCEDED-BY-P<k>`; `C-nn`, `S-nn` and every other status are unchanged.

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

## N participants — moderated pairwise rounds (`--via` with two or more entries)

The debate stays a set of one-on-one debates that share one ledger; it is never a free-for-all
in which participants answer each other. You are the moderator as well as one side.

- **Blind takes.** Every participant gets the same blind brief and writes its own take
  (`02-blind-p<k>.md`, claims `X<k>-nn`). The takes are extracted into the shared ledger
  (`03-ledger.md`, the living copy; each round file also snapshots it).
- **Who debates next.** Before every round run
  `scripts/next-opponent.py --art "$ART" --rounds <N> [--total-rounds <M>]`; it prints the
  next opponent or that the debate is over, and its rule is the schedule:
  - **dissent score** per participant = the sum over its OPEN and VERIFY-PENDING rows of the
    grade weight (E0 = 4, E1 = 3, E2 = 2, E3 = 1, E4 = 0), counting only rows that name a `C-nn`
    id (they attack one of your claims); a participant with no such row scores over all its
    open rows. Highest score debates next; ties go to the lowest k.
  - **one-turn coverage**: a participant that has already had a turn since every eligible
    participant last had one is skipped until the others have had theirs. The one exception is
    a VERIFY-PENDING row with the participant just faced: the check is run and that pair
    continues, because a pending verification decides more than a new opinion.
- **One round = one pair.** The round prompt (`templates/codex-round.md`) goes to that
  participant only, on that participant's own session (`references/codex-invocation.md`
  §Per-participant sessions), and addresses that participant's rows and the `C-` rows it
  attacked. Other participants' rows stay as they are; a fact VERIFIED in one pair applies to
  every row that rests on it (mark them VERIFIED-TRUE/FALSE with the same evidence), which is
  the only way one pair's round changes another pair's rows.
- **Pair-local termination.** Each pair owns its round counter with the user's round number
  (default 3, hard cap 5) and the convergence/stalemate rules above, applied to that
  participant's rows. The global budget (`--total-rounds`, default N × rounds, hard cap 5 × N)
  is a separate limit: when it is spent, every pair that has not reached convergence,
  stalemate or its own cap is recorded `UNRESOLVED (global budget)` — never as converged, and
  never silently. Round files are named `03-round-<n>-p<k>.md` (n global, k the participant).
- **Aggregated ruling.** Rule per participant first (the verdict policy below applied to that
  participant's rows), then aggregate: OVERTURNED if any participant's material opposing claim
  is VERIFIED-TRUE or your load-bearing claim is VERIFIED-FALSE / CONCEDED-BY-CLAUDE; else
  UNRESOLVED if any pair ended `UNRESOLVED (global budget)` or with material rows OPEN;
  else REFINED if any pair refined the motion (state the amended motion; two incompatible
  amendments are UNRESOLVED); else UPHELD. A participant never debated (no round held) has its
  rows VERIFY-or-UNRESOLVED: verify what one command settles, mark the rest UNRESOLVED, and say
  so. Confidence is capped at the lowest pair's: any pair resting only on E3 caps the ruling at
  LOW. Agreement between participants is not evidence.

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
- **NO DEBATE** — no participant could be reached; only your position exists. With N ≥ 2, a
  participant that failed is recorded as such in §8 and the others still debate.

A ruling that rests on any E4 row is invalid. A ruling that rests only on E3
rows must carry `confidence: LOW`.
