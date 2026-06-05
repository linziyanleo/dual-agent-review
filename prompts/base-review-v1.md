{{FRAMING}}

## Spec Context (project norms and constraints)

{{SPEC_CONTEXT}}

{{ROLE_INSTRUCTIONS}}

## Task

1. Read the plan file at: `{{PLAN_PATH}}`
2. Produce a critical review according to the Review Focus above.
3. Write your review as **strict YAML** to: `{{OUTPUT_PATH}}`

## Required output schema (YAML, no markdown fences, no commentary outside YAML)

```yaml
overall_verdict: approve | request_changes | block
summary: <2-3 sentence overall assessment>
review_comments:
  - finding_id: F-1
    severity: high | medium | low | nit
    category: <see allowed categories in Review Focus above>
    location: <which section/step of the plan, or "global">
    description: <what is wrong / missing / risky>
    suggested_change: <concrete actionable change, not just "consider X">
    rationale: <why this matters — 1 sentence>
  - finding_id: F-2
    ...
```

## Rules

- **YAML quoting**: All string scalar values MUST be double-quoted (`"..."`). Any value containing `: ` (colon-space) causes a YAML parse error if unquoted. Example: `location: "re: F-3 from v1 / Step 2"` — NOT `location: re: F-3 from v1 / Step 2`.
- Be specific. "Add error handling" is not actionable. "Step 3 doesn't handle ENOSPC on the cache write — wrap in try/except and surface as a user-visible error" is actionable.
- Do NOT propose architectural rewrites unless the plan has a fundamental flaw. Scope your suggestions to within the plan's stated goals.
- Do NOT modify the plan file. Only write to `{{OUTPUT_PATH}}`.
- If the plan is fundamentally sound, set `overall_verdict: approve` and `review_comments: []` (empty list). Don't invent nits to fill space.
- If you genuinely have no concerns, that's a valid outcome. Say so.

After writing the file, output exactly one line to the terminal:
`REVIEW_COMPLETE: {{OUTPUT_PATH}}`

Then stop. Do not start any other work.
