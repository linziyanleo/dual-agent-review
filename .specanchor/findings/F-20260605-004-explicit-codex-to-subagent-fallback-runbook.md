---
id: F-20260605-004
summary: "DAR documents no explicit resume path from failed codex mode to user-approved subagent mode"
type: pattern
status: candidate
confidence: medium
impact: medium
visibility: handoff
affects:
  - path: "SKILL.md"
  - path: "README.md"
  - path: "pitfalls.md"
evidence_ref:
  - type: file-snapshot
    ref: "SKILL.md:14-22"
  - type: file-snapshot
    ref: "SKILL.md:252-266"
  - type: file-snapshot
    ref: "pitfalls.md:58-65"
suggested_target: task
failure_class: spec_gap
created: 2026-06-05
updated: 2026-06-05
source_task: ".specanchor/tasks/_cross-module/2026-06-05_dar-dogfood-runtime-hardening.spec.md"
---

# Finding: DAR needs an explicit codex-to-subagent fallback runbook

## Observation

The skill correctly forbids implicit fallback from codex mode to subagent mode, because that changes the independence contract. The dogfood failure shows that the operator path after repeated Codex failure is still underspecified: the user must be asked to choose, but the docs do not provide a concrete resume procedure from the latest `vN.md`, `vN.diff`, and dispositions.

## Why It Matters

Without a documented and scriptable fallback path, operators must improvise after Codex pane failures. That increases the chance of losing the current round, rerunning the wrong review inputs, or treating a still-running Codex pane as failed.

## Evidence

- `SKILL.md` defines codex and subagent modes and forbids implicit fallback.
- `pitfalls.md` documents troubleshooting commands, but not a standard "resume this review in subagent mode" flow.
- The dogfood summary reports that the eventual fallback decision was mediated manually after uncertainty about whether Codex was still running.

## Implications

The no-implicit-fallback contract should stay, but it needs a user-approved operational path that is repeatable and auditable.

## Proposed Action

Document a standard failure branch: capture diagnostics, report exact failed round and expected output path, offer explicit choices, and if the user chooses subagent mode, resume from the latest plan/diff/dispositions without rewriting prior artifacts. Consider adding a small helper that renders the subagent prompt for the current round after `REVIEW_MODE=subagent` is explicitly selected.
