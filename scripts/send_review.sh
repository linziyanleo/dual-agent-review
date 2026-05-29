#!/usr/bin/env bash
# Render and send a review prompt to the Codex pane for round N.
#   round 1 → prompts/codex-review-v1.md
#   round N≥2 → prompts/codex-review-vn.md
#
# Usage: send_review.sh <session_root> <round>
#
# The script asserts pane ownership, renders the template (no sed; render_template.py
# handles arbitrary characters), and sends text + Enter. It does NOT wait for done —
# the caller decides how long to wait.
set -euo pipefail

fail() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_skill_dir.sh"

SESSION_ROOT="${1:-}"
ROUND="${2:-}"
[ -n "$SESSION_ROOT" ] || fail "missing arg 1: session_root"
[ -n "$ROUND" ]        || fail "missing arg 2: round"
case "$ROUND" in ''|*[!0-9]*) fail "round must be a positive integer, got: $ROUND" ;; esac
[ "$ROUND" -ge 1 ]     || fail "round must be >= 1, got: $ROUND"

"$SCRIPT_DIR/assert_pane_owned.sh" "$SESSION_ROOT"

CODEX_PANE="$(cat "$SESSION_ROOT/.codex-pane-id")"
PLAN_PATH="$SESSION_ROOT/v${ROUND}.md"
OUTPUT_PATH="$SESSION_ROOT/v${ROUND}.review-comments.yaml"
[ -f "$PLAN_PATH" ] || fail "missing plan file: $PLAN_PATH"
[ -s "$SESSION_ROOT/spec-context.md" ] || fail "spec-context.md missing or empty — prereview_boot must produce non-empty output"

if [ "$ROUND" -eq 1 ]; then
  TEMPLATE="$SKILL_DIR/prompts/codex-review-v1.md"
  PROMPT="$("$SCRIPT_DIR/render_template.py" "$TEMPLATE" \
    "PLAN_PATH=$PLAN_PATH" \
    "OUTPUT_PATH=$OUTPUT_PATH" \
    "SPEC_CONTEXT_FILE=$SESSION_ROOT/spec-context.md")"
else
  TEMPLATE="$SKILL_DIR/prompts/codex-review-vn.md"
  PREV="$((ROUND - 1))"
  PREV_DISPO="$SESSION_ROOT/v${PREV}.dispositions.yaml"
  DIFF_PATH="$SESSION_ROOT/v${ROUND}.diff"
  [ -f "$PREV_DISPO" ] || fail "missing prev dispositions: $PREV_DISPO"
  [ -f "$DIFF_PATH"  ] || fail "missing diff: $DIFF_PATH"
  PROMPT="$("$SCRIPT_DIR/render_template.py" "$TEMPLATE" \
    "PLAN_PATH=$PLAN_PATH" \
    "PREV_DISPOSITION=$PREV_DISPO" \
    "DIFF_PATH=$DIFF_PATH" \
    "OUTPUT_PATH=$OUTPUT_PATH")"
fi

herdr pane send-text "$CODEX_PANE" "$PROMPT"
herdr pane send-keys "$CODEX_PANE" Enter
printf 'sent round=%s output=%s\n' "$ROUND" "$OUTPUT_PATH"
