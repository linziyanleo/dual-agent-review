#!/usr/bin/env bash
# Ensure Codex actually starts processing after a prompt is sent.
#
# After driver_send (send-text + Enter), Codex TUI may intercept the Enter
# with a "Create a plan?" prompt or similar interactive dialog, leaving Codex
# idle instead of working. This script:
#   1. Waits briefly for Codex to enter "working" state
#   2. If still idle/blocked, checks for known TUI prompts and dismisses them
#   3. Re-sends Enter and waits again
#   4. Repeats up to MAX_RETRIES times
#
# Usage: dismiss_codex_plan_prompt.sh <session_root>
set -euo pipefail

fail() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }

SESSION_ROOT="${1:-}"
[ -n "$SESSION_ROOT" ] || fail "missing arg 1: session_root"
[ -f "$SESSION_ROOT/.codex-pane-id" ] || fail "missing $SESSION_ROOT/.codex-pane-id"

CODEX_PANE="$(cat "$SESSION_ROOT/.codex-pane-id")"
MAX_RETRIES=3
WAIT_MS=3000

codex_agent_status() {
  local info
  info="$(herdr pane get "$CODEX_PANE" 2>/dev/null)" || { printf 'unknown'; return; }
  printf '%s' "$info" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"].get("agent_status","unknown"))' 2>/dev/null || printf 'unknown'
}

for attempt in $(seq 1 "$MAX_RETRIES"); do
  if herdr wait agent-status "$CODEX_PANE" --status working --timeout "$WAIT_MS" >/dev/null 2>&1; then
    printf 'codex_working\n'
    exit 0
  fi

  STATUS="$(codex_agent_status)"
  case "$STATUS" in
    working|done)
      printf 'codex_%s\n' "$STATUS"
      exit 0
      ;;
  esac

  VISIBLE="$(herdr pane read "$CODEX_PANE" --source visible --lines 80 --format text 2>/dev/null || true)"

  case "$VISIBLE" in
    *"Create a plan?"*"esc dismiss"*)
      herdr pane send-keys "$CODEX_PANE" esc
      printf '[%s] DISMISSED_CODEX_PLAN_PROMPT attempt=%s pane=%s\n' "$(date)" "$attempt" "$CODEX_PANE" >> "$SESSION_ROOT/session.log"
      sleep 1
      herdr pane send-keys "$CODEX_PANE" Enter
      ;;
    *)
      herdr pane send-keys "$CODEX_PANE" Enter
      printf '[%s] RESENT_ENTER attempt=%s status=%s pane=%s\n' "$(date)" "$attempt" "$STATUS" "$CODEX_PANE" >> "$SESSION_ROOT/session.log"
      ;;
  esac
done

STATUS="$(codex_agent_status)"
case "$STATUS" in
  working|done)
    printf 'codex_%s\n' "$STATUS"
    exit 0
    ;;
esac

printf '[%s] WARN: codex not working after %s retries, status=%s pane=%s\n' "$(date)" "$MAX_RETRIES" "$STATUS" "$CODEX_PANE" >> "$SESSION_ROOT/session.log"
printf 'codex_not_working\n'
exit 1
