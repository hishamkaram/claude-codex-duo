# Contributing

All three plugins are Markdown skills plus small shell and Python scripts. There is no build step.

## Ground rules

- **Read-only stays read-only.** No change may make any plugin modify, stage, stash or commit tracked files, or pass `--write` to Codex.
- **Blindness is procedural.** The initial blind brief and all pre-`JOIN-OK` communication sent to Codex may not mention a second reviewer, a debate, findings, or artifact paths. Post-join exchanges may contain canonical findings and fair normalized positions, but never artifact paths or raw review sidecars.
- **Evidence over agreement.** Findings need `path:line` and quoted code; verdicts follow the ledger and the verdict policy, never who spoke last.
- **Keep it agent-agnostic.** Skills describe procedure; enforcement lives in the scripts and the completion gates.
- **No signal may leave the job it owns.** `kill -- "-N"` is not "process group N" for every N: POSIX gives `-1` the meaning *every process the user may signal* — on macOS the whole GUI login session, `loginwindow` included — and `-0` the meaning *the sender's own process group*, i.e. the invoking shell and every sibling terminal job. A 2026-09-10 audit found `codex-run.sh` reading `pgid=` out of `<prefix>.detached` and signalling it unchecked, while the identity test that authorised the cancel proved `pid=`, a different field; a record carrying `pgid=1` reached `kill -TERM -- -1`. The read-only runner now delegates workload cancellation to CCR by job ID and never sends workload signals. Remaining process-based tools and test teardown must route every group signal through `pgid_is_signalable`, which refuses empty, non-numeric, `0`, `1`, this process, this process's own group, and any group that is no longer the recorded owner pid's group. Cancellation **fails closed** — an unverifiable target returns "not confirmed" having signalled nothing, and no fallback may signal a parent, a shared group, or an arbitrary pid. This applies to test fixtures and teardown too: never write `pgid=0` or `pgid=1` into a fixture, and never default a pgid to `0` (`"-${VAR:-0}"`). Any change touching process groups, cancellation, stalls, timeouts, detach/attach, traps or cleanup must be reviewed against this rule specifically.

## Testing a change

1. Run `bash scripts/validate.sh` — frontmatter YAML, manifest agreement, path resolution, script syntax. CI runs the same script. Then `claude plugin validate .` and `claude plugin validate plugins/<name>`.
2. Install locally: `claude plugin marketplace add /path/to/claude-codex-duo` then `claude plugin install <name>@claude-codex-duo`.
3. Builder smoke test (no Codex needed): run `build-brief.sh --head WORKTREE` against a throwaway clone with staged, unstaged, deleted and untracked changes; assert the repo's `.git/index` checksum and `git status` are unchanged afterwards and that a clean clone exits 3.
4. Runner smoke test: `scripts/codex-run.sh --probe`. The runner is shared by copy; the validator fails if the copies diverge.
5. Deep-plan smoke test (no Codex needed): `init-plan.sh --repo <repo> --out /tmp/x --request "text"`, then `build-prompt.sh --art /tmp/x --round 0` and the two linters on a hand-written `01-evidence.md`; assert `git status` is unchanged.
6. One live run of the skill you changed, following it literally, and log every point of friction into `SKILL-FRICTION.md` in the artifact directory. Fix the frictions before opening a PR.

## Versioning

Bump `version` in the plugin's `.claude-plugin/plugin.json` and in `.claude-plugin/marketplace.json`, and add a CHANGELOG entry. Patch for wording, minor for new behaviour, major for a changed contract (artifact names, verdict policy, command arguments).

### Real CCR lifecycle validation

Run `python3 scripts/test-ccr-live.py --artifacts /tmp/ccr-live-unique --containment process-group`
on macOS with installed CCR >=0.5.1 and the real Claude CLI. The artifact directory
must be new. It uses an isolated job/config store and a deterministic local provider;
it is lifecycle evidence, not proof of provider quality or write-tool refusal.
The CI workflow runs the same test on macOS, Linux systemd scopes, and forced Linux
process groups against pinned CCR0.5.1. It records provider entry, versions, source
digests, watcher recovery, owner cancellation and an unrelated interactive chrome
sentinel. The populated process-group regression also runs separately.
Configured-provider smoke and real task evidence are still required before release.

Collector exclusion uses the platform's file lock through Python `fcntl.flock`,
not process-table reclamation. See [Linux flock](https://man7.org/linux/man-pages/man2/flock.2.html)
and [Apple flock](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/flock.2.html).
The shell retains its inherited open-file description. The lock file persists;
never unlink it to recover a collector. Legacy directory locks must drain before
upgrading. Workload cancellation always uses CCR's admitted job identity.

The collector lease is explicitly closed in observation command substitutions and
external polling children. Admission uses an `exec` handoff to its helper, which
retains the inherited lease through receipt binding. Every mutating helper retains
the same prefix lease through its final artifact write; standalone helper calls
acquire that lease themselves. This prevents an orphaned helper from overwriting
a replacement attempt after collector loss. Saved recovery
commands bind the original job: `--expected-job` on attach rejects prefix reuse;
the cancellation helper enforces the same identity before requesting cancellation.
An unconfirmed write-runner cancellation returns exit5 without waiting for an
unproven stop or staging/committing files that the workload may still change.

The separate write runner checks the recorded owner identity again before forceful
escalation. If the leader disappears or its identity changes, cancellation remains
unconfirmed and the runner does not wait or commit the live worktree. Saved Codex
recovery commands quote every argument, including installation and artifact paths.
