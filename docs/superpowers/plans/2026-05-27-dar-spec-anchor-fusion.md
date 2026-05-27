# DAR × spec-anchor Fusion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hard-integrate dual-agent-review with spec-anchor: rename findings→review_comments, boot spec-context before review, auto-produce Task Spec + sediment Findings after convergence.

**Architecture:** Thin wrappers on both ends of the existing 9-step review loop. Startup adds preflight checks + prereview_boot; review loop gets terminology rename + spec-context injection via render_template.py file-injection; post-convergence adds SKILL.md instruction segments for Task Spec + sediment. Middle steps unchanged.

**Tech Stack:** Bash, Python 3 (PyYAML), herdr CLI, spec-anchor skill scripts

---

## File Structure

### New files
| Path | Responsibility |
|------|---------------|
| `scripts/prereview_boot.sh` | Source SA_SKILL_DIR from session.env, invoke specanchor-boot.sh, write spec-context.md |

### Renamed files
| Old | New |
|-----|-----|
| `scripts/validate_findings.py` | `scripts/validate_review_comments.py` |
| `scripts/retry_findings.sh` | `scripts/retry_review_comments.sh` |
| `prompts/findings-retry.md` | `prompts/review-comments-retry.md` |

### Modified files (grouped by change type)
| File | Change |
|------|--------|
| `scripts/preflight.sh` | Add 5 spec-anchor hard checks + 1 soft warning |
| `scripts/init_session.sh` | Remove fallback branch, fix SESSIONS_ROOT to `.specanchor/tasks`, add `agent_review_` prefix, write SA_SKILL_DIR to session.env |
| `scripts/cleanup_stale_panes.sh` | Remove dual-root scan, only scan `.specanchor/tasks/agent_review_*/` |
| `scripts/render_template.py` | Add `_FILE` suffix file-injection + 200-line budget + unresolved-token assertion |
| `scripts/send_review.sh` | Rename `.findings.yaml` → `.review-comments.yaml`, pass `SPEC_CONTEXT_FILE` |
| `scripts/check_convergence.py` | Rename file glob `.findings.yaml` → `.review-comments.yaml` |
| `scripts/validate_dispositions.py` | Rename `total_findings` → `total_review_comments`, update validator reference |
| `scripts/append_rejected_section.py` | Rename file glob + key `findings` → `review_comments` |
| `scripts/sanity_tests.sh` | Rewrite all tests for new names + add new test sections |
| `prompts/codex-review-v1.md` | Rename yaml key + add `{{SPEC_CONTEXT}}` block |
| `prompts/codex-review-vn.md` | Rename yaml key + add `{{SPEC_CONTEXT}}` block |
| `prompts/disposition.md` | Rename `total_findings` → `total_review_comments` |
| `SKILL.md` | Full rewrite: SA_SKILL_DIR preamble, new steps 0.4/11.5/11.6, link-not-copy |
| `README.md` | Rewrite for hard spec-anchor dependency |
| `pitfalls.md` | Remove fallback section, add specanchor_init troubleshooting |
| `prompts/plan-v1-template.md` | Add Task Spec link head-note |

---

## Task 1: Rename `validate_findings.py` → `validate_review_comments.py` with internal literal changes

**Files:**
- Rename: `scripts/validate_findings.py` → `scripts/validate_review_comments.py`
- Test: `scripts/sanity_tests.sh` (will update in Task 12)

- [ ] **Step 1: Git-move the file**

```bash
git mv scripts/validate_findings.py scripts/validate_review_comments.py
```

- [ ] **Step 2: Rename internal error messages from "findings" to "review_comments"**

In `scripts/validate_review_comments.py`, the validator references `findings` in user-facing messages and as a yaml key lookup. Change the yaml key lookup from `"findings"` to `"review_comments"` and update error messages:

```python
# Line 64-65: change key lookup
findings = doc.get("review_comments")
if not isinstance(findings, list):
    return fail(f"{path}: review_comments must be a list (got {type(findings).__name__})")
```

```python
# Line 69-70: change error prefix
for i, f in enumerate(findings):
    loc = f"review_comments[{i}]"
```

```python
# Line 90-94: update approve cross-check message
if verdict == "approve" and findings:
    return fail(
        f"{path}: overall_verdict='approve' requires review_comments: [] (per review prompt); got {len(findings)} review comment(s): "
        f"{[f['finding_id'] for f in findings]}"
    )
```

The `REQUIRED_FINDING_KEYS` tuple and `finding_id` field name stay unchanged (IDs are identifiers, not concept names).

- [ ] **Step 3: Verify the file is executable**

```bash
chmod +x scripts/validate_review_comments.py
ls -la scripts/validate_review_comments.py | grep -q '^-rwx'
```

- [ ] **Step 4: Quick smoke test with a valid input**

```bash
cat > /tmp/dar-test-rc.yaml <<'YAML'
overall_verdict: request_changes
summary: test
review_comments:
  - {finding_id: F-1, severity: high, category: correctness, location: x, description: d, suggested_change: c, rationale: r}
YAML
python3 scripts/validate_review_comments.py /tmp/dar-test-rc.yaml && echo "PASS" || echo "FAIL"
rm /tmp/dar-test-rc.yaml
```

Expected: PASS (exit 0, no output)

- [ ] **Step 5: Commit**

```bash
git add scripts/validate_review_comments.py
git commit -m "refactor: rename validate_findings.py -> validate_review_comments.py

Internal yaml key lookup changed from 'findings' to 'review_comments'.
Error messages updated accordingly. finding_id field unchanged."
```

---

## Task 2: Rename `retry_findings.sh` → `retry_review_comments.sh` with internal updates

**Files:**
- Rename: `scripts/retry_findings.sh` → `scripts/retry_review_comments.sh`

- [ ] **Step 1: Git-move the file**

```bash
git mv scripts/retry_findings.sh scripts/retry_review_comments.sh
```

- [ ] **Step 2: Update the internal script to reference the new validator name and file names**

