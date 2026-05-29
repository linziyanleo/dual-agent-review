You are continuing the review loop. The plan has been revised based on your previous findings.

## Reminder

Spec Context and output YAML schema were provided in the v1 review prompt — they remain in effect for this round. Use the same top-level YAML schema; number findings F-1, F-2... within this round (not across rounds); keep the summary focused on whether the revision is sufficient. Do not deviate from the schema.

## Task

1. Read the updated plan: `{{PLAN_PATH}}`
2. Read the diff vs previous version: `{{DIFF_PATH}}`
3. Read how Claude handled your previous findings: `{{PREV_DISPOSITION}}`
4. Produce an **incremental** review focused on:
   - Did the incorporated changes actually fix the underlying issue, or just paper over it?
   - For findings Claude rejected with a reason — is that reasoning sound?
   - New issues introduced by the changes
   - Anything still missing that the diff did not address

5. Write your review as strict YAML to: `{{OUTPUT_PATH}}`

## Critical rules for incremental rounds

- **Do NOT re-raise issues you've already raised** unless the fix is genuinely wrong or insufficient. If Claude said "rejected because X" and X is reasonable, accept it and move on. Re-raising rejected items is what makes loops fail to converge.
- **Approve quickly when warranted**. If the v(N-1) findings were all addressed reasonably and you have no genuine new concerns, set `overall_verdict: approve` and `review_comments: []`. Do not invent nits to justify another round.
- **No architectural reframing at this stage**. If the overall approach was acceptable in v1, don't suggest scrapping it now.

After writing the file, output exactly one line:
`REVIEW_COMPLETE: {{OUTPUT_PATH}}`

Then stop.
