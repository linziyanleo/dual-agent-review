#!/usr/bin/env bash
# Split a Codex review pane and wait for its prompt. Appends CODEX_PANE / CODEX_TERMINAL
# to $SESSION_ROOT/session.env using the same POSIX single-quote format.
#
# Usage: spawn_codex.sh <session_root>
set -euo pipefail

fail() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_skill_dir.sh"

SESSION_ROOT="${1:-}"
[ -n "$SESSION_ROOT" ] || fail "missing arg 1: session_root"
[ -f "$SESSION_ROOT/session.env" ] || fail "missing $SESSION_ROOT/session.env (run init_session.sh first)"

# Load fixed-name vars so we know MAIN_PANE / CWD.
set -a; . "$SESSION_ROOT/session.env"; set +a

shquote() {
  local v="$1"
  case "$v" in *$'\n'*) fail "value contains newline" ;; esac
  printf "'%s'" "${v//\'/\'\\\'\'}"
}

# IMPORTANT: split off $MAIN_PANE (= $HERDR_PANE_ID at session init time), not the
# currently focused pane — focused pane can change while this skill runs.
SPLIT_JSON="$(herdr pane split "$MAIN_PANE" --direction right --no-focus --cwd "$CWD")"
NEW="$(printf '%s' "$SPLIT_JSON"          | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')"
NEW_TERMINAL="$(printf '%s' "$SPLIT_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["terminal_id"])')"

printf '%s\n' "$NEW"          > "$SESSION_ROOT/.codex-pane-id"
printf '%s\n' "$NEW_TERMINAL" > "$SESSION_ROOT/.codex-terminal-id"

# Append to both files. session.meta is human-readable; session.env is the source of truth.
{
  printf 'CODEX_PANE=%s\n'     "$NEW"
  printf 'CODEX_TERMINAL=%s\n' "$NEW_TERMINAL"
} >> "$SESSION_ROOT/session.meta"
{
  printf 'CODEX_PANE=%s\n'     "$(shquote "$NEW")"
  printf 'CODEX_TERMINAL=%s\n' "$(shquote "$NEW_TERMINAL")"
} >> "$SESSION_ROOT/session.env"

herdr pane rename "$NEW" "codex-review:${SESSION_ID}" >/dev/null
herdr pane run    "$NEW" "codex" >/dev/null

# Wait for Codex's prompt glyph (U+203A, '›'). Single waiter, no ASCII '>' fallback —
# the ASCII fallback used to false-trigger on bash prompts in panes where codex hadn't started.
herdr wait output "$NEW" --match "›" --timeout 60000 >/dev/null \
  || fail "Codex did not show its prompt within 60s; pane=$NEW"

printf '%s\n' "$NEW"
