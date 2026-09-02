# Contributing

All three plugins are Markdown skills plus small shell and Python scripts. There is no build step.

## Ground rules

- **Read-only stays read-only.** No change may make any plugin modify, stage, stash or commit tracked files, or pass `--write` to Codex.
- **Blindness is procedural.** Nothing sent to Codex may mention a second reviewer, a debate, findings, or artifact paths. Templates carry no such wording; do not add any.
- **Evidence over agreement.** Findings need `path:line` and quoted code; verdicts follow the ledger and the verdict policy, never who spoke last.
- **Keep it agent-agnostic.** Skills describe procedure; enforcement lives in the scripts and the completion gates.

## Testing a change

1. Run `bash scripts/validate.sh` — frontmatter YAML, manifest agreement, path resolution, script syntax. CI runs the same script. Then `claude plugin validate .` and `claude plugin validate plugins/<name>`.
2. Install locally: `claude plugin marketplace add /path/to/claude-codex-duo` then `claude plugin install <name>@claude-codex-duo`.
3. Builder smoke test (no Codex needed): run `build-brief.sh --head WORKTREE` against a throwaway clone with staged, unstaged, deleted and untracked changes; assert the repo's `.git/index` checksum and `git status` are unchanged afterwards and that a clean clone exits 3.
4. Runner smoke test: `scripts/codex-run.sh --probe`. The runner is shared by copy; the validator fails if the copies diverge.
5. Deep-plan smoke test (no Codex needed): `init-plan.sh --repo <repo> --out /tmp/x --request "text"`, then `build-prompt.sh --art /tmp/x --round 0` and the two linters on a hand-written `01-evidence.md`; assert `git status` is unchanged.
6. One live run of the skill you changed, following it literally, and log every point of friction into `SKILL-FRICTION.md` in the artifact directory. Fix the frictions before opening a PR.

## Versioning

Bump `version` in the plugin's `.claude-plugin/plugin.json` and in `.claude-plugin/marketplace.json`, and add a CHANGELOG entry. Patch for wording, minor for new behaviour, major for a changed contract (artifact names, verdict policy, command arguments).
