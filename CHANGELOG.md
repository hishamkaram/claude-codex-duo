# Changelog

All notable changes to this repository are documented here. Versions follow [Semantic Versioning](https://semver.org/).

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