In `scripts/retry_review_comments.sh`:

Line 30 — change output file name pattern:
```bash
OUTPUT_PATH="$SESSION_ROOT/v${ROUND}.review-comments.yaml"
```

Line 53 — change validator invocation:
```bash
if ! "$SCRIPT_DIR/validate_review_comments.py" "$OUTPUT_PATH"; then
```

- [ ] **Step 3: Verify executable**

```bash
chmod +x scripts/retry_review_comments.sh
```

- [ ] **Step 4: Commit**

```bash
git add scripts/retry_review_comments.sh
git commit -m "refactor: rename retry_findings.sh -> retry_review_comments.sh

References updated to validate_review_comments.py and v*.review-comments.yaml."
```

---

## Task 3: Rename `prompts/findings-retry.md` → `prompts/review-comments-retry.md`

**Files:**
- Rename: `prompts/findings-retry.md` → `prompts/review-comments-retry.md`

- [ ] **Step 1: Git-move the file**

```bash
git mv prompts/findings-retry.md prompts/review-comments-retry.md
```

- [ ] **Step 2: No content changes needed**

The template uses `{{OUTPUT_PATH}}` and `{{SCHEMA_ERROR}}` placeholders — the actual file name is injected at runtime. No literal "findings" text needs changing.

- [ ] **Step 3: Commit**

```bash
git add prompts/review-comments-retry.md
git commit -m "refactor: rename findings-retry.md -> review-comments-retry.md"
```

---

## Task 4: Update `validate_dispositions.py` — rename `total_findings` → `total_review_comments` + validator reference

**Files:**
- Modify: `scripts/validate_dispositions.py`

- [ ] **Step 1: Update the validator path reference (line 51-52)**

```python
validator = Path(__file__).with_name("validate_review_comments.py")
```

- [ ] **Step 2: Change the `total_findings` field lookup (line 99-102)**

```python
# Check 6: total_review_comments.
declared_total = dispositions_doc.get("total_review_comments")
if declared_total != len(dispositions):
    return fail(
        f"{dispositions_path}: total_review_comments={declared_total} but actual={len(dispositions)}"
    )
```

- [ ] **Step 3: Quick smoke test**

```bash
cat > /tmp/dar-f.yaml <<'YAML'
overall_verdict: request_changes
summary: x
review_comments:
  - {finding_id: F-1, severity: high, category: correctness, location: x, description: d, suggested_change: c, rationale: r}
YAML
cat > /tmp/dar-d.yaml <<'YAML'
plan_version_reviewed: v1
total_review_comments: 1
dispositions:
  - {finding_id: F-1, disposition: incorporated, plan_change_summary: done}
YAML
python3 scripts/validate_dispositions.py /tmp/dar-f.yaml /tmp/dar-d.yaml && echo "PASS" || echo "FAIL"
rm /tmp/dar-f.yaml /tmp/dar-d.yaml
```

Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add scripts/validate_dispositions.py
git commit -m "refactor: validate_dispositions uses total_review_comments + new validator name"
```

---

## Task 5: Update `check_convergence.py` — rename file glob

**Files:**
- Modify: `scripts/check_convergence.py`

- [ ] **Step 1: Change the findings file lookup pattern (line 80)**

```python
current = load_findings(session_root / f"v{n}.review-comments.yaml")
```

- [ ] **Step 2: Change the previous round lookup (line 106)**

```python
prev = load_findings(session_root / f"v{n - 1}.review-comments.yaml")
```

- [ ] **Step 3: Update the `load_findings` function docstring/error and key lookup**

In `load_findings`, change the internal key from `"findings"` to `"review_comments"`:

```python
def load_findings(path: Path) -> dict:
    if not path.is_file():
        raise FileNotFoundError(f"review-comments file not found: {path}")
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as e:
        raise ValueError(f"YAML parse error in {path}: {e}") from e
    if not isinstance(data, dict):
        raise ValueError(f"top-level of {path} must be a mapping")
    return data
```

In `no_blocker`, change the key:
```python
def no_blocker(findings_doc: dict) -> bool:
    if findings_doc.get("overall_verdict") == "block":
        return False
    findings = findings_doc.get("review_comments", [])
    if not isinstance(findings, list):
        raise ValueError("review_comments must be a list")
    for f in findings:
        if not isinstance(f, dict):
            raise ValueError("each review_comment must be a mapping")
        sev = f.get("severity")
        if sev in BLOCKER_SEVERITIES:
            return False
    return True
```

In `main`, update the workflow gate key:
```python
current_findings = current.get("review_comments") or []
```

- [ ] **Step 4: Quick smoke test**

```bash
mkdir -p /tmp/dar-conv
cat > /tmp/dar-conv/v1.review-comments.yaml <<'YAML'
overall_verdict: approve
summary: ok
review_comments: []
YAML
python3 scripts/check_convergence.py /tmp/dar-conv 1
rm -rf /tmp/dar-conv
```

Expected output: `CONVERGED_APPROVE`

- [ ] **Step 5: Commit**

```bash
git add scripts/check_convergence.py
git commit -m "refactor: check_convergence uses v*.review-comments.yaml + review_comments key"
```

---

## Task 6: Update `append_rejected_section.py` — rename file glob + yaml key

**Files:**
- Modify: `scripts/append_rejected_section.py`

- [ ] **Step 1: Change the file glob in `main` (line 181-183)**

```python
dispo_files = sorted(
    session_root.glob("v*.dispositions.yaml"),
    key=lambda p: version_key(p.name),
)
```

This glob doesn't change (dispositions files keep their name). But the *findings lookup* inside `collect_groups` does.

- [ ] **Step 2: Change the findings file lookup in `collect_groups` (line 58)**

```python
fpath = session_root / f"{version}.review-comments.yaml"
```

- [ ] **Step 3: Change the findings key lookup (line 62)**

```python
for f in (fdoc.get("review_comments") if isinstance(fdoc, dict) else []) or []:
```

- [ ] **Step 4: Quick smoke test**

```bash
mkdir -p /tmp/dar-ars
cat > /tmp/dar-ars/v1.review-comments.yaml <<'YAML'
overall_verdict: request_changes
summary: x
review_comments:
  - {finding_id: F-1, severity: low, category: scope, location: x, description: "test desc", suggested_change: c, rationale: r}
