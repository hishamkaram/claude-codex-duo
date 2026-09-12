# Changelog

All notable changes to this repository are documented here. Versions follow [Semantic Versioning](https://semver.org/).

## [shared runner — recovery binds to a job, not to a prefix] - 2026-09-11

**BREAKING**: `--expected-job` is now required on every `codex-run.sh --attach`.

`codex-pr-review` 7.0.0 · `codex-deep-plan` 4.0.0 · `codex-debate` 3.0.0 — the runner is shipped
byte-identically by all three and its `--attach` command line gains a **required** option, so all
three are released together, and as a MAJOR bump: `scripts/codex-run.sh`'s command line is part of
the versioned surface (the skills' own recovery instructions tell an operator to run it), a
previously valid invocation is removed, and every `attach_command` persisted by an earlier release
stops working. A minor bump would have let a `^6.1.0`-style range pick this up silently.

> **Migration.** `--expected-job` is now mandatory on every `--attach`, cancellation included. The
> `codex-run.sh <prefix> --attach` and `--attach --cancel` forms shown in the two entries below are
> the pre-2026-09-11 spelling and are refused by this runner. Run the `attach_command` the runner
> recorded (in `.meta` and `<prefix>.detached`); a saved command from before the binding existed is
> refused with the correctly bound command to run instead.

Two P1 defects found by the two-model review of the durable-job work below. Both are the same
mistake from opposite ends: **a recovery action was bound to a prefix rather than to a job
identity.** One was the case where no identity had been persisted yet, the other the case where a
stale identity was reused.

- **An interrupted CCR launch could wedge a whole run directory, permanently.** A SIGINT inside
  the admission window left a prefix with a claim and a `.progress` and nothing else. `release`
  refused (its CCR stop check loads `<prefix>.ccr-attempt.json` and raises when it is missing),
  the attach that refusal named could not be admitted (no `<prefix>.detached`), and a relaunch
  refused as an unfinished legacy attempt — so an ordinary Ctrl-C destroyed every artifact the run
  had already produced, with no command that said so.

  The refusal was not protecting anything, and this is provable rather than assumed: the runner
  now writes `<prefix>.ccr-prelaunch` carrying `CCR_PROTOCOL` **before anything can be submitted**,
  and `ccr-job.py prepare()` already persisted `<prefix>.ccr-attempt.json` (fsync + atomic replace)
  strictly before spawning the submitting process. There is no interleaving in which a workload
  exists without the attempt record. A prelaunch marker at the current protocol, with no attempt
  record and no receipt, therefore *proves* no workload was submitted, and `release` frees the
  claim. Absence of the marker proves nothing — a legacy attempt and externally deleted state look
  identical — so those keep failing closed. Exclusivity is unchanged and already sufficient:
  `release_claim` holds `<prefix>.claim.lock`, the same kernel lease a live collector or a
  surviving preparation helper holds, and proves the recorded runner pid and its descendants are
  gone first. `scripts/validate.sh` check 4b1 fails the build if the runner and the gate ever
  disagree about the protocol number, because a gate that honoured a marker written under an
  ordering it did not understand would free a claim whose job may be alive.

- **A saved attach command could collect, and cancel, a different job.** For the companion backend
  the saved command named only the prefix and the three watch bounds. A prefix is legitimately
  reusable — the gate rotates a spent claim, the runner rotates the previous attempt's sidecars —
  so running a stale saved command watched whichever job occupied the prefix now, under the old
  attempt's stall policy, and cancelled it when that bound elapsed. The gateway backend never had
  this hole: its saved command carries `--expected-job` and `verify-attempt` compares it before
  collection. The companion backend now carries the same binding, `--expected-job` is accepted on
  a prefix whose durable record is a `.detached` (it previously required a CCR attempt, which a
  companion prefix never has), and the comparison runs under the publication lock the attach
  already holds, before anything is observed or cancelled.

- **The proof reaches the runner, not only the release gate.** Teaching it to the gate alone left
  the prefix wedged *while reporting `RELEASED`*: `release` does not remove `<prefix>.progress`, and
  the runner's `refuse_if_in_flight` exits 4 on it before `rotate_previous_attempt` would archive
  the orphan that causes the refusal — so the operator looped between a gate that issued a claim
  and a runner that refused it, burning a spent claim each pass. `proven_pre_submission` now states
  the identical predicate on the runner side and is consulted in one place only: the branch where
  the attempt is otherwise unidentifiable (no CCR launch line, no companion job id). Everywhere
  else there is a job whose owner can be asked, and asking beats inferring.

- **A lone `<prefix>.ccr-prelaunch` is archived by the next launch, never inherited.** The marker is
  written one line before `<prefix>.progress`, so an interruption between them leaves a prefix
  carrying a marker and none of the three files rotation used to trigger on. Once the runner honours
  a marker, an inherited one could vouch for an attempt it knows nothing about — authorizing a
  launch beside work that may be live. The marker is now itself a rotation trigger.

- **Every field the marker carries is checked**, on both sides. `stage=` reads as a discriminator,
  so it is one: a later author adding a second stage under the same protocol number cannot have it
  silently accepted as a pre-admission proof, which the protocol-agreement check would not catch
  because it compares only the integers.

- **The attach binding asks the CALLER, not the record. BREAKING for `--attach`.** The first
  attempt at this asked whether the record on the prefix was bound, and accepted an attach that
  named no job whenever it was. That answers a question about the attempt that is *here*, not about
  the one the incoming command was written for — and since a deliberate interactive attach and a
  stale pre-binding saved command have identical arguments, a bound record vouched for every unbound
  caller. An old command replayed against a newer attempt was admitted, watched it, and on its stall
  bound cancelled it: exactly the defect the binding exists to prevent. `--expected-job` is now
  required on every attach on both backends, cancellation included, and must match the job the
  record names; both refusals observe and cancel nothing. There is no weaker check, because there is
  nothing in the process to separate the two cases by. The gateway backend's early cancellation
  path, which reaches the job before the record is read, applies the same requirement in place.
  Unbound admission *discovery* is gone rather than unchanged: the ordering entry below moves the
  refusal above the recovery step, so nothing unbound reaches it, and a lost receipt is repaired by
  the explicit discovery command instead.
- **Every emitted attach command comes from one generator**, is shell-quoted and carries an absolute
  prefix. The refusal above hand-built the command it told the operator to run, so it split at the
  first space in an installation or artifact path — the one actionable remedy it offered did not
  work on paths the quoting tests explicitly support. The unbound fallbacks, the stored commands the
  runner and the phase gate used to forward verbatim, and the command an attach copies forward into
  its own record are all regenerated bound, so no path can print a command the admission block would
  refuse.
- **The release predicate matches the runner's in WHERE it is consulted, not only what it tests.**
  The gate's copy never looked at `<prefix>.progress`, so it was reachable with a completed gateway
  launch on record — the strictly more permissive half of a pair whose comments claim symmetry, and
  the half that *frees* a claim. It now requires the absence of a launch line and of a companion job
  id, as the runner's placement does. The detached-record decision also moved below the runner-pid
  and descendant proofs it names as its precondition, which previously ran after it.
- **The permitting branch leaves evidence.** A launch authorized by the pre-submission proof records
  `PRE-SUBMISSION-PROOF:` in the new attempt's `.progress`, and a release authorized by it records
  `evidence=pre-submission-proof(protocol=N)` on the spent claim and on the `RELEASED` line;
  releases backed by stop evidence or by companion status record theirs the same way. Previously
  nothing distinguished the one branch that permits from the ordinary ones.
- **`<prefix>.ccr-prelaunch.part`** — the marker's staging name — is rotated with the attempt it
  belongs to. A kill between its write and the rename left a permanent file that reads as a marker
  in a directory whose names are load-bearing evidence. It is archived, never read: nothing treats a
  staging file as authorization, and a prefix carrying only one still fails closed.
- **The attach binding is required before anything is read, written or cancelled.** It was checked
  thirty lines below the admission block, which calls `ccr-job.py recover` — and `recover` rewrites
  `<prefix>.ccr-attempt.json` and can publish `<prefix>.detached`. So an unbound attach mutated the
  record it was about to be refused for, while the refusal stated that nothing had been observed,
  cancelled or written. The refusal now precedes both, and the job id its remedy names is read
  directly from the attempt record or the receipt rather than by running recovery to find it. The
  gateway backend's early cancellation path keeps its position ahead of the collector lock — it must
  stay reachable while another collector holds the lease — and already required the binding.
- **A lost receipt is repaired by submission-status discovery, not by attaching unbound.** An
  attempt record does not imply a receipt: preparation precedes admission, so a prefix can carry
  `<prefix>.ccr-attempt.json` with no receipt at all. Recovery for that state is the read-only
  submission lookup and receipt reconciliation, documented in all three protocol references; the
  attach that follows it is bound like every other. Naming a job discovered elsewhere does not
  substitute for it — the binding check requires a readable receipt and refuses without one.
- **A refusal's remedy carries the bounds the attempt was LAUNCHED with**, in the runner and in the
  phase gate's hint, instead of the bounds of the invocation being refused (or, for the gate, none at
  all). On an attach the stall bound is not advisory — reaching it sets `STALLED` and issues a real
  cancel — so a printed recovery that silently shortened it converted the recovery into a
  cancellation of the live job.
- **A launch error keeps the proof note.** `launch_error` truncates `<prefix>.progress` with `>`, so
  the `PRE-SUBMISSION-PROOF:` line written above it was erased on the one branch that both permits a
  relaunch and then fails to start it — leaving an archived orphan with no record of what authorized
  archiving it. The note is now written after the truncation, on every reachable path.
- **The live gateway suite attaches bound, and a build check reads its argument lists.** The suite
  is executed only by the CCR live workflow, never by `scripts/validate.sh`, so making
  `--expected-job` mandatory broke it on every CI configuration while the repository's own
  validation stayed green. Both call sites now pass their own launch's `receipt['job_id']`, and
  `scripts/test-args.sh` parses the suite's positive `subprocess` argument lists and fails the build
  on an unbound one — the deliberate refusal fixtures are allow-listed by name.
- **An unknown watch bound is stated, never substituted.** The remedy's bounds were read from the
  detached record alone, while the job id its own message names is read from three sources — so on
  the prefix an interrupted admission leaves behind (receipt written, detached record not yet
  published) the message named a job and carried the *refused caller's* bounds, which is the
  substitution the entry above says it removed. There are exactly two durable sources for the
  bounds: the detached record's stored command, and the attempt record's numeric `stall_min` /
  `max_min` / `poll_sec` fields. The receipt is not a third — reconciliation keeps only the three
  identity fields. When neither yields a complete, positive-integer tuple the runner now says the
  bounds are unrecorded and offers no runnable command, rather than filling them in from the
  invocation being refused. `ccr-job.py`'s recovery composer and the phase gate's regenerated hint
  follow the same rule: neither manufactures `6/25/15` for a field the record does not carry.
  Unchanged on purpose: an accepted attach and a fresh detach still use the invocation's bounds,
  because there the caller *is* the watcher.
- **A lost receipt is refused as a lost receipt, and names the command that repairs it.** The
  binding is compared against the delivered receipt, so an unreadable one fails before any
  comparison — for every job id, the correct one included — and the single fixed message said
  "saved attach belongs to a different attempt". That told an operator in the one recoverable state
  that their correct command was wrong, and named nothing to run. The two failures are now
  distinguished, and the lost-receipt branch names `ccr-job.py recover <prefix>` — the read-only
  submission-status lookup, which rewrites the delivered receipt under the same identity-conflict
  checks and submits nothing — after which an ordinary bound attach works. That lookup now covers
  **either** lost-delivery state: an attempt record with no receipt of its own, and a delivered
  receipt that is missing or unreadable while the record still carries its copy. Previously an
  embedded receipt suppressed the lookup, which made the repairing operation unavailable in exactly
  the state that needs it. `complete-admission` is deliberately **not** named here: when the gateway
  still reports the admission prepared it replays the saved launch request under its original token
  and may start execution. It never requests a replacement job, but finishing an admission is a
  decision, not an observation, and describing it as read-only was wrong in five places.
- **The binding refusal is above the lock, not only above recovery.** `publish_lock` creates
  `<prefix>.claim.lock` with an append redirect, so the refusal's "nothing was observed, cancelled
  or written" was false by one file. It reads the durable records and nothing else, so it needs
  neither the lock nor recovery, and now runs before both.
- **The release proof excludes a detached record.** The gate's pre-submission proof gained the
  launch-line preconditions last release but not the runner's enclosing `[ ! -e .detached ]` — and
  the branch that consults it fires *because* that record exists, so a record naming a job could be
  released on a proof that says nothing was ever submitted. No code path produces that state; only
  external damage does, which is precisely what the surrounding comment says must fail closed.
- **A fixture that reproduces a caller by hand is a fixture that cannot fail.** The
  relative-prefix test still synthesized `bound_attach_command "$JOB"`, one argument to a
  four-argument generator: `shift 4` failed, the bounds expanded empty, the job was left as a
  trailing argument, and its permissive stub reported success. Both saved-command fixtures now lift
  the runner's own assignment line through one shared extraction that requires an unambiguous
  match, and both assert the complete argument vector.
- **A command with no bound options is not silent about bounds.** The unrecorded-bounds rule above
  emitted `<runner> <prefix> --attach --expected-job <job>` and left the options off — and the
  runner substitutes `6/25/15` for every option it is not given, so that command *means* a
  six-minute stall threshold that cancels, chosen by the parser rather than by the record. The phase
  gate then forwarded it untouched, because its early return accepted any command carrying the
  binding. The composer now records an **empty** `attach_command` plus an `attach_guidance=` line
  saying the bounds are unrecorded and must be chosen deliberately; the gate validates all three
  bounds before forwarding *any* stored command, binding included; and the runner prints the
  guidance where it would otherwise print an empty line. No consumer invents a fallback.
- **A refused attach never publishes `.exit`.** `die4` suppressed its terminal write only when one
  of eight sidecars already existed, and the binding refusal was deliberately moved above every
  writer — so on a bare prefix, the one state that refusal always runs in, the message "nothing was
  observed, cancelled or written" was published as a terminal `4` that every gate reads as a
  finished attempt: a stronger write than the `.claim.lock` the refusal was moved above to avoid.
  An attach is never the attempt a `.exit` describes — it is a second watcher of a job another
  invocation launched — so no attach publishes one, marker or no marker. A launch-shaped argument
  error still does, because that *is* this invocation's attempt. `<prefix>.ccr-prelaunch` and its
  staging name are now also markers, where rotation already treated them as attempt markers.
- **A stored bound is read as a whole token, or not at all.** The runner extracted each with a
  `sed` matching `[1-9][0-9]*` followed by `.*`, so the trailing pattern ate the rest of the token
  and `--stall-min 1e2` was read as `1` — a one-minute cancellation threshold the record never
  expressed, invented by the reader. Both readers now parse the stored command with `shlex` and
  require each value to be a complete positive integer, failing to the unrecorded-bounds message.
- **The lost-receipt remedy is shell-quoted like every other emitted command.** `abs_path` makes a
  path absolute; it does not quote it, so the one command added by the previous entry fell apart on
  exactly the artifact paths the quoting tests support. It is composed through `quote_command` now.
- **A remedy disappeared on a prefix containing a colon.** The job-id lookup packed `path:field`
  into one word and unpacked it with `${f%%:*}`, which strips from the *first* colon — so any
  artifact path containing one truncated, the record was never found, and the refusal ended without
  the remedy it promises. It fails safe (nothing wrong is printed) but silently. Path and field are
  separate values now.
- **An attach never republishes the record's attach command, on either backend.** The command is
  regenerated and bound when an attach is admitted, and the companion path kept that value; both
  gateway detach paths read it back out of the record, so the attach that had just computed the
  correct command republished whatever the record held — an unbound command from a pre-binding
  record, or the empty one the entry above introduces. The rule held on one backend only.
- **The release-policy check asserts a relation, not this release's numbers.** Its first version
  required `"version": "[0-9]+\.0\.0"` in every manifest unconditionally and grepped for this
  entry's own heading, so it asserted "the repository is at 7.0.0/4.0.0/3.0.0" — true the day it was
  written, false at the next ordinary release, and blind to the drift it is named for, since it
  never compared a manifest to the changelog at all. It now reads the top entry's per-plugin
  versions and requires the three manifests and the marketplace record to agree with them, and a
  major bump exactly when that entry is labelled BREAKING.
- **The gate's recovery hint kept its own prefix.** `detached_attach_hint` split the stored bounds
  with `set -- $bounds` and then cleared the positional parameters with a bare `set --`, while both
  regeneration branches still used `$1` for the prefix. Under the file's `set -u` that aborts the
  command substitution the hint is computed in, so the two refusals that tell an operator how to
  recover a detached attempt printed no command at all — in exactly the two record shapes the
  branches exist for (a legacy unbound command, and the empty command the entry above introduces).
  Only the early return survived: the function worked in the one case where it does nothing. The
  prefix is now captured before anything can clobber `$@`, and the bounds are read with `read`.
- **The release-policy check can now fail, and tests a relation between two releases.** Three
  defects in one fixture, each hiding the next. Its `2>&1` sat on its own line after the heredoc
  terminator, which inside `$(…)` is a separate, successful command — so the substitution's status
  was 0 however the validator exited, and the check could not report anything for any input. Behind
  that, the BREAKING clause tested the *shape* `X.0.0` rather than an increase, so a breaking
  release repeating the current versions passed; and it matched the word anywhere in the entry body,
  so an ordinary release whose notes merely said "nothing here is BREAKING" was forced to a major
  bump. The check now requires each declared version to increase over the most recent earlier entry
  naming that plugin, with the major component increasing exactly when the entry carries a
  **BREAKING** label — a line of its own, which this release now carries. Four scratch-tree cases
  cover both directions, and one asserts that a failing check is reported at all.
- **A delivered receipt that is not an object is not a receipt.** `delivered_receipt_readable`
  called `.get()` on whatever `json.loads` returned, so a receipt of `null` or `[]` raised
  `AttributeError` — past its own `except` clause and past the command-line handler — out of
  `recover()`, the command every lost-receipt refusal names. The runner's own `receipt_readable`
  had the mirror-image defect: it accepted any document with a non-empty `job_id` while the binding
  it guards requires all three identity fields, so a receipt that parsed but was incomplete failed
  the binding and then passed the readability test, and the operator was told their correct command
  "belongs to a different attempt". Both predicates now ask the same question of the same file.
- **The relaunch refusal names a remedy on both backends.** The job was read only inside the
  companion arm of the backend test, so on the gateway backend neither the regeneration nor the
  unrecorded-bounds sentence ran, and the record's own `attach_command` was echoed — a blank line
  for the record shape whose command is deliberately empty. The job is read for both arms now, and
  anything still empty renders the record's own guidance.
- **The identity-mismatch refusal writes nothing either.** It sat below `publish_lock`, which
  creates `<prefix>.claim.lock` and never unlinks it, so the refusal that says nothing was observed
  or cancelled left a file on a prefix it had just refused — the same file the binding-presence
  refusal was moved up to avoid. The comparison now runs as soon as the record names a job, before
  the lock; the comparison below it stays, as the authoritative one and the one that refuses a
  record naming no job, and both go through a single refusal so the message cannot drift.
- **An empty attach command travels with the reason it is empty.** Both publication blocks copied
  `attach_command` and dropped `attach_guidance`, so a republished record stopped explaining its own
  empty field.
- **The T-3 fixture links the real interpreter, not `command -v python3`.** On a machine where
  `python3` is a version-manager shim (pyenv, asdf), the shim re-execs through helpers — `basename`
  among them — that T-3's deliberately bare PATH does not carry, so the symlinked shim failed before
  the runner could reach the check T-3 exists to make. Pre-existing; unrelated to the rest of this
  entry.

## [shared runner — guarded CCR continuation] - 2026-09-11

`codex-pr-review` 6.1.0 · `codex-deep-plan` 3.1.0 · `codex-debate` 2.1.0.

- Require CCR0.6.0 for transactional submissions and same-session continuation.
- Persist submission identity before launch; recover lost receipts by read-only status.
- Require explicit expected-parent jobs and resolve session heads before round prompts.
- Validate committed output boundaries/digests and distinguish stopped from never started.
- Preserve claims on unresolved admission, ownership, identity, or output evidence.

## [shared runner — CCR durable job ownership] - 2026-09-11

`codex-pr-review` 6.0.0 · `codex-deep-plan` 3.0.0 · `codex-debate` 2.0.0.

### Changed
- Requires CCR 0.5.1 for the CCR review backend. Launch, smoke, watch, attach,
  cancellation, claim release, and termination confirmation use durable CCR jobs.
- CCR resume is temporarily unavailable: both resume options return exit 4 before
  admission or claim mutation. Explicitly record unavailable continuity and use a
  self-contained fresh exchange for subsequent CCR rounds. Codex resume is unchanged.
- Drain legacy process-based attempts with the original runner before upgrading.
  The new runner never derives workload cancellation authority from PID/PGID records.

### Fixed
- Persist attempt inputs and the receipt before releasing admission ownership.
  A dead watcher is immediately attachable; missing receipts remain unresolved and
  never permit automatic resubmission or terminal claim release.
- Require positive exit and cleanup evidence separately from successful output.
  Unknown cleanup and observed survivors keep the attempt open; partial coverage
  remains visible. A failed job cannot promote a successful-looking result event.
- Bind accepted output to job/session/model identity and committed log bytes.
  Changed or truncated result evidence fails validation; later appends cannot
  replace the result. Attach retains the launch's original control context.
- Detect activity on CCR's source log, so polling copies do not mask a stalled job.

## [shared runner — detach on the watch bound; tri-state availability] - 2026-09-09

`codex-pr-review` 5.1.0 · `codex-deep-plan` 2.4.0 · `codex-debate` 1.3.0 — the runner is shipped
byte-identically by all three, and its caller-visible exit contract gains a state (**6**), so all
three are released together.

Two defects in `scripts/codex-run.sh`, the runner all three plugins ship byte-identically. Both
have the same shape: a state the runner could not determine, or had merely stopped observing, was
reported as a terminal negative. Planned with a blind second-model diagnosis and a three-round
debate (artifacts: `runner-hard-negatives-20260909-140134`, termination T1).

### Fixed
- **The watch bound killed healthy jobs.** `--max-min` bounds the *runner's monitoring loop*, but
  it was implemented as a kill: TIMEOUT entered the same branch as STALLED and cancelled the
  companion job or signalled the ccr child's group. Reproduced at `09543ad`: a job logging
  progress on every poll was cancelled at 63 s and its `.stdout` held 306 bytes whose only content
  was `Cancelled by user.` — a whole turn spent and discarded, with every caller contract telling
  the caller not to retry. The bound now **detaches**: nothing is signalled, the job keeps
  running, the runner exits **6**, and `codex-run.sh <prefix> --attach` resumes the watch and
  publishes the real outcome. `--stall-min` keeps its cancel unchanged — no log activity for
  minutes is a determination that the job is wedged; the bound elapsing is not a determination
  about the job at all.
- **The probe reported the second model unusable while it was usable.** Availability was
  `ready and loggedIn` read as plain booleans, so a companion that could not reach its runtime to
  *answer* the auth question returned `loggedIn: false` (with `authMethod: null, verified: null`
  and a connect-ENOENT detail) and the run was refused — while `codex login status` said
  `Logged in using ChatGPT` and a real launch through the same runner completed in 11 s. Since a
  participant recorded UNAVAILABLE is never launched, a false negative silently dropped a
  reviewer. UNAVAILABLE is now reserved for an authoritative negative about the launch path;
  anything the companion did not determine is **`PROBE UNDETERMINED`**, which never refuses a run.
  No model call is spent to predict a launch: the authorized task is itself the determination.
  Nothing infers meaning from undocumented `verified` / `authMethod` values — they distinguish
  only "it answered" from "it never got to answer".

### Added
- **A durable execution owner for the ccr backend.** The runner no longer execs the child
  directly: a minimal supervisor leads the job's process group, forks the child, waits for it, and
  atomically publishes `child_exit=` to `<prefix>.childexit`. This is what lets an attach preserve
  the success predicate — child exit zero **and** a successful `result` event — because an
  attaching process is not the child's parent and can never `wait()` for it. Raised by the second
  model (X-6) against a draft that would have dropped the exit-status condition while claiming to
  preserve the contract. The codex backend needs no supervisor: the companion already is that owner.
- **`--attach`, an operation rather than a launch mode.** It takes no prompt, no `--via` and no
  claim, spends no launch budget, rotates no sidecar, and leaves `mode=` as the original launch
  mode so every review gate anchors its thread exactly as before; attachment is recorded in
  `attached=<n>`. `--attach --cancel` ends the job instead.
- **`<prefix>.detached`**, and `.exit` becomes terminal-only. A detached attempt must not write
  `.exit`, because `phase-gate.sh` reads an existing `.exit` as a finished attempt and would
  rotate the claim and authorize a **second concurrent launch against the still-running job** —
  the second model's X-2, confirmed against the code. The gate now reads `.detached` with no
  `.exit` as still in flight. `release` refuses a detached prefix while its job is not PROVABLY
  finished — a matching recorded identity, a process group that is not provably empty, or a
  companion that cannot be consulted — and releases one whose job is provably over, so a prefix
  cannot wedge when the attach itself cannot reach its backend.
- **Identity before action.** A recorded pid or pgid is never signalled on the strength of the
  record alone: it is paired with the process's start time and re-proved first. A start-time
  mismatch means the number now names a different execution — nothing is signalled; a matching
  identity that is gone means the execution finished — its receipt and log are collected.

### Changed
- Exit **6** (DETACHED) is documented in all three protocol files and the README, and the exit-3
  row no longer tells callers a timeout is terminal. `scripts/validate.sh` derives the exit-code
  list from the script itself, so the documentation cannot drift from it.
- `.exit` is never rewritten once written. A refused `--attach` on a finished prefix previously
  overwrote a COMPLETED `0` with a `4`, destroying the very result this change exists to preserve.
  Nor is it invented for somebody else's live attempt: an argument error against a prefix that has
  a claim, an `.exit`, a `.detached` **or a `.progress`** is reported and publishes nothing — the
  last of those is the only marker present in the window between a launch starting and its first
  outcome, which is where an early `--attach` lands.
- **`<prefix>.claim.lock` is reclaimed from a dead holder, never on age.** Both the runner and
  `phase-gate.sh` used "older than sixty seconds"; that was true while every hold lasted
  milliseconds, and false the moment an `--attach` began holding the lock for its whole watch —
  up to twenty-five minutes — so the gate or a second attach would take the lock from a healthy
  collector and admit exactly the concurrency the lock exists to exclude. The holder now records
  its pid and start-time identity inside the lock and the lock is released only once that
  execution is provably gone. The clock still decides one case: a lock with no holder record.
- **A launch never rotates a live detached job away.** Rotating `<prefix>.detached` to
  `.attemptN.*` would strand a running job — nothing could attach to it or cancel it again — while
  a second job started against the same prefix. The launch is refused (exit 4) while the recorded
  identity is provably still running, and prints the record's own attach and cancel commands. An
  identity that cannot be proved is allowed to rotate, so a dead record can never deadlock a prefix.
- **A process-group number read from a file was signalled without being checked — the whole login
  session was in the blast radius.** `kill -- "-N"` is not "process group N" for every N: POSIX
  gives `-1` the meaning *every process the user may signal* (on macOS that is the entire GUI
  session, `loginwindow` included, which then relaunches every app) and `-0` the meaning *the
  sender's own process group* (the invoking shell and every sibling terminal job). The `--attach`
  path read `pgid=` straight out of `<prefix>.detached` and never validated it — the only PGID
  assignment in the file that was unguarded — and the identity check that authorises a cancel
  proves `pid=`, a **different field**. A record carrying `pgid=1` (a truncated write, a stale
  file, a hand edit, or a test fixture — one was found on disk) therefore reached
  `kill -TERM -- -1` followed by `kill -KILL -- -1`.

  Every signal now goes through one fail-closed gate, `pgid_is_signalable`, which refuses empty,
  non-numeric, `0`, `1`, this process, this process's own group, and — when the caller can name
  the process it recorded — any group that is no longer that process's group. A refused target
  returns "not confirmed" **having signalled nothing**, so callers treat it as a failed cancel
  rather than a completed kill; `group_alive` is gated the same way, because `kill -0 -- "-1"` is
  a permission probe against the whole machine that would answer "alive" for a group that does not
  exist. The same gate is in `implement-run.sh`. The audit that used to stand here claimed more
  than it had checked — it said no other path signals a process-group target while
  `scripts/test-args.sh` held a `kill -KILL "${VAR:-0}"`, which POSIX makes a signal to the
  sender's whole process group, and it described every test teardown as ownership-proved when only
  three of twelve were. What is true after this release is narrower and mechanically enforced:
  every signal in `scripts/test-args.sh` goes through one of three guarded helpers — `signal_group`
  (refuses 0, 1, empty, non-numeric and our own group), `signal_pid` (the same refusals for the
  per-pid form, where 0 means the sender's group) and `pid_alive` — and the suite's own S-08 sweep
  now fails on any `kill` or `pkill` outside those three bodies, so a new call site is a failure by
  default rather than by regex coverage. `phase-gate.sh` sends no signal at all: its four `kill`
  calls are `kill -0` liveness probes of a single pid (verified at this release by `git grep`), and
  group emptiness is read from the process table rather than probed with `kill -0 -- "-N"`, which
  for `N=1` tests every process the user owns and answers "alive" for a group that never existed.
  Nothing in the repository invokes `killall`, `launchctl`, `osascript` or `pmset`,
  and the only configured hook (`impeccable`) sends no signals.

  Forensics on the machine where this was found: `kill_group` had only ever been invoked on two
  pgids, both from the validated launch path, and the one attach that did run against the `pgid=1`
  record refused it (`nothing will be signalled … pgid 1 left alive`). The defect was reachable
  and one field-value from firing; it had not fired.
- **A signal handler that returns does not stop the script.** `trap 'publish_unlock' EXIT INT TERM`
  released the publication lock on TERM and then *kept watching and publishing*, so a second
  `--attach` was admitted and two collectors shared one job — and an operator who "stopped" the
  runner had not stopped it. INT and TERM now exit (130 / 143).
- **The supervisor never publishes a status it did not actually reap.** Its signal handler waited
  three seconds and then wrote `child_exit=-<signal>` whether or not the child had exited —
  publishing a terminal outcome for a job still running (reproduced: `child_exit=-15` with the
  child alive). The handler could not have done better: `Popen.wait()` called from it can never
  acquire the reaping lock the main thread already holds, so it always timed out. The supervisor
  now **outlives** these signals instead of answering them. A group cancel reaches the child
  directly, the main `wait()` returns the child's real status, and the receipt is true; a signal
  aimed at the supervisor alone leaves it in place, still owning the child and still able to
  publish the truth later. `SIGKILL` remains uncatchable, and the empty-group proof below is what
  covers it. The dispositions are set after the fork on purpose — an ignored signal is inherited
  across `exec`, and the child must stay killable by the `TERM` that `kill_group` sends.
- **A receiptless attempt can be closed instead of wedging the run directory forever.** A
  supervisor killed before it could reap (SIGKILL, the OOM killer, a host crash) left no receipt,
  and all four recoveries then refused: `--attach` re-detached, `--attach --cancel` would not signal
  an unprovable identity, `phase-gate.sh release` refused a detached prefix, and the taken claim
  refused a relaunch. An **empty process group** is now accepted as the proof it is: pgid reuse can
  only make a dead group look alive, never a live one look dead. The attempt closes as FAILED with
  `child_exit=unknown` — the status is recorded as unknown, never manufactured as success.
- **Lock reclaim is atomic, and an unreadable holder never wedges the lock.** Testing the holder
  and deleting it were two steps, so a second reclaimer could delete the *replacement* holder and
  two processes both held the lock; reclaim now renames the holder file, and only the process whose
  rename won — and whose moved record is the one it judged stale — takes the lock. Separately, a
  `holder` file that existed but was empty (an interrupted write) wedged the lock permanently: no
  pid to prove dead, and `rmdir` cannot remove a non-empty directory. An unreadable holder now falls
  to the clock, which deletes the file too.
- **The relaunch guard works on the codex backend.** It tested a `pid=` the codex detach record
  never wrote, so it was dead code exactly where it mattered most: `codex-debate` and
  `codex-deep-plan` pass no `--claim`, and the guard is their only protection against relaunching
  over a live job. The record now carries the worker pid and its identity, and the guard asks the
  companion for the recorded `job=`; an undetermined answer refuses the launch rather than
  permitting it.
- **`.detached` is published last.** It is the token that admits an `--attach`, so writing it before
  `.meta` opened a window in which an attach could collect the job and write `.exit`, only for the
  launcher's outstanding `.meta` to land on top of the terminal record with `outcome=DETACHED`.
- **A finished attempt is never discarded because a lock was busy.** The publication path took the
  claim lock *after* the job had completed and its answer was on disk, then exited 4 — a completed
  second-model review reported as a LAUNCH-ERROR — if the lock was held for five seconds, which
  `phase-gate.sh release` alone can exceed. It now waits out a *provably live* holder instead, and
  `stamp_claim` shares the one holder-based staleness rule rather than keeping a second, clock-based
  copy of it.
- **Exit 3 (TIMEOUT) is documented as retired** in all three protocol files and the README: no path
  assigns it any more, and the arm is kept only so older sidecars stay readable. `--attach --cancel`
  now prints the attach command it still requires, `--claim` is no longer advertised for `--attach`
  (it was silently ignored), and an attach carries the launch's `max_turns` forward instead of
  recording its own default.
- **The gate half of this change has tests for the first time.** `phase-gate.sh` had none: the suite
  stayed green if that file was reverted. Three fixtures now cover a detached attempt blocking the
  gate, `release` refusing it, and the holder-based lock being kept for a live holder and reclaimed
  from a dead one.
- **Nothing that identity could not prove is ever signalled, or written down as proven.** The
  stall path used to TERM/KILL the recorded process group even on an attach that had already
  logged that the identity was unresolved; it now re-detaches instead. And a re-detaching attach
  copies `identity=`, `claude_model_id=` and `prompt_sha256=` forward verbatim rather than
  re-deriving them: re-deriving would record whoever holds the number now — laundering an identity
  this very run refused to act on into one a later attach would signal on — and would erase what
  the launch pinned with values an attach cannot know.
- `scripts/test-args.sh`: the timeout case asserted `rc = 3` with `cancel_confirmed=yes` — it
  encoded the defect, so it is **replaced**, not extended around (the second model's X-4). New
  fixtures cover detach, attach and collection, refusal paths, terminal-`.exit` preservation, and
  the probe's three states; a new fake-gateway mode outlives the bound and then completes.

## [codex-pr-review 5.0.0] - 2026-09-08

Four defects reported after three rounds of live use, each fixed and each proven by a check that fails before the change and passes after. Major, because the run-directory contract changes: the schema marker is now `codex-pr-review/5`, the brief carries a `- Tier:` line, and Phase 4 has a third terminal state — a `/4` directory is refused rather than reinterpreted.

### Fixed
- **The watcher tested arrival, not completion.** `agent-watch.sh --expect` used `[ -s ]`, which a producer satisfies the instant it creates the file, so both the advisory and deadline watchers exited 0 within seconds of every run and supervised nothing — harmless only for an operator who knew to ignore them. New `--expect-mode <octal>`; callers pass `000`, which is the lead's terminal act and the join gate's own definition of a finished review. `stat` works on a mode-000 file while reading its bytes does not, so mode is the only available post-seal predicate. A mismatch reads as "not yet arrived", so the documented 0/2/3 exit contract is unchanged. The producer fix is what makes the observer fix sound: `agents/lead-reviewer.md` now publishes atomically — one write to `01-lead.md.part`, `chmod 000`, then `mv` — so `rename(2)` guarantees the path resolves only to absent or to the finished, sealed review, and a 15-second poll cannot land in a write-then-chmod gap. Thresholds recalibrated from 200 measured reviews (median 19.9 min, p95 47.0, max 73.1): advisory 20 → 50 min, deadline 45 → 90 min; the old 20-minute advisory would have fired on half of all runs once the predicate was fixed. A fired deadline now records the run INCOMPLETE and stops, instead of spending a second full review in-context on one that was merely slow.
- **The builder violated its own rubric.** `references/review-rubric.md` makes the review's object `<BASE>...HEAD`, but `build-brief.sh` emitted two-dot against a base resolved from a branch tip; once the trunk moved on, its own post-divergence commits appeared as deletions *by the PR*. Measured across stored runs: 5 of 15 checkable range-mode runs had a non-ancestor base, median scope inflation 3.5×, 93 extra files reviewed. In range mode the builder now computes `git merge-base --all`, requires exactly one result (a criss-cross history exits 2 rather than pick one), reviews from the fork point, records both bases (`- Requested base:` and `- Base:`), and freezes `00-brief.md.scope.json` naming every excluded path — hashed with the packets and accepted `final` at the join, because `00-run.md` is never hashed and so is not evidence. Not `--fork-point`, which selects via the ref's reflog. (Worktree mode was left out here and corrected in round 5 below: a snapshot tree does have an ancestry anchor.) Replaying the round-3 run that motivated this: **54 files → 30**, both genuine P1s kept, all three noise findings excluded.
- **No gate checked change attribution.** `validate-verdicts.py` validated a citation's revision, existence, line bounds and quote, but never whether the cited path is in the diff — which is how findings about untouched trunk code reached P1. A CONFIRMED P0/P1 must now cite a path inside `base..head`. Deliberately narrow: REFUTED verdicts are exempt (citing the base is often the point of a refutation), P2/P3 are exempt (they do not block a merge), `cmd:` evidence is exempt (it carries no path and already cannot confirm anything alone), and a finding about unchanged code that a changed caller newly reaches keeps its anchor at the changed caller. `references/adjudication.md` now binds causal attribution to every evidence rung rather than only rung (c).
- **It was slow and token-heavy.** Measurement across 169 stored lead reviews located the cost: the median review is 26.7 KB of which findings are 5.4 KB (21%), 29 reviews contain zero finding bytes, and a 26+ file diff produces only 1.43× the output of a 1–3 file diff (r²=0.023). Duration tracks output size, not input size. The obligation is a fixed, rubric-mandated writing task stated in ten places and enforced by no script. New `TIER`, frozen in the brief, default `compact-v1` with `--full` to opt out: one combined pass, no separate DESIGN section, no category-by-category recital. What is REVIEWED is identical at both tiers — every category applies and consumers are still searched repo-wide; the tier governs only what is written down.

### Added
- **The lead's terminal marker is checked at the join gate**, before the review is sealed, hashed and accepted, instead of only at `post-join` — by which time an unfinished review has already been admitted as evidence. It runs in its own unseal window, so a re-entered join re-checks it, and the EXIT trap reseals the lead on failure.
- **`STATUS: PHASE <n> NOT_RUN_POLICY <tier>`**, a third terminal state for Phase 4: an ELIGIBLE phase the frozen tier deliberately did not execute. SKIPPED means the run tried and got nothing usable, or the phase was ineligible; collapsing the two would make "we decided to skip this" indistinguishable from "this broke". The gate refuses the state when the omission does not cite the brief's tier, when that tier is `full`, when an attempt was recorded, or when any blocking (P0/P1) candidate was selected — in the production run that motivated the tier, the selected candidates *were* the two genuine P1s. The reachable case is a `BOTH`/`CONFLICT` row at P2/P3: the two reviewers disagreeing over a nit.
- **`05-scope-attribution.tsv`**, written by `pre-report` and accepted `final`: one row per finding recording whether its evidence path was inside the requested base's comparison, the reviewed one, or neither. Descriptive, never a gate — it makes "would the old two-dot scope have produced this finding?" a lookup instead of archaeology across a run directory.

### Found by this release's own two-model review (round 1, run `fix-review-speed-scope-watcher-20260908-021242`: lead 10 findings + 1 question, Codex 4 findings; the two P1s were raised independently by both models and each reproduced by execution — all fixed here with regression tests)
- **P1** `pre-report` read the Phase-4 policy token out of the `PST_POLICY` global *after* its own `phase_status 05-verification.md` had cleared it, so every run taking the documented `compact-v1` omission path completed six phases and was then refused at the gate that authorizes the report — accused of citing the wrong tier when it had cited the right one (F-01). The token is now captured beside `$PST` at all four call sites, so no intervening parse can empty it.
- **P1** `phase_status` admitted `NOT_RUN_POLICY` for *every* phase while `policy_omission_check` guarded only Phase 4, so the third state fell through every `= SKIPPED` branch: `STATUS: PHASE 6 NOT_RUN_POLICY <anything>` yielded `REPORT-OK` on a run with an unhandled residual and remaining budget — a strictly weaker gate than 4.0.1 shipped — and Phase 2 could record a blind review that never ran (F-02). The parser now refuses the state for any phase but 4, the only phase with a checker.
- **P2** The change-anchor rule had no regression coverage at all: every gate fixture pins base = head, which makes `changed_paths()` empty and the rule inert, so deleting it left the suite green (F-03). Six cases now run against the one repository in the suite with a real `base..head`, asserting the rule and all of its documented exemptions.
- **P2** `tier_check` ran after `initial_packets`, and `hashcheck` RECORDS on its first call — so a brief with no `- Tier:` line failed with advice ("rebuild the brief") that then failed on the recorded hash, discarding all of Phase 0 (F-04). `pre-codex` now validates the tier before the record exists and after it once it does.
- **P2** `01-lead.md.part`, the staging file of the new atomic publish, is a readable copy of the review and fell outside `pre-codex`'s `01-lead*.md` seal glob (F-05). The glob now covers it, and a `.part` never counts as a sealed lead.
- **P2** Phase 0 enumerated `00-scope.md` *before* running `build-brief.sh`, so the scope document — which the lead reads and a participant does not — kept the uncorrected file list the merge-base fix exists to eliminate, leaving the two reviewers blind to different scopes (F-06). Phase 0 now builds the brief first and writes the scope document from it.
- **P2** Mode 000 is transient: unsealing at the join before a watcher's next poll closes the completion window forever, and the watcher then runs to its deadline and reports a finished review as overdue — which the deadline handler turns into recording a successful run INCOMPLETE (F-07). Both watcher `.exit` files must now exist before `chmod 600`.
- **P2** `git diff --name-only` C-quotes unusual paths, so a CONFIRMED P1 citing a changed `src/café.py` was compared against `"src/caf\303\251.py"` and rejected for touching a file the change demonstrably touched (F-08). The membership set now comes from `-z` output.
- **P3** README documented the superseded `/4` marker and omitted both new frozen artifacts; `manifest_ids()` was left with no caller anywhere; `anchor_error`'s empty-diff comment asserted something git does not do (`git diff A..B` takes two endpoints, so a snapshot tree diffs against a commit fine); and `workflow-mode.md` still taught shard reviewers the non-atomic publish the rest of the change replaced (F-09 … F-12).

### Found by this release's own two-model review (round 2, run `fix-review-speed-scope-watcher-r2-20260908-034532`, against the round-1 fixes: lead 11 findings + 2 questions, Codex 4 findings; both models independently found the same provisional-severity defect — all fixed here with regression tests)

Round 2 was stopped at the join: its findings were read from the two sealed blind reviews and fixed directly, so it has no Phase-5 verdicts. The zero-P0/P1/P2 gate is satisfied by round 3, below.

- **P1** The change-anchor rule keyed on `03-matrix.tsv`'s severity, which the consultation is documented to change: a validated `REFINE` disposition replaces every packet field including severity, so a P2 upgraded to P1 kept the P2 exemption and a confirmed blocker could reach the report with no anchor at all (CL-03, CX-01 — raised independently by both models, each reproducing it by execution). `validate-verdicts.py` now takes `--packets 05-verifier-packets.ndjson` and lets the packet's severity override the matrix's, because after consultation the packet is the authoritative record; the gate passes the file whenever it exists.
- **P1** The scope sidecar named files the correction had *not* excluded. `comm` collates in the ambient locale, but its inputs were `LC_ALL=C sort`ed — so under a UTF-8 locale the two orderings disagreed and the frozen, hashed `00-brief.md.scope.json` recorded a false exclusion list (CL-01). Reproduced by running the shipped builder under both locales; the comparison is now `LC_ALL=C comm` on `-z` output, which also fixes the C-quoting mismatch between the sidecar and every other new consumer (CL-11).
- **P1** The merge-base correction could silently set base == head — when the requested base already contains the head — producing a brief with an empty file list that every gate accepted, and a review of nothing that could still be reported (CL-02). The builder now exits 3 with the two resolved commits named. Its counterpart in the validator: an empty reviewed comparison made `anchor_error` vacuously true, disabling change attribution exactly when nothing had changed (CX-02). An empty set now *rejects* a blocking finding rather than admitting it.
- **P1** Three of the new guards, including round 1's own `.part` fix, had no regression coverage: deleting any of them left the suite green, because every gate fixture pinned base = head (CL-06, CX-03). The suite's second throwaway repository now has two commits and a real `base..head`, and eight new blocks (R-01 … R-08) cover the schema marker, `NOT_RUN_POLICY` and its phase restriction, the anchor rule, the builder's empty-range refusal and locale independence, policy-omission eligibility, `.part` sealing with tier ordering, and packet severity.
- **P2** `policy_omission_check` never tested that the omitted phase was *eligible*, so a Phase 4 that could not have run — no completed participant, or no finding selected for consultation — could be recorded as a deliberate policy omission rather than SKIPPED, erasing the distinction the state exists to draw (CL-04). It now requires Phase 2 COMPLETE and at least one selected finding. The check's earlier "no bare claim" test was also unreachable, since `pre-consultation` mints that claim as its last step; it is now a test for the absence of `<prefix>.exit`.
- **P2** The shipped `templates/review-workflow.js` still gave shard reviewers the non-atomic write-then-`chmod` this release replaced, so workflow mode kept the race the watcher fix depends on being closed (CL-05). Its shard prompt now teaches the `.part` → `chmod 000` → `mv` publish.
- **P2** `scope-attribution.py` reported `unknown` for every row in worktree mode because membership was gated on merge-base applicability — but `git diff <base> <tree>` answers membership fine; only the *correction* is inapplicable there (CX-04). Both columns now agree instead of discarding the record the file exists to provide.
- **P3** `agent-watch.sh` accepted `--expect-mode ""` and silently reverted to the arrival predicate — the exact defect this release fixes, reachable through an unset shell variable (CL-10). An empty value now exits 2. Three documents still described the pre-atomic-publish sequence, the pre-`.part` glob, or a "take no claim" policy omission the gate's own comment contradicts, and `scope-attribution.py`'s worktree comment described behaviour the code did not have (CL-07 … CL-09).

### Found by this release's own two-model review (round 3, run `fix-review-speed-scope-watcher-r3-20260908-111933`, against the round-2 fixes: lead 7 findings + 2 questions, Codex 2 findings; both models independently found the rename defect — all fixed here with regression tests)

- **P1** Membership counted only one end of a rename. `changed_paths()` used `git diff --name-only`, which for a detected rename prints ONLY the destination — so the source path, which the change deleted and which no longer exists at head, looked untouched. A CONFIRMED P0/P1 whose strongest evidence is the base-side line a rename removed ("this rename dropped an authorization check") was rejected for citing a file the change demonstrably touched, and the diagnostic's closing advice pushed the orchestrator to demote a real blocker to the non-blocking list (CL-01, CX-01 — raised independently by both models). The membership set now comes from `--no-renames`, which contributes both endpoints; `agents/finding-verifier.md` teaches the same command. Proven by execution: before the change the rename source is refused, after it anchors.
- **P2** The builder's new range-mode exit 3 was absent from the exit-code contract the orchestrator actually reads: `codex-protocol.md` documented exit 3 as "tree equals base tree", which is worktree-specific, and the paragraph describing the correction listed only exit 2 (CL-02). Both now name the range-mode case and its different remedy — name a head the base does not already contain, rather than recapture the tree.
- **P2** `scope-attribution.py` wrote straight to the final pathname, so an interrupted run left a partial table there — and `pre-report` regenerated only when the path was ABSENT, so the next call hashed the truncated file `final` and silently lost the audit rows the feature exists to provide (CX-02). The producer now publishes atomically through a `.part` rename, and the gate regenerates whenever the table is not yet in the ledger. It deliberately does NOT re-derive and compare once the row exists: the table is built from `05-verdicts.tsv`, a draft until Phase 6, so comparing on every entry would turn a legal verdict correction into a hard failure — `accepted_check` is the tamper-evident guard from that point on.
- **P3** The empty-range refusal blamed ancestry, which an empty diff does not prove — a full revert or an empty commit produces one too, and the advice was then wrong (CL-03). `scope-attribution.py` split the EVIDENCE column on the first tab while `validate-verdicts.py` joined it, so a citation quoting a tab was recorded `unanchored` (CL-04). `policy_omission_check` lacked the accepted-response guard `SKIPPED` already has, so deleting the deletable sidecars could relabel a completed consultation as a deliberate omission (CL-05). Nothing asserted that `pre-report` produced or froze `05-scope-attribution.tsv` (CL-06). `ids = set(severities)` made the identity check's reference set matrix ∪ packets, so a packet-only id could become a required verdict id in standalone use (CL-07).

### Found by a Codex review of the branch (round 4, `/codex:review --base main`; 1 P2, 1 P3 — both fixed here with regression tests)

- **P2** The exclusion set compared unlike with unlike. Rename detection is a per-comparison heuristic, so the requested and effective comparisons can disagree about whether one edit is a rename: a feature that renames `a.py` to `b.py` while the trunk heavily edits `a.py` yields a rename in one and a delete+add in the other, and `a.py` was then frozen in `00-brief.md.scope.json` as "excluded by the merge base" even though the feature itself deletes that path — contradicting the anchor rule's own `--no-renames` membership set. Both sides of the set difference now use `--no-renames`. Proven by execution: before the fix the sidecar lists `a.py`, after it the exclusion set is empty.
- **P3** `05-scope-attribution.tsv` recorded the matrix's provisional severity, so a P1 that consultation REFINEd to P3 was frozen in the audit table as P1 — the value the gate did *not* act on. The gate now passes `--packets` when they exist, and the packet severity wins, exactly as it does in `validate-verdicts.py`.
- **P2** (round 5, found by re-reviewing the fix above) That `--packets` change built the optional argument as an unquoted word list, so an artifact directory containing a space split the pathname into several arguments and argparse rejected the command — failing `pre-report` *after* verification, the most expensive possible place. It now uses positional parameters, the pattern `validate_verdicts()` already follows for the same optional flag. The lesson is the one this release keeps relearning: a fix is a change, and it needs the same review as the defect.

### Found by this release's own two-model review (round 5, run `fix-review-speed-scope-watcher-r4-20260908-134530`, against the Codex-plugin rounds: lead 5 findings + 3 questions, Codex 4 findings; 1 P1, 4 P2, 3 P3 — all fixed here with regression tests)

- **P1** Phase 5 sets the final severity, and nothing structural carried it. `adjudication.md` makes Phase-5 evidence the last word on severity, but the verifier reported a change only as prose (`severity_note`), so the change-anchor rule kept keying on the classification the finding had *before* verification. A finding promoted P2 → P1 during verification could confirm citing an untouched file and never meet the anchor requirement — the exact case the rule exists for — while one demoted P1 → P3 stayed subject to a rule that no longer applied (CX-01). New `05-final-severity.tsv` (`F-nn<TAB>P0|P1|P2|P3`, written only when Phase 5 changed a severity, accepted as a draft beside the verdicts) is now the highest-precedence severity source — above the verifier packet, above the matrix — for both the anchor rule and `05-scope-attribution.tsv`, and the verifier returns a machine-readable `SEVERITY_FINAL:` instead of prose alone. The severity the report states and the severity the gate enforced are now the same number.
- **P2** The merge-base correction was skipped in worktree mode because the guard keyed on the head literal `WORKTREE` rather than on whether an ancestry question could be asked — and a snapshot tree has an anchor, the commit it was captured from. `--base` is caller-supplied in both modes, so a worktree review against a moved trunk tip put the trunk's own post-divergence work in the brief as changes by the review target, froze `merge_base_applicable: false` in a hashed audit artifact when the correction had merely never been attempted, and left `changed_paths()` computing membership from the uncorrected base — so a CONFIRMED P0/P1 could be anchored entirely in trunk work (CL-01). Proven by execution: before, `trunkonly.txt` reaches the brief; after, it is excluded. `merge_base_applicable` now means "an ancestry anchor exists", which is a different fact from `merge_base_applied`.
- **P2** `tr '\0' '\n'` destroyed filename boundaries before the exclusion comparison, so one trunk path named `trunk<newline>name.txt` became the two phantom exclusions `trunk` and `name.txt` in a frozen, accept-final artifact — the opposite of the "degrades to a false not-excluded, which is the safe direction" the old comment claimed (CX-04). The set difference is computed in Python from raw NUL-delimited bytes, which also removes the `comm` collation hazard entirely.
- **P2** The Phase-4 blocking count read comment lines that the canonical selector parser skips, so a commented-out P1 row blocked a legal policy omission over a P3 — two readers of one file disagreeing about which findings were selected (CX-02). And the in-context recovery paragraph still listed a fired deadline among its triggers, giving one state two contradictory mandatory actions: rerun Phase 1, and record the run INCOMPLETE (CX-03). The fallback now excludes deadlines explicitly and says why.
- **P3** The empty-range refusal named the *corrected* base, printing "merge-base(main, feature) (abc) already contains feature (abc)" — a sentence about a commit containing itself (CL-02). The backtick guard covered the Base ref but not the Head ref, though both reach the same anchored parser (CL-03). The watcher's progress log never recorded which predicate was in force, so a run that silently reverted to the arrival test — this release's whole subject — was indistinguishable in the record from one supervising completion (CL-04).

### Found by this release's own two-model review (round 6, run `fix-review-speed-scope-watcher-r5-20260908-152749`, against the round-5 fixes: lead 8 findings + 2 questions, Codex 3 findings; 2 P1, 4 P2, 3 P3 — all fixed here. Both models independently found both P1s, and both are in the severity mechanism round 5 added)

- **P1** The Phase-5 severity chain was **inert on the only path that spawns the verifier agent**. `templates/review-workflow.js` declares the verdict schema `additionalProperties: false` and never listed `severity_final`, so under `--workflow` — the one mode in which `finding-verifier` actually runs — a promotion could come back only as prose, which is verbatim the state the chain exists to fix (CX-01, CL-01). The field is now a required enum (`unchanged`, `P0`–`P3`) in the schema, in the null-verdict fallback, and in both the agent contract and `workflow-mode.md`.
- **P1** The absence of `05-final-severity.tsv` was never frozen. `pre-resolution` accepted it only when it already existed, and `accepted_check` verifies rows that are *in* the ledger — so a file absent there and created before `pre-report` was never hashed, never compared and never required, while both the change-anchor rule and an `accept … final` audit table read it (CX-02, CL-04). It is now written unconditionally, recording "no Phase-5 severity changes" as a frozen claim about the run rather than as the absence of one, and `pre-report` requires its ledger row exactly as it does the verdicts'.
- **P2** An unknown id in the severity file was silently filtered out, so a mistyped row preserved the pre-verification severity and quietly suppressed the anchor check it was written to trigger — and round 5's own regression test had enshrined that behaviour (CX-03). Unknown ids are refused; an omitted id still inherits its packet or matrix severity.
- **P2** `README.md` still told the operator to rerun Phase 1 in-context after a fired deadline, the instruction `SKILL.md` had just been corrected to forbid — the same defect as round-4 CX-03, reintroduced by omission in the other shipped document (CL-02). Three further statements still asserted worktree mode gets no merge-base correction, including `codex-protocol.md`, the operational contract the orchestrator is pointed at (CL-03).
- **P2** `scope-attribution.py` validated only that the scope sidecar was JSON. Missing revision keys degraded silently to an all-`unknown` table that still exited 0 — and `pre-report` freezes that table `final` with no second chance, leaving it indistinguishable from a genuine git failure, which is the other thing `unknown` means (CL-05). The sidecar's shape is now checked. This also exposed that every gate fixture in the suite seeded a stub sidecar with no revision keys — round-3 CL-06 had flagged exactly that and nothing enforced it — so the fixtures now build a real sidecar and the attribution path is genuinely exercised.

### Found by this release's own two-model review (round 7, run `fix-review-speed-scope-watcher-r6-20260908-164309`, against the round-6 fixes: lead 5 findings + 2 questions, Codex 2 findings; **no P0 and no P1** — the first round to reach that, and the point at which the review cycle stopped)

- **P2** The frozen sidecar advertised an `equivalent_three_dot` expression git refuses. A three-dot comparison needs two commits, and worktree mode's head is a snapshot tree — so extending the correction to worktree mode in round 6 made `<commit>...<tree>` reachable in a hashed audit artifact, where git exits 128 on it (CL-01, CX-01 — both models). The field is now `null` for a tree head, and the ancestry anchor the merge base was computed against is recorded instead, so the calculation stays replayable.
- **P2** A literal tab inside a quoted citation path went straight into the tab-delimited attribution table, so a promised seven-column row emitted eight and every positional reader misparsed the path, the membership flags and the disposition — with `pre-report` freezing the malformed table `final` (CX-02). The path field is now backslash-escaped. Round 6 had fixed the same hazard for a tab inside the *excerpt* and missed the path.
- **P2** `templates/REVIEW.md` still offered "merge-base correction not applicable: local snapshot-tree review" as a fill-in, and `SKILL.md` still described the correction as range-mode only (CL-02) — the third consecutive round to find this class, each time in a file the previous fix did not reach.
- **P3** `README.md` described the lead's superseded two-pass write-up and the non-atomic publish, and never mentioned the tier (CL-03). The report template made the category-by-category recital mandatory, which the *default* tier suppresses in both reviews, so it asked for something no reviewer had written (CL-04). `agent-watch.sh`'s usage header omitted `--expect-mode`, the option this release exists to add (CL-05).

### Not changed
- **Blindness stays procedural.** No mechanism enforces it in this sandbox: Codex's read-only sandbox can read `~/.claude/projects/**/*.jsonl`, and no file placement changes that. The honest label in `templates/REVIEW.md` stays.

## [codex-debate 1.2.1, codex-deep-plan 2.3.1] - 2026-09-07

### Fixed
- **The shared runner fix reaches both plugins.** `scripts/codex-run.sh` is shipped byte-identically in all three plugins (`validate.sh` check 4b), so `codex-debate` and `codex-deep-plan` already carried the 4.0.1 CCR hardening — the configured alias as the only `ccr launch --model` value before `--`, a preflight that requires both `provider_model` and `claude_model_id`, the `routed_model == claude_model_id` route assertion with `UNAVAILABLE` (exit 4) and no alias or Claude fallback, `prompt_file=` in `.meta`, and a cleared `.stdout` on an unconfirmed exit-5 cancellation. Neither plugin was version-bumped at the time, so `claude plugin update` reported them as already current and never delivered it. These patch releases exist to ship it.
- **codex-debate `references/codex-invocation.md`** now uses the same three-identity vocabulary as the other two plugins: alias vs `provider_model` vs `claude_model_id`, the smoke record bound to all of them, and what `routed_model=` / `route_identity=no` mean when a launch is refused.

## [4.0.1] - 2026-09-07

### Fixed
- **Provider-agnostic review reliability.** The shared runner now binds a CCR smoke receipt to the configured alias, provider model, CCR-generated child model ID, observed child `system/init.model`, CCR version, and launch digest. It passes the configured alias only as `ccr launch --model <alias>` before `--`; a generated-child-ID mismatch is recorded as `UNAVAILABLE` (exit 4), never silently retried with another alias or Claude. The smoke remains fail-closed for broad permission configurations.
- **Canonical exchange recovery.** An exit-0, non-empty consultation or residual-resolution response that fails the unchanged canonical validator now gets exactly one corrective resubmission. Its gate creates a sealed `*.prompt.retry.md` containing fixed correction wording plus the stable validation class/diagnostic; the existing launch and response caps still apply, and a second malformed response follows the existing SKIPPED fallback.
- **Cancellation recovery.** `phase-gate.sh confirm-terminated` can add an immutable SHA-bound receipt only after the same backend liveness checks prove an exit-5 attempt is dead. Original sidecars remain intact, and absent or invalid proof continues to block relaunch.
- **Citation provenance.** Repository source quotes can contain project identifiers or provenance-like wording without being treated as reviewer authorship; authored fields and citation paths remain filtered and quotes remain independently source-validated.

## [3.0.0] - 2026-09-07

Planned with `/codex-deep-plan:plan --deep` (deep-plan run `ccr-backend-20260907-003456`), debated with Codex over a blind round 0 plus three rounds (termination T1, converged; APPROVE_WITH_CONDITIONS — the conditions are the T-5b/T-5c, T-10b/T-19b and T-27/T-27b tests, which ship here). One PR, four commit groups.

### Added
- **A second backend for the second model: `--via codex|ccr:<alias>`** in all three plugins, implemented in the shared `scripts/codex-run.sh` (byte-identical in every plugin) under the unchanged contract — prompt file in, the six sidecars out, exit codes 0–5, `--claim`, `--fresh`/`--resume-last`. The ccr backend launches a headless, plan-mode, MCP-less Claude Code through the user's [claude-code-router](https://github.com/hishamkaram/claude-code-router) gateway (`ccr launch --model <alias> --permission-mode plan -p --no-lifecycle --no-statusline -- --output-format stream-json --verbose --strict-mcp-config --mcp-config '{"mcpServers":{}}' --disallowedTools Write,Edit,MultiEdit,NotebookEdit,Agent --max-turns <N>`), in its own process group (`pgid=` on the `.progress` launch line; a stall TERMs then KILLs the group and exits 5 only when a member survives), with the version gate (`ccr` ≥ 0.4.11), `ccr model show <alias> --json` recorded in `.meta`, the `result` event as `.stdout`, the session id as `thread=` and `.ccr-last-session`, and ccr-only `--max-turns` / `--resume-session <id>`. `--probe --via ccr:<alias>` additionally runs a read-only smoke in a throwaway repository (the exact launch line, a prompt that tries to write by tool and by shell) and records `.ccr-smoke.<alias>`; every ccr launch in that directory requires a matching record for its ccr version, model and launch-line digest, and fails closed (exit 4, nothing launched) without one. No alias is ever hardcoded (`validate.sh` check 12); no runner copy contains `acceptEdits` and every copy still refuses `--write` (check 13); every command's argument hint lists `--via` (check 14).
- **codex-deep-plan 2.3.0 — cheap-implementer handoff.** `--implement ccr:<alias>` records the implementer in `meta.json`; after plan-mode approval the new `scripts/implement-run.sh` creates a branch in a worktree at the base SHA, launches the alias through `ccr` with `--permission-mode acceptEdits` on a brief made of the approved `PLAN.md` verbatim plus the test commands, and records the same sidecars plus `.diff`, `.worktree` and `.plan.sha256`. It is a separate launcher — it refuses any backend but `ccr:` — so the read-only review runner never gains write mode. The plan validator fixes made during this run ship first: a non-verbatim citation or an objection left without one is dropped with a WARN (`DROPPED_CITATION`, `DROPPED_OBJECTION`, `UNVERIFIED_ROOT_CAUSE`) instead of rejecting the whole reply, a concession may cite the plan row (`CH-`/`T-`/`D-`/`ER-`) that answered it, and `build-prompt.sh` checks leftover placeholders on the template rather than the filled text.
- **codex-pr-review 4.0.0 — N blind reviewers.** `--via codex,ccr:<alias>,…` (1 to 8, at most one Codex) fans the blind review out to N participants. Phase 0 writes `00-participants.tsv`, frozen and hashed with the packets by `pre-codex`, which now claims one launch per participant (`claim.p<k>=`) and writes the schema marker `00-schema` (`codex-pr-review/4`; a directory without it fails every gate as a legacy run). Every participant owns the `02-p<k>` prefix (sidecars, session, `02-p<k>.md`); Phase 2 is COMPLETE when at least one completed; the join seals the lead plus every participant body in order, records the exchange participant (`02-exchange-participant`, the lowest-numbered COMPLETE one) whose session anchors the unchanged two-response/four-launch consultation and residual budget, and accepts the schema marker into the ledger after the seal. Reconciliation is over the lead and every participant; the new `03-provenance.tsv` (`F-nn<TAB>lead|p<k><TAB>original-id`) records who raised each canonical finding and `validate-provenance.py` checks it against the matrix and the four unchanged origin literals (BOTH = lead and ≥ 1 participant, CODEX-ONLY = participants only, any number). `phase-gate.sh release` of a ccr attempt refuses while the recorded process group or any descendant is alive and never consults the Codex companion. `07-review.md` §6 lists the participants.
- **codex-debate 1.2.0 — N-way debate.** `--via codex,ccr:<alias>,…` (1 to 5) gives every opponent its own blind take (`02-blind-p<k>.md`), then Claude moderates one-on-one rounds against the strongest dissent: the new `scripts/next-opponent.py` scores each participant's open rows (E0 = 4 … E4 = 0, over rows attacking a Claude claim), picks the highest with ties by lowest number, gives every eligible participant one turn before anyone repeats, re-selects a participant with a pending VERIFY, keeps one round counter per pair (the user's round number, hard cap 5, the existing convergence and stalemate rules) and a separate global budget (`--total-rounds`, default N × rounds, hard cap 5 × N) whose exhaustion prints `UNRESOLVED-GLOBAL` for the pairs left rather than converting them into converged ones. Owners are `X<k>-nn`, concessions `CONCEDED-BY-P<k>`, the living ledger is `03-ledger.md`, rounds are `03-round-<n>-p<k>.md`; the ruling aggregates per owner and caps confidence when any pair is unresolved. With one participant the `X-nn` / `CONCEDED-BY-CODEX` grammar and the file names are unchanged.

### Found by the release review (two-model review of the branch, round 1: lead 7 findings + 2 questions, Codex 11 findings; 13 confirmed, 3 refuted, 2 more found during verification — all fixed here with regression tests)
- **P1** `--resume-session` was not a launch mode: the runner recorded `mode=--fresh` and the gates skipped the session comparison, so a ccr exchange could be accepted from the wrong session (F-01; now `mode=--resume-session` + `resume_session=`, anchored like `--resume-last`; Phase 6 ccr line documented). deep-plan documented the smoke record in `$ART` while its launches look beside their prefixes in `$ART/debate`, so every deep-plan ccr launch exited 4 (F-02). The review and debate commands expanded only `$1..$3` / `$4..$7` and dropped the `--via` (and `--total-rounds`) they advertise (F-08, F-09; both bodies now forward `$ARGUMENTS`, checked by `validate.sh` 14). The implementer could not commit or run tests headless — verified live: under `acceptEdits -p` every Bash command is denied — so its branch stayed empty (F-17; the launcher now pre-allows the git subcommands and each `--test-cmd`, commits whatever the child leaves uncommitted, and reports `launcher_committed_paths=`). The provenance filter rejected any citation quoting the flag text `--via codex` as an attribution — it rejected this very review's consultation response (F-18; a leading `--` is no longer a preposition).
- **P2** `next-opponent.py` declared a stalemate when only Claude-owned rows moved in the pair's last two rounds (F-03) and could re-select a participant before another had its turn because the coverage scan reset at the previous complete cycle (F-15). The probe's read-only smoke ran unbounded in the foreground — a hung alias blocked Phase 0 and leaked the child (F-04; now its own process group under `CODEX_RUN_SMOKE_MAX_SEC`, default 300 s, killed as a group and reported UNAVAILABLE; the smoke also asks for a write outside the repository). The probe accepted an alias the launch path refuses and printed `recorded=` even when the record could not be written (F-05). An explicit `--slug` was stored verbatim, so the documented `plan/<slug>` branch could be an invalid name (F-14).
- **P3** an error `result` event (`is_error`, `error_max_turns`) with child exit 0 counted as COMPLETED (F-10; the live nested CLI exits 1 on it, so this is defensive; `.meta` now records `result_event=`); dead code (F-06); the implementer branch was documented as `<slug>` in one place and `plan/<slug>` in another, README's exit-5 wording omitted the unreadable-pgid case, and the smoke digest wording overstated what it covers (F-07); this changelog embedded a machine-local artifact path (F-16). Refuted with executed evidence: "the implementer has no filesystem boundary" (a Write or shell redirection outside the worktree and git on another repository are denied by the nested session's permission engine — now documented in `phases.md` §8), "the smoke record does not bind the alias" (it is keyed by alias), "init-plan accepts an empty alias" (it exits 2).
- **Round 2 (fix-scoped, lead 9 findings + 2 questions, Codex 6; 11 confirmed, 0 refuted; both P1s settled by executing the trigger).** **P1** the implementer's recovery commit could fail (a pre-commit hook, signing, a lock) and the run still reported COMPLETED / exit 0 with a `.diff` that omitted the uncommitted work (F-01; the branch is the deliverable, so a failed recovery commit is FAILED / exit 1 with `launcher_commit=failed`, and `.diff` is taken against the working tree so the work stays inspectable). The `--allowedTools` rule derived from a test command's first word pre-approved the whole interpreter — verified live: `Bash(python3:*)` let `python3 -c` write outside the worktree (F-02, F-10; the rule is now the whole command, `Bash(<cmd>)` and `Bash(<cmd>:*)`, leading `NAME=value` words dropped, and a command with shell metacharacters is refused with a warning; the residual — a test command executes repository code — is stated in `phases.md` §8). **P2** `CODEX_RUN_SMOKE_MAX_SEC` was not validated, so a non-numeric value made a hung smoke unbounded again (F-03; positive whole number or UNAVAILABLE); the probe's timeout branch could signal the runner's own process group when the smoke's pgid could not be read (F-07; pgid must equal the smoke pid, else the pid is killed directly and the cancel reported unconfirmed); `--fresh --resume-session` was accepted while the reverse order was refused (F-09; an explicit-mode flag makes every order exclusive). Test gaps closed with regressions: the gates were never exercised with `mode=--resume-session` (F-04; wrong-thread / exchange-thread pairs at `pre-verification` and `pre-report`, and the fake gateway keeps the resumed session id as the live CLI does), the error-result case never ran through the implementer's own parser (F-05), the outside-write smoke detection had no fixture (F-06), and the hung-smoke test asserted and killed host-wide instead of on the reported process group (F-08). **P3** the runner's header comment still listed two modes (F-11).
- **Round 3 (fix-scoped, lead 1 finding, Codex 4; 4 confirmed, 1 refuted).** No P0/P1 after verification (termination). Codex P1 on assignment values bypassing `test_rule` was **refuted live**: the nested matcher denied `simple_expansion` and no outside file was created. **P2** an all-digit smoke timeout longer than a Bash integer made the wait loop fail-open (F-02; now at most 9 digits). If `git add -N` failed, `.diff` omitted untracked files (F-03; the run is FAILED and the porcelain listing is written instead). **P3** sidecar header still said `git diff <base>..HEAD` (F-04); hung-smoke FAIL path still `pkill -f` (F-05).

### Changed
- README: optional `ccr` prerequisite, the sending-content sentence names the alias's provider, the runner table gains the backend row, quick-start examples for every `--via` use, artifact listings for the new files.
- This is a major contract change for codex-pr-review: review directories created under 3.0.0 (`02-codex` prefix, no participants file, no schema marker) cannot be resumed under 4.0.0; every gate says so. Runs without `--via` behave as before at every layer.

## [2.0.0] - 2026-09-04

### Changed
- **codex-debate 1.1.1 / codex-deep-plan 2.2.1 — shared runner fix.** `scripts/codex-run.sh` (byte-identical in all three plugins) now records `.meta`, `.stderr` and `.progress` when the Codex plugin cannot be located, rotates a previous attempt when only its `.exit` or `.progress` sidecar exists (an orphaned launch is preserved as `attemptN.*`, never truncated), appends `runner_pid=`/`started=` to a `<prefix>.claim/owner` file when a launch gate left one, and writes `mode=--fresh|--resume-last` into `.meta`. codex-debate's SKILL.md seed example now names the review's `05-verification.md`.
- **codex-pr-review 3.0.0 — consultation before verification.** The concurrent, blind lead/Codex reviews and `JOIN-OK` boundary remain unchanged. After reconciliation, the review now creates a complete selector of every BOTH, CONFLICT, and provisional P0/P1 canonical finding, then sends one bounded set-level consultation to Codex before evidence-based verification. The existing post-verification exchange becomes conditional residual resolution.
- The review seal records separate, readable hashes for `01-lead.md` and `02-codex.stdout` at the consultation boundary. Later gates reject tampering before consultation, verification, resolution, or report generation.
- Consultation output is an exact-ID, provenance-free normalized packet. It can refine a claim, trigger, severity, falsifier, or proposed check, but only Phase 5 verification can mark a finding CONFIRMED or REFUTED. Across consultation and residual resolution, the shared cap is two successful Codex responses and four launches.
- Added `validate-consultation.py` and hermetic regression coverage for selection, exact response coverage, provenance rejection, review-body tampering, malformed seals, and the new state gates. The shared Codex runner (all three copies) gained launch-error sidecars, attempt rotation on `.exit`, and a `mode=` metadata field; see the codex-debate 1.1.1 and codex-deep-plan 2.2.1 entries below.
- This is a major contract change: reviews created under earlier artifact numbering/state contracts must not be resumed using 3.0.0.
- Round 42 preparation closed the recorded follow-ups: launch gates run the in-flight claim check before re-accepting any draft; an exchange attempt whose runner recorded `thread=unknown` is a failed attempt (skip and `--fresh` relaunch stay open); an exhausted exchange budget prints `budget=exhausted` on the gate's OK line instead of failing; the runner's token check is a fixed-string match; residual-ID validation lives only in `validate-consultation.py` (`--validate-selection` accepts `--ids`); `sidecar_count` and the unused `review_common.py` helpers are gone; packet build scratch files are removed on failure; `post-join` re-checks that the snapshot tree still resolves; `build-brief.sh` normalises `--base`/`--head` to full ids; the exit table says how to retry under `--claim`; `templates/codex-exchange.md` carries the consultation/resolution prompt and the exact response contract; README documents `--claim`.
- Round 42 (full diff): Codex reported no findings; the lead's five P3s (a stale-lock reclaim that could busy-loop when `rmdir` fails; an unfollowable packet-recovery message; a verdict-column whitespace mismatch between the three readers of `05-verdicts.tsv`; a claim-less argument error leaving a `.exit` that later blocked every gate; two stale doc sentences) are fixed with regressions.
- The two design follow-ups from the cycle debates are in 3.0.0 as well: `pre-resolution` and `pre-report` no longer rebuild `05-verifier-packets.ndjson` (the accept ledger already proves it byte-identical to the validated generation at `pre-verification`; the consultation response was already checked by its ledger rows); and `templates/review-workflow.js` no longer hand-mirrors the Python rules — its citation, artifact and provenance constants are a block generated from `review_common.py` by `scripts/gen-workflow-constants.py`, which `validate.sh` checks for drift.
- **Follow-ups recorded by the release review (rounds 37–41, two cycle debates), all closed as above.** P2: launch gates re-accept draft inputs (matrix, selector, base packets, verdicts, residual selector) on a failing re-entry while the launch claim is live, so the ledger can attest inputs the authorized launch did not see (round-39/40 CL-01; fix: run the in-flight claim predicate read-only before the draft accepts); a `--fresh` consultation whose runner recorded `thread=unknown` can be neither accepted, skipped nor relaunched (round-39 CL-02; fix: treat it as unusable or make the anchor optional); `pre-resolution` fails on an exhausted exchange budget instead of printing an OK-with-skip (round-38 CX-04; the failure message already names the SKIPPED recording that `pre-report` accepts). Design: drop the `pre-report` re-parse of ledger-frozen exchange responses; derive `review-workflow.js`'s rules from `review_common.py` or drop the mirror (both cycle debates). P3: the claim-token check is a BRE (`grep -qx` with a hex token is safe today); `review_common.py` ships two unused helpers; residual-ID validation exists twice (gate and validator); the exchange prompts have no template; `sidecar_count` is dead code; failed packet rebuilds leave `.packets-*` scratch files; the runner exit table still says "retry with the same command" (under `--claim` that is refused, re-run the gate); `build-brief.sh` accepts an abbreviated `--base`/`--head` and `pre-codex` then blames the builder; snapshot reachability is checked before launch but not after Codex returns; a kill inside the seal's hashing window leaves `01-lead.md` at mode 400 and the re-run refuses without naming `chmod 000`; `usable_count` re-validates every attempt on every gate (cost note); the legacy no-`--claim` runner path is untested; the README option table. Cycle record: rounds 27–41 each reported at least one finding from a fresh Codex pass (P1 counts 37–41: 4, 3, 1, 1, 1); the last three P1s were an interrupted-join strand and two artifact-tampering windows indistinguishable from a wiped directory, which the `seal=` fingerprint in `JOIN-OK` makes visible against the run record.
- **Fixed during review, before release:** Phase 5 now has an explicit instruction to write `05-verifier-packets.ndjson` (previously required by `pre-resolution` with no documented producer). The provenance-filter regex in `validate-verifier-packets.py`/`validate-consultation.py` no longer rejects ordinary domain words ("artifact", "consensus", "agreement", "transcript") and now also catches a possessive model-attribution phrase ("Codex's ..."). A status downgrade on `02-codex.md` after a review seal exists is now caught by every gate, not silently accepted. The residual-resolution `--ids` list is now cross-checked against the reconciliation manifest. `pre-resolution` no longer requires a residual-selection file when Phase 5 left nothing to resolve. The consultation gate's seal fingerprint is a real 12-hex prefix instead of the raw multi-line seal file. Added `validate-verifier-packets.py` and regression coverage for the `codex=SKIPPED` branch of all four new gates. Later review rounds tightened the citation grammar (repository-relative `path:line`, double-quoted paths for spaces, no absolute/`..`/scratch paths) shared by both Python validators and the workflow script, widened the attribution filter, made `pre-resolution` budget checks residual-aware, counted launch-error attempts that leave only a `.exit` sidecar, and had the runner record `.meta`, `.stderr` and `.progress` for a missing-plugin launch error. The shared validator module imports on Python 3.9 (macOS system python), the artifact-name filter arm is generic (`NN-name.*`, `REVIEW.md`, scratch dirs) and table-tested against every shipped artifact, and `pre-report` rejects an unconfirmed-cancel consultation sidecar even when that phase was skipped. A deleted review seal is never recreated once post-join artifacts exist; a skipped residual phase with UNVERIFIABLE findings is accepted only after an attempted exchange or an exhausted budget; workflow verdicts require citation-shaped or command-shaped evidence; citations may quote lines containing double quotes and line ranges; the residual selector rejects duplicates and empty lists before launch; thread-continuity checks read the runner's new `mode=` field instead of substring-matching the command. Artifact names and scratch directories are rejected at any path depth; a fresh retry no longer needs a prior thread ID; `pre-resolution` requires a terminal consultation artifact; the workflow rejects a non-array `open_factual_questions`. Workflow evidence citations are held to the same repository-relative, artifact-free, provenance-free checks as packet inputs; the initial blind review is subject to the unconfirmed-cancel check in every gate. `pre-consultation` also refuses to launch over an unconfirmed cancel; an eligible consultation may be skipped only after a recorded attempt; a residual launch needs a non-empty validated selector first; origin labels (`CLAUDE-ONLY`, `CX-nn`) and `lead's` are filtered. The review seal is written for SKIPPED reviews too and a missing seal after post-join artifacts is fatal in every gate; `pre-codex` refuses to relaunch over an unconfirmed cancel; the reconciliation selector is frozen at `pre-consultation`. `05-verdicts.tsv` now carries method and evidence per verdict, validated by the new `validate-verdicts.py`; the accepted consultation response is attested (`04-consultation.stdout.sha256`, chained to the selector and review seal) at `pre-verification` and re-checked later; `pre-codex` refuses to redo an unjoined completed review. Every launch gate refuses a second launch over an accepted attempt or a terminal artifact; the residual selector is attested at `pre-resolution` and required by `pre-report` whenever residual findings remain. Launch gates take an atomic per-phase claim directory; a joined run never relaunches Phase 2; the verdict validator accepts the verifier's rung spelling (`(b) trace`); the residual selector is attested even when the budget is exhausted. Consultation dispositions now reach the verifiers: Phase 3 writes the normalized base packets (`03-findings.ndjson`, validated and frozen at `pre-consultation`), `pre-verification` generates `05-verifier-packets.ndjson` from them with the new `build-verifier-packets.py` (MAINTAIN unchanged, REFINE replaces, VERIFY/RETRACT append), and later gates rebuild the file and reject any edit. The final report is `07-review.md` (an artifact name the citation filters reject at any depth; a repository's own `REVIEW.md` stays citable). An orphaned `.progress` is rotated rather than truncated and counts as a launch, and spent claims are capped at nine. After a Codex debate on the growing per-artifact seal/attestation code (fourteen review rounds each found one more gap in it), the five seal/attestation files and the per-artifact recheck blocks were replaced by one accept ledger, `00-accepted.sha256`: every gate records each artifact it accepts or generates once (`<sha256>  <artifact>  <gate>  <final|draft>`) and every gate verifies every row on entry; drafts (selector, base packets, verdicts, residual selector, generated packets) are replaceable only by their gate while their phase is open, finals (review seal, accepted consultation and resolution responses, thread anchor) never. The launch claim is now the last step of a launch gate and is in flight while the runner has started or the claim directory is younger than the grace window — no process-liveness heuristics. Base packets must carry the matrix's provisional severity. The attribution filter also catches prepositional attribution ("checked by Codex", "according to Codex"); one launch claim authorizes exactly one runner (the runner takes `<prefix>.claim/runner` with an atomic mkdir before touching any sidecar; a second runner exits 4 and writes nothing); an accepted consultation can never be recorded SKIPPED afterwards. Verdict evidence written as a backticked citation is normalized rather than rejected. A phase can be recorded SKIPPED only when no attempt succeeded with a usable response (Phase 2: any exit 0 with a non-empty response, which is also what COMPLETE requires; Phases 4/6: an exit-0 attempt whose response validates, or one the ledger holds), and a claim whose runner has taken its lock stays in flight regardless of age. Round-32 debate (claim as the single launch record): the runner's new `--claim` flag makes it write nothing before it owns the claim (argument errors included); the launch budget counts runner-taken claims, not sidecars, spent claims are never deleted, a phase with more attempt sidecars than runner-taken claims fails every gate, `phase-gate.sh release <ART> <prefix>` replaces manual claim removal (refuses a live runner pid or a job the codex plugin does not report finished, fails closed without the plugin), and every post-join gate requires the review seal's ledger row. Round 33: Phase-5 citations are resolved in the reviewed repository (`pre-codex` records it in `00-repo.txt`, accepted final at the join; `validate-verdicts.py --repo/--tree` checks sha, path, line range and quote, and a `cmd:` item alone cannot confirm or refute); the reconciliation matrix (`03-matrix.tsv`/`.md`) is accepted at `pre-consultation` so it cannot change after consultation begins; the runner detects `--claim` as an exact argument, never as a substring of a value. Round 34: the brief builder records `.base`/`.head`, `00-repo.txt` carries `repo=`/`base=`/`head=`, and a citation sha must be a hex id whose tree is the reviewed head's or the base's (symbolic refs and other commits are rejected); `release` also fails closed when `.progress` exists without a job id while any Codex job runs in the reviewed repository. Round 35: the workflow mirror coerces a CONFIRMED/REFUTED verdict with no citation item (command output only) to UNVERIFIABLE, matching the gate. Round 36: launch gates print `claim=<token>` and the runner takes only the claim carrying that token (`--claim <token>`); a runner-held claim without `.exit` blocks every later gate; the repository attestation and its ledger row are required after the join and the verdict validator never runs unpinned; response budgets and relaunch refusals count usable responses (exit 0 with a body that validates), not bare exit codes; the brief builder records `.repo` and `pre-codex` refuses a different repository and writes `00-repo.txt` only after every check passed. Round 37: a citation's repository path is checked only for artifact/run-directory/scratch shapes (a file such as `agents/finding-verifier.md` is citable) while its quote gets the full provenance filter; the gate allocates its one scratch file at startup and fails closed if it cannot; `release` refuses a runner directory without a pid unless it is a minute old; a valid exchange response on an unexpected thread is a failed attempt (it neither blocks the `--fresh` retry nor forbids a skip). Round 38: the join seal is minted once — an accept ledger without its seal fails every gate instead of letting `pre-phase3` re-mint over edited bodies; `00-repo.txt` must restate the frozen brief's Target section (checked at `pre-codex` from the builder's sidecars, at the join before it is accepted, and at every later gate); creating, rotating and taking a claim are serialized by `<prefix>.claim.lock` in both the gate and the runner; response-validator arguments are passed as an array so a run directory with spaces still recognizes a usable response. Round 39: the runner keeps the claim lock until the previous attempt's sidecars are rotated, so a stale `.exit` cannot let a concurrent gate rotate a just-started runner's claim. Round 40: the join mints the seal before it creates the accept ledger and each step is atomic, so a join interrupted anywhere (crash, power loss) is completed by re-running `pre-phase3` instead of stranding the finished blind reviews; a ledger without a seal, a seal row missing at any later gate, or a seal row missing once later artifacts exist still fail closed. Round 41 (fix-scoped): the `JOIN-OK` line carries the seal fingerprint (`seal=`) so a directory wiped and re-joined over edited bodies — which no file-level check can distinguish from a never-joined directory, before or after this change — is visible against the run record.

