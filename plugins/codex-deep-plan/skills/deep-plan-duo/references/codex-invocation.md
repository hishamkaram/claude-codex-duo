# Codex invocation

## The only permitted path: the monitored runner

`${CLAUDE_PLUGIN_ROOT}/scripts/codex-run.sh` launches the Codex plugin's `task` in the
background, refuses `--write`, polls the job, detects a dead worker or a stalled job log, cancels
anything it abandons, verifies the cancel, and writes sidecars. A foreground `task` call is
forbidden: a 10-minute shell limit killed one mid-round on 2026-09-02 and left a phantom job.

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/codex-run.sh "$ART/debate/r<n>-codex" --fresh|--resume-last \
    --prompt-file "$ART/debate/r<n>-prompt.md" [--stall-min 8] [--max-min 30] [--poll-sec 15]
```

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
| 3 | TIMEOUT | do not retry; T5, keep any partial `.stdout` |
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
    --out "$ART/debate/r<n>-codex.json" --round <n> --role codex --repo "$REPO" [--prior "$ART/debate/r<n-1>-codex.json"]
${CLAUDE_PLUGIN_ROOT}/skills/deep-plan-duo/scripts/debate-status.py --art "$ART"
```

If the validator fails: write `r<n>-prompt.retry.md` = the original prompt plus a final line
`RETRY: the previous reply was rejected by the schema validator for: <reasons>. Return ONLY one fenced json block. Every objection needs evidence[] and a falsifier.`
Run the runner once more with `--resume-last` and `--prompt-file` pointing at the retry file
(sidecars rotate to `.attemptN.*`). A second validator failure is T5 for that round: record the
validator output verbatim in `05-disagreements.md`, and never hand-edit a reply to make it pass.

A verdict JSON that was not written by `validate-verdict.py` from a runner `.stdout` is not a
verdict. Do not author one.

## Probe (Phase 0, once)

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/codex-run.sh --probe
```

`PROBE SUCCEEDED …` (exit 0) or `PROBE UNAVAILABLE/FAILED …` (exit 1); record the line verbatim in
`00-scope.md`. On failure tell the user `/codex:setup` exists; do not improvise auth. Confirm with
the user that sending repository content to Codex (OpenAI) is permitted for this repository;
record DECLINED if not. `--solo` skips the probe and records SOLO.

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
