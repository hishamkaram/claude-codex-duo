# Second-model invocation (Codex plugin, or a ccr alias)

## The only permitted path: the monitored runner

`${CLAUDE_PLUGIN_ROOT}/scripts/codex-run.sh` launches the second model in the background,
refuses `--write`, polls it, detects a dead worker or a stalled log, cancels anything it
abandons, verifies the cancel, and writes sidecars. With the default backend it drives the Codex
plugin's `task`; with `--via ccr:<alias>` it drives a headless Claude Code through the
claude-code-router gateway (see "ccr backend" below). A foreground call is forbidden: a 10-minute
shell limit killed one mid-round on 2026-09-02 and left a phantom job.

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/codex-run.sh "$ART/debate/r<n>-codex" [--via codex|ccr:<alias>] --fresh|--resume-last \
    --prompt-file "$ART/debate/r<n>-prompt.md" [--stall-min 8] [--max-min 30] [--poll-sec 15]

# exit 6: the watch bound elapsed while the round was still running. Resume the watch — do not
# relaunch, which would start a second round against the same prompt.
${CLAUDE_PLUGIN_ROOT}/scripts/codex-run.sh "$ART/debate/r<n>-codex" --attach [--max-min 30]
```

`--via` comes from `meta.json` (`via`, recorded by `init-plan.sh`); pass the same value on every
call of the run. The word "Codex" in the rest of this file means the second model whichever
backend runs it, except where a backend is named.

Always call it with the caller's background execution (Claude Code: `run_in_background: true`);
you are notified when it exits. Meanwhile `tail -n 5 "$ART/debate/r<n>-codex.progress"` shows
`elapsed status idle | last job-log line`. Do nothing else with Codex while a round is running.

Observed envelope (plugin 1.0.6): ~9 min for a design question with a 12-command budget; ~26 min
for a 400-line code review. Round 0 reads a repository from scratch: set `--max-min 30` or more.

Exit codes and what to do:

| exit | outcome | action |
|---|---|---|
| 0 | COMPLETED | run `validate-verdict.py` on `.stdout` |
| 1 | FAILED (plugin failure or worker died) | retry the same call once; then T5 |
| 2 | STALLED (cancel confirmed) | retry once with `--budget` lowered; then T5 |
| 3 | TIMEOUT — **retired.** No path produces it any more: a watch bound that elapses detaches (6). The code is kept so older sidecars stay readable | if you see it, the sidecar was written by an older runner; treat it as T5 |
| 6 | DETACHED — the watch bound elapsed while the job was still running. The runner did NOT cancel it: the job is alive and `.exit` is deliberately absent | **attach again, never relaunch.** Run the `attach_command` the runner printed (also in `.meta` and `<prefix>.detached`) to resume the watch; it publishes the real outcome and exit code when the job lands. Relaunching would run a second job against the same round. To abandon the round instead, run the `cancel_command` first |
| 4 | LAUNCH-ERROR, or any invalid invocation (missing option value, unknown argument, unreadable prompt file, `--write`) | record UNAVAILABLE with `.stderr`; a usage message means fix the call, not retry |
| 5 | STALLED or TIMEOUT **and the cancel could not be confirmed** — a Codex worker may still be running | DO NOT retry: a second job would run alongside the first. Report the job id, quote `.progress`, treat the round as failed (T5). |

Sidecars: `r<n>-codex.stdout` (final message verbatim plus two helper trailer lines), `.stderr`,
`.progress`, `.joblog`, `.meta` (job id, thread id, outcome, timings, exact command), `.exit`.
Never edit them. The round artifact references them; it never pastes them.

## One round, end to end

```bash
${CLAUDE_PLUGIN_ROOT}/skills/deep-plan-duo/scripts/build-prompt.sh --art "$ART" --round <n>     # exit 3 = leak; fix, never bypass
${CLAUDE_PLUGIN_ROOT}/scripts/codex-run.sh "$ART/debate/r<n>-codex" <--fresh|--resume-last> --prompt-file "$ART/debate/r<n>-prompt.md" --max-min 30   # background
${CLAUDE_PLUGIN_ROOT}/skills/deep-plan-duo/scripts/validate-verdict.py --extract "$ART/debate/r<n>-codex.stdout" \
    --out "$ART/debate/r<n>-codex.json" --round <n> --role codex
