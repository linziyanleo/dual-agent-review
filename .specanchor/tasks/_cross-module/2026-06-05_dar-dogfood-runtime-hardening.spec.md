---
specanchor:
  level: task
  task_name: "DAR dogfooding runtime hardening"
  author: "方壶"
  created: "2026-06-05"
  status: "draft"
  last_change: "All fix steps implemented and sanity-tested"
  related_modules: []
  related_global:
    - ".specanchor/global/architecture.spec.md"
    - ".specanchor/global/coding-standards.spec.md"
    - ".specanchor/global/project-setup.spec.md"
  writing_protocol: "bug-fix"
  bugfix_phase: "VERIFYING"
  branch: "main"
---

# Bug Fix: DAR dogfooding runtime hardening

## 0. Bug Report

- **报告来源**: `/dual-agent-review` dogfooding summary on 2026-06-05.
- **严重程度**: High for review-loop reliability; Medium for YAML/retry/fallback polish.
- **影响范围**: Codex-backed DAR review loops, especially incremental vN review, schema retry, and operator recovery when the Codex pane reports `done` or `unknown` without producing `vN.review-comments.yaml`.

## 1. Reproduce

- **复现步骤**:
  1. Run a codex-mode DAR session through at least one successful review round.
  2. Send an incremental vN review prompt that requires Codex to write `vN.review-comments.yaml`.
  3. Observe one of these failure states: Codex reaches `done` without the YAML file, Codex status becomes `unknown`, or Codex writes YAML containing an unquoted colon-space scalar such as `location: re: F-1 from v1`.
  4. Run `validate_review_comments.py` on the output → YAML parse error (e.g. `mapping values are not allowed here` for unquoted colon-space). Then run `retry_review_comments.sh` → it deletes the invalid file, attempts retry, but may fail if pane is unavailable (artifact already gone).
- **环境**: herdr-backed codex mode in this repository; exact failed 2026-06-05 session artifacts were not available in `.specanchor/tasks`.
- **预期行为**: The workflow classifies the failure, preserves diagnostic evidence, gives one precise retry when appropriate, and never reports success before the expected YAML exists.
- **实际行为**: The operator sees ambiguous timeout/status failures, generic YAML parse errors, and a retry path that can delete invalid output before proving the retry path is available.
- **复现率**: Intermittent for runtime status failures; deterministic for unquoted YAML values containing `: `.

## 2. Diagnose

### 2.1 诊断策略

- Inspect current script contracts instead of trusting failure prose:
  - `scripts/wait_codex_done.sh` - completion and timeout semantics.
  - `scripts/dismiss_codex_plan_prompt.sh` - whether send actually starts Codex work.
  - `scripts/retry_review_comments.sh` - retry preconditions and artifact preservation.
  - `prompts/base-review-v1.md`, `prompts/base-review-vn.md`, `prompts/review-comments-retry.md` - YAML contract.
  - `scripts/validate_review_comments.py` - parse error reporting.

### 2.2 诊断代码

- No diagnostic code has been added yet.

### 2.3 User-reported Output

```text
wait_codex_done.sh timeout after 600s:
ABORT: Codex stopped without producing output (... status=done)

Second spawned attempt:
status=unknown

validate_review_comments.py:
YAML parse error ... mapping values are not allowed here

retry_review_comments.sh:
Tool result missing due to internal error
```

### 2.4 Evidence Analysis

- `wait_codex_done.sh` is already file-first and has `--total-timeout`; the failure is not a simple missing timeout option.
- `dismiss_codex_plan_prompt.sh` can end with `codex_not_working` without hard-failing.
- `retry_review_comments.sh` deletes the invalid output before retry and bypasses the terminal driver abstraction.
- PyYAML deterministically rejects `location: re: F-1...`; quoted strings parse correctly.

## 3. Root Cause

- **Root cause 1**: DAR wait/send has file-first success but not enough failure-state classification or diagnostics for `done without file`, `unknown`, and `prompt sent but not consumed`.
- **Root cause 2**: Review prompts and retry prompt specify schema fields but omit a YAML lexical contract for scalar quoting.
- **Root cause 3**: Retry consumes the only retry budget through a less robust path than the initial send path and can remove the invalid artifact before retry viability is known.
- **Root cause 4**: The skill forbids implicit codex-to-subagent fallback, correctly, but lacks a documented user-approved resume branch.

