# Real solution vs. workaround (Phase 3)

## The operational test

A change is a **workaround** if it makes the symptom unobservable while leaving the mechanism that
produced it intact. Ask: after this change, can I still write a failing test that exercises the
same mechanism through a different entry point? If yes, it is a workaround.

Second test: describe the change in one sentence without naming the symptom or the input number.
If you cannot, it is a patch.

## Five gates — any NO makes it a workaround

| Gate | Question | Fails as |
|---|---|---|
| G1 Mechanism | Does it change the code that causes the wrong state, not code that observes or repairs it? | symptom suppression |
| G2 Universality | Does it fix every call site of the mechanism? Cite the exhaustive search; report `fixed/total`. | whack-a-mole |
| G3 Invariant | Is the invariant enforced structurally — types, schema constraint, single choke point, exhaustive match — rather than by convention? | discipline-dependent |
| G4 Deletion | Does it remove or unify code? Count net new branches, flags and special cases. Real fixes usually subtract. | complexity accretion |
| G5 Regression proof | Is there a test that fails at the base SHA and exercises the mechanism, not just the reported input? | unproven |

## Auto-classify as workaround

- try/catch or null-guard at the crash site with no change to what produced the bad value
- retry, sleep or timeout bump for a race whose ordering is not fixed
- defensive re-validation of data a writer must never have produced
- cache invalidation added because the cache key is wrong
- `if (caller === X)` or a new boolean to make one caller behave differently
- rewriting the test, snapshot or threshold instead of the behaviour
- a copy of a function with the fix applied, original left in place
- a feature flag used as the fix rather than as the rollout mechanism

## Counterweight — read before scoring

The gates reward structure and therefore bias toward rewrites. Score every candidate also on:

- **Blast radius**: files, modules, public API and schema deltas; consumers affected (cite counts)
- **Reversibility**: can it be reverted after 24 hours of production writes? Migrations cannot.
- **Verifiability**: can correctness be demonstrated by tests that exist or that this PR adds?
- **Cost of being wrong**: worst realistic outcome and its detection latency

A design passing all gates with irreversible migrations and a 40-file blast radius loses to one
passing all gates in 4 files. "Real" means addresses the cause, not large.

## Mandatory candidates in `03-designs.md`

Always score: **do-nothing** (state the cost of the status quo), **the largest correct change**
(unlimited review budget), and **the tempting workaround** (labelled, rejected, so the rejection is
on record). The chosen design must beat all three in writing with a specific reason, never
"simplicity". Every score cell cites an `F-`/`V-` id or says `n/a`.

## Escape hatch: TACTICAL_MITIGATION

Permitted only with all four: (1) the structural design written out in full in `03-designs.md`;
(2) a filed follow-up issue, number recorded; (3) a removal trigger — date, release, or condition;
(4) a code comment at the site pointing to the issue. Never labelled "fix" in the PR body. Never
silent. Honesty must be cheaper than pretending.

## Single-PR hypothesis

Phase 2 ends with a shared-cause verdict: SHARED (one mechanism explains every input), PARTIAL
(overlapping mechanisms or the same change surface), DISTINCT (different mechanisms and surfaces).
SHARED → one PR. PARTIAL → one PR only if the change surfaces overlap by file; say which inputs
ride along. DISTINCT → recommend a split even if one PR was requested, and say so before Phase 3:
forcing unrelated fixes into one PR is itself a workaround of the review process.
