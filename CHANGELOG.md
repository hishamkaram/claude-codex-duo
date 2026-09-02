# Changelog

All notable changes to this repository are documented here. Versions follow [Semantic Versioning](https://semver.org/).

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
