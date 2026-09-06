# Workflow mode (`--workflow`)

An opt-in execution mode for the fan-out stages of the review. It changes WHO runs a unit of
work, never what the unit is or what the artifacts look like: reconciliation, consultation,
verification, residual resolution, and `07-review.md` are identical with and without it.

## The tool

Claude Code's built-in **Workflow** tool runs a JavaScript orchestration script that spawns
subagents deterministically (`agent()`, `parallel()`, `pipeline()`; concurrent agents capped at
`min(16, CPUs − 2)`; `agentType` selects a registered agent such as this plugin's
`codex-pr-review:lead-reviewer` and `codex-pr-review:finding-verifier`; a `schema` forces a
validated structured return; an agent that is skipped or dies returns `null`). The script body
has no filesystem access; the agents do. The tool is user-gated: it may be called only when the
user opted in, and a slash command or skill instruction counts as that opt-in — which is why
this mode exists only behind an explicit `--workflow` argument. Never call the tool without it.

The script's citation, artifact and provenance rules are a block generated from
`scripts/review_common.py` by `scripts/gen-workflow-constants.py --write`
(`validate.sh` fails if it drifts); edit the Python module, never the block.
The script is shipped at `${CLAUDE_PLUGIN_ROOT}/skills/two-model-pr-review/templates/review-workflow.js`
and is passed by path (`scriptPath`) with a JSON `args` object; it is checked with `node --check`
by `scripts/validate.sh`. Codex never runs inside a workflow agent: the monitored runner's
cancel and exit-code contract assumes one owner, and that owner is you.

## Agent types

The script spawns `codex-pr-review:lead-reviewer` and `codex-pr-review:finding-verifier`. If those
types are not registered in the session (the plugin was just installed or runs from a checkout),
pass both `agentTypes: { "lead": "general-purpose", "verifier": "general-purpose" }` and
`agentInstructions: { "lead": "<agents/lead-reviewer.md verbatim>", "verifier": "<agents/finding-verifier.md verbatim>" }`
in `args`; the script prepends the contract to every prompt. Record the substitution in `00-run.md`
and in `07-review.md` §8 (`Lead: general-purpose fallback (…)`).

## Capability check and fallback

Before the first stage, check that the Workflow tool is listed in this session. If it is not:
say so immediately, run the stage with plain Agent-tool calls (several agents launched in one
message run concurrently; use the same agent types, prompts and per-item contracts), and write
`Workflow: unavailable — Agent-tool fallback` into `00-run.md` and into `07-review.md` §8. Never
silently switch. If the tool is present but a run is cancelled or returns nothing, finish the
stage in-context and record `Workflow: partial — <reason>` the same way.

## Supervision of fan-out units

Every unit launched in the background gets the same pair of `agent-watch.sh` jobs the join turn
gives the lead (SKILL.md §Join turn): one advisory, one deadline. A background job notifies once,
at exit, so two single-purpose watchers are what produce an advisory and, later, a deadline.

- **Lead shards.** One pair per shard, `--expect "$ART/01-lead.<shard>.md"`.
- **Phase 5.** A verifier agent itself returns a structured object and writes no file of its own —
  the `findings` the orchestrator passes to the script are the packets `pre-verification` generated
  into `05-verifier-packets.ndjson`, one per line, unchanged (see `references/adjudication.md`) — so
  there is nothing to watch per finding while the agents run. Watch the STAGE instead: write
  `$ART/.stage-verify.done` the moment the
  Workflow call returns, and point one pair of watchers at that sentinel. Teardown is then
  automatic — a successful fan-out ends both watchers at exit 0, and neither can outlive the work
  it watched and report a stale verdict.

A verifier's repro commands are chosen after Phase 3, from findings that do not exist at Phase 0,
so the Phase-0 consent probe cannot enumerate them. Supervision, not the probe, is what bounds
them.

## Stage `verify` (Phase 5, always under `--workflow`)

```json
{ "stage": "verify", "art": "<ART>", "repo": "<REPO>", "base": "<sha>", "head": "<sha or tree>",
  "findings": [ { "id": "F-01", "severity": "P1", "claim": "...", "locations": ["path:line"],
                  "trigger": "...", "impact": "...", "observations": ["path:line@sha \"quote\""],
                  "falsifier": "...", "proposed_checks": ["..."], "open_factual_questions": [] } ] }
```

`locations` and `observations` entries are repository-relative `path:line` or `path:line@sha "quote"`
citations; a path containing spaces is double-quoted (`"docs/API guide.md":42`). Absolute paths,
`.`/`..` segments and scratch directories are rejected before any verifier is spawned.

This packet is the complete verifier input contract. Do not add source labels, selector decisions,
reviewer identity/count, agreement/concession state, rhetoric, transcript references, debate
verdicts, or artifact paths.

One `finding-verifier` per finding (pipeline, no barrier), rungs (a), (b), (d) only. The script
returns `{ verdicts: [ { id, verdict, method, evidence, trigger, severity_note, refutation_searched } ] }`
and logs the ids whose agent returned `null`; those you verify in-context. A CONFIRMED or
REFUTED verdict whose `method` is `none`, whose `evidence` items are not citation-shaped
(`path:line[@sha] "quote"`) or recorded commands (`cmd: ... -> ...`), or which carries no
citation item at all (a `cmd:` line alone cannot be re-verified, and the gate's verdict
validator resolves every citation at the reviewed head or base) is coerced to UNVERIFIABLE
before it reaches you. Rung (c) — the
project's own suite, linter, typechecker — you run once, sequentially, after the script returns.
Copy each verdict into `05-verification.md` under its finding with the method used.

## Stage `lead` (Phase 1, only under `--workflow` AND a diff over ~2000 LOC)

```json
{ "stage": "lead", "art": "<ART>", "repo": "<REPO>", "pluginRoot": "<CLAUDE_PLUGIN_ROOT>",
  "files": [ "every changed path" ],
  "shards": { "api": [ "src/api/a.ts", "src/api/b.ts" ], "web": [ "web/x.tsx" ] } }
```

The shard manifest comes from the Phase 0 subsystem table. The script refuses to spawn anything
unless every changed file is owned by exactly one shard and every shard file is a changed file
(unowned, duplicate or unknown paths are listed in the error). One `lead-reviewer` per shard
(parallel), each writing and sealing `01-lead.<shard>.md`, each still searching consumers
repo-wide for the symbols its files change. Merge only after Codex has finished OR before
opening any `02-codex.*` file: `chmod 600` the shard files, concatenate them under one heading
per shard with the per-shard coverage table the rubric already requires, add a "Cross-shard"
section with anything you see spanning shards, write `01-lead.md`, `chmod 000` it, `chmod 000`
every shard file again, and only then run `phase-gate.sh pre-phase3`. `pre-codex` refuses a
resumed run while any `01-lead*.md` is readable. The shard files are never sent to Codex. Shard
names must match `[A-Za-z0-9][A-Za-z0-9_.-]{0,63}`; file lists reach each agent JSON-encoded, so
a path with a newline or quote stays one token.

## What to record

`00-run.md`: `Workflow: ran | unavailable — Agent-tool fallback | partial — <reason>`, the
run id printed by the tool, and per stage the agent task ids and start/end times it reports.
`07-review.md` §8 repeats the first line. Cancellation by the user is reported as `partial`.
