#!/usr/bin/env bash
# Split a Codex review pane and wait for its prompt. Single Step 2 entrypoint.
# Sources the detected terminal driver and delegates to driver_spawn.
# Writes .codex-pane-id, .codex-terminal-id, and appends to session.env/meta.
#
# Usage: spawn_codex.sh <session_root>
set -euo pipefail

fail() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_skill_dir.sh"

SESSION_ROOT="${1:-}"
[ -n "$SESSION_ROOT" ] || fail "missing arg 1: session_root"
[ -f "$SESSION_ROOT/session.env" ] || fail "missing $SESSION_ROOT/session.env (run init_session.sh first)"

set -a; . "$SESSION_ROOT/session.env"; set +a

shquote() {
  local v="$1"
  case "$v" in *$'\n'*) fail "value contains newline" ;; esac
  printf "'%s'" "${v//\'/\'\\\'\'}"
}

# Detect and source terminal driver
TERMINAL_DRIVER="$("$SKILL_DIR/scripts/detect_driver.sh")"
. "$SKILL_DIR/scripts/drivers/${TERMINAL_DRIVER}.sh"

# driver_spawn outputs "pane_id\nterminal_id" on stdout
SPAWN_OUT="$(driver_spawn "codex" "$CWD" "$MAIN_PANE" "$SESSION_ROOT")"
NEW="$(printf '%s' "$SPAWN_OUT" | head -1)"
NEW_TERMINAL="$(printf '%s' "$SPAWN_OUT" | tail -1)"

[ -n "$NEW" ]          || fail "driver_spawn returned empty pane_id"
[ -n "$NEW_TERMINAL" ] || fail "driver_spawn returned empty terminal_id"

# Write session files (single place for all drivers)
printf '%s\n' "$NEW"          > "$SESSION_ROOT/.codex-pane-id"
printf '%s\n' "$NEW_TERMINAL" > "$SESSION_ROOT/.codex-terminal-id"

{
  printf 'CODEX_PANE=%s\n'     "$NEW"
  printf 'CODEX_TERMINAL=%s\n' "$NEW_TERMINAL"
} >> "$SESSION_ROOT/session.meta"
{
  printf 'CODEX_PANE=%s\n'     "$(shquote "$NEW")"
  printf 'CODEX_TERMINAL=%s\n' "$(shquote "$NEW_TERMINAL")"
} >> "$SESSION_ROOT/session.env"

printf '%s\n' "$NEW"