YAML
cat > /tmp/dar-ars/v1.dispositions.yaml <<'YAML'
plan_version_reviewed: v1
total_review_comments: 1
dispositions:
  - {finding_id: F-1, disposition: rejected, reason: "out of scope"}
YAML
printf '# Plan\n\n## Context\nstub\n' > /tmp/dar-ars/plan.md
python3 scripts/append_rejected_section.py /tmp/dar-ars /tmp/dar-ars/plan.md
grep -q "F-1" /tmp/dar-ars/plan.md && echo "PASS" || echo "FAIL"
rm -rf /tmp/dar-ars
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/append_rejected_section.py
git commit -m "refactor: append_rejected_section reads v*.review-comments.yaml + review_comments key"
```

---

## Task 7: Update `send_review.sh` — rename output file pattern + add SPEC_CONTEXT_FILE

**Files:**
- Modify: `scripts/send_review.sh`

- [ ] **Step 1: Change OUTPUT_PATH file name (line 29)**

```bash
OUTPUT_PATH="$SESSION_ROOT/v${ROUND}.review-comments.yaml"
```

- [ ] **Step 2: Add SPEC_CONTEXT_FILE to the round-1 render call (after line 34)**

```bash
if [ "$ROUND" -eq 1 ]; then
  TEMPLATE="$SKILL_DIR/prompts/codex-review-v1.md"
  PROMPT="$("$SCRIPT_DIR/render_template.py" "$TEMPLATE" \
    "PLAN_PATH=$PLAN_PATH" \
    "OUTPUT_PATH=$OUTPUT_PATH" \
    "SPEC_CONTEXT_FILE=$SESSION_ROOT/spec-context.md")"
else
  TEMPLATE="$SKILL_DIR/prompts/codex-review-vn.md"
  PREV="$((ROUND - 1))"
  PREV_DISPO="$SESSION_ROOT/v${PREV}.dispositions.yaml"
  DIFF_PATH="$SESSION_ROOT/v${ROUND}.diff"
  [ -f "$PREV_DISPO" ] || fail "missing prev dispositions: $PREV_DISPO"
  [ -f "$DIFF_PATH"  ] || fail "missing diff: $DIFF_PATH"
  PROMPT="$("$SCRIPT_DIR/render_template.py" "$TEMPLATE" \
    "PLAN_PATH=$PLAN_PATH" \
    "PREV_DISPOSITION=$PREV_DISPO" \
    "DIFF_PATH=$DIFF_PATH" \
    "OUTPUT_PATH=$OUTPUT_PATH" \
    "SPEC_CONTEXT_FILE=$SESSION_ROOT/spec-context.md")"
fi
```

- [ ] **Step 3: Update the retry template reference in `retry_review_comments.sh`**

In `scripts/retry_review_comments.sh`, line 40:
```bash
TEMPLATE="$SKILL_DIR/prompts/review-comments-retry.md"
```

- [ ] **Step 4: Commit**

```bash
git add scripts/send_review.sh scripts/retry_review_comments.sh
git commit -m "feat: send_review outputs to v*.review-comments.yaml, passes SPEC_CONTEXT_FILE"
```

---

## Task 8: Extend `render_template.py` with `_FILE` suffix file-injection + budget + assertion

**Files:**
- Modify: `scripts/render_template.py`

- [ ] **Step 1: Rewrite render_template.py with file-injection support**

```python
#!/usr/bin/env python3
"""Render a prompt template by replacing {{KEY}} placeholders.

Usage: render_template.py <template_path> KEY=value [KEY=value ...]

Keys ending in _FILE trigger file-injection: the suffix is stripped to derive
the placeholder name (e.g. SPEC_CONTEXT_FILE -> {{SPEC_CONTEXT}}), the file at
<value> is read and its content replaces the placeholder. Budget: first N lines
(default 200, override with DAR_SPEC_CONTEXT_MAX_LINES env var for SPEC_CONTEXT).

After all replacements, asserts no unresolved {{SPEC_CONTEXT}} tokens remain.
"""
import os
import re
import sys
from pathlib import Path

MAX_LINES_DEFAULT = 200


def read_with_budget(file_path: Path, placeholder_name: str) -> str:
    """Read file content, truncating to budget if needed."""
    if not file_path.is_file():
        return ""
    lines = file_path.read_text(encoding="utf-8").splitlines(keepends=True)
    env_key = f"DAR_{placeholder_name}_MAX_LINES"
    max_lines = int(os.environ.get(env_key, MAX_LINES_DEFAULT))
    if len(lines) > max_lines:
        truncated = "".join(lines[:max_lines])
        truncated += f"\n... (truncated at {max_lines} lines)\n"
        return truncated
    return "".join(lines)


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: render_template.py <template> KEY=value ...", file=sys.stderr)
        return 2
    template_path = Path(sys.argv[1])
    if not template_path.is_file():
        print(f"ABORT: template not found: {template_path}", file=sys.stderr)
        return 1

    pairs: list[tuple[str, str]] = []
    file_pairs: list[tuple[str, str]] = []

    for raw in sys.argv[2:]:
        if "=" not in raw:
            print(f"ABORT: arg {raw!r} is not KEY=value", file=sys.stderr)
            return 2
        k, v = raw.split("=", 1)
        if not k:
            print(f"ABORT: empty key in {raw!r}", file=sys.stderr)
            return 2
        if k.endswith("_FILE"):
            placeholder = k[: -len("_FILE")]
            file_pairs.append((placeholder, v))
        else:
            pairs.append((k, v))

    text = template_path.read_text(encoding="utf-8")

    for placeholder, file_path_str in file_pairs:
        content = read_with_budget(Path(file_path_str), placeholder)
        text = text.replace("{{" + placeholder + "}}", content)

    for k, v in pairs:
        text = text.replace("{{" + k + "}}", v)

    if "{{SPEC_CONTEXT}}" in text:
        print("ABORT: unresolved {{SPEC_CONTEXT}} token in rendered output", file=sys.stderr)
        return 1

    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Verify the basic rendering still works**

