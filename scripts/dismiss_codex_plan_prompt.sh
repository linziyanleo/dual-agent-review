#!/usr/bin/env bash
# Dismiss Codex TUI's Plan-mode suggestion only when the exact prompt is visible.
#
# Usage: dismiss_codex_plan_prompt.sh <session_root>
set -euo pipefail

fail() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }

SESSION_ROOT="${1:-}"
[ -n "$SESSION_ROOT" ] || fail "missing arg 1: session_root"
[ -f "$SESSION_ROOT/.codex-pane-id" ] || fail "missing $SESSION_ROOT/.codex-pane-id"

CODEX_PANE="$(cat "$SESSION_ROOT/.codex-pane-id")"
herdr wait output "$CODEX_PANE" --match "Create a plan?" --source visible --lines 80 --timeout 1000 >/dev/null 2>&1 || true
VISIBLE="$(herdr pane read "$CODEX_PANE" --source visible --lines 80 --format text)"

case "$VISIBLE" in
  *"Create a plan?"*"Plan mode"*"esc dismiss"*)
    herdr pane send-keys "$CODEX_PANE" esc Enter
    printf '[%s] DISMISSED_CODEX_PLAN_PROMPT pane=%s\n' "$(date)" "$CODEX_PANE" >> "$SESSION_ROOT/session.log"
    printf 'dismissed_codex_plan_prompt\n'
    ;;
esac
