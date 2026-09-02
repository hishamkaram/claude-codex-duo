# Review rubric

## Scope

Diff-anchored, blast-radius-aware. Primary object is `<BASE>...HEAD`, but for
every changed function, type, endpoint, schema, config key, or public symbol:
grep all call sites and consumers repo-wide (tests, scripts, IaC, generated
clients) and check each against the new behavior.

Review DESIGN (right approach? fits existing architecture? simpler pattern
already used here? reversible?) and IMPLEMENTATION (does it do what it claims?)
as separate passes. Write the DESIGN pass as its own short section (those four
questions, answered) above the findings; design problems that are defects still
become findings.

Exclude lockfiles, generated and vendored code by name with a one-line sanity
check. If the diff exceeds ~2000 LOC, review subsystem-by-subsystem with
per-subsystem coverage notes rather than skimming.

## Checklist — apply every category; write "n/a" where it doesn't apply

Silence is not coverage.

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
