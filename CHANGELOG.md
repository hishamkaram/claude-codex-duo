# Changelog

All notable changes to this repository are documented here. Versions follow [Semantic Versioning](https://semver.org/).

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