```bash
printf 'A={{A}} B={{B}}\n' > /tmp/dar-tpl.txt
python3 scripts/render_template.py /tmp/dar-tpl.txt 'A=hello' 'B=world'
rm /tmp/dar-tpl.txt
```

Expected: `A=hello B=world`

- [ ] **Step 3: Test file injection**

```bash
printf 'line1\nline2\nline3\n' > /tmp/dar-ctx.txt
printf 'Before\n{{SPEC_CONTEXT}}\nAfter\n' > /tmp/dar-tpl2.txt
python3 scripts/render_template.py /tmp/dar-tpl2.txt "SPEC_CONTEXT_FILE=/tmp/dar-ctx.txt"
rm /tmp/dar-ctx.txt /tmp/dar-tpl2.txt
```

Expected:
```
Before
line1
line2
line3

After
```

- [ ] **Step 4: Test budget truncation**

```bash
python3 -c "
for i in range(500):
    print(f'line {i+1}')
" > /tmp/dar-big.txt
printf '{{SPEC_CONTEXT}}\n' > /tmp/dar-tpl3.txt
python3 scripts/render_template.py /tmp/dar-tpl3.txt "SPEC_CONTEXT_FILE=/tmp/dar-big.txt" | tail -3
rm /tmp/dar-big.txt /tmp/dar-tpl3.txt
```

Expected last 3 lines should include `line 200` and `... (truncated at 200 lines)`

- [ ] **Step 5: Test unresolved assertion**

```bash
printf '{{SPEC_CONTEXT}}\n' > /tmp/dar-tpl4.txt
python3 scripts/render_template.py /tmp/dar-tpl4.txt 2>&1; echo "exit=$?"
rm /tmp/dar-tpl4.txt
```

Expected: stderr says "ABORT: unresolved {{SPEC_CONTEXT}}", exit=1

- [ ] **Step 6: Commit**

```bash
git add scripts/render_template.py
git commit -m "feat: render_template.py adds _FILE suffix injection + 200-line budget + assertion"
```

---

## Task 9: Update prompt templates — rename yaml key + add `{{SPEC_CONTEXT}}`

**Files:**
- Modify: `prompts/codex-review-v1.md`
- Modify: `prompts/codex-review-vn.md`
- Modify: `prompts/disposition.md`

- [ ] **Step 1: Update `prompts/codex-review-v1.md`**

Add a Spec Context section before the Task section. Change `findings:` yaml key to `review_comments:`. The full file should become:

```markdown
You are acting as an independent senior reviewer of a software plan.
Your job is to find what's wrong, missing, or risky — not to be polite.

## Spec Context (project norms and constraints)

{{SPEC_CONTEXT}}

## Task

1. Read the plan file at: `{{PLAN_PATH}}`
2. Produce a critical review. Cross-check the plan against the Spec Context above — flag deviations from established project norms.
3. Write your review as **strict YAML** to: `{{OUTPUT_PATH}}`

## Required output schema (YAML, no markdown fences, no commentary outside YAML)

```yaml
overall_verdict: approve | request_changes | block
summary: <2-3 sentence overall assessment>
review_comments:
  - finding_id: F-1
    severity: high | medium | low | nit
    category: correctness | security | performance | maintainability | scope | testing | unclear-requirements | other
    location: <which section/step of the plan, or "global">
    description: <what is wrong / missing / risky>
    suggested_change: <concrete actionable change, not just "consider X">
    rationale: <why this matters — 1 sentence>
  - finding_id: F-2
    ...
```

## Severity guidance

- **high**: plan will produce broken / insecure / wrong behavior if executed as-is
- **medium**: plan will work but has clear quality/maintainability/scope problems
- **low**: improvement worth doing but not blocking
- **nit**: style / wording / minor — use sparingly, this is not a syntax review

## Rules

- Be specific. "Add error handling" is not actionable. "Step 3 doesn't handle ENOSPC on the cache write — wrap in try/except and surface as a user-visible error" is actionable.
- Do NOT propose architectural rewrites unless the plan has a fundamental flaw. Scope your suggestions to within the plan's stated goals.
- Do NOT modify the plan file. Only write to `{{OUTPUT_PATH}}`.
- If the plan is fundamentally sound, set `overall_verdict: approve` and `review_comments: []` (empty list). Don't invent nits to fill space.
- If you genuinely have no concerns, that's a valid outcome. Say so.

After writing the file, output exactly one line to the terminal:
`REVIEW_COMPLETE: {{OUTPUT_PATH}}`

Then stop. Do not start any other work.
```

- [ ] **Step 2: Update `prompts/codex-review-vn.md`**

Add `{{SPEC_CONTEXT}}` section and rename `findings:` to `review_comments:`. Same pattern as v1 — add the Spec Context section at the top, rename yaml key in the schema example, change "findings: []" reference to "review_comments: []".

- [ ] **Step 3: Update `prompts/disposition.md`**

Change `total_findings` to `total_review_comments` in the schema example. Change the `{{FINDINGS_PATH}}` reference accordingly — the disposition template now references review-comments files:

Line 3: `For each review comment in \`{{FINDINGS_PATH}}\`, decide a disposition.`

Schema example:
```yaml
plan_version_reviewed: v1
total_review_comments: 5
dispositions:
  - finding_id: F-1
    disposition: incorporated | rejected | deferred
    ...
```

- [ ] **Step 4: Commit**

