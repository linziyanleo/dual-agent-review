#!/usr/bin/env bash
# Verify the Codex pane registered in $SESSION_ROOT still exists and matches
# the terminal we originally split. Updates .codex-pane-id if the compact id
# shifted due to pane compaction.
#
# Primary path uses herdr agent get with terminal_id for stable lookup (v0.6.5+).
# Falls back to pane list scanning for older herdr versions.
#
# Usage: assert_pane_owned.sh <session_root>
set -euo pipefail

fail() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }

SESSION_ROOT="${1:-}"
[ -n "$SESSION_ROOT" ] || fail "missing arg 1: session_root"
[ -f "$SESSION_ROOT/.codex-pane-id"     ] || fail "missing $SESSION_ROOT/.codex-pane-id"
[ -f "$SESSION_ROOT/.codex-terminal-id" ] || fail "missing $SESSION_ROOT/.codex-terminal-id"

CODEX_PANE="$(cat "$SESSION_ROOT/.codex-pane-id")"
CODEX_TERMINAL="$(cat "$SESSION_ROOT/.codex-terminal-id")"

# Primary: direct terminal_id lookup via herdr agent get (stable, no pane id needed)
if INFO="$(herdr agent get "$CODEX_TERMINAL" 2>/dev/null)"; then
  RESOLVED="$(printf '%s' "$INFO" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["agent"]["pane_id"])')"
  if [ "$RESOLVED" != "$CODEX_PANE" ]; then
    printf '%s\n' "$RESOLVED" > "$SESSION_ROOT/.codex-pane-id"
    CODEX_PANE="$RESOLVED"
  fi
else
  # Fallback: pane list + terminal_id scan
  WORKSPACE="$(awk -F= '$1=="WORKSPACE_ID"{print $2}' "$SESSION_ROOT/session.meta")"
  [ -n "$WORKSPACE" ] || fail "herdr agent get $CODEX_TERMINAL failed and WORKSPACE_ID not in session.meta"
  RESOLVED="$(herdr pane list --workspace "$WORKSPACE" 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
for p in data['result']['panes']:
    if p['terminal_id'] == '$CODEX_TERMINAL':
        print(p['pane_id'])
        break
")"
  [ -n "$RESOLVED" ] \
    || fail "Codex terminal $CODEX_TERMINAL not found in workspace $WORKSPACE; pane genuinely gone"
  printf '%s\n' "$RESOLVED" > "$SESSION_ROOT/.codex-pane-id"
  CODEX_PANE="$RESOLVED"
  INFO="$(herdr pane get "$CODEX_PANE" 2>/dev/null)" \
    || fail "herdr pane get $CODEX_PANE failed even after resolving from terminal_id"
fi

# foreground_cwd drift warning (once per session to avoid noise)
if [ ! -f "$SESSION_ROOT/.cwd-drift-warned" ]; then
  ACTUAL_CWD="$(printf '%s' "$INFO" | python3 -c '
import sys,json
d = json.load(sys.stdin)
r = d.get("result",{})
pane = r.get("pane", r.get("agent", {}))
print(pane.get("foreground_cwd", ""))
' 2>/dev/null || true)"
  EXPECTED_CWD="$(awk -F= '$1=="CWD"{print $2}' "$SESSION_ROOT/session.meta")"
  if [ -n "$ACTUAL_CWD" ] && [ -n "$EXPECTED_CWD" ] && [ "$ACTUAL_CWD" != "$EXPECTED_CWD" ]; then
    printf 'WARN: Codex pane foreground_cwd=%s differs from session CWD=%s\n' "$ACTUAL_CWD" "$EXPECTED_CWD" >&2
    touch "$SESSION_ROOT/.cwd-drift-warned"
  fi
fi
