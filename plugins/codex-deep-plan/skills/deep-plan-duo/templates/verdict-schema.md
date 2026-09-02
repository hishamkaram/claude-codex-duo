Return exactly one fenced ```json block with this shape. Every string field is plain text; every citation has the form `path:lines@sha "quote of at most 15 words"` or `cmd: <command> -> <output excerpt>`.

{
  "role": "codex",
  "round": <n>,
  "verdict": "APPROVE | APPROVE_WITH_CONDITIONS | REJECT | NO_OPINION_INSUFFICIENT_EVIDENCE",
  "summary": "one paragraph, evidence not adjectives",
  "root_causes": [                         // round 0: required. later rounds: only if changed
    {"id": "RC-1", "explains": ["issue-123"],
     "cause_class": "violated_invariant | missing_abstraction | wrong_domain_model | broken_contract | absent_constraint",
     "statement": "one falsifiable sentence naming the mechanism, not the symptom",
     "evidence": ["src/x.ts:40-44@<sha> \"quote\"", "cmd: <command> -> <excerpt>"]}
  ],
  "designs": [                             // round 0: at least 2, including the narrowest fix and the largest correct change
    {"id": "DS-1", "one_sentence": "describe it without naming the symptom or the issue number",
     "addresses": ["RC-1"], "files": ["path", "path"], "blast_radius": "files/modules/public API/schema touched, consumers affected",
     "reversibility": "revertable after production writes? migrations?", "risks": "worst realistic outcome and how it would be detected",
     "preferred": true}
  ],
  "single_pr_recommendation": {"verdict": "ONE_PR | SPLIT | INSUFFICIENT_EVIDENCE", "because": "shared root cause and change surface, or not — cite"},
  "objections": [
    {"id": "X-1", "class": "FACT_ERROR | MISSING_EVIDENCE | ROOT_CAUSE_WRONG | SUPERIOR_ALTERNATIVE | RISK_UNMANAGED | SCOPE | TEST_GAP | MIGRATION_UNSAFE",
     "severity": "BLOCKER | MAJOR | MINOR | NIT",
     "claim": "one falsifiable sentence",
     "evidence": ["path:lines@sha \"quote\"", "cmd: ... -> ..."],
     "proposed_change": "what should change, concretely",
     "falsifier": "the observation that would prove this objection wrong"}
  ],
  "objection_resolutions": [               // rounds 2+: one entry per objection you raised earlier
    {"id": "X-1", "status": "SUSTAINED | WITHDRAWN | DOWNGRADED", "severity": "<new severity if DOWNGRADED>", "because": "citation or evidence id (F-3, V-1, X-2)"}
  ],
  "changed_positions": [                   // anything you now hold differently; empty list is legitimate
    {"objection_id": "X-1", "from": "...", "to": "...", "because": "citation or evidence id"}
  ],
  "evidence_requests": [                   // facts you could not settle in your sandbox
    {"id": "ER-1", "claim": "...", "how_to_verify": "exact command or test"}
  ],
  "attestations": {
    "files_read": ["path", "path"],
    "checks_performed": ["cmd -> result", "cmd -> result", "cmd -> result"],
    "adversarial_attempt": "what you tried in order to break your own preferred design or the plan, and what happened"
  }
}

Rules the validator enforces: an objection without evidence[] or without a falsifier is discarded; an objection whose only evidence is a hypothesis cannot be BLOCKER or MAJOR; a bare APPROVE with no objections needs adversarial_attempt and at least three checks_performed; a WITHDRAWN or DOWNGRADED resolution and every changed_positions entry need a citation or evidence id in because; praise or agreement language ("great", "I agree", "good point") fails validation — state evidence instead. NO_OPINION_INSUFFICIENT_EVIDENCE is a respected answer.
