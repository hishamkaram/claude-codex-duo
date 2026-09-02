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

## 6. DISAGREEMENT LOG
BOTH: {{n}} | CLAUDE-ONLY: {{n}} | CODEX-ONLY: {{n}} | CONFLICT: {{n}}
Codex status: {{SUCCEEDED | UNAVAILABLE | FAILED | DECLINED — reason}} · job ids: {{from 02-codex.meta / 05-exchange-*.meta}}
Blindness: procedural (unmotivated brief + ordering + mode-000 defense-in-depth); not structurally guaranteed.
{{every UNRESOLVED item with both positions and strongest evidence for each}}

**Escalate one at a time (optional):** for each UNRESOLVED item, a ready-to-paste line:
`/debate "{{finding title as a falsifiable defect claim, with path:line}}" hypothesis 3 --seed {{artifact dir}}/04-verification.md`

## 7. FALSE-POSITIVE APPENDIX
{{every claim either model raised and refuted, with the refuting evidence.
Mandatory — write "none" only if genuinely none.}}

## 8. COVERAGE STATEMENT
{{categories reviewed vs. n/a; paths you could not review and why; commands run
and their results; what a human should still check manually}}

## 9. GOOD PARTS
{{2–3 bullets max}}
