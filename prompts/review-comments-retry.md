Your previous review output at {{OUTPUT_PATH}} failed schema validation:

  {{SCHEMA_ERROR}}

Please rewrite the file at {{OUTPUT_PATH}} to match the schema exactly.
Reuse your previous analysis; only fix the schema problem. Do not change verdicts or findings content unless necessary to satisfy the schema.

After rewriting, output exactly one line:
REVIEW_COMPLETE: {{OUTPUT_PATH}}

Then stop.
