#!/usr/bin/env bash
# Close review panes left behind by previous sessions on the same Claude main terminal
# and the same workspace. Only closes panes the registry proves we own. Normal path
# closes done/idle; TTL path force-closes working/blocked panes whose session directory
# mtime is older than DAR_PANE_TTL_SECS (default 7200s = 2h) — the only available
# heuristic for "Codex hung mid-review", since herdr doesn't expose last-activity time.
#
# Scans both the current SESSIONS_ROOT (derived from SESSION_ROOT) and the legacy
# .plan/sessions root under the session's own recorded CWD. This covers the migration
# window where a repo gained spec-anchor between sessions: old sessions still live in
# .plan/sessions, new ones in .specanchor/dual-agent-review/sessions. Root discovery
# never reads $(pwd) and never depends on an exported SESSIONS_ROOT env var, so the
# script stays correct under set -u and when invoked with an absolute path from any
# working directory.
#
# Usage: cleanup_stale_panes.sh <session_root> <main_terminal> <workspace_id>
set -euo pipefail

fail() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }

SESSION_ROOT="${1:-}"
MAIN_TERMINAL="${2:-}"
WORKSPACE_ID="${3:-}"

[ -n "$SESSION_ROOT"  ] || fail "missing arg 1: session_root"
[ -n "$MAIN_TERMINAL" ] || fail "missing arg 2: main_terminal"
[ -n "$WORKSPACE_ID"  ] || fail "missing arg 3: workspace_id"

TTL_SECS="${DAR_PANE_TTL_SECS:-7200}"

scan_root() {
  local root="$1"
  [ -d "$root" ] || return 0

  find "$root" -mindepth 2 -maxdepth 2 -name session.meta -print 2>/dev/null | while IFS= read -r META; do
    [ -f "$META" ] || continue
    OLD_ROOT="$(dirname "$META")"
    [ "$OLD_ROOT" = "$SESSION_ROOT" ] && continue

    OLD_MAIN_TERMINAL="$(awk -F= '$1=="MAIN_TERMINAL"{print $2}' "$META")"
    OLD_WORKSPACE_ID="$(awk -F= '$1=="WORKSPACE_ID"{print $2}' "$META")"
    [ "$OLD_MAIN_TERMINAL" = "$MAIN_TERMINAL" ] || continue
    [ "$OLD_WORKSPACE_ID"  = "$WORKSPACE_ID"  ] || continue
    [ -f "$OLD_ROOT/.codex-pane-id"     ] || continue
    [ -f "$OLD_ROOT/.codex-terminal-id" ] || continue

    OLD_PANE="$(cat "$OLD_ROOT/.codex-pane-id")"
    OLD_TERMINAL="$(cat "$OLD_ROOT/.codex-terminal-id")"

    if ! OLD_INFO="$(herdr pane get "$OLD_PANE" 2>/dev/null)"; then
      rm -f "$OLD_ROOT/.codex-pane-id" "$OLD_ROOT/.codex-terminal-id"
      continue
    fi

    ACTUAL_TERMINAL="$(printf '%s' "$OLD_INFO" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["terminal_id"])')"
    [ "$ACTUAL_TERMINAL" = "$OLD_TERMINAL" ] || continue

    STATUS="$(printf '%s' "$OLD_INFO" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"].get("agent_status", "unknown"))')"
    REASON=""
    case "$STATUS" in
      done|idle) REASON="AUTO_CLOSED_STALE" ;;
      *)
        AGE="$(python3 -c 'import os,sys,time; print(int(time.time() - os.path.getmtime(sys.argv[1])))' "$OLD_ROOT")"
        if [ "$AGE" -ge "$TTL_SECS" ]; then
          REASON="AUTO_CLOSED_STALE_TTL"
        else
          continue
        fi
        ;;
    esac

    herdr pane close "$OLD_PANE" >/dev/null
    rm -f "$OLD_ROOT/.codex-pane-id" "$OLD_ROOT/.codex-terminal-id"
    printf '[%s] %s pane=%s terminal=%s status=%s\n' \
      "$(date)" "$REASON" "$OLD_PANE" "$OLD_TERMINAL" "$STATUS" >> "$OLD_ROOT/session.log"
  done
}

CURRENT_ROOT="$(dirname "$SESSION_ROOT")"
scan_root "$CURRENT_ROOT"

OWN_META="$SESSION_ROOT/session.meta"
if [ -f "$OWN_META" ]; then
  OWN_CWD="$(awk -F= '$1=="CWD"{print $2}' "$OWN_META")"
  if [ -n "$OWN_CWD" ]; then
    LEGACY_ROOT="$OWN_CWD/.plan/sessions"
    if [ "$LEGACY_ROOT" != "$CURRENT_ROOT" ]; then
      scan_root "$LEGACY_ROOT"
    fi
  fi
fi
