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
warn_diag() { printf 'WARN: %s\n' "$*" >&2; }

SESSION_ROOT="${1:-}"
OUTPUT_PATH="${2:-}"
[ -n "$SESSION_ROOT" ] || fail "missing arg 1: session_root"
[ -n "$OUTPUT_PATH"  ] || fail "missing arg 2: output_path"

TOTAL_TIMEOUT=600
if [ "${3:-}" = "--total-timeout" ]; then
  TOTAL_TIMEOUT="${4:-$TOTAL_TIMEOUT}"
fi

CODEX_PANE="$(cat "$SESSION_ROOT/.codex-pane-id")"
POLL_INTERVAL=120  # seconds per agent-status wait cycle (lowered from 300: v0.6.7 done detection is more reliable)
GRACE_SECS=10      # after "done" fires, tolerate this much fs-flush / event lead time (lowered from 20: v0.6.7 fixes transcript viewer false idle)
                   # before the output file must appear (see done-handling below)

# Current agent_status for the Codex pane ("working"/"done"/"idle"/...), or
# "unknown" when herdr is unreachable or returns unparseable JSON.
codex_agent_status() {
  local info
  info="$(herdr pane get "$CODEX_PANE" 2>/dev/null)" || { printf 'unknown'; return; }
  printf '%s' "$info" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"].get("agent_status", "unknown"))' 2>/dev/null || printf 'unknown'
}

capture_failure_diagnostics() {
  local status="$1" reason="$2"
  local diag="$SESSION_ROOT/wait-failure-$(date +%Y%m%d-%H%M%S).diag"
  {
    printf '=== DAR wait failure diagnostics ===\n'
    printf 'timestamp: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'reason: %s\n' "$reason"
    printf 'agent_status: %s\n' "$status"
    printf 'expected_output: %s\n' "$OUTPUT_PATH"
    printf 'elapsed: %ss\n' "$ELAPSED"
    printf '\n=== herdr pane get ===\n'
    herdr pane get "$CODEX_PANE" 2>&1 || printf '(unavailable)\n'
    printf '\n=== pane read --source visible (last 40 lines) ===\n'
    herdr pane read "$CODEX_PANE" --source visible --lines 40 --format text 2>&1 || printf '(unavailable)\n'
    printf '\n=== pane read --source recent (last 80 lines) ===\n'
    herdr pane read "$CODEX_PANE" --source recent --lines 80 --format text 2>&1 || printf '(unavailable)\n'
    printf '\n=== session files ===\n'
    ls -la "$SESSION_ROOT/" 2>&1
  } > "$diag" 2>&1
  printf '%s' "$diag"
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

  # Short agent-status wait. Exit 0 = "done" reached; exit 1 = timeout (Codex
  # still working / herdr unreachable) — in which case we loop and re-check.
  WAIT_MS=$(( POLL_INTERVAL * 1000 ))
  if herdr wait agent-status "$CODEX_PANE" --status done --timeout "$WAIT_MS" >/dev/null 2>&1; then
    # "done" is a hint, not proof of completion: Codex sometimes ends its turn
    # without writing the deliverable (pitfalls.md §运行时). The output file is
    # the only authoritative success signal — grace-poll it for fs-flush / event
    # lead time before deciding.
    for _ in $(seq 1 "$GRACE_SECS"); do
      if [ -f "$OUTPUT_PATH" ] && [ -s "$OUTPUT_PATH" ]; then
        printf 'file_ready\n'
        exit 0
      fi
      sleep 1
    done
    # Grace elapsed, still no file. If Codex resumed working it was a mid-task
    # turn boundary — keep waiting. Otherwise it stopped without output: break to
    # the final check + fail so the caller can resend instead of proceeding on a
    # phantom success.
    [ "$(codex_agent_status)" = "working" ] || break
  fi

  ELAPSED=$(( ELAPSED + POLL_INTERVAL ))
done

# Final file check after loop exit.
if [ -f "$OUTPUT_PATH" ] && [ -s "$OUTPUT_PATH" ]; then
  printf 'file_ready\n'
  exit 0
fi

# Classify failure state
FINAL_STATUS="$(codex_agent_status)"
case "$FINAL_STATUS" in
  done)    FAIL_REASON="no_output_after_done" ;;
  unknown) FAIL_REASON="status_unknown" ;;
  idle)    FAIL_REASON="pane_idle_without_output" ;;
  *)       FAIL_REASON="stopped_without_output_status_${FINAL_STATUS}" ;;
esac

if ! herdr pane get "$CODEX_PANE" >/dev/null 2>&1; then
  FAIL_REASON="pane_unavailable"
fi

DIAG_PATH="$(capture_failure_diagnostics "$FINAL_STATUS" "$FAIL_REASON")"
warn_diag "diagnostics written to $DIAG_PATH"
fail "Codex $FAIL_REASON (pane=$CODEX_PANE, status=$FINAL_STATUS, waited>=${ELAPSED}s, expected=$OUTPUT_PATH, diagnostics=$DIAG_PATH)"
