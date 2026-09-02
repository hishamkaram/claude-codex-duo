---
description: Two-model PR review with a blind Codex second reviewer; ends in one merge decision with an audit trail
argument-hint: '<pr-number|branch|commit|local> <base-ref> "<stated intent>"'
---
Use the two-model-pr-review skill.
PR/branch: $1 (use `local` or `worktree` for uncommitted changes → head = WORKTREE snapshot). Base ref: $2 (defaults to HEAD in local mode). Stated intent: $3.
