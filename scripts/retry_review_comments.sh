#!/usr/bin/env bash
# Retry a failed Codex review-comments round exactly once. Caller decides when to invoke:
# usually right after validate_review_comments.py exits non-zero on a fresh review-comments file.
#
# Usage: retry_review_comments.sh <session_root> <round> <schema_error>
#   <schema_error> is the single-line error printed by validate_review_comments.py.
#
# Behaviour:
#   1. Delete the broken review-comments file (so downstream code can't accidentally read it).
#   2. Re-assert pane ownership.
#   3. Render prompts/review-comments-retry.md with OUTPUT_PATH + SCHEMA_ERROR.
#   4. send-text + Enter, then wait agent-status done.
#   5. Re-validate. If still broken, exit 1 — caller surfaces to the user.
#      Hard cap of 1 retry. We do not retry the retry.
set -euo pipefail

fail() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_skill_dir.sh"

SESSION_ROOT="${1:-}"
ROUND="${2:-}"
SCHEMA_ERROR="${3:-}"
[ -n "$SESSION_ROOT" ] || fail "missing arg 1: session_root"
[ -n "$ROUND" ]        || fail "missing arg 2: round"
[ -n "$SCHEMA_ERROR" ] || fail "missing arg 3: schema_error"
case "$ROUND" in ''|*[!0-9]*) fail "round must be a positive integer, got: $ROUND" ;; esac

OUTPUT_PATH="$SESSION_ROOT/v${ROUND}.review-comments.yaml"

# Step 1
rm -f "$OUTPUT_PATH"

# Step 2
"$SCRIPT_DIR/assert_pane_owned.sh" "$SESSION_ROOT"
CODEX_PANE="$(cat "$SESSION_ROOT/.codex-pane-id")"

# Step 3
TEMPLATE="$SKILL_DIR/prompts/review-comments-retry.md"
[ -f "$TEMPLATE" ] || fail "missing retry template: $TEMPLATE"
PROMPT="$("$SCRIPT_DIR/render_template.py" "$TEMPLATE" \
  "OUTPUT_PATH=$OUTPUT_PATH" \
  "SCHEMA_ERROR=$SCHEMA_ERROR")"

# Step 4
herdr pane send-text "$CODEX_PANE" "$PROMPT"
herdr pane send-keys "$CODEX_PANE" Enter
"$SCRIPT_DIR/wait_codex_done.sh" "$SESSION_ROOT" "$OUTPUT_PATH" >/dev/null

# Step 5
[ -f "$OUTPUT_PATH" ] || fail "Codex retry did not produce $OUTPUT_PATH"
if ! "$SCRIPT_DIR/validate_review_comments.py" "$OUTPUT_PATH"; then
  fail "retry produced review-comments file still failing schema validation; aborting (hard cap 1 retry)"
fi

printf 'retry succeeded; %s now valid\n' "$OUTPUT_PATH"
