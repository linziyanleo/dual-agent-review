# Internal template — Claude uses this when processing Codex findings

For each review comment in `{{FINDINGS_PATH}}`, decide a disposition.

## Output schema (write to {{DISPOSITION_PATH}})

```yaml
plan_version_reviewed: v1   # or v2, v3...
total_review_comments: 5
dispositions:
  - finding_id: F-1
    disposition: incorporated | rejected | deferred
    reason: <required for rejected>
    plan_change_summary: <required when incorporated: which section of next plan version reflects this>
  - finding_id: F-2
    ...
```

`validate_dispositions.py` enforces:
- `rejected` requires non-empty `reason`.
- `incorporated` requires non-empty `plan_change_summary`.
- `deferred` is **not allowed** for `high` or `medium` severity findings — those must be either `incorporated` or `rejected`. Use `rejected` with a substantive `reason` pointing to where the work is tracked externally (ticket id, doc link, or owner+deadline). Low/nit deferrals stay lightweight.

## Decision guidelines

**Incorporate when:**
- finding is correct and the suggested_change is reasonable → apply
- finding identifies a real issue even if the suggested fix is suboptimal → apply your own better fix and note it in `plan_change_summary`

**Reject when:**
- finding is based on a misunderstanding of the plan / context
- finding is out of scope for the current task and is being tracked elsewhere (ticket, doc, separate plan)
- finding contradicts an explicit user constraint
- suggested_change makes the plan worse

When rejecting, **`reason` must be substantive** — "disagree" is not enough.
A future Codex round will see this reason; weak reasons invite re-raise.

For a **high or medium** severity finding that is genuinely out of scope but still needs to happen, reject it with a `reason` that points to where the follow-up is tracked (ticket id, doc link, or owner + deadline). That reason becomes the audit record. The validator forbids `deferred` for high/medium because a deferred status has no resolution path — a rejected-with-external-tracker reason does.

**Defer when:**
- finding is a **low or nit** severity issue that is valid but genuinely separate and small
- record it as a follow-up TODO in the next plan version's "Risks & open questions" section

`deferred` is the lightweight escape hatch for low/nit-level nice-to-haves. It is **not** valid for high/medium findings — those must be either incorporated now or rejected with an external-tracker pointer.

## Anti-patterns to avoid

- Don't "incorporate" cosmetically (adding a sentence that doesn't actually change the approach) just to make Codex shut up. That guarantees Codex re-raises it as "the fix is insufficient".
- Don't reject everything from a particular category just to push toward convergence. Each finding stands on its own.
- Don't accumulate "deferred" items as an escape hatch. If more than 2 findings are deferred in a single round, the plan probably has real scope problems — surface this to the user.
