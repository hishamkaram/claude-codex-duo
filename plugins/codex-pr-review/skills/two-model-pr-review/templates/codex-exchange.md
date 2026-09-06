# Exchange request — {{phase: consultation | resolution}}

You are continuing a code review of the repository at {{repo path}} (head `{{head SHA}}`, base `{{base SHA}}`).
Read code only at those revisions (`git show <sha>:<path>`). Do not read files outside the repository.

## Findings under discussion
{{one block per selected canonical ID, in ID order:}}

### {{F-nn}} — provisional {{severity}}
- Claim: {{normalized claim}}
- Locations: {{path:line[-line]@sha, one per line}}
- Trigger: {{concrete trigger}}
- Impact: {{impact}}
- Position A: {{fair statement of the first position, with its quoted evidence}}
- Position B: {{fair statement of the second position, with its quoted evidence}}
- Challenge: {{one falsifiable question that would decide it}}
{{resolution only:}} - Executed evidence: {{command → output excerpt, or the cited verifier evidence}}

## Response contract
Reply with exactly one fenced `json` block and nothing else:

```json
{"phase": "{{consultation | resolution}}",
 "dispositions": [
  {"id": "F-nn", "action": "MAINTAIN | RETRACT | REFINE | VERIFY",
   "claim": "…", "severity": "P0 | P1 | P2 | P3",
   "locations": ["path:line[-line]@sha \"quoted code\""],
   "trigger": "…", "impact": "…",
   "observations": ["path:line[-line]@sha \"quoted code\""],
   "falsifier": "…",
   "proposed_checks": ["command or trace that decides it"],
   "open_factual_questions": []}
 ]}
```

Rules the validator enforces (a violation makes the whole response unusable):
- exactly one disposition per finding listed above, no other IDs, no other root keys, no missing or extra fields;
- every list item is non-blank; `locations` and `observations` are repository-relative `path:line[-line]@sha "quote"` citations at the head or base revision — never absolute paths, `.`/`..` segments, scratch directories or review artifacts;
- no text names a reviewer, model, agent, transcript, run directory or artifact file; state facts about the code, not who said them;
- `RETRACT` names the fact that changes the position; `REFINE` restates the claim or severity; `VERIFY` gives the command or trace that decides the question.
