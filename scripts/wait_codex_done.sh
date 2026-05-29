#!/usr/bin/env bash
# Wait for Codex to finish by polling two signals in parallel:
#   1. herdr agent-status transitions to "done" (the happy path)
#   2. The expected output file appears on disk (fallback when stop hook fails)
#
# When the stop hook returns invalid JSON, herdr never flips agent_status to
# "done" and the old single `herdr wait agent-status --timeout 600000` blocks
# for the full 10 minutes even though Codex already wrote its output.
#
# Usage: wait_codex_done.sh <session_root> <output_path> [--total-timeout SECS]
#   Default total timeout: 600 seconds (10 min) — but this is a SOFT cap: once it
#   elapses we only abort if Codex is no longer "working". While agent-status
#   still reports "working" we keep waiting, so a slow-but-alive Codex is never
#   killed mid-task (the TTL reaper in cleanup_stale_panes.sh is the hard
#   backstop for a genuinely stuck pane).
#   Each polling cycle uses a 300s agent-status wait so file-based early exit
#   never lags more than ~300s behind the actual write.
set -euo pipefail

fail() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }

SESSION_ROOT="${1:-}"
OUTPUT_PATH="${2:-}"
[ -n "$SESSION_ROOT" ] || fail "missing arg 1: session_root"
[ -n "$OUTPUT_PATH"  ] || fail "missing arg 2: output_path"

TOTAL_TIMEOUT=600
if [ "${3:-}" = "--total-timeout" ]; then
  TOTAL_TIMEOUT="${4:-$TOTAL_TIMEOUT}"
fi

CODEX_PANE="$(cat "$SESSION_ROOT/.codex-pane-id")"
POLL_INTERVAL=300  # seconds per agent-status wait cycle

# Current agent_status for the Codex pane ("working"/"done"/"idle"/...), or
# "unknown" when herdr is unreachable or returns unparseable JSON.
codex_agent_status() {
  local info
  info="$(herdr pane get "$CODEX_PANE" 2>/dev/null)" || { printf 'unknown'; return; }
  printf '%s' "$info" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"].get("agent_status", "unknown"))' 2>/dev/null || printf 'unknown'
}

ELAPSED=0
# Soft timeout: stay in the loop while under TOTAL_TIMEOUT, OR while Codex is
# still actively working past the cap (short-circuit avoids the herdr call until
# the cap is actually reached).
while [ "$ELAPSED" -lt "$TOTAL_TIMEOUT" ] || [ "$(codex_agent_status)" = "working" ]; do
  # Check file first — zero-cost and catches the hook-failure case instantly
  # on subsequent iterations.
  if [ -f "$OUTPUT_PATH" ] && [ -s "$OUTPUT_PATH" ]; then
    printf 'file_ready\n'
    exit 0
  fi

  # Short agent-status wait. Exit 0 = status reached; exit 1 = timeout.
  WAIT_MS=$(( POLL_INTERVAL * 1000 ))
  if herdr wait agent-status "$CODEX_PANE" --status done --timeout "$WAIT_MS" >/dev/null 2>&1; then
    printf 'agent_done\n'
    exit 0
  fi

  ELAPSED=$(( ELAPSED + POLL_INTERVAL ))
done

# Final file check after total timeout.
if [ -f "$OUTPUT_PATH" ] && [ -s "$OUTPUT_PATH" ]; then
  printf 'file_ready\n'
  exit 0
fi

fail "Codex stopped without producing output (pane=$CODEX_PANE, status=$(codex_agent_status), waited >=${TOTAL_TIMEOUT}s, expected=$OUTPUT_PATH)"
