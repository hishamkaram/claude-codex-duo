# Review: {{target}} ({{base}}...{{head}})

{{if single-model: `SINGLE-MODEL REVIEW — cross-review not performed: <reason>`}}

## 1. VERDICT
{{BLOCK | REQUEST CHANGES | APPROVE WITH COMMENTS | APPROVE | NEEDS CLARIFICATION}}

{{one paragraph of justification}}

**MERGE CONDITIONS:** {{finite list of finding IDs that must be resolved}}

## 2. SUMMARY
{{what the PR does, in your own words, from reading the CODE — not the PR
description. Then: whether that matches the stated intent.}}

## 3. RISK
{{1–3 things most likely to break in production, plus the rollback story}}

## 4. FINDINGS
{{grouped by severity, full finding schema, P0 → P3, then QUESTIONs}}

### Pre-existing (non-blocking, untouched by this diff)
{{...}}

## 5. QUESTIONS FOR THE AUTHOR
{{...}}

## 6. CONSULTATION & DISAGREEMENT LOG
BOTH: {{n}} | CLAUDE-ONLY: {{n}} | CODEX-ONLY: {{n}} | CONFLICT: {{n}}
Selection: {{candidate count}} candidates · {{exact selector artifact and predicate summary}}
Consultation: {{COMPLETE | SKIPPED — reason | NOT RUN BY POLICY — tier <tier>, an eligible phase deliberately not executed, never a failure}} · dispositions: {{selected/returned ID equality}} · job ids: {{from 04-consultation*.meta}}
Verification: {{every P0–P3 finding verified from normalized evidence-only packets}}
Residual resolution: {{COMPLETE | SKIPPED — reason}} · job ids: {{from 06-resolution*.meta}}
Participants (from 00-participants.tsv and 03-provenance.tsv):
| id | backend | alias | status | job or session id | findings raised |
|---|---|---|---|---|---|
| p1 | {{codex | ccr}} | {{alias | -}} | {{SUCCEEDED | UNAVAILABLE | FAILED | DECLINED — reason}} | {{from 02-p1.meta: job= or thread=}} | {{n}} |
Exchange participant: {{p<k> from 02-exchange-participant | none}} · unified budget: {{successful responses}}/2 responses, {{launches}}/4 launches
Lead: {{`codex-pr-review:lead-reviewer` task <id> | general-purpose fallback (reason) | in-context fallback (reason)}} · join: {{JOIN-OK line from 03-matrix.md}} · review seal: {{unchanged | not applicable}}
Tier: {{compact-v1 | full}} — from the frozen brief's `- Tier:` line. Both tiers apply every rubric category and search consumers repo-wide; `compact-v1` writes one combined pass with no category recital. State it plainly: a reader must be able to tell how much was written down, and must never read a shorter report as a shallower review.
Scope: {{`<base>..<head>` — base is the merge base of <requested base> and the head, so the diff is what this change introduces | requested base was already the fork point}} · {{n}} file(s) excluded as trunk-only work by the merge-base correction (00-brief.md.scope.json) {{| merge-base correction not applicable: local snapshot-tree review}}
Blindness: procedural (neutral packets hashed before any finding + lead sealed before any participant output was read + lead in its own context + mode-000 defense-in-depth + no participant told of another); not structurally guaranteed. {{Concurrency: the lead and {{N}} participant review(s) overlapped from <lead start> to <first end> (00-run.md) | single-model run: no cross-review, nothing ran concurrently}}
{{every UNRESOLVED item with both positions and strongest evidence for each}}

**Escalate one at a time (optional):** for each UNRESOLVED item, a ready-to-paste line:
`/debate "{{finding title as a falsifiable defect claim, with path:line}}" hypothesis 3 --seed {{artifact dir}}/05-verification.md`

## 7. FALSE-POSITIVE APPENDIX
{{every claim either model raised and refuted, with the refuting evidence.
Mandatory — write "none" only if genuinely none.}}

## 8. COVERAGE STATEMENT
{{categories reviewed vs. n/a; paths you could not review and why; commands run
and their results; what a human should still check manually}}
{{when 05-scope-attribution.tsv has any `trunk-only` row: name those findings and say
they were attributed to work the trunk did after this branch diverged, not to this change}}

## 9. GOOD PARTS
{{2–3 bullets max}}
