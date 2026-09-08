# Review rubric

## Scope

Diff-anchored, blast-radius-aware. Primary object is `<BASE>...HEAD`, but for
every changed function, type, endpoint, schema, config key, or public symbol:
search all call sites and consumers repo-wide (tests, scripts, IaC, generated
clients) and check each against the new behavior.

Search with the **Grep tool** and the **Glob tool**, never with a shell search command: they are
read-only and never wait on an approval nobody is watching for, while a Bash search can block a
reviewer indefinitely. Use Bash for `git -C <repo> show|diff|log` at a pinned SHA, for the pinned
`git grep` fallback when the working tree is not the review head, and for running a repro. A tree
search finds candidates; confirm every line you quote or count at the pinned SHA before citing it.

Review DESIGN (right approach? fits existing architecture? simpler pattern
already used here? reversible?) and IMPLEMENTATION (does it do what it claims?).
Design problems that are defects still become findings.

Exclude lockfiles, generated and vendored code by name with a one-line sanity
check. If the diff exceeds ~2000 LOC, review subsystem-by-subsystem with
per-subsystem coverage notes rather than skimming.

## Output contract — selected by the `Tier` line in the brief

**What you REVIEW never changes with the tier.** Every category below is applied
at every tier, both lenses are considered, and consumers are searched repo-wide.
The tier governs only how much of that reasoning you WRITE DOWN.

- **`compact-v1`** (the default). ONE combined pass. Do NOT write a separate
  DESIGN section, and do NOT walk the checklist category by category. Write: the
  findings; the exact commands you ran with their results; any path you could NOT
  review and why; and anything left unresolved. A design problem is filed as a
  finding like any other. Under this tier, saying nothing about a category is not
  a claim of coverage — the category recital is omitted, not abbreviated.
- **`full`**. Both passes written separately: the DESIGN pass as its own short
  section (those four questions, answered) above the findings, then the
  IMPLEMENTATION pass; every checklist category marked reviewed or `n/a`, where
  silence is not coverage; and a closing coverage statement naming each category.

Neither tier may drop a finding, soften a severity, skip the consumer search, or
claim a check it did not run. A finding costs the same in both tiers; only the
prose around it differs.

## Checklist — apply every category; write it up as the output contract directs

- **Intent conformance, both directions:** does it accomplish the stated goal
  fully, and does the diff contain changes NOT explained by the stated intent?
- **Correctness:** logic, boundaries, empty/null, error paths, early returns,
  type coercion, timezone/encoding, float-vs-decimal money.
- **Error handling:** swallowed exceptions, over-broad catches, partial failure
  leaving inconsistent state, missing timeouts, unbounded retries.
- **Concurrency & state:** races, non-atomic read-modify-write, lock ordering,
  transaction boundaries, handler/job idempotency, cache invalidation.
- **Data & migrations:** reversibility, lock/downtime risk on large tables,
  index strategy, backfill correctness and restartability, expand-then-contract
  ordering, and whether OLD and NEW code can both run against the migrated
  schema mid-rollout.
- **Backward compatibility:** API shape, event/serialization schema evolution,
  config defaults, persisted formats, N-1 version skew between services and
  client/server.
- **Security:** authn/authz on every new entry point, object- and tenant-level
  access control, injection (SQL/command/template/path), SSRF, deserialization,
  secrets or PII in logs, new dependency provenance, permission changes.
- **Performance:** N+1 queries, missing indexes for new query shapes, unbounded
  result sets / missing pagination, work added to hot paths, blocking I/O on
  async paths.
- **Tests — adequacy not presence:** would these tests FAIL if the production
  change were reverted or mutated? Are new branches and error paths covered? Do
  they assert behavior or re-assert mocks? Any flakiness (time, ordering,
  network, randomness)?
- **Observability & ops:** debuggable from logs/metrics? kill switch? rollback
  story?
- **Maintainability:** dead code, duplicated logic, misleading names, stale docs.

## Severity — use exactly these

- **P0 BLOCKER** — data loss/corruption, security vulnerability, breaks
  production or a documented contract, or the change fails its stated purpose.
- **P1 MUST FIX** — real defect on a reachable path, or an expensive-to-reverse
  design choice.
- **P2 SHOULD FIX** — real but tolerable; acceptable as tracked follow-up.
- **P3 NIT** — optional, cap at 5 total.
- **QUESTION** — suspected problem with no established trigger.

## Confidence

- **HIGH** — verified by execution, or by tracing every call site.
- **MEDIUM** — careful read of all relevant code, not executed.
- **LOW** — suspicion only.

Gate: no P0/P1 may be filed at LOW confidence — it becomes a QUESTION.
