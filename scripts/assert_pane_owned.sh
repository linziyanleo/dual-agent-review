#!/usr/bin/env bash
# Verify the Codex pane registered in $SESSION_ROOT still points at the terminal
# we originally split. Refuses to proceed if id was compacted onto another terminal.
#
# Usage: assert_pane_owned.sh <session_root>
# stdout: nothing on success. Two lines exported via stdout would be brittle here,
#         so the caller should re-read .codex-pane-id / .codex-terminal-id itself.
set -euo pipefail

fail() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }

SESSION_ROOT="${1:-}"
[ -n "$SESSION_ROOT" ] || fail "missing arg 1: session_root"
[ -f "$SESSION_ROOT/.codex-pane-id"     ] || fail "missing $SESSION_ROOT/.codex-pane-id"
[ -f "$SESSION_ROOT/.codex-terminal-id" ] || fail "missing $SESSION_ROOT/.codex-terminal-id"

CODEX_PANE="$(cat "$SESSION_ROOT/.codex-pane-id")"
CODEX_TERMINAL="$(cat "$SESSION_ROOT/.codex-terminal-id")"

if ! INFO="$(herdr pane get "$CODEX_PANE" 2>/dev/null)"; then
  # Compact pane id may have shifted after another pane in the same workspace
  # was closed (herdr re-numbers panes). Resolve via the stable terminal_id.
  WORKSPACE="$(cat "$SESSION_ROOT/session.meta" | awk -F= '$1=="WORKSPACE_ID"{print $2}')"
  [ -n "$WORKSPACE" ] || fail "herdr pane get $CODEX_PANE failed and WORKSPACE_ID not in session.meta"
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
    || fail "herdr pane get $CODEX_PANE failed and terminal $CODEX_TERMINAL not found in workspace $WORKSPACE; Codex pane genuinely gone"
  # Update the saved compact id so subsequent calls don't repeat this lookup.
  printf '%s\n' "$RESOLVED" > "$SESSION_ROOT/.codex-pane-id"
  CODEX_PANE="$RESOLVED"
  INFO="$(herdr pane get "$CODEX_PANE" 2>/dev/null)" \
    || fail "herdr pane get $CODEX_PANE failed even after resolving from terminal_id"
fi

ACTUAL="$(printf '%s' "$INFO" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["terminal_id"])')"
[ "$ACTUAL" = "$CODEX_TERMINAL" ] \
  || fail "Codex pane $CODEX_PANE now points at terminal $ACTUAL (expected $CODEX_TERMINAL); refusing to send input"
