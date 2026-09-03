---
description: Two-model PR review with a blind Codex second reviewer; ends in one merge decision with an audit trail
argument-hint: '<pr-number|branch|commit|local> <base-ref> "<stated intent>" [--workflow]'
---
Use the two-model-pr-review skill.
PR/branch: $1 (use `local` or `worktree` for uncommitted changes → head = WORKTREE snapshot). Base ref: $2 (defaults to HEAD in local mode). Stated intent: $3. Optional flag `--workflow`, recognised anywhere in the arguments (local mode may omit the base ref, so it is not positional): selects the Workflow-tool fan-out for verification (and for the lead review above ~2000 LOC) as described in the skill's `references/workflow-mode.md`. Any other `--token` is an error to report, not a mode.
