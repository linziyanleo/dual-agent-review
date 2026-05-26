#!/usr/bin/env bash
# Close the Codex pane for this session if it's safe to (status done/idle).
# Working/blocked panes are left open so the user can inspect — pass --force to
# close regardless of status (used by Step 11 manual cleanup and the TTL reaper).
#
# Usage: close_codex_pane.sh <session_root> [--force]
set -euo pipefail

fail() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SESSION_ROOT="${1:-}"
[ -n "$SESSION_ROOT" ] || fail "missing arg 1: session_root"

FORCE=0
if [ "${2:-}" = "--force" ]; then
  FORCE=1
elif [ -n "${2:-}" ]; then
  fail "unexpected arg 2: $2 (expected --force or nothing)"
fi

# If registry files are gone we have nothing to close (already cleaned up).
if [ ! -f "$SESSION_ROOT/.codex-pane-id" ] || [ ! -f "$SESSION_ROOT/.codex-terminal-id" ]; then
  printf 'no Codex pane registered; nothing to close\n'
  exit 0
fi

"$SCRIPT_DIR/assert_pane_owned.sh" "$SESSION_ROOT"

CODEX_PANE="$(cat "$SESSION_ROOT/.codex-pane-id")"
CODEX_TERMINAL="$(cat "$SESSION_ROOT/.codex-terminal-id")"
INFO="$(herdr pane get "$CODEX_PANE")"
STATUS="$(printf '%s' "$INFO" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"].get("agent_status", "unknown"))')"

if [ "$FORCE" -eq 0 ]; then
  case "$STATUS" in
    working|blocked)
      printf 'WARN: Codex pane status=%s; leaving open for manual inspection\n' "$STATUS" >&2
      ;;
    *)
      herdr pane close "$CODEX_PANE" >/dev/null
      rm -f "$SESSION_ROOT/.codex-pane-id" "$SESSION_ROOT/.codex-terminal-id"
      printf '[%s] CLOSED pane=%s terminal=%s status=%s\n' \
        "$(date)" "$CODEX_PANE" "$CODEX_TERMINAL" "$STATUS" >> "$SESSION_ROOT/session.log"
      printf 'closed pane=%s\n' "$CODEX_PANE"
      ;;
  esac
else
  herdr pane close "$CODEX_PANE" >/dev/null
  rm -f "$SESSION_ROOT/.codex-pane-id" "$SESSION_ROOT/.codex-terminal-id"
  printf '[%s] FORCE_CLOSED pane=%s terminal=%s status=%s\n' \
    "$(date)" "$CODEX_PANE" "$CODEX_TERMINAL" "$STATUS" >> "$SESSION_ROOT/session.log"
  printf 'force-closed pane=%s\n' "$CODEX_PANE"
fi

# Snapshot workspace state for audit.
if [ -f "$SESSION_ROOT/session.env" ]; then
  WS="$(awk -F= '$1=="WORKSPACE_ID"{print $2}' "$SESSION_ROOT/session.meta")"
  [ -n "$WS" ] && herdr pane list --workspace "$WS" > "$SESSION_ROOT/workspace-panes.after.json" || true
fi