```bash
git add prompts/codex-review-v1.md prompts/codex-review-vn.md prompts/disposition.md
git commit -m "feat: prompt templates use review_comments key + inject {{SPEC_CONTEXT}}"
```

---

## Task 10: Rewrite `scripts/preflight.sh` — add 5 spec-anchor hard checks + soft warning

**Files:**
- Modify: `scripts/preflight.sh`

- [ ] **Step 1: Rewrite preflight.sh**

```bash
#!/usr/bin/env bash
# Hard preflight checks for dual-agent-review. Any failure → exit 1 + stderr diagnostic.
set -euo pipefail

fail() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

[ "${HERDR_ENV:-}" = "1" ]   || fail "not running inside herdr (HERDR_ENV != 1)"
[ -n "${HERDR_PANE_ID:-}" ]  || fail "HERDR_PANE_ID not injected; cannot locate Claude main pane"

command -v herdr   >/dev/null 2>&1 || fail "herdr CLI not on PATH"
command -v codex   >/dev/null 2>&1 || fail "codex CLI not on PATH"
command -v python3 >/dev/null 2>&1 || fail "python3 not on PATH"

python3 -c 'import yaml' >/dev/null 2>&1 || fail "PyYAML not importable (pip install pyyaml)"

# spec-anchor hard checks
SA_SKILL_DIR="${SA_SKILL_DIR:-}"
[ -n "$SA_SKILL_DIR" ] || fail "SA_SKILL_DIR not set"
[ -f "$SA_SKILL_DIR/SKILL.md" ] || fail "spec-anchor SKILL.md not found at $SA_SKILL_DIR/SKILL.md"
[ -f "$SA_SKILL_DIR/scripts/specanchor-boot.sh" ] || fail "specanchor-boot.sh not found at $SA_SKILL_DIR/scripts/specanchor-boot.sh"
[ -f "$(pwd)/anchor.yaml" ] || fail "anchor.yaml not found in $(pwd)"
[ -d "$(pwd)/.specanchor" ] || fail ".specanchor/ directory not found in $(pwd)"

# Verify paths.task_specs is default or absent
TASK_SPECS_CHECK="$(python3 -c '
import yaml, sys
with open("anchor.yaml") as f:
    cfg = yaml.safe_load(f) or {}
paths = cfg.get("paths", {}) or {}
val = paths.get("task_specs", ".specanchor/tasks")
normalized = val.rstrip("/")
if normalized != ".specanchor/tasks":
    print(f"NON_DEFAULT:{val}")
    sys.exit(0)
print("OK")
' 2>&1)" || fail "failed to parse anchor.yaml"
case "$TASK_SPECS_CHECK" in
  NON_DEFAULT:*)
    fail "DAR requires default spec-anchor task layout (.specanchor/tasks/). Non-default paths.task_specs is unsupported: ${TASK_SPECS_CHECK#NON_DEFAULT:}"
    ;;
esac

# herdr integration status check — soft warn.
INTEG_STATUS="$(herdr integration status 2>&1 || true)"
printf '%s\n' "$INTEG_STATUS" | grep -q 'codex: current'  || warn "codex integration may be missing/stale; agent_status detection will degrade"
printf '%s\n' "$INTEG_STATUS" | grep -q 'claude: current' || warn "claude integration may be missing/stale"

# Legacy layout soft warning
[ ! -d "$(pwd)/.plan/sessions" ] || warn ".plan/sessions/ detected — legacy DAR layout; consider removing after migration"

printf 'preflight OK\n'
```

- [ ] **Step 2: Test it fails without SA_SKILL_DIR**

```bash
(unset SA_SKILL_DIR; HERDR_ENV=1 HERDR_PANE_ID=p_1 bash scripts/preflight.sh 2>&1) && echo "should fail" || echo "PASS: failed as expected"
```

- [ ] **Step 3: Commit**

```bash
git add scripts/preflight.sh
git commit -m "feat: preflight.sh adds 5 spec-anchor hard checks + legacy warning"
```

---

## Task 11: Rewrite `scripts/init_session.sh` — hard spec-anchor path + agent_review_ prefix + SA_SKILL_DIR in session.env

**Files:**
- Modify: `scripts/init_session.sh`

- [ ] **Step 1: Replace the SESSIONS_ROOT selection logic (lines 39-48)**

Remove the dual-condition gate. Replace with:

```bash
CWD="$(pwd)"

# Hard spec-anchor dependency: sessions live under .specanchor/tasks/
SESSIONS_ROOT="$CWD/.specanchor/tasks"
```

- [ ] **Step 2: Change SESSION_ID prefix from date-pane to agent_review_**

Replace line 35:
```bash
SESSION_ID="agent_review_$(date +%Y%m%d-%H%M%S)-pane-${SAFE_MAIN_PANE}-${RAND_SUFFIX}"
```

- [ ] **Step 3: Add SA_SKILL_DIR to session.env output (after CWD line)**

Add to the session.env printf block:
```bash
printf 'SA_SKILL_DIR=%s\n'  "$(shquote "${SA_SKILL_DIR:-}")"
```

And to session.meta:
```bash
printf 'SA_SKILL_DIR=%s\n'  "${SA_SKILL_DIR:-}"
```

- [ ] **Step 4: Verify script still has correct shebang and +x**

```bash
head -1 scripts/init_session.sh
ls -la scripts/init_session.sh | grep -q '^-rwx'
```

- [ ] **Step 5: Commit**

```bash
git add scripts/init_session.sh
git commit -m "feat: init_session uses .specanchor/tasks + agent_review_ prefix + SA_SKILL_DIR"
```

---

## Task 12: Create `scripts/prereview_boot.sh`

