---
id: F-20260605-001
summary: "wait_codex_done status=unknown/done lacks enough liveness diagnostics for dogfood failures"
type: risk
status: candidate
confidence: high
impact: high
visibility: handoff
affects:
  - path: "scripts/wait_codex_done.sh"
  - path: "scripts/dismiss_codex_plan_prompt.sh"
  - path: "SKILL.md"
evidence_ref:
  - type: file-snapshot
    ref: "scripts/wait_codex_done.sh:49-88"
  - type: file-snapshot
    ref: "scripts/dismiss_codex_plan_prompt.sh:61-70"
  - type: file-snapshot
    ref: ".specanchor/findings/F-20260530-001-wait-codex-done-file-contract.md"
suggested_target: task
failure_class: bug
created: 2026-06-05
updated: 2026-06-05
source_task: ".specanchor/tasks/_cross-module/2026-06-05_dar-dogfood-runtime-hardening.spec.md"
---

# Finding: DAR wait path needs liveness diagnostics

## Observation

`wait_codex_done.sh` correctly treats a non-empty output file as the only success signal and treats `agent_status=done` as only a hint. The dogfood failure shows the remaining gap: when Codex reaches `done` without writing a file, or when `codex_agent_status()` returns `unknown`, the failure message does not preserve enough live pane evidence to distinguish a dead pane, an unconsumed prompt, a still-running Codex process with degraded status, a wrong output path, or a model turn that ended without writing the YAML.

`dismiss_codex_plan_prompt.sh` also prints `codex_not_working` after retries but does not explicitly exit non-zero, so `send_review.sh` can continue after a prompt was sent but Codex did not begin consuming it.

## Why It Matters

The review loop can mislead the operator into respawning or retrying while the original Codex pane is still active, or can surface an ambiguous timeout instead of the actual terminal/runtime state. This burns the single retry budget and makes dogfooding failures harder to reproduce.

## Evidence

- `scripts/wait_codex_done.sh` lines 49-88 implement file-first success and final `ABORT`, but only report status/cwd/expected path at failure.
- `scripts/dismiss_codex_plan_prompt.sh` lines 61-70 report `codex_not_working` without an explicit failure exit.
- Prior finding `F-20260530-001` already established `agent_status=done` does not prove the review artifact exists.

## Implications

The wait path should become a small state classifier: `file_ready`, `no_output_after_done`, `pane_unavailable`, `status_unknown_with_pane_readable`, and `working_past_soft_timeout`. Only `file_ready` should be success; the other states should capture diagnostics before aborting or continuing.

## Proposed Action

Patch the wait/send path so failures write a diagnostic bundle into the session directory: `herdr pane get`, `herdr pane read --source visible`, `herdr pane read --source recent`, and a session file listing. Make `dismiss_codex_plan_prompt.sh` fail when Codex is still not working/done after retries. Keep file-first success intact.