# repo, base SHA and the earlier rounds are read from "$ART/meta.json" and "$ART/debate/"; every
# sha-pinned citation is checked against the code AT THE BASE SHA, and from round 1 on every
# objection still outstanding from earlier rounds must carry a resolution
${CLAUDE_PLUGIN_ROOT}/skills/deep-plan-duo/scripts/debate-status.py --art "$ART"
```

A citation whose quote is not verbatim does not fail the reply: the validator drops that citation, drops an objection left without any sha-pinned citation, prints `WARN DROPPED_CITATION` / `DROPPED_OBJECTION` / `UNVERIFIED_ROOT_CAUSE` lines, and records `dropped_citations` and `flags` in the verdict JSON. Record every WARN line in the round artifact and treat an unverified root cause as E4. Only structural failures (schema, contract, praise, unresolved prior objections) fail the reply.

If the validator fails: write `r<n>-prompt.retry.md` = the original prompt plus a final line
`RETRY: the previous reply was rejected by the schema validator for: <reasons>. Return ONLY one fenced json block. Every objection needs evidence[] and a falsifier.`
Run the runner once more with `--resume-last` and `--prompt-file` pointing at the retry file
(sidecars rotate to `.attemptN.*`). A second validator failure is T5 for that round: record the
validator output verbatim in `05-disagreements.md`, and never hand-edit a reply to make it pass.

A verdict JSON that was not written by `validate-verdict.py` from a runner `.stdout` is not a
verdict. Do not author one.

## Probe (Phase 0, once)

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/codex-run.sh --probe                                   # codex backend
${CLAUDE_PLUGIN_ROOT}/scripts/codex-run.sh --probe --via ccr:<alias> --record-dir "$ART/debate"   # ccr backend
```

`PROBE SUCCEEDED …` (exit 0), `PROBE UNAVAILABLE/FAILED …` (exit 1), or `PROBE UNDETERMINED …`
(exit 0 — the companion could not determine authentication, which is not an authoritative
negative: record the line and proceed to the launch, which settles it; never treat it as
unavailable and never stamp the run SOLO on it); record the line verbatim in
`00-scope.md` — for the ccr backend also the `ccr model show` JSON the probe prints after it, in a
fenced block. On failure tell the user `/codex:setup` exists (codex) or `ccr model list` /
`ccr model show <alias>` (ccr); do not improvise auth. Confirm with the user that sending
repository content to the second model's provider (OpenAI for Codex; whatever provider the alias
routes to for ccr — the probe line names it) is permitted for this repository; record DECLINED
if not. `--solo` skips the probe and records SOLO.

## ccr backend (`--via ccr:<alias>`)

The gateway is the user's `ccr` (claude-code-router, >= 0.5.1). Aliases are machine-local
(`ccr model list`); never write one into a shipped file, and never default to one. The runner's
launch line is fixed and is the only one the plugin ever uses:

```
ccr launch --model <alias> --permission-mode plan -p --no-lifecycle --no-statusline \
  --detach --prompt-file <file> --output-format=stream-json --verbose \
  --strict-mcp-config --mcp-config='{"mcpServers":{}}' \
  --disallowedTools=Write,Edit,MultiEdit,NotebookEdit,Agent --max-turns=<N>
```