## [1.5.1] - 2026-09-04

### Added
- **A check that the version recorded as installed is the version on disk** (`scripts/validate.sh` check 11). Found while diagnosing the reviewer stalls: `installed_plugins.json` recorded `codex-pr-review 2.1.0`, `codex-deep-plan 2.1.0` and `codex-debate 1.1.0` at cache directories that did not exist, while the newest directories present were `2.0.0`, `2.0.1` and `1.0.5`. A release can therefore reach the repository and never reach a session, and `claude plugin update` answers "already at the latest version" because the version record was bumped regardless. The check reports each mismatch and names the reinstall that recovers it; on a machine with no record, or with none of this marketplace's plugins installed, it passes quietly, so CI is unaffected.
- Separate from the 1.5.0 fix by design: different mechanism, different change surface, and — established during the debate — **not** the cause of the observed stalls. The registry was last written at `04:07:10.197Z`, after the affected agents started at `03:44:30Z` and `03:46:59Z`, so which contract those runs loaded is not established either way.

## [1.5.0] - 2026-09-04

### Fixed
- **Reviewer subagents no longer block indefinitely on an unanswered tool-approval prompt** (codex-pr-review 2.2.0, codex-deep-plan 2.2.0). Reported as "many sessions say the lead agent has been hung for over two hours". Planned with `/codex-deep-plan:plan --deep` and debated with Codex over a blind round 0 plus three rounds (termination T2, round cap; APPROVE_WITH_CONDITIONS, one BLOCKER raised and closed, zero open majors).
  - **The agent was never hung.** Four `codex-pr-review:lead-reviewer` runs stalled between 35 minutes and 2h16m, and every one of those transcripts ends with `The user doesn't want to proceed with this tool use`: the agent had issued a Bash call and waited for an approval nobody answered. Measured across every subagent transcript on the reporting machine: `Grep` 867 calls, maximum 2.4 s; `Glob` 168, maximum 8.4 s; `Read` 3780, maximum 5.2 s; **`Bash` 9419 calls, 96 of them over 300 s, worst 8177.7 s**. One `mcp__*` call blocked for 2228 s, so the gated set is "requires approval", not "is Bash".
  - **Cause 1 — `incorrect_authoritative_content` (conceded to Codex in round 1).** The text that is the source of truth for how a reviewer searches directed it to the gated instrument. `lead-reviewer.md` said to *grep all call sites and consumers repo-wide*, `finding-verifier.md`'s rung (b) named `git grep`, and the one sentence in each about search instruments enumerated `grep`, `rg`, `egrep`, `fgrep`, `diff`, `cp`, `mv` — a sentence written in 1.4.0 to carry a path-form rule, which became by default the answer to a question it was never asked. `Grep` and `Glob` appeared in the shipped plugins **only** as frontmatter capability grants and in no prose anywhere (fact-checker: CONFIRMED). The lead and verifier agents had made 792 Bash calls and zero Grep/Glob calls.
  - **Cause 2 — `missing_abstraction`.** Since 2.0.0 the join turn launches two background units and defined liveness for one. The Codex job has a progress sidecar, a stall window and a deadline; the lead agent had no progress file, no heartbeat and no deadline (fact-checker: CONFIRMED), and its only fallback fires when *Codex* finishes — so a lead that blocks while Codex still runs had no trigger at all. In the 2h16m case the orchestrator recorded nothing for the whole window, then diagnosed it in under a minute once the user asked, and recovered by hand with `TaskStop`.
  - **The instrument rule.** `lead-reviewer.md`, `finding-verifier.md`, `fact-checker.md` and `references/review-rubric.md` (the rubric reaches the lead through the brief and is its procedure — Codex's X-5; the first draft missed it) now say: search with the **Grep and Glob tools**, never with a shell search command, because they are read-only and never wait on an approval nobody is watching for. Bash is retained for `git -C <repo> show|diff|log` at a pinned SHA and for repro runs.
  - **`TREE-IS-HEAD`.** The tools search the working tree while the brief pins SHAs, so the join turn now states which the tree is: range mode requires `rev-parse HEAD` to equal the head SHA **and** `status --porcelain=v1 --untracked-files=all` to be empty (untracked files count — a tree search can hit a file absent from the pinned tree); local mode requires the snapshot tree to recapture identically. `no` restricts tree results to discovery and sends every exhaustive or absence claim through one `git grep` at the pinned SHA. Every quoted or counted line is confirmed at the pinned SHA regardless.
  - **`agent-watch.sh`** (new) supervises one asynchronous review unit: `--expect <file>`, one deadline, exit 0 when the artifact arrives non-empty, 3 when the deadline passes, 2 on a usage error, with `.progress` and `.exit` sidecars. It is launched in the background exactly as `codex-run.sh` is, so the harness's completion notification is the wake source the join turn never had. **One process, one verdict:** a background job notifies once, at exit, so the join turn launches TWO per unit — advisory and deadline. An advisory exit tells the user a prompt may be pending and nothing else; a deadline exit calls `TaskStop` and may run Phase 1 in-context **only after the stop is acknowledged**, because a stopped-but-running agent and the fallback would otherwise both write `01-lead.md`.
  - **Fan-out** gets the same pair per lead shard, and Phase 4 watches a stage sentinel (`.stage-verify.done`, written when the Workflow call returns) because a verifier returns a structured object and writes no file. A verifier's repro commands are chosen after Phase 3 and cannot be enumerated at Phase 0.
  - **Consent probe** at the end of Phase 0: the residual gated families are issued as separate top-level Bash calls, recorded in `00-run.md`. It is documented as **best-effort prompt surfacing only** — it cannot be one script, because the harness matches the top-level command string and never a script's interior, and it is not asserted to authorise any later call, least of all inside a subagent.
  - **Validator check 10** asserts the instrument rule is present in all four files, and deliberately does **not** forbid the word `grep`: the pinned `git grep` fallback is sanctioned and check 8's path-form clause legitimately names the commands it constrains. It failed on all four files before the edits. `scripts/test-args.sh` gained 18 executed assertions for `agent-watch.sh`, including the paired-watcher lifecycle (advisory exits while the deadline watcher is still alive, then the artifact appears and the deadline watcher exits 0) and the stage sentinel ending both watchers.
  - **From the debate.** Codex raised six majors blind. Five were accepted: the rubric was missing from scope (X-5); the probe cannot demonstrate authorisation reuse and must not claim it (X-2); Phase-0 cannot enumerate Phase-4 repro commands (X-3); a timer without an acknowledged cancellation gives two writers (X-6); and the transcripts do **not** prove which plugin version those runs loaded (X-4 — the registry was written at 04:07:10.197Z, after the agents started at 03:44:30Z and 03:46:59Z, so an earlier claim to that effect was withdrawn). Round 2 raised a **BLOCKER**, X-10: the drafted watcher claimed three exit codes from one process, so its advisory verdict would have killed the supervision it was meant to begin — the paired-watcher design is the fix. Round 3 removed the last pure-timer mode, which had no success condition and could emit a stale verdict after a successful fan-out (X-11).
  - **Two elements were withdrawn by the author**, both before any round raised them. A "one gated call at a time" rule was refuted by the author's own complete extraction — maximum tool uses per assistant message is 1 in all four transcripts, and the supersessions are cross-session (four agents in three different sessions received one within two seconds), so the plugin cannot reduce contention it does not cause. And "run the watcher at each poll of the join turn" had nothing to wake it: that is precisely the 2h16m failure.
  - Not changed, with reasons on record: the three existing phase gates, every artifact format, and the prompts sent to Codex. `01-lead.md`'s seal, the frozen packets and the join gates are untouched, so a partial revert cannot strand a run directory.

## [1.4.0] - 2026-09-04

### Added
- **A path-form constraint in every context that composes shell commands** (codex-pr-review 2.1.0, codex-deep-plan 2.1.0, codex-debate 1.1.0). Planned with `/codex-deep-plan:plan` and reviewed by Codex over a blind round 0 plus two debate rounds (termination T1, APPROVE_WITH_CONDITIONS, zero open majors). Root cause: the three skills' hard constraints enumerate *which* commands a run may execute and never state *how* those commands address paths, while every run spans a repository and an artifact directory at once, and review runs add a scratch directory and a throwaway worktree. Cause class: absent constraint.
  - The trigger, read out of Claude Code 2.1.259 and reproduced in four permission modes: the harness circuit breaker `deniedPathInsideDirectory` refuses `grep`, `egrep`, `fgrep`, `rg`, `diff`, `git`, `cp` and `mv` when a compound command changes directory and then names a **relative** path, and it is armed by the mere presence of any deny rule named `Read` or beginning `Read(` in the repository being worked on. The breaker's own flag table reads `{bypassImmune: true, classifierRouted: false}`: bypass mode re-raises it and the auto-mode classifier is never offered it, so no permission mode, allow rule or `--add-dir` clears it. Only the command's shape avoids it. Reproduced in two fixture projects identical but for `"deny": ["Read(**/.env)"]`: the deny-rule fixture is refused under default, plan, auto and `--dangerously-skip-permissions`; the other runs clean; the same search with an absolute path and no `cd` runs clean in both.
  - **The rule.** One clause, verbatim in all six contexts: *address every path absolutely; never `cd` inside a tool command.* Read the repository with `git -C <repo> …`, give the guarded commands absolute path arguments, and name artifact-directory files absolutely. Added as hard constraint 11 to two-model-pr-review and deep-plan-duo, constraint 9 to codex-debate, and as a rule to `lead-reviewer.md`, `finding-verifier.md` and `fact-checker.md` — the three subagents receive their agent definition file as their whole instruction set, so a sentence in a skill never reaches them.
  - `lead-reviewer.md` and `finding-verifier.md` now read pinned SHAs with `git -C <repo> show <sha>:<path>`; `fact-checker.md`'s parenthetical `git -C` form is promoted to the primary one.
  - **Validator check 8** asserts all six files carry the clause, insensitive to line wrapping, and fails the build if one does not or is missing. It failed on all six before the edits, and its mutation tests — clause deleted, clause reworded to a near miss, file absent — each produced the expected FAIL.
  - **Behavioural check.** The `fact-checker` agent was run headless twice against the same claim, in a fixture whose settings carry `"deny": ["Read(**/.env)"]` and whose working directory is not the repository, once with the pre-change agent file and once with the new one. Pre-change it composed `cd <repo> && git cat-file … && git show …` — the refused shape. Post-change it composed `git -C <repo> show …` for both of its commands, with no directory change. One run per variant, one model; adherence is evidence, not a guarantee (risk R-1 in the plan).
  - **From the debate.** Codex raised five objections blind. Two became changes: `codex-protocol.md:49` and `build-brief.sh` published `( cd "$REPO" && … && git add -A . … )` — a shipped reference demonstrating the shape constraint 11 forbids — now two `GIT_INDEX_FILE=… git -C "$REPO" …` calls, verified to yield the same tree SHA, capture unstaged and untracked files, leave the index untouched and stay deterministic on recapture; and validator **check 9**, which fails on any `cd <operand>` in shipped markdown, because check 8 asserts only that the rule is present and cannot catch a reintroduced counterexample (mutation-tested by restoring the old line). One objection was rejected on cited evidence — Codex could not reproduce the permission matrix in its read-only sandbox, and its own falsifier is satisfied by the fixture runs — and Codex withdrew it in round 1. Two were already in the plan. Where Codex implied the reference command was a second instance of the unbypassable breaker, that was checked and corrected: it is the `shell-operators` breaker, deny-rule-independent and bypass-clearable, so the line was fixed for coherence, not for correctness.
  - Not changed, with reasons on record: the prompts and templates sent to Codex (Codex runs in its own process and sandbox, outside this harness's permission engine); the bundled shell scripts (the harness never parses a script's interior, only the top-level command string).

## [1.3.0] - 2026-09-03

### Changed
- **codex-pr-review 2.0.0 — concurrent reviews** (major: new command argument `--workflow`, new artifacts `00-brief.md.sha256` / `00-scope.md.sha256`, the lead review runs in an agent). Planned with `/codex-deep-plan:plan --deep` and debated with Codex over four rounds (round 0 blind; final verdict APPROVE, every objection accepted or withdrawn on cited evidence). Root cause: the phase gate modelled "Codex contact" as one atomic event that had to follow the lead commit, although only the *read* of Codex's output must; and the lead reviewer had no execution unit of its own, so the orchestrator's timeline carried the lead's constraint.
  - **Join turn.** Phase 0 ends with `phase-gate.sh pre-codex`, which freezes and hashes the brief and the scope (create-once, compare-forever). Then, in one turn, the monitored runner launches Codex in the background and the new `lead-reviewer` agent starts from the same brief in its own context. Neither receives the other's output; the runner's completion line carries no Codex text (fact-checked at the base SHA). `phase-gate.sh pre-phase3` (`JOIN-OK`) — lead file sealed at mode 000, `02-codex.md` written with its STATUS line, hashes unchanged — is the only door to Phase 3. Executed gate tests in `scripts/test-args.sh` cover every branch of all three subcommands.
  - **Agents.** `agents/lead-reviewer.md` (locked rubric procedure, `CL-` ids, single permitted write, seals its file, returns one status line, never opens another run-directory file) and `agents/finding-verifier.md` (one finding, adjudication rungs a/b/d, never the shared test suite). Both use the session model; tools are Read, Grep, Glob, Bash.
  - **`--workflow`.** Opt-in Workflow-tool fan-out via the shipped `templates/review-workflow.js` (checked by `node --check` in the validator): Phase 4 one verifier per finding; Phase 1 one lead per subsystem only above ~2000 LOC and only when every changed file has exactly one owner in the shard manifest. Rung (c) stays sequential in the orchestrator. An unavailable tool is announced and recorded in `00-scope.md` and REVIEW.md §8, never a silent switch. Codex never runs inside a workflow agent.
  - Blindness wording replaced everywhere it appeared (SKILL.md, codex-protocol.md, REVIEW.md template, README): procedural, four properties (unmotivated brief, frozen hashed packets, no cross-output before the join, mode-000 defense-in-depth); the reviews run concurrently and the report says so.
  - Runner stall window for the review raised from 8 to 12 minutes: the job log is silent while Codex composes a long final answer, and the 8-minute window cancelled one such round during this release's planning.
  - Live run of the new skill on this release's own diff (local mode, 16 files, +546/−78): Codex launched 08:45:52Z and finished after 919 s; the lead agent (general-purpose fallback with the agent file verbatim, because the freshly added agent type was not registered in the running session) started 08:45:53Z and sealed 9 findings and 4 questions after 672 s; the two overlapped for 663 s, and both reviews were in hand 910 s after launch. Serial ESTIMATE from the same run: 1591 s. Not a measured serial control.
  - That live run and its two reviews found, and this release fixes: the join gate could never pass because the skill appended run records to the hashed scope (both reviewers, P0; run records now go to `00-run.md`); the single-model path could not pass the gate because it never produces a runner sidecar (both, P1; the SKIPPED status needs none); the procedure contradicted its own no-read rule for `.meta`/`.exit`/`.progress` (both; control files may be read, `.progress` only through `cut -d'|' -f1` before the join, Codex output only after); the lead file had no Phase 1 status line and the completion gate reused the join gate after Phase 3 unseals the file (Codex; new `post-join` subcommand); newline-bearing paths reached shard prompts unencoded (Codex; JSON-encoded now, shard names validated); `node --check` accepted a broken module (both; `scripts/js-check.sh` compiles the script the way the tool evaluates it, and an executed smoke test drives both stages with stubbed globals); an unavailable hasher recorded an empty hash and passed forever (lead; fails the gate now, with `shasum`/`sha256sum` fallbacks); a trailing blank line failed the gate (lead); shard files were outside the gates (lead; every `01-lead*.md` must be sealed, shards re-sealed after the merge); the lead could run tests that write into the tree Codex reads (lead; gitignored output only, else a scratch worktree); `--workflow` was positional (lead; recognised anywhere). A second live exercise ran both stages of the shipped workflow script through the Workflow tool: three finding-verifier agents in parallel (167 s, every verdict a schema-validated object with an executed repro) and two lead-reviewer shards over an explicit file manifest (760 s, both files sealed at mode 0), using the `agentTypes`/`agentInstructions` fallback because the plugin's agent types were not registered in the session; their five extra findings (relative run path in the gate, a third brief sentence the lead overrides, three untested gate branches, a tautological hash test, validator label order) are fixed here too. Not exercised live: an executor null or cancellation, and the Workflow-unavailable fallback.

## [1.2.1] - 2026-09-03

### Fixed
- **codex-deep-plan 2.0.1.** Two live runs of the released skill against this repository, both with Codex: a question ("does every runner refuse `--write`?") took the new answer-only round-0 path (`root_causes: []`, accepted by the validator in question mode) and ended in `ANSWER.md` with no defect; a light change request ("fix the README's Bounded-debate bullet") ran one blind round, then entered Claude Code plan mode with `PLAN.md` verbatim and came back approved — the first observed plan-mode handoff. Applied from that plan (Codex added the last four): README's bullet now says 2 rounds, 3 with `--deep`, lists T0 and orders the conditions by precedence with their owners; SKILL.md's Rounds row and debate-protocol.md's T2 row carry the same default.
- `lint-claims.py` names a sealed (mode 000) file instead of raising a traceback.

## [1.2.0] - 2026-09-03

### Changed
- **codex-deep-plan 2.0.0 — proportionate depth** (major: `PLAN.md` loses sections 3 and 6–9, `PLAN-EVIDENCE.md` and `ANSWER.md` are new outputs, `--deep` is a new argument). The first real use, on the four-word question "is read me updated", produced a 111-line plan proposing a checker script, a validator section and six fixtures for three wrong README lines. A codex-debate run (ruling REFINED, convergence after one round) traced this to rules, not misapplication: the skill had no notion of intent or size, none of its five cause classes fit "the content is wrong", so README drift became `absent_constraint` and the rubric rejected the direct edit as a workaround exactly as written; Codex retracted its own "faulty application" claim after tracing the chain. Changes, as amended in the debate:
  - Phase 0 classifies **intent** (a question ends in `ANSWER.md`, never a plan) and **scale** (`light` for corrections to authoritative content, `standard` otherwise, `deep` with `--deep` or several issues). Light runs evidence, a short root cause, one blind Codex round and a short plan; it skips the candidate matrix and the debate rounds. Light is provisional and escalates after Phase 1 or after round 0 when the content is generated, duplicated or overridden, an accepted objection or new evidence requires a change beyond the edit, a blocking unknown remains, or an accepted objection goes beyond the edit.
  - New cause class `incorrect_authoritative_content`, accepted by the verdict validator and named in the blind brief. The rubric's new Proportionality section makes the direct correction the real fix for such content and demotes enforcement machinery to an optional follow-up unless drift has recurred or the user asked; content that fails the authority test continues the causal chain to its generator or source.
  - `PLAN.md` is summary-first and short by construction: summary, root cause → change → test → closure, file-by-file, tests, order and rollback. Scoring, risks, unknowns, debate closure, concessions and optional follow-ups move to `PLAN-EVIDENCE.md`; both are linted and citation-checked, and only `PLAN.md` is copied into plan mode. Codex's conditions — keep the mapping table, keep the ordering constraint, check both files — are met.
  - `--deep` flag; `init-plan.sh` records `mode_requested`. Tests cover the flag, the cause class and the filled templates.



### Added
- **codex-deep-plan** plugin (skill `deep-plan-duo`, command `/codex-deep-plan:plan`): evidence-only planning for GitHub issues, pull-request review comments, a single comment, or a plain request, ending in one reviewed PR plan. Nine phases on disk: scope → evidence → root cause → designs → draft → blind Codex round → divergence → bounded debate → `PLAN.md` or `DECISION-REQUIRED.md`.
  - Every claim is tagged `[FACT]`/`[VERIFIED]`/`[INFERENCE]`/`[UNKNOWN]`; `check-citations.py` resolves each `path:lines@sha` with `git show` and string-matches the quote, and `lint-claims.py` rejects hedges, untagged facts and decisions that cite no evidence id.
  - Root causes must terminate in a cause class; "one PR" is treated as a hypothesis and a split is recommended when the inputs do not share a mechanism.
  - Designs are scored on five real-fix gates with blast radius and reversibility as counterweights; do-nothing, the largest correct change and the tempting workaround are always scored.
  - Round 0 is blind: `build-prompt.sh` builds the brief before any evidence exists and refuses wording that reveals another analysis. `validate-verdict.py` enforces the objection contract (evidence, falsifier, proposed change), rejects praise and evidence-free concessions, makes a bare APPROVE cost an adversarial attempt, and checks Codex's sha-pinned citations against the code. `debate-status.py` reports the termination condition (T1 converged, T2 cap, T3 no new information, T4 human decision, T5 Codex unavailable).
  - A `fact-checker` agent verifies one claim at a pinned SHA without seeing the reasoning behind it.
  - The finished plan is handed to Claude Code plan mode verbatim for approval (`--no-plan-mode` prints it instead).
  - Inputs are pinned verbatim by `init-plan.sh` from `gh` (issues, PRs with inline review comments, single comments) or from text and files; a fetch failure exits 3 and names the input.
- Review of this release by its own two-model loop (blind Codex review, verification of every finding by execution, one debate exchange). Codex found seven P1 gaps in the new gates that Claude's review missed, all fixed with regression tests: unpinned or non-base citations were accepted as evidence (now every citation must pin the run's base SHA); untagged or mis-tagged evidence rows passed the linter; a decision could rest on an inference id; empty design objects validated as designs; round 1 did not have to resolve round-0 objections; a withdrawn objection was reopened when a later round did not repeat it. Claude's review found `init-plan.sh` creating a refused `--out` directory inside the repository (fixed: resolved before creation), the praise filter rejecting quoted code, and the validator writing bytecode into the tree. Also fixed: untracked-only trees reported clean, malformed comment fragments tracing back instead of exiting 2, extensionless paths rejected, README wording, a table header read as a decision line, `--request` text starting with a dash, and the round cap not enforced by `build-prompt.sh`. The one conflict (paginated `gh api` output) was settled by executing the real tool: modern `gh` merges pages, so it is hardening, not a defect.
- First live run of the skill on this repository (request: the validator's machine-specific-path check) produced a plan in which Codex's blind round found a real fail-open bug: `grep` exit 2 reached the success branch. Friction found and fixed: dot-paths and quoted lines containing quotes were rejected by the citation checker; a reused objection id confused the status report.
- Validator: Python scripts are checked for executability and syntax without writing bytecode; all `codex-run.sh` copies must be byte-identical; the deep-plan skill's exit-code table is checked like the others. Regression tests cover every new script's usage errors, the citation checker against a fixture repository, the linter rules, the verdict validator's contract, the leak check and the termination logic.

### Fixed, from the live replays of the README request (question mode, then light mode)
- `build-prompt.sh` rejected the blind brief when an in-scope path merely contained a leak word (`plugins/codex-debate/…`, `.claude-plugin/…`). A bullet that resolves to a repository path at the base SHA is now exempt; text after the path is still checked.
- `check-citations.py` could not check two `path:line@sha "quote"` citations in one table cell: the inner-quote rule swallowed everything after the first citation. Candidates are now bounded by the next citation on the line.
- Phase 5 pre-flight wording: a question run has only `01-evidence.md` to seal.

### Fixed, from the two-model review of this release (Codex blind review: 3 P1, 5 P2, 1 pre-existing; one conflict debated, Codex retracted)
- **F-01 (P1, both models).** The leak-check exemption accepted any existing path, including an absolute artifact path or a `..` escape, so the blind brief could name the artifact directory. Only normalized relative paths inside the repository (at the base SHA or under the checkout's real path) are exempt; tests cover absolute, parent-relative and base-SHA-only bullets, with fixtures created before the base is pinned.
- **F-02 (P2, both).** A citation without its own quote could borrow a neighbour's quote on the same line. A quote never crosses a citation boundary; the quote-before-citation form is accepted only for a lone citation.
- **F-03 (P1, Codex).** Question mode could not pass the round-0 validator or the phase gate without a fabricated plan: the brief asked for a diagnosis and the validator demanded root causes, two designs and a PR recommendation. The brief now carries a question note when `meta.json` says `"mode": "question"`, the validator (`--mode` or `meta.json`) accepts an empty diagnosis when the summary carries a cited answer, and the SKILL gates name the question-mode exception.
- **F-04 (P2, Codex).** `PLAN.md` and `PLAN-EVIDENCE.md` cite by id, so the documented checker command failed with "zero citations"; Phase 8 and the completion gate now say `--allow-empty` for the final files and re-check `01-evidence.md` without it.
- **F-05 (P2, Codex).** `--deep` recorded metadata only; it now defaults rounds to 3 unless `--rounds` is explicit, and the canonical invocation lists it.
- **F-06 (P2, conflict → debated).** The escalation triggers disagreed between README, phases §1 and §5, and "more than one defect" would have escalated the motivating three-sentence README fix. Codex retracted the count trigger; escalation is by mechanism only, and an accepted objection of any severity that requires more than a content edit escalates.
- **F-07 (P2, lead).** SKILL.md said several issues select `deep`, phases.md's example said `standard`; the example now matches.
- **F-08 (P2, Codex).** The artifact contract changed (PLAN.md sections removed, new outputs, new flag), so this release is codex-deep-plan 2.0.0 per CONTRIBUTING, not 1.1.0.
- **F-09 (P3, Codex).** README's headline now says the checkout is never modified and names the `.git/objects` writes of local review.
- **F-10 (pre-existing, Codex).** `scripts/test-args.sh` aborts when `mktemp -d` fails instead of continuing with root-relative paths.
- The replays' own findings, applied: the `gh` prerequisite row scoped `gh` to deep-plan although codex-pr-review resolves a PR number with it; the "Nothing is touched" headline claimed more than the plugins guarantee (artifacts outside the repo, unreachable git objects from local review, one plan-mode file); the deep-plan entry-point cell drifted from the command's argument hint; the plugin-table row, the workflow diagram, the rubric bullet and four discovery descriptions still described every run as ending in a plan-mode plan with five cause classes and unconditional scoring. Codex's blind round found the last four and one contract gap: the skill's "write only to the artifact directory" rule now states the plan-mode file as its single exception.

## [1.0.5] - 2026-09-02

Round 2 of the same Codex debate. Two of the 1.0.4 fixes had moved a defect rather than closed it; both are now closed properly.

### Fixed
- File-list paths are quoted the way git's own `core.quotePath` does: plain when ordinary, otherwise double-quoted with C escapes and `\ooo` octal for raw bytes. The 1.0.4 escaping was ambiguous — a path holding an invalid byte and a path whose own characters were a backslash and an x rendered identically — and the escaped text could not be used with the `git show <tree>:<path>` form the brief documents. The brief's snapshot note now explains the quoting and points at `git diff <base> <tree> -- <path>` and `git ls-tree -r -z <tree>` for such paths.
- A stalled or timed-out job whose cancel could not be confirmed now exits 5, not 2 or 3. Exits 2 and 3 tell the caller to retry or to treat the job as finished, and neither is safe while a worker may still be running. Both skills' exit tables and the README document 5 as "do not retry". The metadata sidecar records `cancel_confirmed`.
- The README no longer claims categorically that stalls and timeouts cancel the job; it states that the cancel is verified and that an unverified cancel is reported rather than asserted.

### Changed
- The file-list formatter moved out of an inline `python3 -c` string into `skills/two-model-pr-review/scripts/quote-name-status.py`. The inline form could not hold a single quote, which is how the 1.0.4 escaping came to be written incorrectly in the first place.

### Added
- Tests that the quoting is reversible and that ordinary paths are left untouched.
- A validator check that every exit code the runner can emit is documented in both skills and the README.

## [1.0.4] - 2026-09-02

Round 1 of the same Codex debate. Every claim was reproduced before being accepted.

### Fixed
- `build-brief.sh`: a range-mode call missing only `--head-ref` still aborted with `HREF: parameter null or not set` and exit 1, because the 1.0.3 required-option check omitted that variable. It is now a usage error with exit 2. This was an incomplete fix in 1.0.3, not a new defect.
- `codex-run.sh`: `--stall-min 08` passed the digit test but aborted the polling arithmetic with `value too great for base`, because bash reads a leading-zero literal as octal. Timing values are now normalised to base 10 and bounded, so `08` behaves as 8 and an oversized value is rejected up front.
- `build-brief.sh` file-list parser: a path containing a non-UTF-8 byte crashed the builder with `UnicodeDecodeError`, and a path containing a newline was emitted as two Markdown lines, so one changed file stopped being one entry. Paths are now decoded without crashing and control characters are escaped, keeping one file per line.
- `codex-run.sh` cancellation: the runner wrote "no phantom running job left behind" without checking. It now re-reads the job status and looks for a live worker process after cancelling, and reports honestly on both the progress file and stderr when the cancel is not confirmed.

### Added
- Regression tests for all four, including leading-zero timings, a range call missing `--head-ref`, and parser input with non-UTF-8 bytes, newlines, spaces and renames.

## [1.0.3] - 2026-09-02

Found by a Codex debate on packaging and portability; both claims were reproduced before being accepted.

### Fixed
- `codex-run.sh` and `build-brief.sh` dereferenced `"$2"` for every value-taking option under `set -u`. A missing operand (`--stall-min` with no number, `--repo` with no path) aborted with a raw `unbound variable` message and exit 1. Exit 1 is the code the runner's own contract reserves for "Codex failed, retry once", so a typo was indistinguishable from an upstream failure. All invalid runner invocations now exit 4 (LAUNCH-ERROR) and all builder usage errors exit 2, each with a usage message.
- Added operand and type validation: numeric options reject non-numbers, `--prompt-file` is required and must be readable, `--repo` must be a directory, and intent and conventions files must be readable.

### Added
- `scripts/test-args.sh`: executed regression tests for every argument-handling path plus a builder happy-path fixture (clean tree exits 3, dirty tree captures a deterministic snapshot, the repository index is untouched, untracked files reach the brief, the scratch index is cleaned up). Wired into `scripts/validate.sh` and CI, so the contract is verified on Linux as well as macOS.

### Changed
- The exit-code tables in both skills now state that 4 covers any invalid invocation and that a usage message means fix the call rather than retry.

## [1.0.2] - 2026-09-02

### Fixed
- `two-model-pr-review` skill frontmatter was not valid strict YAML: the description ended with `Review-only: never use to implement fixes.`, and an unquoted scalar containing `": "` parses as a nested mapping. Same defect class as 1.0.1, in the review plugin's main skill.

### Added
- `scripts/validate.sh`: dependency-free packaging checks — strict-YAML frontmatter, manifest agreement, `${CLAUDE_PLUGIN_ROOT}` path resolution, script executability and shell syntax, and machine-specific path leaks. Run before every release.
- GitHub Actions workflow running the validator on push and pull request.

## [1.0.1] - 2026-09-02

### Fixed
- Command frontmatter: `argument-hint` values are now valid YAML (quoted in full). Strict parsers, including GitHub's preview, rejected the previous form.

## [1.0.0] - 2026-09-02

### codex-pr-review
- Blind two-model review pipeline: scope → independent lead review → blind Codex review → reconciliation matrix → verification → bounded debate → `REVIEW.md`.
- Local-changes mode (`--head WORKTREE`): the working tree (staged, unstaged, deleted, renamed, untracked) is snapshotted as an unreachable git tree object through an artifact-local scratch index; the repository's index, refs, stash and files are never touched.
- Deterministic brief builder (`scripts/build-brief.sh`) with leak checks.
- Ordered, exclusive verdict policy; canonical severities; every P0–P3 verified regardless of who raised it.
- Unresolved items are emitted as ready-to-run `/debate` lines.

### codex-debate
- Modes: `challenge`, `compare`, `hypothesis`; blind first round by default; hard cap of 5 rounds.
- Claim ledger with evidence grades E0–E4, per-round rulings, convergence and stalemate rules, anti-sycophancy rules that bind both sides.
- `--seed <file>` imports a review's verification record as pre-graded ledger rows.

### Shared
- Monitored Codex runner (`scripts/codex-run.sh`): background jobs, dead-worker and stall detection, timeouts, phantom-job cancellation, attempt rotation, sidecar files, `--probe`.
