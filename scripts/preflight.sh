#!/usr/bin/env bash
# Hard preflight checks for dual-agent-review. Any failure → exit 1 + stderr diagnostic.
# Replaces the inline check block at the top of SKILL.md.
set -euo pipefail

fail() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

[ "${HERDR_ENV:-}" = "1" ]   || fail "not running inside herdr (HERDR_ENV != 1)"
[ -n "${HERDR_PANE_ID:-}" ]  || fail "HERDR_PANE_ID not injected; cannot locate Claude main pane"

command -v herdr   >/dev/null 2>&1 || fail "herdr CLI not on PATH"
command -v codex   >/dev/null 2>&1 || fail "codex CLI not on PATH"
command -v python3 >/dev/null 2>&1 || fail "python3 not on PATH"

python3 -c 'import yaml' >/dev/null 2>&1 || fail "PyYAML not importable (pip install pyyaml)"

# herdr integration status check — degrade to warn (not fatal) per skill convention.
INTEG_STATUS="$(herdr integration status 2>&1 || true)"
printf '%s\n' "$INTEG_STATUS" | grep -q 'codex: current'  || warn "codex integration may be missing/stale; agent_status detection will degrade"
printf '%s\n' "$INTEG_STATUS" | grep -q 'claude: current' || warn "claude integration may be missing/stale"

printf 'preflight OK\n'
