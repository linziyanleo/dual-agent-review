{{FRAMING}}

## Spec Context (project norms and constraints)

{{SPEC_CONTEXT}}

{{ROLE_INSTRUCTIONS}}

## Task

1. Read the updated plan: `{{PLAN_PATH}}`
2. Read the diff vs previous version: `{{DIFF_PATH}}`
3. Read how the author handled your previous findings: `{{PREV_DISPOSITION}}`
4. Produce an **incremental** review focused on:
   - Did the incorporated changes actually fix the underlying issue, or just paper over it?
   - For findings the author rejected with a reason — is that reasoning sound?
   - New issues introduced by the changes
   - Anything still missing that the diff did not address

5. Write your review as strict YAML to: `{{OUTPUT_PATH}}`

## Same schema as v1 review

```yaml
overall_verdict: approve | request_changes | block
summary: <2-3 sentences focused on what changed and whether it's now sufficient>
review_comments:
  - finding_id: F-1
    severity: high | medium | low | nit
    category: <see allowed categories in Review Focus above>
    location: <section/step, or reference a previous F-id like "re: F-3 from v1">
    description: ...
    suggested_change: ...
    rationale: ...
```

Number findings F-1, F-2... within THIS round (not across rounds).

## Critical rules for incremental rounds

- **Do NOT re-raise issues you've already raised** unless the fix is genuinely wrong or insufficient. If the author said "rejected because X" and X is reasonable, accept it and move on. Re-raising rejected items is what makes loops fail to converge.
- **Approve quickly when warranted**. If the previous findings were all addressed reasonably and you have no genuine new concerns, set `overall_verdict: approve` and `review_comments: []`. Do not invent nits to justify another round.
- **No architectural reframing at this stage**. If the overall approach was acceptable earlier, don't suggest scrapping it now.
- Do NOT modify the plan file. Only write to `{{OUTPUT_PATH}}`.

After writing the file, output exactly one line:
`REVIEW_COMPLETE: {{OUTPUT_PATH}}`

Then stop.
