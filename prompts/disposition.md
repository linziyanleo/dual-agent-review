# Internal template — Claude uses this when processing Codex findings

For each `finding` in `{{FINDINGS_PATH}}`, decide a disposition.

## Output schema (write to {{DISPOSITION_PATH}})

```yaml
plan_version_reviewed: v1   # or v2, v3...
total_findings: 5
dispositions:
  - finding_id: F-1
    disposition: incorporated | rejected | deferred
    reason: <1-2 sentences>
    plan_change_summary: <only when incorporated: which section of next plan version reflects this>
  - finding_id: F-2
    ...
```

## Decision guidelines

**Incorporate when:**
- finding is correct and the suggested_change is reasonable → apply
- finding identifies a real issue even if the suggested fix is suboptimal → apply your own better fix and note it in `plan_change_summary`

**Reject when:**
- finding is based on a misunderstanding of the plan / context
- finding is out of scope for the current task (note this — it might become a follow-up task)
- finding contradicts an explicit user constraint
- suggested_change makes the plan worse

When rejecting, **`reason` must be substantive** — "disagree" is not enough.
A future Codex round will see this reason; weak reasons invite re-raise.

**Defer when:**
- finding is valid but is genuinely a separate, larger piece of work
- record it as a follow-up TODO in the next plan version's "Risks & open questions" section

## Anti-patterns to avoid

- Don't "incorporate" cosmetically (adding a sentence that doesn't actually change the approach) just to make Codex shut up. That guarantees Codex re-raises it as "the fix is insufficient".
- Don't reject everything from a particular category just to push toward convergence. Each finding stands on its own.
- Don't accumulate "deferred" items as an escape hatch. If more than 2 findings are deferred in a single round, the plan probably has real scope problems — surface this to the user.
