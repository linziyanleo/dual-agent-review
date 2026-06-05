---
id: F-20260605-003
summary: "retry_review_comments deletes invalid YAML before proving the Codex retry path is available"
type: risk
status: candidate
confidence: high
impact: medium
visibility: handoff
affects:
  - path: "scripts/retry_review_comments.sh"
  - path: "scripts/send_review.sh"
  - path: "scripts/drivers/herdr.sh"
evidence_ref:
  - type: file-snapshot
    ref: "scripts/retry_review_comments.sh:30-50"
  - type: file-snapshot
    ref: "scripts/send_review.sh:84-90"
suggested_target: task
failure_class: bug
created: 2026-06-05
updated: 2026-06-05
source_task: ".specanchor/tasks/_cross-module/2026-06-05_dar-dogfood-runtime-hardening.spec.md"
---

# Finding: Retry path should preserve invalid output and reuse send driver

## Observation

`retry_review_comments.sh` removes the invalid review-comments file before proving the retry can be sent and completed. It does call `assert_pane_owned.sh`, but it bypasses the driver abstraction used by `send_review.sh` and directly calls `herdr pane send-text` and `herdr pane send-keys`.

## Why It Matters

If the pane is unavailable, status reporting is degraded, or the driver is not herdr, retry can fail while also deleting the artifact needed to diagnose the original validation failure. This makes the operator see a tool/runtime error instead of an actionable "pane not available for retry" failure.

## Evidence

- `scripts/retry_review_comments.sh` line 33 deletes the output path before pane assertion and send.
- `scripts/retry_review_comments.sh` lines 47-50 send directly through herdr and then wait.
- `scripts/send_review.sh` lines 84-90 uses the selected terminal driver and dismiss helper.

## Implications

Retry should be treated as the same terminal-driver operation as first send, with stricter preconditions because it consumes the only retry budget.

## Proposed Action

Move the invalid file to `vN.review-comments.invalid.yaml` before retry instead of deleting it. Assert pane ownership and acceptable status before sending. Use the same driver-send path as `send_review.sh`. If the pane is gone, unknown, or busy, exit with an explicit `ABORT: Codex pane not available for retry` message and keep the invalid artifact for diagnosis.
