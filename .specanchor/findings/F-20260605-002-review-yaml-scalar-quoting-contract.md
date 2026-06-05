---
id: F-20260605-002
summary: "review prompt schema omits YAML scalar quoting rule for colon-space values"
type: risk
status: candidate
confidence: high
impact: medium
visibility: handoff
affects:
  - path: "prompts/base-review-v1.md"
  - path: "prompts/base-review-vn.md"
  - path: "prompts/review-comments-retry.md"
  - path: "scripts/validate_review_comments.py"
evidence_ref:
  - type: file-snapshot
    ref: "prompts/base-review-vn.md:22-35"
  - type: file-snapshot
    ref: "prompts/review-comments-retry.md:5-11"
  - type: command
    ref: "python3 PyYAML reproduction: location: re: F-1 -> mapping values are not allowed here"
suggested_target: task
failure_class: contract_ambiguity
created: 2026-06-05
updated: 2026-06-05
source_task: ".specanchor/tasks/_cross-module/2026-06-05_dar-dogfood-runtime-hardening.spec.md"
---

# Finding: Review YAML needs explicit scalar quoting rules

## Observation

The review prompts require strict YAML, but they do not explicitly require string scalar values containing `: ` to be quoted or represented as block scalars. The vN schema example quotes the `location` example `"re: F-3 from v1"`, but that example is not stated as a general lexical rule. The retry prompt restates the field schema but does not explain the colon-space YAML failure mode.

## Why It Matters

Codex can produce semantically correct review content that is syntactically invalid YAML, for example `location: re: F-1 from v1`. PyYAML rejects that before the schema validator can inspect fields, so retry needs a precise instruction rather than a generic "match this schema" request.

## Evidence

- `prompts/base-review-vn.md` lines 22-35 show the schema example but do not state a quoting rule.
- `prompts/review-comments-retry.md` lines 5-11 repeats the schema and approve rule only.
- A local PyYAML reproduction confirmed `location: re: F-1 from v1 / Phase 1` fails with `mapping values are not allowed here`, while `location: "re: F-1 from v1 / Phase 1"` parses.

## Implications

The validator should continue to fail fast on invalid YAML, but the prompt and retry prompt should reduce avoidable parse failures and make the one retry useful.

## Proposed Action

Update `base-review-v1.md`, `base-review-vn.md`, and `review-comments-retry.md` to require all string scalar values to use double quotes or `>-` block scalars, with an explicit note that any value containing `: ` must be quoted. Add a targeted parse-error diagnostic in `validate_review_comments.py` when PyYAML reports `mapping values are not allowed here`.
