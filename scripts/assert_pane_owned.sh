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

INFO="$(herdr pane get "$CODEX_PANE" 2>/dev/null)" \
  || fail "herdr pane get $CODEX_PANE failed; Codex pane vanished?"

ACTUAL="$(printf '%s' "$INFO" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["terminal_id"])')"
[ "$ACTUAL" = "$CODEX_TERMINAL" ] \
  || fail "Codex pane $CODEX_PANE now points at terminal $ACTUAL (expected $CODEX_TERMINAL); refusing to send input"
