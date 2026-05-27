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
