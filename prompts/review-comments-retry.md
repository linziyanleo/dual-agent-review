Your previous review output at {{OUTPUT_PATH}} failed schema validation:

  {{SCHEMA_ERROR}}

**Common fix**: If the error is "mapping values are not allowed here", you have an unquoted string containing `: ` (colon-space). Fix by double-quoting ALL string scalar values. Example: `location: "re: F-1 from v1 / Phase 1"` — NOT `location: re: F-1 from v1 / Phase 1`.

Required schema:
- Top-level keys: overall_verdict (approve|request_changes|block), summary (string), review_comments (list).
- Each review_comment: finding_id (F-N), severity (high|medium|low|nit), category (correctness|security|performance|maintainability|scope|testing|unclear-requirements|other), location, description, suggested_change, rationale.
- Rule: overall_verdict: approve requires review_comments: [] (empty list).

Please rewrite the file at {{OUTPUT_PATH}} to match this schema exactly.
Reuse your previous analysis; only fix the schema problem. Do not change verdicts or findings content unless necessary to satisfy the schema.

After rewriting, output exactly one line:
REVIEW_COMPLETE: {{OUTPUT_PATH}}

Then stop.