**Files:**
- Create: `scripts/prereview_boot.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Boot spec-anchor and write spec-context.md for injection into review prompts.
# Sources SA_SKILL_DIR from session.env, invokes specanchor-boot.sh --format=summary.
#
# Usage: prereview_boot.sh <session_root>
# Exit 0 on success (even if spec-context.md is empty — soft warn).
# Exit 1 if boot script itself fails (hard fail).
set -euo pipefail

fail() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

SESSION_ROOT="${1:-}"
[ -n "$SESSION_ROOT" ] || fail "missing arg 1: session_root"
[ -f "$SESSION_ROOT/session.env" ] || fail "session.env not found in $SESSION_ROOT"

# Source SA_SKILL_DIR from session.env
set -a
. "$SESSION_ROOT/session.env"
set +a

[ -n "${SA_SKILL_DIR:-}" ] || fail "SA_SKILL_DIR not found in session.env"

BOOT_SCRIPT="$SA_SKILL_DIR/scripts/specanchor-boot.sh"
[ -f "$BOOT_SCRIPT" ] || fail "specanchor-boot.sh not found: $BOOT_SCRIPT"

SPEC_CONTEXT="$SESSION_ROOT/spec-context.md"

SPECANCHOR_SKILL_DIR="$SA_SKILL_DIR" bash "$BOOT_SCRIPT" --format=summary > "$SPEC_CONTEXT"

if [ ! -s "$SPEC_CONTEXT" ]; then
  warn "spec-context.md is empty — review will proceed without Spec context"
fi

printf 'prereview_boot OK: %s\n' "$SPEC_CONTEXT"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/prereview_boot.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/prereview_boot.sh
git commit -m "feat: add prereview_boot.sh — boots spec-anchor and writes spec-context.md"
```

---

## Task 13: Rewrite `scripts/cleanup_stale_panes.sh` — single root scan

**Files:**
- Modify: `scripts/cleanup_stale_panes.sh`

- [ ] **Step 1: Remove the dual-root logic (lines 79-91)**

Replace the bottom section with single-root scan:

```bash
CURRENT_ROOT="$(dirname "$SESSION_ROOT")"
scan_root "$CURRENT_ROOT"
```

Remove the `OWN_META` / `OWN_CWD` / `LEGACY_ROOT` logic entirely.

- [ ] **Step 2: Update the scan pattern in `scan_root`**

Change the `find` command to only look for `agent_review_*` directories:

```bash
scan_root() {
  local root="$1"
  [ -d "$root" ] || return 0

  find "$root" -mindepth 2 -maxdepth 2 -name session.meta -path "*/agent_review_*/session.meta" -print 2>/dev/null | while IFS= read -r META; do
```

- [ ] **Step 3: Remove the file header comment about dual-root scanning**

Update the script header to reflect new behavior.

- [ ] **Step 4: Commit**

```bash
git add scripts/cleanup_stale_panes.sh
git commit -m "refactor: cleanup_stale_panes scans only .specanchor/tasks/agent_review_*"
```

---

## Task 14: Update `prompts/plan-v1-template.md` — add Task Spec link head-note

**Files:**
- Modify: `prompts/plan-v1-template.md`

- [ ] **Step 1: Add a head-note linking to spec-anchor Task Spec format**

```markdown
<!-- After convergence this plan becomes a formal Task Spec under .specanchor/tasks/.
     Format reference: ~/.claude/skills/spec-anchor/references/commands/task.md -->

# Plan v1: <一行标题>

## Context / Goals
<问题、约束、目标>

## Non-goals
<明确不做的事>

## Proposed approach
<具体方案，按步骤>

## Affected files
<列出会改的文件 / 模块>

## Risks & open questions
<已知风险、待定问题>

## Verification plan
<怎么验证方案落地后是对的>
```

- [ ] **Step 2: Commit**

```bash
git add prompts/plan-v1-template.md
git commit -m "docs: plan-v1-template adds Task Spec link head-note"
```

---

## Task 15: Rewrite `SKILL.md` — SA_SKILL_DIR preamble + new steps + link-not-copy

**Files:**
- Modify: `SKILL.md`

- [ ] **Step 1: Rewrite SKILL.md frontmatter and preamble section**

Update the frontmatter `description` to reflect hard spec-anchor dependency (remove fallback mention). Add the SA_SKILL_DIR export in the "前置：解析 SKILL_DIR + 全局开关" section:

```bash
export SKILL_DIR="$(dirname "$(realpath ~/.claude/skills/dual-agent-review/SKILL.md)")"
export SA_SKILL_DIR="$HOME/.claude/skills/spec-anchor"
set -euo pipefail
```

- [ ] **Step 2: Update Step 0 documentation**

Replace the `init_session.sh` documentation paragraph to reflect:
- No fallback; `SESSIONS_ROOT` fixed to `$(pwd)/.specanchor/tasks`
- Session directory prefix: `agent_review_`
- SA_SKILL_DIR written to session.env

- [ ] **Step 3: Add Step 0.4 — prereview boot**

After Step 0.5 (cleanup_stale_panes), add:

```markdown
## Step 0.4：Boot spec-anchor context

\```bash
"$SKILL_DIR/scripts/prereview_boot.sh" "$SESSION_ROOT"
\```

Invokes `specanchor-boot.sh --format=summary` (contract: `~/.claude/skills/spec-anchor/scripts/specanchor-boot.sh`) and writes `$SESSION_ROOT/spec-context.md`. If boot fails → hard fail. If empty → soft warn, review proceeds without Spec context.
```

- [ ] **Step 4: Update Steps 4, 5, 6, 9 — rename findings references**

Change all `findings` file references to `review-comments`:
- `v1.findings.yaml` → `v1.review-comments.yaml`
- `validate_findings.py` → `validate_review_comments.py`
- `retry_findings.sh` → `retry_review_comments.sh`

- [ ] **Step 5: Update Step 6 disposition documentation**

Change `total_findings` to `total_review_comments` in the schema reference.

- [ ] **Step 6: Add Step 11.5 — Task Spec 转写**

```markdown
## Step 11.5：Task Spec 转写（Claude 自动执行）

读 `~/.claude/skills/spec-anchor/references/commands/task.md` 协议。从 final.md 的 Goals + Affected files 提取 module + slug。创建 `.specanchor/tasks/<module>/YYYY-MM-DD_<slug>.spec.md`。路径写到 `$SESSION_ROOT/.task-spec-path`。失败 → 写 `.task-spec-error`，soft fail（不阻塞 final.md 报告）。
```