## 4. Fix Plan

### 4.1 Fix Checklist

- [x] 1. Add failure-state diagnostics to `wait_codex_done.sh` without weakening file-first success.
- [x] 2. Make `dismiss_codex_plan_prompt.sh` return non-zero when Codex never reaches `working` or `done` after retries.
- [x] 3. Preserve invalid YAML before retry and make retry reuse the same terminal driver send path as first-send.
- [x] 4. Add precise scalar quoting requirements to v1/vN review prompts and retry prompt.
- [x] 5. Improve validator parse-error diagnostics for common unquoted colon-space scalar failures.
- [x] 6. Document the explicit codex failure branch and user-approved subagent resume path.
- [x] 7. Add focused sanity tests with fake herdr and YAML fixtures.

### 4.2 File Changes

| File | Change |
|------|--------|
| `scripts/wait_codex_done.sh` | Keep output-file success as authority; add classified failure diagnostics and status-unknown handling. |
| `scripts/dismiss_codex_plan_prompt.sh` | Fail when Codex remains not working/done after retries. |
| `scripts/retry_review_comments.sh` | Preserve invalid output (mv to `.invalid.yaml`), assert retry viability before send, and use the terminal driver abstraction via `driver_send` (the existing `driver_send` interface already accepts pane + prompt — no driver-side changes needed). |
| `prompts/base-review-v1.md` | Add explicit YAML scalar quoting contract. |
| `prompts/base-review-vn.md` | Add explicit YAML scalar quoting contract for incremental rounds. |
| `prompts/review-comments-retry.md` | Tell Codex exactly how to fix unquoted colon-space scalar parse failures. |
| `scripts/validate_review_comments.py` | Add targeted parse-error hints without auto-fixing invalid YAML. |
| `SKILL.md` / `README.md` / `pitfalls.md` | Document explicit codex failure handling and user-approved subagent fallback/resume. |
| `scripts/sanity_tests.sh` | Add regression cases for diagnostics, retry preservation, prompt quoting, and fallback docs. |

### 4.3 Risk Assessment

- **回归风险**: Medium. These scripts are core DAR runtime paths.
- **影响的其他功能**: Existing codex-mode review loop; subagent mode docs only unless a helper is added.
- **需要额外测试的场景**:
  - Output file exists before `done` status.
  - `done` with no output file captures diagnostics and fails.
  - `unknown` with pane still readable captures diagnostics and does not pretend success.
  - `dismiss_codex_plan_prompt.sh` failure stops `send_review.sh`.
  - Retry preserves `vN.review-comments.invalid.yaml`.
  - Retry sends through the configured driver.
  - YAML value with `location: "re: F-1 from v1"` validates; unquoted `location: re: F-1 from v1` produces an actionable hint.

## 5. Fix Log

- [x] Step 1: Implement wait/send diagnostics.
- [x] Step 2: Implement retry hardening.
- [x] Step 3: Implement prompt/validator YAML improvements.
- [x] Step 4: Document explicit fallback/resume path.
- [x] Step 5: Run sanity tests and targeted validators.

## 6. Verify

- [ ] Bug has been fixed against the reproduction states in §1.
- [x] `./scripts/sanity_tests.sh` passes. (72 passed, 0 failed)
- [x] Targeted YAML parse fixture proves the retry prompt/validator hint covers colon-space values.
- [x] No regression to file-first completion: status-only completion never exits success.
- [ ] Diagnostic artifacts are written under the active session root on failure. (needs live herdr dogfood)
- [ ] Module Spec needs update: No module specs currently cover these files.
- **Follow-ups**: Consider sedimenting the file-first success and explicit fallback contracts into a global or module spec after this hardening is implemented and dogfooded.

## Related Findings

- `.specanchor/findings/F-20260605-001-dar-wait-liveness-diagnostics.md`
- `.specanchor/findings/F-20260605-002-review-yaml-scalar-quoting-contract.md`
- `.specanchor/findings/F-20260605-003-retry-path-preserve-invalid-output-and-driver.md`
- `.specanchor/findings/F-20260605-004-explicit-codex-to-subagent-fallback-runbook.md`
