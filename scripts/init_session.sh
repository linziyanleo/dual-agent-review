#!/usr/bin/env bash
# Initialize a new review session.
# stdout: raw SESSION_ROOT path (single line, no prefix), so the caller can:
#   SESSION_ROOT=$("$SKILL_DIR/scripts/init_session.sh")
#   set -a; . "$SESSION_ROOT/session.env"; set +a
# session.env contains POSIX shell-quoted KEY='value' lines. Caller never eval-s anything.
set -euo pipefail

fail() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }

SKILL_DIR="${SKILL_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
REVIEW_MODE="${REVIEW_MODE:-codex}"

# Use stderr for any progress noise; stdout is reserved for SESSION_ROOT.

if [ "$REVIEW_MODE" = "subagent" ]; then
  MAIN_TERMINAL="subagent-virtual"
  WORKSPACE_ID="subagent-virtual"
  TAB_ID="subagent-virtual"
elif [ -n "${HERDR_PANE_ID:-}" ]; then
  MAIN_INFO="$(herdr pane get "$HERDR_PANE_ID")"
  MAIN_TERMINAL="$(printf '%s' "$MAIN_INFO" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["terminal_id"])')"
  WORKSPACE_ID="$(printf '%s' "$MAIN_INFO"  | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["workspace_id"])')"
  TAB_ID="$(printf '%s' "$MAIN_INFO"        | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["tab_id"])')"
else
  # Auto-detect via herdr agent list
  DETECTED="$("$SKILL_DIR/scripts/resolve_herdr_env.sh" 2>&2)" || fail "HERDR_PANE_ID not set and auto-detection failed"
  eval "$DETECTED"
  MAIN_INFO="$(herdr pane get "$HERDR_PANE_ID")"
  MAIN_TERMINAL="$(printf '%s' "$MAIN_INFO" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["terminal_id"])')"
  WORKSPACE_ID="$(printf '%s' "$MAIN_INFO"  | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["workspace_id"])')"
  TAB_ID="$(printf '%s' "$MAIN_INFO"        | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["tab_id"])')"
fi

# Sanitize a single value for embedding inside POSIX single-quoted strings.
# Strategy: only reject NUL bytes and newlines (neither can be safely represented inside
# a single-quoted POSIX expression). Everything else — spaces, single quotes, $, `, etc. —
# is handled by single-quote wrapping plus '\'' escaping.
shquote() {
  local v="$1"
  case "$v" in
    *$'\n'*) fail "value contains newline: $(printf '%s' "$v" | head -c 80)" ;;
  esac
  # POSIX single-quote escape: ' -> '\''
  printf "'%s'" "${v//\'/\'\\\'\'}"
}

if [ "$REVIEW_MODE" = "subagent" ]; then
  SAFE_MAIN_PANE="subagent"
else
  SAFE_MAIN_PANE="$(printf '%s' "${HERDR_PANE_ID:-auto}" | tr -c 'A-Za-z0-9_.-' '-')"
fi
RAND_SUFFIX="$(python3 -c 'import secrets; print(secrets.token_hex(2))')"
SESSION_ID="agent_review_$(date +%Y%m%d-%H%M%S)-pane-${SAFE_MAIN_PANE}-${RAND_SUFFIX}"

CWD="$(pwd)"

# Hard spec-anchor dependency: sessions live under .specanchor/tasks/
SESSIONS_ROOT="$CWD/.specanchor/tasks"
SESSION_ROOT="$SESSIONS_ROOT/${SESSION_ID}"
mkdir -p "$SESSION_ROOT"

# Human-readable meta (the old format SKILL.md used to write).
{
  printf 'SESSION_ID=%s\n'     "$SESSION_ID"
  printf 'SESSION_ROOT=%s\n'   "$SESSION_ROOT"
  printf 'SESSIONS_ROOT=%s\n'  "$SESSIONS_ROOT"
  printf 'MAIN_PANE=%s\n'      "${HERDR_PANE_ID:-subagent-virtual}"
  printf 'MAIN_TERMINAL=%s\n'  "$MAIN_TERMINAL"
  printf 'WORKSPACE_ID=%s\n'   "$WORKSPACE_ID"
  printf 'TAB_ID=%s\n'         "$TAB_ID"
  printf 'CWD=%s\n'            "$CWD"
  printf 'SA_SKILL_DIR=%s\n'  "${SA_SKILL_DIR:-}"
  printf 'REVIEW_MODE=%s\n'   "$REVIEW_MODE"
} > "$SESSION_ROOT/session.meta"

# Shell-loadable env file. Variable names are FIXED here; only values come from herdr.
{
  printf 'SESSION_ID=%s\n'     "$(shquote "$SESSION_ID")"
  printf 'SESSION_ROOT=%s\n'   "$(shquote "$SESSION_ROOT")"
  printf 'SESSIONS_ROOT=%s\n'  "$(shquote "$SESSIONS_ROOT")"
  printf 'MAIN_PANE=%s\n'      "$(shquote "${HERDR_PANE_ID:-subagent-virtual}")"
  printf 'MAIN_TERMINAL=%s\n'  "$(shquote "$MAIN_TERMINAL")"
  printf 'WORKSPACE_ID=%s\n'   "$(shquote "$WORKSPACE_ID")"
  printf 'TAB_ID=%s\n'         "$(shquote "$TAB_ID")"
  printf 'CWD=%s\n'            "$(shquote "$CWD")"
  printf 'SA_SKILL_DIR=%s\n'  "$(shquote "${SA_SKILL_DIR:-}")"
  printf 'REVIEW_MODE=%s\n'   "$(shquote "$REVIEW_MODE")"
} > "$SESSION_ROOT/session.env"

if [ "$REVIEW_MODE" = "subagent" ]; then
  printf '[]\n' > "$SESSION_ROOT/workspace-panes.before.json"
else
  herdr pane list --workspace "$WORKSPACE_ID" > "$SESSION_ROOT/workspace-panes.before.json"
fi

# stdout = single line, raw path, no prefix.
printf '%s\n' "$SESSION_ROOT"