- [ ] **Step 7: Add Step 11.6 — sediment 提炼**

```markdown
## Step 11.6：sediment 提炼（Claude 自动执行）

读所有 `vN.dispositions.yaml`。按 `~/.claude/skills/spec-anchor/references/templates/finding-template.md`（参见 `~/.claude/skills/spec-anchor/references/concepts/findings-ledger.md` §3）格式创建 Finding：

- **主筛选**：`disposition=incorporated` 的 review comment，判断语义是否属于 `{fact, contradiction, stale-claim, risk, reuse-opportunity, pattern}` 之一
- **次筛选**：`disposition=rejected` 的 review comment，其 rejection reason 显式陈述了一个 spec-anchor-relevant 事实 → 提取为 Finding，`visibility=hidden`
- **不提取** `disposition=deferred` 的 review comment

`source_task` 填 `.task-spec-path` 内容。清单写 `$SESSION_ROOT/sediment.log`。失败 → 写 `.sediment-error`，soft fail。
```

- [ ] **Step 8: Commit**

```bash
git add SKILL.md
git commit -m "feat: SKILL.md adds SA_SKILL_DIR preamble, prereview boot, steps 11.5/11.6, link-not-copy"
```

---

## Task 16: Rewrite `README.md` — hard spec-anchor dependency documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the 安装 section**

Add spec-anchor as a hard dependency:
```markdown
依赖：
- herdr ≥ 0.6.2
- `codex` CLI ≥ 0.133.0
- herdr 集成：`herdr integration install claude && herdr integration install codex`
- **spec-anchor skill** 已安装到 `~/.claude/skills/spec-anchor/`（参见 spec-anchor SKILL.md）
- 项目已 `specanchor_init`（`anchor.yaml` + `.specanchor/` 存在）
- `paths.task_specs` 使用默认值 `.specanchor/tasks`
```

- [ ] **Step 2: Update Pane 管理 section**

Remove fallback documentation. Replace with:
```markdown
- `SESSIONS_ROOT` 固定为 `$(pwd)/.specanchor/tasks`，session 目录名前缀 `agent_review_`
```

- [ ] **Step 3: Update Skill internals table**

Rename all script references (validate_findings→validate_review_comments, retry_findings→retry_review_comments). Add `prereview_boot.sh` row.

- [ ] **Step 4: Update sanity tests section**

Update expected test count and test descriptions to match new tests.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: README reflects hard spec-anchor dependency and renamed scripts"
```

---

## Task 17: Rewrite `pitfalls.md` — remove fallback, add specanchor troubleshooting

**Files:**
- Modify: `pitfalls.md`

- [ ] **Step 1: Remove §配置 bullet about "spec-anchor 非默认布局" fallback**

Delete the bullet that explains DAR falls back to `.plan/sessions/`. Replace with a note about the hard requirement:

```markdown
- [ ] **spec-anchor 必须已 init** —— `anchor.yaml` + `.specanchor/` 必须存在，且 `paths.task_specs` 为默认值。否则 `preflight.sh` 直接 exit 1。修复：运行 `specanchor_init`（参见 `~/.claude/skills/spec-anchor/references/commands/init.md`）。
```

- [ ] **Step 2: Update §运行时 session root bullet**

Change from dual-root description to single root:
```markdown
- [ ] **每次 review 都用独立 `$SESSION_ROOT`** —— 形如 `.specanchor/tasks/agent_review_<session-id>/`。不要在 `.specanchor/` 下写全局文件。
```

- [ ] **Step 3: Update 排查路径 step 5**

```markdown
5. `find .specanchor/tasks/agent_review_* -maxdepth 1 -type f 2>/dev/null | sort` —— 看当前 session 写文件到哪一步
```

- [ ] **Step 4: Commit**

```bash
git add pitfalls.md
git commit -m "docs: pitfalls removes fallback, adds specanchor_init troubleshooting"
```

---

## Task 18: Rewrite `scripts/sanity_tests.sh` — comprehensive test suite for new behavior

**Files:**
- Modify: `scripts/sanity_tests.sh`

- [ ] **Step 1: Update existing validate_findings tests to use new file/key names**

In the "validate_findings.py" test section, rename to "validate_review_comments.py". Update all fixture yaml to use `review_comments:` key instead of `findings:`. Update the validator invocation path.

- [ ] **Step 2: Update validate_dispositions tests**

Change `total_findings` to `total_review_comments` in all fixture yaml. Update validator reference.

- [ ] **Step 3: Update check_convergence tests**

Change all fixture file names from `v*.findings.yaml` to `v*.review-comments.yaml`. Change yaml key from `findings:` to `review_comments:`.

- [ ] **Step 4: Update append_rejected_section tests**

Change all fixture file names from `v*.findings.yaml` to `v*.review-comments.yaml`. Change yaml key from `findings:` to `review_comments:`.

- [ ] **Step 5: Add render_template file-injection tests**

Add a new test section:
```bash
step "render_template.py — _FILE suffix injection + budget"

# Basic file injection
INJECT_TPL="$WORKDIR/inject_tpl.txt"
INJECT_FILE="$WORKDIR/inject_content.txt"
printf 'Before\n{{SPEC_CONTEXT}}\nAfter\n' > "$INJECT_TPL"
printf 'ctx line 1\nctx line 2\n' > "$INJECT_FILE"
OUT="$("$SCRIPT_DIR/render_template.py" "$INJECT_TPL" "SPEC_CONTEXT_FILE=$INJECT_FILE")"
case "$OUT" in *"ctx line 1"*"ctx line 2"*"After"*) pass "file injection replaces placeholder" ;;
                                                   *) die "file injection failed: $OUT" ;;
esac