Read-only rests on three controls, in order of importance: `--permission-mode plan` (Claude
Code's own permission engine blocks every write, Bash included, while read-only Bash such as
`git log` still runs), the empty strict MCP config (removes the user's MCP tools), and the
disallowed edit tools. A disallow-list alone is NOT enough: a nested session inherits the user's
permission settings, and Bash writes were observed with only `--disallowedTools` set. The probe
therefore runs a read-only smoke for the alias (a disposable repository, this launch line, a
prompt that asks for a write by the Write tool and by Bash) and records `readonly=verified` in
`<dir>/.ccr-smoke.<alias>`; every ccr launch in that directory refuses to start (exit 4) unless a
matching record exists (same alias, provider model, CCR-generated child model ID, observed child init model, ccr version and launch-line digest). One smoke per alias per run. The configured alias is the only value passed to `ccr launch --model` before `--`; `provider_model` is descriptive, never a child CLI argument. The runner accepts a completed launch only when the child init model equals `claude_model_id`; a mismatch is `UNAVAILABLE` without an alias or Claude fallback.

CCR currently supports fresh detached jobs in this runner. Resume requests fail with
exit 4 before admission or claim mutation. Record `continuity=unavailable` and explicitly
choose `--fresh` for later CCR rounds, carrying the previous response and ledger in the
self-contained prompt. Codex resume behavior is unchanged.

The receipt binds job and session IDs. Initialization, result, and model identities must
agree before success is accepted. CCR alone owns workload cancellation. Watch expiry
detaches; a stall requests cancellation by job ID. Unknown admission or cleanup, observed
survivors, and missing exit evidence leave the attempt open without `.exit`. Partial
coverage remains visible. The private attempt, receipt, and committed result sidecars
support attach after collector death and prevent later log bytes replacing the result.
Drain legacy process-based attempts using their original runner before upgrading.

Plan mode's own plan file under `~/.claude/plans/` is the one write a ccr child may make outside
the artifact directory (Claude Code writes it when a plan-mode session ends); it holds nothing
the run relies on.

## Thread semantics

- Round 0: `--fresh`, so no earlier Codex thread in this repo leaks in.
- Rounds 1–3: `--resume-last`, so Codex keeps its own positions. Any probe between rounds breaks the
  chain; if you must probe, run the next round `--fresh` and say so in the ledger. Every round
  prompt is self-contained (inputs, materials, previous reply), so a lost thread degrades to a
  fresh context, not a broken debate.
- Never pass `--model` or `--effort` unless the user asked.

## What Codex can see — and what that means

Verified 2026-09-02 under plugin 1.0.6: the read-only sandbox denies writes and chmod but reads
`/tmp`, `~/.claude`, and Claude Code session transcripts (`~/.claude/projects/**/*.jsonl`), which
contain everything you write. Blindness for round 0 is therefore procedural: the brief never
mentions you, a comparison, or the run directory, and Codex has no reason to look. `chmod 000` on
`01`–`04` while round 0 runs is defense-in-depth only. Do not describe round 0 as structurally
blind in `PLAN.md`.

## Prompt-file discipline

Always `--prompt-file`. Never pass the prompt as one quoted string: the helper splits a single raw
argument and parses any `--resume`, `--write`, or `--background` inside it as options.

## Shell gotchas

- zsh treats `$VAR:x` as a modifier; always brace: `${SHA}:path`.
- Shell state does not persist between tool calls; re-derive `ART` and `REPO` from `meta.json` each call.

CCR admission observation is bounded to 30 seconds and the remaining watch or
smoke budget. Expiry ends only the submitting CLI, retains admission evidence,
and reports unresolved admission; it never cancels the detached job or permits
resubmission. Attach observes the original receipt when one was saved.
Workload stderr is frozen separately in `.ccr-errorlog`, with submission diagnostics
in `.ccr-submit.stderr`; `.stderr` exposes their combined diagnostics without
repeating them on attach. The committed evidence checks both stream digests.
Collectors use a kernel lease on the persistent `.claim.lock` file. Do not delete
that file. Drain legacy directory locks and unfinished legacy attempts before
upgrading. Partial cleanup coverage cannot exclude escaped descendants; an empty
observed survivor list does not establish that escaped tool processes are absent.