# Budget truncation at 200 lines
BIG_FILE="$WORKDIR/big.txt"
python3 -c 'for i in range(500): print(f"line {i+1}")' > "$BIG_FILE"
printf '{{SPEC_CONTEXT}}\n' > "$INJECT_TPL"
OUT="$("$SCRIPT_DIR/render_template.py" "$INJECT_TPL" "SPEC_CONTEXT_FILE=$BIG_FILE")"
case "$OUT" in *"line 200"*"truncated at 200 lines"*) pass "budget truncation at 200 lines" ;;
                                                    *) die "budget truncation failed" ;;
esac
case "$OUT" in *"line 201"*) die "line 201 should not appear after truncation" ;; esac
pass "line 201 absent after truncation"

# Missing file -> empty replacement (no error)
printf '{{SPEC_CONTEXT}}\n' > "$INJECT_TPL"
OUT="$("$SCRIPT_DIR/render_template.py" "$INJECT_TPL" "SPEC_CONTEXT_FILE=/tmp/nonexistent_dar_file" 2>&1)"
[ $? -eq 0 ] || die "missing injection file should not error"
pass "missing injection file -> empty string (no error)"

# Unresolved {{SPEC_CONTEXT}} -> exit 1
printf '{{SPEC_CONTEXT}}\n' > "$INJECT_TPL"
"$SCRIPT_DIR/render_template.py" "$INJECT_TPL" 2>/dev/null && die "unresolved SPEC_CONTEXT should fail" || pass "unresolved {{SPEC_CONTEXT}} -> exit 1"
```

- [ ] **Step 6: Add preflight spec-anchor tests**

Add test section for new preflight checks (using a shimmed environment):
```bash
step "preflight.sh — spec-anchor hard checks"

# Missing SA_SKILL_DIR
(unset SA_SKILL_DIR; HERDR_ENV=1 HERDR_PANE_ID=p_1 PATH="$SHIM_DIR:$PATH" "$SCRIPT_DIR/preflight.sh" 2>&1) && die "missing SA_SKILL_DIR should fail" || pass "no SA_SKILL_DIR -> fail"

# Missing anchor.yaml (run from a temp dir without it)
...
```

- [ ] **Step 7: Update init_session tests for new path + prefix**

Replace the A1/A2/A3 test cases with a single case that verifies:
- SESSIONS_ROOT = `$(pwd)/.specanchor/tasks`
- Session directory starts with `agent_review_`
- session.env contains SA_SKILL_DIR

- [ ] **Step 8: Update cleanup tests for single-root scan**

Remove dual-root scan tests. Add `agent_review_*` glob test.

- [ ] **Step 9: Run the full test suite**

```bash
./scripts/sanity_tests.sh
```

Expected: all pass

- [ ] **Step 10: Commit**

```bash
git add scripts/sanity_tests.sh
git commit -m "test: rewrite sanity_tests for renamed files, file injection, preflight checks"
```

---

## Task 19: Update `examples/example-session/` — rename findings files

**Files:**
- Rename: `examples/example-session/v1.findings.yaml` → `examples/example-session/v1.review-comments.yaml`
- Rename: `examples/example-session/v2.findings.yaml` → `examples/example-session/v2.review-comments.yaml`
- Modify: internal yaml keys

- [ ] **Step 1: Rename the files**

```bash
git mv examples/example-session/v1.findings.yaml examples/example-session/v1.review-comments.yaml
git mv examples/example-session/v2.findings.yaml examples/example-session/v2.review-comments.yaml
```

- [ ] **Step 2: Update yaml keys inside the files**

In both files, change the top-level `findings:` key to `review_comments:`.

- [ ] **Step 3: Update dispositions files**

In `v1.dispositions.yaml` and `v2.dispositions.yaml`, change `total_findings:` to `total_review_comments:`.

- [ ] **Step 4: Update `examples/example-session/README.md` if it references old names**

- [ ] **Step 5: Commit**

```bash
git add examples/example-session/
git commit -m "refactor: example-session uses review-comments naming + total_review_comments"
```

---

## Task 20: Final integration verification

**Files:**
- None (verification only)

- [ ] **Step 1: Run sanity tests**

```bash
./scripts/sanity_tests.sh
```

Expected: all tests pass.

- [ ] **Step 2: Grep for stale "findings" literals that should have been renamed**

```bash
grep -rn "findings" scripts/ prompts/ --include="*.py" --include="*.sh" --include="*.md" | grep -v "finding_id" | grep -v "review-comments" | grep -v "sanity_tests"
```

Expected: no hits except `finding_id` references (which stay unchanged) and this grep command itself.

- [ ] **Step 3: Grep for stale `total_findings` in yaml-handling code**

```bash
grep -rn "total_findings" scripts/ prompts/
```

Expected: zero hits.

- [ ] **Step 4: Verify all scripts have +x and correct shebang**

```bash
for f in scripts/*.sh scripts/*.py; do
  [ -x "$f" ] || echo "NOT EXECUTABLE: $f"
  head -1 "$f"
done
```

- [ ] **Step 5: Verify no `.plan/sessions` fallback logic remains**

```bash
grep -rn "\.plan/sessions" scripts/ SKILL.md README.md pitfalls.md
```

Expected: zero hits (or only in a "legacy warning" context in preflight).

- [ ] **Step 6: Commit any final fixups if needed**

```bash
git status
# If clean: done
# If changes: git add -A && git commit -m "fix: final integration cleanup"
```

---

## Execution Notes

- Tasks 1-9 are the core rename + file-injection changes and can be done in sequence.
- Tasks 10-13 are the startup-path rewrites (preflight, init_session, prereview_boot, cleanup).
- Tasks 14-17 are documentation updates.
- Task 18 (sanity_tests rewrite) is the largest single task and depends on all prior tasks.
- Task 19-20 are finalization and verification.
- Breaking change: after this plan ships, DAR will refuse to run in projects without spec-anchor. A migration guide should accompany the release (out of scope for this plan).
